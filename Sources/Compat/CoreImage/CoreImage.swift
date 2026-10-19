// CoreImage compat: a lazily evaluated CIImage graph with a CPU float evaluator (see CIRaster.swift), covering the
// filters upstream uses — Gaussian and motion blur, colour matrix/clamp/cube, blend-with-mask, colour burn/dodge,
// perspective transform, edge-preserving upsample — plus crop, clamp-to-extent, affine transforms and EXIF
// orientation. CIImage values are immutable and cheap to chain; pixels are only computed by `CIContext`.
//
// This is the portable floor of the effects backend chain. Vulkan/Skia/OpenCV implementations can replace individual
// nodes later behind `CIFilterBackend` without touching callers.

@_exported import CoreGraphics
import Foundation
import CompatSupport
import CoreVideo
import Dispatch
import Metal

// MARK: - Small value types

public struct CIVector: Sendable {
    public let values: [CGFloat]
    public var count: Int { values.count }
    public init(values: [CGFloat]) { self.values = values }
    public init(values: UnsafePointer<CGFloat>, count: Int) { self.values = Array(UnsafeBufferPointer(start: values, count: count)) }
    public init(x: CGFloat) { values = [x] }
    public init(x: CGFloat, y: CGFloat) { values = [x, y] }
    public init(x: CGFloat, y: CGFloat, z: CGFloat) { values = [x, y, z] }
    public init(x: CGFloat, y: CGFloat, z: CGFloat, w: CGFloat) { values = [x, y, z, w] }
    public init(cgPoint: CGPoint) { values = [cgPoint.x, cgPoint.y] }
    public init(cgRect: CGRect) { values = [cgRect.origin.x, cgRect.origin.y, cgRect.size.width, cgRect.size.height] }
    public subscript(index: Int) -> CGFloat { index < values.count ? values[index] : 0 }
    public var x: CGFloat { self[0] }
    public var y: CGFloat { self[1] }
    public var z: CGFloat { self[2] }
    public var w: CGFloat { self[3] }
    public var cgPointValue: CGPoint { CGPoint(x: x, y: y) }
    public var cgRectValue: CGRect { CGRect(x: x, y: y, width: z, height: w) }
}

public struct CIColor: Sendable, Equatable {
    public let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { self.red = red; self.green = green; self.blue = blue; self.alpha = alpha }
    public init(red: CGFloat, green: CGFloat, blue: CGFloat) { self.init(red: red, green: green, blue: blue, alpha: 1) }
    public init(cgColor: CGColor) { self.init(red: cgColor.red, green: cgColor.green, blue: cgColor.blue, alpha: cgColor.alpha) }
    public init?(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, colorSpace: CGColorSpace) {
        _ = colorSpace
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
    public static let clear = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
    public static let black = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
}

public struct CIFormat: Hashable, Sendable {
    let rawValue: Int
    public static let RGBA8 = CIFormat(rawValue: 0), BGRA8 = CIFormat(rawValue: 1), L8 = CIFormat(rawValue: 2)
    public static let RGBAf = CIFormat(rawValue: 3), A8 = CIFormat(rawValue: 4)
    /// Internal: 32-bit floats kept in an encoded (non-linear) space, for `CIContext.render(_:toBitmap:...)`.
    static let RGBAfEncoded = CIFormat(rawValue: 1003)
    /// Half-float working format on Apple; treated as float here.
    public static let RGBAh = CIFormat(rawValue: 5)
    /// 16-bit unsigned per channel (RAW dither path).
    public static let RGBA16 = CIFormat(rawValue: 6)
}

public let kCIInputImageKey = "inputImage"
public let kCIInputBackgroundImageKey = "inputBackgroundImage"
public let kCIInputMaskImageKey = "inputMaskImage"
public let kCIInputRadiusKey = "inputRadius"
public let kCIInputAngleKey = "inputAngle"
public let kCIInputIntensityKey = "inputIntensity"
public let kCIInputTransformKey = "inputTransform"
public let kCIInputCenterKey = "inputCenter"
public let kCIInputScaleKey = "inputScale"
public let kCIInputAspectRatioKey = "inputAspectRatio"

// MARK: - Graph

private let infiniteExtent = CGRect(x: -8_000_000, y: -8_000_000, width: 16_000_000, height: 16_000_000)

private struct Env { var linear: Bool; var gpu: VulkanRaster? = nil }

private indirect enum Node {
    case source(Raster, CGRect)
    /// A bitmap kept as it is until something reads it (RAW output): rendering it unchanged hands the bitmap back
    /// without the float round trip, which for a very large RAW would cost more memory than the image itself.
    case bitmap(CGImage)
    case color(CIColor)
    /// CIRandomGenerator: independent uniform values in [0, 1) for every channel of every pixel (alpha included), the
    /// same at the same place every time, over the whole plane.
    case random
    /// CILinearGradient: color0 at point0 to color1 at point1 along their line, constant beyond either end.
    case linearGradient(CGPoint, CIColor, CGPoint, CIColor)
    case crop(Node, CGRect)
    case clamp(Node)
    case unpremultiply(Node)
    /// CIMaximumComponent: each pixel's brightest color component in all three (gray), alpha kept.
    case maxComponent(Node)
    case alphaOne(Node, CGRect)
    case gaussian(Node, Double)
    case variableBlur(Node, Node, Double)
    case bloom(Node, Double, Double)          // radius, intensity
    case motion(Node, Double, Double)
    case matrix(Node, [[Float]], [Float])
    case colorClamp(Node, [Float], [Float])
    case cube(Node, Int, [Float])
    /// CIColorCubeWithColorSpace: the lookup reads and writes colors in its own space (linear or sRGB-encoded),
    /// whatever the context's working space.
    case cubeInSpace(Node, Int, [Float], linear: Bool)
    /// CIBlendWithMask family: input where the mask is on, background where it is off. `channel` is which part of the
    /// mask decides: 0 red (CIBlendWithRedMask), 3 alpha (CIBlendWithAlphaMask), 4 luminance (CIBlendWithMask).
    case blendMask(Node, Node, Node, Int)
    /// samplingNearest(): the same pixels, sampled without smoothing wherever they are transformed.
    case nearest(Node)
    /// Source-over: `top` composited over `bottom` (CIImage.composited(over:)).
    case over(Node, Node)
    /// CIAffineTile: the image transformed, then repeated across the plane with the transformed extent as the period.
    case tile(Node, CGAffineTransform)
    /// CIRadialGradient: color0 inside radius0 to color1 at radius1 around `center`, constant beyond either.
    case radialGradient(CGPoint, Double, CIColor, Double, CIColor)
    /// CIColorCurves: per-channel lookup (`table` holds r,g,b triples) over `domain`, applied to unpremultiplied sRGB.
    case curves(Node, [Float], ClosedRange<Double>)
    /// Separable PDF/W3C blend of source over backdrop (`mode` is the Core Image filter name).
    case separable(Node, Node, String)
    case transform(Node, CGAffineTransform)
    /// Target corners TL, TR, BR, BL in CI space; the source rectangle mapped onto them is `source` when given
    /// (CIPerspectiveTransformWithExtent's inputExtent), else the input's extent.
    case perspective(Node, [CGPoint], CGRect?)
    case upsample(guide: Node, small: Node, Double, Double)
    case processor(CIImageProcessorKernel.Type, [Node], [String: Any], CGRect)

    var extent: CGRect {
        switch self {
        case .source(_, let r): return r
        case .bitmap(let image): return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        case .color, .random, .clamp, .linearGradient, .radialGradient, .tile: return infiniteExtent
        case .crop(let n, let r): return n.extent.intersection(r)
        case .gaussian(let n, let s): return n.extent.isInfiniteLike ? n.extent : n.extent.insetBy(dx: -ceil(s * 3), dy: -ceil(s * 3))
        case .variableBlur(let n, _, let s): return n.extent.isInfiniteLike ? n.extent : n.extent.insetBy(dx: -ceil(s * 3), dy: -ceil(s * 3))
        case .bloom(let n, let r, _): return n.extent.isInfiniteLike ? n.extent : n.extent.insetBy(dx: -ceil(r * 3), dy: -ceil(r * 3))
        case .motion(let n, let r, _): return n.extent.isInfiniteLike ? n.extent : n.extent.insetBy(dx: -ceil(r * 3), dy: -ceil(r * 3))
        case .matrix(let n, _, _), .colorClamp(let n, _, _), .cube(let n, _, _), .cubeInSpace(let n, _, _, _): return n.extent
        case .blendMask(let n, let bg, _, _): return n.extent.union(bg.extent)
        case .curves(let n, _, _), .nearest(let n), .unpremultiply(let n), .maxComponent(let n): return n.extent
        case .alphaOne(let n, let rect): return n.extent.union(rect)
        case .over(let top, let bottom): return top.extent.union(bottom.extent)
        case .separable(let s, let b, _): return s.extent.union(b.extent)
        case .transform(let n, let t): return n.extent.applying(t)
        case .perspective(_, let pts, _):
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        case .upsample(let g, _, _, _): return g.extent
        case .processor(_, _, _, let r): return r
        }
    }

    /// Whether a transform of this image samples nearest pixels: samplingNearest() applied, possibly under a clamp or crop.
    var samplesNearest: Bool {
        switch self {
        case .nearest: return true
        case .clamp(let n), .crop(let n, _): return n.samplesNearest
        default: return false
        }
    }

    var isRegionalFilter: Bool {
        switch self {
        case .gaussian, .variableBlur: return true
        case .crop(let node, _): return node.isRegionalFilter
        default: return false
        }
    }

    // Count only connected pointwise operations, stopping once batching is worthwhile.
    private func graphOperationCount(_ limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        switch self {
        case .crop(let n, _):
            let count = n.graphOperationCount(limit)
            return count > 0 ? min(limit, count + 1) : 0
        case .matrix(let n, _, _), .colorClamp(let n, _, _), .unpremultiply(let n), .maxComponent(let n):
            return 1 + n.graphOperationCount(limit - 1)
        case .processor(_, let inputs, _, _) where inputs.count == 1:
            return 1 + inputs[0].graphOperationCount(limit - 1)
        case .over(let s, let b):
            let count = 1 + s.graphOperationCount(limit - 1)
            return count + b.graphOperationCount(limit - count)
        case .blendMask(let s, let b, let m, _):
            var count = 1 + s.graphOperationCount(limit - 1)
            count += b.graphOperationCount(limit - count)
            return count + m.graphOperationCount(limit - count)
        default: return 0
        }
    }

    /// An exact identity for a leaf whose pixels depend only on what the key records: retained source storage (by
    /// address, kept alive with the cached result so it cannot be reused), geometry, generators and blur radii. Equal
    /// keys always evaluate to the same pixels, so a cached leaf can stand in for evaluating it again.
    private func geometryLeafIdentity(domain: CGRect, region: CGRect, linear: Bool) -> (sources: [[Float]], key: [UInt64])? {
        var sources: [[Float]] = [], key: [UInt64] = []
        func rectangle(_ rect: CGRect) {
            key += [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)].map(\.bitPattern)
        }
        func color(_ value: CIColor) {
            key += [Double(value.red), Double(value.green), Double(value.blue), Double(value.alpha)].map(\.bitPattern)
        }
        func affine(_ transform: CGAffineTransform) {
            key += [Double(transform.a), Double(transform.b), Double(transform.c), Double(transform.d),
                    Double(transform.tx), Double(transform.ty)].map(\.bitPattern)
        }
        func visit(_ node: Node, depth: Int) -> Bool {
            guard depth < 64, key.count < 4096 else { return false }
            switch node {
            case .source(let raster, let extent):
                sources.append(raster.data)
                key.append(raster.data.withUnsafeBufferPointer {
                    $0.baseAddress.map { UInt64(UInt(bitPattern: UnsafeRawPointer($0))) } ?? 0
                })
                rectangle(raster.rect); rectangle(extent)
            case .nearest(let child):
                guard visit(child, depth: depth + 1) else { return false }
                key.append(1)
            case .clamp(let child):
                guard visit(child, depth: depth + 1) else { return false }
                key.append(2)
            case .crop(let child, let rect):
                guard visit(child, depth: depth + 1) else { return false }
                key.append(3); rectangle(rect)
            case .transform(let child, let transform):
                guard visit(child, depth: depth + 1) else { return false }
                key.append(4); affine(transform)
            case .color(let value):
                key.append(5); color(value)
            case .random:
                key.append(9)
            case .tile(let child, let transform):
                guard visit(child, depth: depth + 1) else { return false }
                key.append(6); affine(transform)
            case .over(let top, let bottom):
                guard visit(top, depth: depth + 1), visit(bottom, depth: depth + 1) else { return false }
                key.append(7)
            case .gaussian(let child, let sigma):
                guard visit(child, depth: depth + 1) else { return false }
                key.append(8); key.append(sigma.bitPattern)
            default: return false
            }
            return true
        }
        guard visit(self, depth: 0) else { return nil }
        key.append(linear ? 1 : 0)
        rectangle(domain); rectangle(region)
        return (sources, key)
    }

    /// Gaussian add_noise stays on the CPU twin: on Mesa (RADV, lavapipe) the shader's log/cos under the raster
    /// shader's float controls left pixels without noise or NaN, where NoisePixels.c adds tens of levels.
    private static func runsOnGPU(_ step: VulkanRasterStep) -> Bool {
        step.operation != 8 || step.parameters[1] == 0
    }

    private static func encodeProcessorStep(kernel: CIImageProcessorKernel.Type, arguments: [String: Any],
                                            region: CGRect, sourceIndex: Int = 0) -> VulkanRasterStep? {
        let outRect = region.integral
        let w = Int(outRect.width), h = Int(outRect.height)
        guard w > 0, h > 0 else { return nil }
        let inRect = kernel.roi(forInput: 0, arguments: arguments, outputRect: outRect).integral
        let inTex = MTLTexture(proxyWidth: max(1, Int(inRect.width)), height: max(1, Int(inRect.height)), usage: .shaderRead)
        let outTex = MTLTexture(proxyWidth: w, height: h, usage: .shaderWrite)
        let cmdBuf = MTLCommandBuffer()
        let input = CIImageProcessorInput(region: inRect, metalTexture: inTex)
        let output = CIImageProcessorOutput(region: outRect, metalTexture: outTex, metalCommandBuffer: cmdBuf)
        guard (try? kernel.process(with: [input], arguments: arguments, output: output)) != nil,
              let encoder = cmdBuf.computeEncoders.last, encoder.ended,
              let name = encoder.pipeline?.name,
              let paramData = encoder.bytes[0],
              let placeData = encoder.bytes[1], placeData.count >= 16 else { return nil }
        func readFloat(_ data: Data, _ offset: Int) -> Float {
            var v: Float = 0
            _ = withUnsafeMutableBytes(of: &v) { dst in data.copyBytes(to: dst, from: offset..<(offset + 4)) }
            return v
        }
        func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
            var v: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &v) { dst in data.copyBytes(to: dst, from: offset..<(offset + 4)) }
            return v
        }
        func readInt32(_ data: Data, _ offset: Int) -> Int32 {
            var v: Int32 = 0
            _ = withUnsafeMutableBytes(of: &v) { dst in data.copyBytes(to: dst, from: offset..<(offset + 4)) }
            return v
        }
        let placeX = readInt32(placeData, 0)
        let placeY = readInt32(placeData, 4)
        let minY = placeY &- Int32(h - 1)
        switch name {
        case "add_noise" where paramData.count >= 24:
            let amount = readFloat(paramData, 0)
            let gaussian = readUInt32(paramData, 4)
            let monochromatic = readUInt32(paramData, 8)
            let seed = readUInt32(paramData, 12)
            let cornerX = readInt32(paramData, 16)
            let cornerY = readInt32(paramData, 20)
            let originX = placeX &+ cornerX
            let originY = minY &+ cornerY
            return VulkanRasterStep(operation: 8, source: sourceIndex, parameters: [
                amount, Float(gaussian), Float(monochromatic), Float(bitPattern: seed),
                Float(bitPattern: UInt32(bitPattern: originX)), Float(bitPattern: UInt32(bitPattern: originY)), 0, 0
            ])
        case "add_grain" where paramData.count >= 32:
            let strength = readFloat(paramData, 0)
            let roughness = readFloat(paramData, 4)
            let size = readFloat(paramData, 8)
            let detailSize = readFloat(paramData, 12)
            let originX = readFloat(paramData, 16)
            let originY = readFloat(paramData, 20)
            let unitsPerPixel = readFloat(paramData, 24)
            let seed = readUInt32(paramData, 28)
            return VulkanRasterStep(operation: 9, source: sourceIndex, parameters: [
                strength, roughness, size, detailSize, originX, originY, unitsPerPixel, Float(bitPattern: seed),
                Float(bitPattern: UInt32(bitPattern: placeX)), Float(bitPattern: UInt32(bitPattern: minY)), 0, 0
            ])
        default:
            return nil
        }
    }

    private func evalGraph(_ region: CGRect, _ env: Env) -> Raster? {
        guard let gpu = env.gpu, gpu.isAvailable, region.width * region.height >= Double(gpu.minimumGraphPixels),
              graphOperationCount(2) > 1 else { return nil }
        var sources: [Raster] = [], steps: [VulkanRasterStep] = []
        func visit(_ node: Node, _ domain: CGRect, depth: Int) -> Int? {
            guard depth < 128, steps.count < 128 else { return nil }
            let step: VulkanRasterStep
            switch node {
            case .crop(let n, let rect) where n.graphOperationCount(1) > 0:
                let intersection = domain.intersection(rect)
                if intersection.isNull || intersection.width <= 0 || intersection.height <= 0 {
                    guard sources.count < 64 else { return nil }
                    sources.append(Raster(rect: region))
                    return -sources.count
                }
                let clipped = intersection.integral
                guard let input = visit(n, clipped, depth: depth + 1) else { return nil }
                step = VulkanRasterStep(operation: 7, source: input, parameters: [
                    Float(clipped.minX - region.minX), Float(clipped.minY - region.minY),
                    Float(clipped.maxX - region.minX), Float(clipped.maxY - region.minY)])
            case .over(let s, let b):
                guard let top = visit(s, domain, depth: depth + 1), let bottom = visit(b, domain, depth: depth + 1) else { return nil }
                step = VulkanRasterStep(operation: 1, source: top, background: bottom)
            case .blendMask(let s, let b, let m, let channel):
                guard let top = visit(s, domain, depth: depth + 1), let bottom = visit(b, domain, depth: depth + 1),
                      let mask = visit(m, domain, depth: depth + 1) else { return nil }
                step = VulkanRasterStep(operation: 2, source: top, background: bottom, mask: mask, channel: UInt32(channel))
            case .matrix(let n, let rows, let bias):
                guard let input = visit(n, domain, depth: depth + 1) else { return nil }
                step = VulkanRasterStep(operation: 3, source: input, parameters: rows.flatMap { $0 } + bias)
            case .colorClamp(let n, let lo, let hi):
                guard let input = visit(n, domain, depth: depth + 1) else { return nil }
                step = VulkanRasterStep(operation: 4, source: input, parameters: lo + hi)
            case .unpremultiply(let n):
                guard let input = visit(n, domain, depth: depth + 1) else { return nil }
                step = VulkanRasterStep(operation: 5, source: input)
            case .maxComponent(let n):
                guard let input = visit(n, domain, depth: depth + 1) else { return nil }
                step = VulkanRasterStep(operation: 6, source: input)
            case .processor(let kernel, let inputs, let arguments, _) where !env.linear && inputs.count == 1:
                guard let input = visit(inputs[0], domain, depth: depth + 1),
                      let encoded = Self.encodeProcessorStep(kernel: kernel, arguments: arguments, region: region, sourceIndex: input),
                      Self.runsOnGPU(encoded)
                else { return nil }
                step = encoded
            default:
                // Keep the CPU node's original crop domain; padding happens only at the graph boundary.
                let evaluate = { node.eval(domain, Env(linear: env.linear)).cropped(to: region) }
                let raster: Raster
                if let identity = node.geometryLeafIdentity(domain: domain, region: region, linear: env.linear) {
                    raster = gpu.geometryLeaf(key: identity.key, sources: identity.sources, evaluate: evaluate)
                } else {
                    raster = evaluate()
                }
                for (index, old) in sources.enumerated() where old.data.count == raster.data.count {
                    let same = old.data.withUnsafeBufferPointer { a in
                        raster.data.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
                    }
                    if same { return -index - 1 }
                }
                guard sources.count < 64 else { return nil }
                sources.append(raster)
                return -sources.count
            }
            guard steps.count < 128 else { return nil }
            steps.append(step)
            return steps.count - 1
        }
        guard visit(self, region, depth: 0) != nil else { return nil }
        func reference(_ value: Int) -> Int { value < 0 ? -value - 1 : sources.count + value }
        let nativeSteps = steps.map { step -> VulkanRasterStep in
            var s = step; s.source = reference(step.source)
            if s.operation <= 2 { s.background = reference(step.background) }
            if s.operation == 2 { s.mask = reference(step.mask) }
            return s
        }
        return gpu.renderGraph(sources: sources, steps: nativeSteps)
    }

    /// Computes `region` (integral, in CI coordinates). Outside the node's extent the result is transparent.
    func eval(_ region: CGRect, _ env: Env) -> Raster {
        if let batched = evalGraph(region, env) { return batched }
        switch self {
        case .bitmap(let image): return CIImage(cgImage: image).node.eval(region, env)
        case .source(let raster, let rect):
            if raster.rect == region {
                if env.linear {
                    var out = raster
                    Gamma.map(&out, Gamma.toLinear)
                    return out
                }
                return raster
            }
            var out = raster.cropped(to: region.intersection(rect).isNull ? CGRect(x: region.minX, y: region.minY, width: 0, height: 0) : region.intersection(rect))
            if env.linear { Gamma.map(&out, Gamma.toLinear) }
            return out.rect == region ? out : out.cropped(to: region)
        case .color(let c):
            var out = Raster(rect: region)
            let a = Float(c.alpha)
            var r = Float(c.red), g = Float(c.green), b = Float(c.blue)
            if env.linear { r = Gamma.toLinear(r); g = Gamma.toLinear(g); b = Gamma.toLinear(b) }
            var i = 0
            while i < out.data.count { out.data[i] = r * a; out.data[i + 1] = g * a; out.data[i + 2] = b * a; out.data[i + 3] = a; i += 4 }
            return out
        case .random:
            var out = Raster(rect: region, uninitialized: true)
            let x0 = Int(region.minX), y0 = Int(region.minY), w = out.width, h = out.height
            out.data.withUnsafeMutableBufferPointer { values in
                for y in 0..<h {
                    for x in 0..<w {
                        let base = (y * w + x) * 4
                        for c in 0..<4 { values[base + c] = RandomField.value(x: x0 + x, y: y0 + y, channel: c) }
                    }
                }
            }
            return out
        case .linearGradient(let p0, let c0, let p1, let c1):
            // Premultiplied, interpolated per channel like Core Image's generator; sampled at pixel centers.
            var out = Raster(rect: region)
            let dx = Double(p1.x - p0.x), dy = Double(p1.y - p0.y), length2 = dx * dx + dy * dy
            func channels(_ c: CIColor) -> [Float] {
                var rgb = [Float(c.red), Float(c.green), Float(c.blue)]
                if env.linear { rgb = rgb.map(Gamma.toLinear) }
                let a = Float(c.alpha)
                return [rgb[0] * a, rgb[1] * a, rgb[2] * a, a]
            }
            let a = channels(c0), b = channels(c1)
            for y in 0..<out.height {
                let cy = Double(region.minY) + Double(y) + 0.5
                for x in 0..<out.width {
                    let cx = Double(region.minX) + Double(x) + 0.5
                    let t = length2 > 0 ? Float(min(1, max(0, ((cx - Double(p0.x)) * dx + (cy - Double(p0.y)) * dy) / length2))) : 0
                    let o = out.index(x, y)
                    for k in 0..<4 { out.data[o + k] = a[k] + (b[k] - a[k]) * t }
                }
            }
            return out
        case .crop(let n, let rect):
            let inter = region.intersection(rect)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { return Raster(rect: region) }
            return n.eval(inter.integral, env).cropped(to: region)
        case .clamp(let n):
            let ext = n.extent
            // Already endless (or empty): there is no edge to carry outwards.
            guard !ext.isInfiniteLike, !ext.isNull, ext.width >= 1, ext.height >= 1 else { return n.eval(region, env) }
            let inner = n.eval(ext.intersection(infiniteExtent).integral, env)
            return inner.clamped(to: region)
        case .maxComponent(let n):
            var out = n.eval(region, env)
            if let result = env.gpu?.render(6, source: out) { return result }
            for i in stride(from: 0, to: out.data.count, by: 4) {
                let m = max(out.data[i], out.data[i + 1], out.data[i + 2])
                out.data[i] = m; out.data[i + 1] = m; out.data[i + 2] = m
            }
            return out
        case .unpremultiply(let n):
            var out = n.eval(region, env)
            if let result = env.gpu?.render(5, source: out) { return result }
            for i in stride(from: 0, to: out.data.count, by: 4) {
                let alpha = out.data[i + 3]
                for c in 0..<3 { out.data[i + c] = alpha > 0 ? out.data[i + c] / alpha : 0 }
            }
            return out
        case .alphaOne(let n, let rect):
            var out = n.eval(region, env)
            for y in 0..<out.height { for x in 0..<out.width {
                if rect.contains(CGPoint(x: region.minX + CGFloat(x) + 0.5, y: region.minY + CGFloat(y) + 0.5)) {
                    out.data[out.index(x, y) + 3] = 1
                }
            } }
            return out
        case .gaussian(let n, let sigma):
            let pad = ceil(sigma * 3)
            return RasterFilters.gaussian(n.eval(region.insetBy(dx: -pad, dy: -pad), env), sigma: sigma, output: region)
        case .variableBlur(let n, let mask, let radius):
            let pad = ceil(radius * 3)
            return RasterFilters.variableBlur(n.eval(region.insetBy(dx: -pad, dy: -pad), env),
                                              mask: mask.eval(region, Env(linear: false)), radius: radius, output: region)
        case .bloom(let n, let radius, let intensity):
            // CIBloom: adds a blurred, intensity-scaled copy of the image back onto itself — a screen-like glow
            // that brightens highlights without touching midtones/shadows much (their blurred neighborhood is dark).
            let pad = ceil(radius * 3)
            let source = n.eval(region, env)
            let blurred = RasterFilters.gaussian(n.eval(region.insetBy(dx: -pad, dy: -pad), env), sigma: radius, output: region)
            return RasterFilters.bloom(source, blurred: blurred, intensity: Float(intensity))
        case .motion(let n, let radius, let angle):
            let pad = ceil(radius * 3) + 1
            return RasterFilters.motionBlur(n.eval(region.insetBy(dx: -pad, dy: -pad), env), radius: radius, angle: angle, output: region)
        case .matrix(let n, let rows, let bias):
            let input = n.eval(region, env)
            if let result = env.gpu?.render(3, source: input, parameters: rows.flatMap { $0 } + bias) { return result }
            return RasterFilters.colorMatrix(input, r: rows[0], g: rows[1], b: rows[2], a: rows[3], bias: bias)
        case .colorClamp(let n, let lo, let hi):
            let input = n.eval(region, env)
            if let result = env.gpu?.render(4, source: input, parameters: lo + hi) { return result }
            return RasterFilters.colorClamp(input, minimum: lo, maximum: hi)
        case .cube(let n, let dim, let data): return RasterFilters.colorCube(n.eval(region, env), dimension: dim, cube: data)
        case .cubeInSpace(let n, let dim, let data, let linear):
            var out = RasterFilters.colorCube(n.eval(region, Env(linear: linear, gpu: env.gpu)), dimension: dim, cube: data)
            if env.linear != linear { Gamma.map(&out, env.linear ? Gamma.toLinear : Gamma.toSRGB) }
            return out
        case .blendMask(let n, let bg, let mask, let channel):
            let input = n.eval(region, env), background = bg.eval(region, env), coverage = mask.eval(region, env)
            if let result = env.gpu?.render(2, source: input, background: background, mask: coverage, channel: UInt32(channel)) { return result }
            return RasterFilters.blendWithMask(input, background: background, mask: coverage, channel: channel)
        case .nearest(let n):
            return n.eval(region, env)
        case .over(let top, let bottom):
            let s = top.eval(region, env)
            var out = bottom.eval(region, env)
            if let result = env.gpu?.render(1, source: s, background: out) { return result }
            var i = 0
            while i < out.data.count {
                let keep = 1 - s.data[i + 3]
                for c in 0..<4 { out.data[i + c] = s.data[i + c] + out.data[i + c] * keep }
                i += 4
            }
            return out
        case .tile(let n, let t):
            let tile = Node.transform(n, t)
            let period = tile.extent.integral
            guard !period.isNull, period.width >= 1, period.height >= 1, !period.isInfiniteLike else { return tile.eval(region, env) }
            let inner = tile.eval(period, env)
            var out = Raster(rect: region)
            let pw = Int(period.width), ph = Int(period.height)
            for y in 0..<out.height {
                var sy = (Int(region.minY) + y - Int(period.minY)) % ph; if sy < 0 { sy += ph }
                for x in 0..<out.width {
                    var sx = (Int(region.minX) + x - Int(period.minX)) % pw; if sx < 0 { sx += pw }
                    let s = inner.index(sx, sy), o = out.index(x, y)
                    for c in 0..<4 { out.data[o + c] = inner.data[s + c] }
                }
            }
            return out
        case .radialGradient(let center, let r0, let c0, let r1, let c1):
            var out = Raster(rect: region)
            func channels(_ c: CIColor) -> [Float] {
                var rgb = [Float(c.red), Float(c.green), Float(c.blue)]
                if env.linear { rgb = rgb.map(Gamma.toLinear) }
                let a = Float(c.alpha)
                return [rgb[0] * a, rgb[1] * a, rgb[2] * a, a]
            }
            let a = channels(c0), b = channels(c1), span = r1 - r0
            for y in 0..<out.height {
                let cy = Double(region.minY) + Double(y) + 0.5 - Double(center.y)
                for x in 0..<out.width {
                    let cx = Double(region.minX) + Double(x) + 0.5 - Double(center.x)
                    let d = (cx * cx + cy * cy).squareRoot()
                    let t = span != 0 ? Float(min(1, max(0, (d - r0) / span))) : (d >= r1 ? 1 : 0)
                    let o = out.index(x, y)
                    for k in 0..<4 { out.data[o + k] = a[k] + (b[k] - a[k]) * t }
                }
            }
            return out
        case .curves(let n, let table, let domain):
            var out = n.eval(region, Env(linear: false, gpu: env.gpu))
            let entries = table.count / 3
            guard entries >= 2 else { return n.eval(region, env) }
            let lo = Float(domain.lowerBound), hi = Float(domain.upperBound), scale = Float(entries - 1) / max(1e-6, hi - lo)
            func lookup(_ v: Float, _ channel: Int) -> Float {
                let position = min(Float(entries - 1), max(0, (v - lo) * scale))
                let i = min(entries - 2, Int(position)), f = position - Float(i)
                return table[i * 3 + channel] * (1 - f) + table[(i + 1) * 3 + channel] * f
            }
            var i = 0
            while i < out.data.count {
                let alpha = out.data[i + 3]
                if alpha > 0 {
                    // The lookup holds its ends past the curve's domain (0...1 usually; wider for HDR exposure curves).
                    for c in 0..<3 { out.data[i + c] = lookup(out.data[i + c] / alpha, c) * alpha }
                }
                i += 4
            }
            if env.linear { Gamma.map(&out, Gamma.toLinear) }
            return out
        case .separable(let s, let b, let mode):
            // Separable blend modes (PDF 1.7 / W3C Compositing & Blending) are defined on non-linear perceptual
            // (sRGB) color components. When linear working space is active, evaluate inputs in sRGB and map the
            // blended result into linear space so the caller receives the linear values it expects.
            let sRGB_s = s.eval(region, Env(linear: false, gpu: env.gpu))
            let sRGB_b = b.eval(region, Env(linear: false, gpu: env.gpu))
            var res = RasterFilters.nonSeparableModes.contains(mode)
                ? RasterFilters.nonSeparableBlend(sRGB_s, backdrop: sRGB_b, mode: mode)
                : RasterFilters.separableBlend(sRGB_s, backdrop: sRGB_b, RasterFilters.separableFormula(mode))
            if env.linear {
                Gamma.map(&res, Gamma.toLinear)
            }
            return res
        case .transform(let n, let t):
            guard abs(t.a * t.d - t.b * t.c) > 1e-12 else { return Raster(rect: region) }
            let inv = t.inverted()
            // Always sample the child in the pre-transform space of `region`. Using `region` itself when
            // the child is infinite (clampedToExtent) skipped the shrink of tip's Scanlines glow
            // (scale-down → blur → scale-up), so the bloom never left the CRT lines.
            let mapped = region.applying(inv).insetBy(dx: -2, dy: -2).integral
            let src = n.extent.isInfiniteLike ? mapped : mapped.intersection(n.extent.integral)
            let input = n.eval(src.isNull ? region : src, env)
            let m = [Double(inv.a), Double(inv.c), Double(inv.tx), Double(inv.b), Double(inv.d), Double(inv.ty), 0, 0, 1]
            return RasterFilters.projective(input, inverse: m, output: region, nearest: n.samplesNearest)
        case .perspective(let n, let target, let source):
            let e = (source ?? n.extent).integral
            guard !e.isInfiniteLike, !e.isNull, e.width >= 1, e.height >= 1 else { return Raster(rect: region) }
            let corners = [CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.minX, y: e.minY)]
            guard let h = RasterFilters.homography(from: target, to: corners) else { return Raster(rect: region) }
            // One pixel more around the source, so sampling at its edge reads what the input has there (a clamped
            // image's own edge pixels) rather than transparency.
            let read = e.insetBy(dx: -1, dy: -1)
            return RasterFilters.projective(n.eval(read, env), inverse: h, output: region, nearest: n.samplesNearest)
        case .upsample(let g, let small, let spatial, let luma):
            return RasterFilters.edgePreserveUpsample(guide: g.eval(region, env), small: small.eval(small.extent.integral, env),
                                                      spatialSigma: spatial, lumaSigma: luma)
        case .processor(let kernel, let inputs, let arguments, let extent):
            let inter = region.intersection(extent).integral
            guard !inter.isNull, inter.width > 0, inter.height > 0, let first = inputs.first else { return Raster(rect: region) }
            let input = first.eval(inter, Env(linear: false, gpu: env.gpu))
            var out: Raster
            if let step = Self.encodeProcessorStep(kernel: kernel, arguments: arguments, region: inter) {
                if Self.runsOnGPU(step), let gpuResult = env.gpu?.render(step.operation, source: input, parameters: step.parameters) {
                    out = gpuResult
                } else if step.operation == 8 {
                    out = RasterFilters.addNoise(input, parameters: step.parameters)
                } else if step.operation == 9 {
                    out = RasterFilters.addGrain(input, parameters: step.parameters)
                } else {
                    out = input
                }
            } else {
                out = input
            }
            if env.linear { Gamma.map(&out, Gamma.toLinear) }
            return out.rect == region ? out : out.cropped(to: region)
        }
    }
}

private extension CGRect {
    var isInfiniteLike: Bool { width > 4_000_000 || height > 4_000_000 }
    var integral32: CGRect { integral }
}

private let byteToFloatTable: [Float] = (0...255).map { Float($0) / 255.0 }

/// CIRandomGenerator's field: a hash of the pixel's position and channel, so the noise stays put as an image moves
/// over it (a dithered canvas doesn't crawl from frame to frame).
enum RandomField {
    static func value(x: Int, y: Int, channel: Int) -> Float {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15 ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2AE3D27D4EB4F
            ^ UInt64(channel) &* 0x165667B19E3779F9
        h ^= h >> 33; h &*= 0xFF51AFD7ED558CCD; h ^= h >> 33; h &*= 0xC4CEB9FE1A85EC53; h ^= h >> 33
        // 24 random bits: every value exact in a Float, all below 1.
        return Float(h >> 40) / 16_777_216
    }
}

// MARK: - CIImage

public final class CIImage: @unchecked Sendable {
    fileprivate let node: Node
    public var extent: CGRect { node.extent }

    fileprivate init(node: Node) { self.node = node }

    public convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, topDownRows: false)
    }

    /// Linux canvas textures keep their uploaded row order instead of flipping the bitmap during every evaluation.
    public convenience init(cgImage: CGImage, topDownRows: Bool) {
        let w = cgImage.width, h = cgImage.height
        // A 16-bit, half-float or 32-bit-float image keeps its precision (and an HDR one its light past white): its
        // values come in as sRGB-encoded floats like every other source, 32-bit floats (linear light) encoded first.
        let native = cgImage.nativeImage
        if native.kind == .rgba, native.depth != .uint8 {
            var deep = Raster(rect: CGRect(x: 0, y: 0, width: w, height: h), uninitialized: true)
            let values = native.premultipliedSRGB()
            deep.data.withUnsafeMutableBufferPointer { dst in
                values.withUnsafeBufferPointer { src in
                    for y in 0..<h {
                        let row = topDownRows ? y : h - 1 - y
                        memcpy(dst.baseAddress! + row * w * 4, src.baseAddress! + y * w * 4, w * 4 * MemoryLayout<Float>.size)
                    }
                }
            }
            self.init(node: .source(deep, deep.rect))
            return
        }
        var raster = Raster(rect: CGRect(x: 0, y: 0, width: w, height: h), uninitialized: true)
        let bytes = cgImage.portableImage.bytes, stride = cgImage.bytesPerRow
        let gray = cgImage.isGrayPlane
        raster.data.withUnsafeMutableBufferPointer { rBuf in
            bytes.withUnsafeBufferPointer { bBuf in
                byteToFloatTable.withUnsafeBufferPointer { lutBuf in
                    guard let rPtr = rBuf.baseAddress, let bPtr = bBuf.baseAddress, let lut = lutBuf.baseAddress else { return }
                    let chunks = min(h, max(1, ProcessInfo.processInfo.activeProcessorCount * 2))
                    let chunkSize = (h + chunks - 1) / chunks
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        let startY = c * chunkSize
                        guard startY < h else { return }
                        let endY = min(h, startY + chunkSize)
                        for y in startY..<endY {
                            let dst = (topDownRows ? y : h - 1 - y) * w * 4
                            let srcRow = y * stride
                            if gray {
                                var srcP = bPtr + srcRow
                                var dstP = rPtr + dst
                                for _ in 0..<w {
                                    let v = lut[Int(srcP[0])]
                                    dstP[0] = v; dstP[1] = v; dstP[2] = v; dstP[3] = 1.0
                                    srcP += 1
                                    dstP += 4
                                }
                            } else {
                                var srcP = bPtr + srcRow
                                var dstP = rPtr + dst
                                for _ in 0..<w {
                                    dstP[0] = lut[Int(srcP[0])]
                                    dstP[1] = lut[Int(srcP[1])]
                                    dstP[2] = lut[Int(srcP[2])]
                                    dstP[3] = lut[Int(srcP[3])]
                                    srcP += 4
                                    dstP += 4
                                }
                            }
                        }
                    }
                }
            }
        }
        self.init(node: .source(raster, raster.rect))
    }

    /// A one-component mask buffer (Vision's output) as an opaque gray image.
    public convenience init(cvPixelBuffer buffer: CVPixelBuffer) {
        let w = buffer.width, h = buffer.height, values = buffer.normalized
        var raster = Raster(rect: CGRect(x: 0, y: 0, width: w, height: h))
        for y in 0..<h { for x in 0..<w {
            let v = values[y * w + x], o = ((h - 1 - y) * w + x) * 4
            raster.data[o] = v; raster.data[o + 1] = v; raster.data[o + 2] = v; raster.data[o + 3] = 1
        } }
        self.init(node: .source(raster, raster.rect))
    }

    public convenience init(color: CIColor) { self.init(node: .color(color)) }

    /// No pixels and no extent (CGRect.null), as in Core Image; `CIImage.clear` is the endless transparent one.
    public static func empty() -> CIImage { CIImage(node: .crop(.color(.clear), .null)) }
    public static var black: CIImage { CIImage(color: .black) }
    public static var clear: CIImage { CIImage(color: .clear) }

    public func cropped(to rect: CGRect) -> CIImage { CIImage(node: .crop(node, rect)) }
    public func unpremultiplyingAlpha() -> CIImage { CIImage(node: .unpremultiply(node)) }
    public func settingAlphaOne(in rect: CGRect) -> CIImage { CIImage(node: .alphaOne(node, rect)) }
    public func clampedToExtent() -> CIImage { CIImage(node: .clamp(node)) }
    public func applyingGaussianBlur(sigma: Double) -> CIImage { sigma > 0 ? CIImage(node: .gaussian(node, sigma)) : self }
    public func transformed(by matrix: CGAffineTransform) -> CIImage { CIImage(node: .transform(node, matrix)) }
    public func samplingNearest() -> CIImage { CIImage(node: .nearest(node)) }

    /// EXIF orientation 1...8, keeping the result's origin at (0, 0) like Core Image.
    public func oriented(forExifOrientation orientation: Int32) -> CIImage {
        let e = extent
        let w = e.width, h = e.height
        let t: CGAffineTransform
        switch orientation {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return self
        }
        return transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(t))
    }

    public func applyingFilter(_ name: String, parameters: [String: Any] = [:]) -> CIImage {
        // The receiver is the filter's input image unless the parameters name one themselves (as on the Mac, where
        // `straight.applyingFilter("CIDivideBlendMode", [kCIInputImageKey: brightest, ...])` divides by `brightest`).
        var params = parameters
        if params[kCIInputImageKey] == nil { params[kCIInputImageKey] = self }
        return CIFilter(name: name, parameters: params)?.outputImage ?? self
    }
    public func applyingFilter(_ name: String) -> CIImage { applyingFilter(name, parameters: [:]) }

    public func composited(over background: CIImage) -> CIImage {
        // Source-over: the top's premultiplied pixels plus what shows through its transparency.
        CIImage(node: .over(node, background.node))
    }
}

// MARK: - CIFilter

public class CIFilter {
    public let name: String
    private var inputs: [String: Any] = [:]
    /// Every name `outputImage` implements; `CIFilter(name:)` is nil (and `applyingFilter` a no-op) for any other.
    public static let supportedNames: Set<String> = [
        "CIAffineTile", "CIBlendWithAlphaMask", "CIBlendWithMask", "CIBlendWithRedMask", "CIBloom",
        "CIColorBlendMode", "CIColorBurnBlendMode", "CIColorClamp", "CIColorCube", "CIColorCubeWithColorSpace", "CIColorCurves",
        "CIColorDodgeBlendMode", "CIColorMatrix", "CIDarkenBlendMode", "CIDifferenceBlendMode", "CIDivideBlendMode",
        "CIEdgePreserveUpsampleFilter", "CIExclusionBlendMode", "CIGaussianBlur", "CIMaskedVariableBlur", "CIHardLightBlendMode",
        "CIHardMixBlendMode", "CIHueBlendMode", "CILanczosScaleTransform", "CILightenBlendMode",
        "CILinearBurnBlendMode", "CILinearDodgeBlendMode", "CILinearGradient", "CILinearLightBlendMode",
        "CILuminosityBlendMode", "CIMaximumComponent", "CIMotionBlur", "CIMultiplyBlendMode", "CIMultiplyCompositing",
        "CIOverlayBlendMode",
        "CIPerspectiveTransform", "CIPerspectiveTransformWithExtent", "CIPinLightBlendMode", "CIRadialGradient", "CIRandomGenerator",
        "CISaturationBlendMode", "CIScreenBlendMode", "CISoftLightBlendMode", "CISubtractBlendMode",
        "CIVividLightBlendMode"]

    public init?(name: String) {
        guard Self.supportedNames.contains(name) else { return nil }
        self.name = name
    }
    public convenience init?(name: String, parameters: [String: Any]) {
        self.init(name: name)
        for (k, v) in parameters { setValue(v, forKey: k) }
    }
    public func setValue(_ value: Any?, forKey key: String) { inputs[key] = value }
    public func value(forKey key: String) -> Any? { inputs[key] }

    private func image(_ key: String) -> CIImage? { inputs[key] as? CIImage }
    private func number(_ key: String, _ fallback: Double) -> Double {
        if let v = inputs[key] as? Double { return v }
        if let v = inputs[key] as? Int { return Double(v) }
        if let v = inputs[key] as? CGFloat { return Double(v) }
        if let v = inputs[key] as? Float { return Double(v) }
        return fallback
    }
    private func vector(_ key: String, _ fallback: [Float]) -> [Float] {
        (inputs[key] as? CIVector).map { v in (0..<4).map { Float(v[$0]) } } ?? fallback
    }

    public var outputImage: CIImage? {
        // Generators make an image from their parameters alone.
        if name == "CIRandomGenerator" { return CIImage(node: .random) }
        if name == "CIRadialGradient" {
            let center = (inputs[kCIInputCenterKey] as? CIVector).map { CGPoint(x: $0[0], y: $0[1]) } ?? CGPoint(x: 150, y: 150)
            let r0 = number("inputRadius0", 5), r1 = number("inputRadius1", 100)
            let c0 = inputs["inputColor0"] as? CIColor ?? CIColor(red: 1, green: 1, blue: 1)
            let c1 = inputs["inputColor1"] as? CIColor ?? CIColor(red: 0, green: 0, blue: 0)
            return CIImage(node: .radialGradient(center, r0, c0, r1, c1))
        }
        if name == "CILinearGradient" {
            guard let p0 = inputs["inputPoint0"] as? CIVector, let p1 = inputs["inputPoint1"] as? CIVector else { return nil }
            let c0 = inputs["inputColor0"] as? CIColor ?? CIColor(red: 1, green: 1, blue: 1)
            let c1 = inputs["inputColor1"] as? CIColor ?? CIColor(red: 0, green: 0, blue: 0)
            return CIImage(node: .linearGradient(CGPoint(x: p0[0], y: p0[1]), c0, CGPoint(x: p1[0], y: p1[1]), c1))
        }
        guard let input = image(kCIInputImageKey) else { return nil }
        switch name {
        case "CIGaussianBlur": return input.applyingGaussianBlur(sigma: number(kCIInputRadiusKey, 10))
        case "CIMaskedVariableBlur":
            guard let mask = image("inputMask") else { return nil }
            let radius = number(kCIInputRadiusKey, 10)
            return radius > 0 && radius.isFinite ? CIImage(node: .variableBlur(input.node, mask.node, radius)) : input
        case "CIBloom": return CIImage(node: .bloom(input.node, number(kCIInputRadiusKey, 10), number(kCIInputIntensityKey, 0.5)))
        case "CIMotionBlur":
            return CIImage(node: .motion(input.node, number(kCIInputRadiusKey, 20), number(kCIInputAngleKey, 0)))
        case "CIColorMatrix":
            let rows = [vector("inputRVector", [1, 0, 0, 0]), vector("inputGVector", [0, 1, 0, 0]),
                        vector("inputBVector", [0, 0, 1, 0]), vector("inputAVector", [0, 0, 0, 1])]
            return CIImage(node: .matrix(input.node, rows, vector("inputBiasVector", [0, 0, 0, 0])))
        case "CIMaximumComponent":
            return CIImage(node: .maxComponent(input.node))
        case "CIMultiplyCompositing":
            // Porter-Duff multiply: S·B + S·(1 − αB) + B·(1 − αS), premultiplied — the multiply blend's own formula.
            guard let bg = image(kCIInputBackgroundImageKey) else { return nil }
            return CIImage(node: .separable(input.node, bg.node, "CIMultiplyBlendMode"))
        case "CIColorClamp":
            return CIImage(node: .colorClamp(input.node, vector("inputMinComponents", [0, 0, 0, 0]), vector("inputMaxComponents", [1, 1, 1, 1])))
        case "CIColorCube":
            guard let data = inputs["inputCubeData"] as? Data else { return nil }
            let dim = Int(number("inputCubeDimension", 2))
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return CIImage(node: .cube(input.node, dim, floats))
        case "CIColorCubeWithColorSpace":
            // Upstream's CMYK proof passes sRGB: the table maps encoded colors, as LittleCMS built it.
            guard let data = inputs["inputCubeData"] as? Data else { return nil }
            let space = (inputs["inputColorSpace"] as? CGColorSpace)?.name ?? CGColorSpace.sRGB
            let linear = space == CGColorSpace.linearSRGB || space == CGColorSpace.extendedLinearSRGB
            let dim = Int(number("inputCubeDimension", 2))
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return CIImage(node: .cubeInSpace(input.node, dim, floats, linear: linear))
        case "CIBlendWithMask", "CIBlendWithRedMask", "CIBlendWithAlphaMask":
            guard let bg = image(kCIInputBackgroundImageKey), let mask = image(kCIInputMaskImageKey) else { return nil }
            let channel = name == "CIBlendWithRedMask" ? 0 : name == "CIBlendWithAlphaMask" ? 3 : 4
            return CIImage(node: .blendMask(input.node, bg.node, mask.node, channel))
        case "CILanczosScaleTransform":
            let scale = number(kCIInputScaleKey, 1)
            let aspect = number(kCIInputAspectRatioKey, 1)
            let sx = scale * aspect, sy = scale
            return input.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        case "CIPerspectiveTransform", "CIPerspectiveTransformWithExtent":
            func corner(_ k: String) -> CGPoint { (inputs[k] as? CIVector)?.cgPointValue ?? .zero }
            let source = name == "CIPerspectiveTransformWithExtent" ? (inputs["inputExtent"] as? CIVector)?.cgRectValue : nil
            return CIImage(node: .perspective(input.node, [corner("inputTopLeft"), corner("inputTopRight"),
                                                           corner("inputBottomRight"), corner("inputBottomLeft")], source))
        case "CIColorCurves":
            guard let data = inputs["inputCurvesData"] as? Data else { return input }
            let table = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let domain = inputs["inputCurvesDomain"] as? CIVector
            let lo = domain.map { Double($0[0]) } ?? 0, hi = domain.map { Double($0[1]) } ?? 1
            return CIImage(node: .curves(input.node, table, lo...max(lo + 1e-6, hi)))
        case "CIColorBurnBlendMode", "CIColorDodgeBlendMode", "CISoftLightBlendMode",
             "CILinearBurnBlendMode", "CILinearDodgeBlendMode", "CIVividLightBlendMode",
             "CILinearLightBlendMode", "CIPinLightBlendMode", "CIHardMixBlendMode",
             "CISubtractBlendMode", "CIDivideBlendMode",
             "CIDarkenBlendMode", "CIMultiplyBlendMode", "CILightenBlendMode", "CIScreenBlendMode",
             "CIOverlayBlendMode", "CIHardLightBlendMode", "CIDifferenceBlendMode", "CIExclusionBlendMode",
             "CIHueBlendMode", "CISaturationBlendMode", "CIColorBlendMode", "CILuminosityBlendMode":
            guard let bg = image(kCIInputBackgroundImageKey) else { return nil }
            return CIImage(node: .separable(input.node, bg.node, name))
        case "CIAffineTile":
            let transform = (inputs[kCIInputTransformKey] as? NSAffineTransform)?.transformStruct
            let t = transform.map { CGAffineTransform(a: $0.m11, b: $0.m12, c: $0.m21, d: $0.m22, tx: $0.tX, ty: $0.tY) } ?? .identity
            return CIImage(node: .tile(input.node, t))
        case "CIEdgePreserveUpsampleFilter":
            guard let small = image("inputSmallImage") else { return nil }
            return CIImage(node: .upsample(guide: input.node, small: small.node, number("inputSpatialSigma", 3), number("inputLumaSigma", 0.15)))
        default: return nil
        }
    }
}

// MARK: - CIContext

public struct CIContextOption: Hashable, Sendable {
    let key: String
    public static let workingColorSpace = CIContextOption(key: "workingColorSpace")
    public static let outputColorSpace = CIContextOption(key: "outputColorSpace")
    public static let cacheIntermediates = CIContextOption(key: "cacheIntermediates")
    public static let useSoftwareRenderer = CIContextOption(key: "useSoftwareRenderer")
    /// Linux canvas contexts may batch larger graphs on hardware; ordinary image contexts stay CPU by default.
    public static let hardwareCanvas = CIContextOption(key: "hardwareCanvas")
    /// Apple working-pixel format; recorded and ignored (evaluator stays float).
    public static let workingFormat = CIContextOption(key: "workingFormat")
}

public final class CIContext: @unchecked Sendable {
    private let linearWorkingSpace: Bool
    private let gpu: VulkanRaster?
    public var gpuDevice: String? { gpu?.device }
    public var gpuDeviceType: UInt32? { gpu?.deviceType }
    public var gpuSubmissionCount: UInt64 { gpu?.submissions ?? 0 }
    public var gpuUploadBytes: UInt64 { gpu?.uploadBytes ?? 0 }
    /// Graph evaluations that ran as one fused hardware pass.
    public var gpuFusedSubmissionCount: UInt64 { gpu?.fusedSubmissions ?? 0 }
    public var gpuReadbackBytes: UInt64 { gpu?.readbackBytes ?? 0 }
    public var gpuAvailable: Bool { gpu?.isAvailable ?? false }
    var gpuBackend: OpaquePointer? { gpu?.backend }
    public init(options: [CIContextOption: Any]? = nil) {
        let backend = ProcessInfo.processInfo.environment["COMPOSITOR_COREIMAGE_BACKEND"]
        let hardwareCanvas = (options?[.hardwareCanvas] as? Bool) == true
        gpu = backend != "cpu" && (backend == "vulkan" || hardwareCanvas)
            && (options?[.useSoftwareRenderer] as? Bool) != true
            ? VulkanRaster(graphsOnly: backend != "vulkan") : nil
        // Core Image works in linear light unless told otherwise. An explicit NSNull working space turns colour
        // management off (values pass through), and a named one is worked in as it is: sRGB stays gamma-encoded,
        // only a linear space (linearSRGB, extendedLinearSRGB) is linear.
        switch options?[.workingColorSpace] {
        case nil: linearWorkingSpace = true
        case let space as CGColorSpace: linearWorkingSpace = space.name.contains("Linear")
        default: linearWorkingSpace = false
        }
    }
    public convenience init() { self.init(options: nil) }

    private func raster(_ image: CIImage, _ rect: CGRect) -> Raster? {
        let region = rect.integral
        guard region.width >= 1, region.height >= 1, region.width * region.height <= 200_000_000 else { return nil }
        var raster = image.node.eval(region, Env(linear: linearWorkingSpace, gpu: gpu))
        if linearWorkingSpace { Gamma.map(&raster, Gamma.toSRGB) }
        return raster
    }

    public func createCGImage(_ image: CIImage, from rect: CGRect, format: CIFormat = .RGBA8, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let region = rect.integral
        if [.RGBA16, .RGBAh, .RGBAf].contains(format) { return deepCGImage(image, from: region, format: format, colorSpace: colorSpace) }
        if image.node.isRegionalFilter, region.width * region.height > 256 * 256,
           region.width >= 1, region.height >= 1, region.width * region.height <= 200_000_000 {
            return CGImage(width: Int(region.width), height: Int(region.height), isGray: format == .L8 || format == .A8) { tile in
                // CGImage rows run downwards, whereas the filter graph uses bottom-left coordinates.
                let slice = CGRect(x: region.minX + tile.minX, y: region.maxY - tile.maxY,
                                   width: tile.width, height: tile.height)
                return self.createCGImageEager(image, from: slice, format: format, colorSpace: colorSpace)!.portableImage
            }
        }
        return createCGImageEager(image, from: region, format: format, colorSpace: colorSpace)
    }

    private func createCGImageEager(_ image: CIImage, from rect: CGRect, format: CIFormat, colorSpace: CGColorSpace?) -> CGImage? {
        if case .bitmap(let bitmap) = image.node, format == .RGBA8, rect.integral == image.extent { return bitmap }
        guard let r = raster(image, rect) else { return nil }
        let w = r.width, h = r.height
        if format == .L8 || format == .A8 {
            var plane = Array<UInt8>(unsafeUninitializedCapacity: w * h) { _, count in count = w * h }
            plane.withUnsafeMutableBufferPointer { pBuf in
                r.data.withUnsafeBufferPointer { rBuf in
                    guard let pPtr = pBuf.baseAddress, let rPtr = rBuf.baseAddress else { return }
                    let chunks = min(h, max(1, ProcessInfo.processInfo.activeProcessorCount * 2))
                    let chunkSize = (h + chunks - 1) / chunks
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        let startY = c * chunkSize
                        guard startY < h else { return }
                        let endY = min(h, startY + chunkSize)
                        for y in startY..<endY {
                            let srcRow = (h - 1 - y) * w * 4
                            let dstRow = y * w
                            for x in 0..<w {
                                let i = srcRow + x * 4
                                let v = format == .A8 ? rPtr[i + 3] : 0.2126 * rPtr[i] + 0.7152 * rPtr[i + 1] + 0.0722 * rPtr[i + 2]
                                pPtr[dstRow + x] = UInt8(max(0, min(255, Int32(v * 255.0 + 0.5))))
                            }
                        }
                    }
                }
            }
            return CGImage(PortableImage(width: w, height: h, kind: .mask, bytesPerRow: w, bytes: plane))
        }
        var out = Array<UInt8>(unsafeUninitializedCapacity: w * h * 4) { _, count in count = w * h * 4 }
        out.withUnsafeMutableBufferPointer { oBuf in
            r.data.withUnsafeBufferPointer { rBuf in
                guard let oPtr = oBuf.baseAddress, let rPtr = rBuf.baseAddress else { return }
                let chunks = min(h, max(1, ProcessInfo.processInfo.activeProcessorCount * 2))
                let chunkSize = (h + chunks - 1) / chunks
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let startY = c * chunkSize
                    guard startY < h else { return }
                    let endY = min(h, startY + chunkSize)
                    for y in startY..<endY {
                        let srcRow = (h - 1 - y) * w * 4
                        let dstRow = y * w * 4
                        var srcP = rPtr + srcRow
                        var dstP = oPtr + dstRow
                        for _ in 0..<w {
                            let a = srcP[3]
                            if a >= 1.0 {
                                let r255 = srcP[0] * 255.0 + 0.5
                                let g255 = srcP[1] * 255.0 + 0.5
                                let b255 = srcP[2] * 255.0 + 0.5
                                dstP[0] = UInt8(max(0, min(255, Int32(r255))))
                                dstP[1] = UInt8(max(0, min(255, Int32(g255))))
                                dstP[2] = UInt8(max(0, min(255, Int32(b255))))
                                dstP[3] = 255
                            } else if a <= 0.0 {
                                dstP[0] = 0
                                dstP[1] = 0
                                dstP[2] = 0
                                dstP[3] = 0
                            } else {
                                let a255 = a * 255.0 + 0.5
                                let r255 = min(srcP[0], a) * 255.0 + 0.5
                                let g255 = min(srcP[1], a) * 255.0 + 0.5
                                let b255 = min(srcP[2], a) * 255.0 + 0.5
                                dstP[0] = UInt8(max(0, min(255, Int32(r255))))
                                dstP[1] = UInt8(max(0, min(255, Int32(g255))))
                                dstP[2] = UInt8(max(0, min(255, Int32(b255))))
                                dstP[3] = UInt8(max(0, min(255, Int32(a255))))
                            }
                            srcP += 4
                            dstP += 4
                        }
                    }
                }
            }
        }
        return CGImage(PortableImage(width: w, height: h, kind: .rgba, bytesPerRow: w * 4, bytes: out))
    }

    /// A 16-bit (`RGBA16`), half-float (`RGBAh`) or 32-bit-float (`RGBAf`) image, as Core Image renders them: 16-bit
    /// values clipped to 0...1; floats kept past white, half floats sRGB-encoded (in an extended sRGB space), 32-bit
    /// floats linear light.
    private func deepCGImage(_ image: CIImage, from region: CGRect, format: CIFormat, colorSpace: CGColorSpace?) -> CGImage? {
        guard let r = raster(image, region) else { return nil }
        let w = r.width, h = r.height
        var topDown = [Float](repeating: 0, count: w * h * 4)
        r.data.withUnsafeBufferPointer { src in
            topDown.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h { memcpy(dst.baseAddress! + y * w * 4, src.baseAddress! + (h - 1 - y) * w * 4, w * 4 * MemoryLayout<Float>.size) }
            }
        }
        let bytes: [UInt8], depth: PortableImage.Depth, rowBytes: Int
        switch format {
        case .RGBA16:
            let values = topDown.map { UInt16(max(0, min(65535, ($0.isFinite ? $0 : 0) * 65535 + 0.5))) }
            bytes = values.withUnsafeBytes { Array($0) }; depth = .uint16; rowBytes = w * 8
        case .RGBAh:
            let values = topDown.map { Float16($0.isFinite ? $0 : 0) }
            bytes = values.withUnsafeBytes { Array($0) }; depth = .half; rowBytes = w * 8
        case .RGBAfEncoded:   // render(toBitmap:) only: 32-bit floats left sRGB-encoded
            bytes = topDown.withUnsafeBytes { Array($0) }; depth = .float32; rowBytes = w * 16
        default:
            var linear = Raster(rect: CGRect(x: 0, y: 0, width: w, height: h))
            linear.data = topDown
            Gamma.map(&linear, Gamma.toLinear)
            bytes = linear.data.withUnsafeBytes { Array($0) }; depth = .float32; rowBytes = w * 16
        }
        return CGImage(PortableImage(width: w, height: h, kind: .rgba, depth: depth, bytesPerRow: rowBytes, bytes: bytes))
    }

    public func render(_ image: CIImage, toBitmap bitmap: UnsafeMutableRawPointer, rowBytes: Int, bounds: CGRect,
                       format: CIFormat, colorSpace: CGColorSpace?) {
        // Half and 32-bit floats, in the requested space: linear light only for a linear one (32-bit floats in an
        // extended sRGB space stay encoded, as Core Image writes them).
        if format == .RGBAh || format == .RGBAf {
            let linear = colorSpace.map { $0.name.contains("Linear") } ?? (format == .RGBAf)
            guard let cg = deepCGImage(image, from: bounds.integral, format: format == .RGBAf && !linear ? .RGBAfEncoded : format,
                                       colorSpace: colorSpace) else { return }
            let native = cg.nativeImage
            native.bytes.withUnsafeBufferPointer { src in
                for y in 0..<cg.height {
                    memcpy(bitmap + y * rowBytes, src.baseAddress! + y * native.bytesPerRow, min(rowBytes, native.bytesPerRow))
                }
            }
            return
        }
        // RGBA16 (premultiplied, top row first), straight from the float graph: RawImporter.dithered quantizes
        // these 16-bit samples itself, so rounding them to 8 bits here first would throw the dither's input away.
        if format == .RGBA16 {
            guard let r = raster(image, bounds.integral) else { return }
            let w = r.width, h = r.height
            r.data.withUnsafeBufferPointer { src in
                for y in 0..<h {
                    let dst = bitmap.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                    let row = (h - 1 - y) * w * 4
                    for x in 0..<(w * 4) {
                        dst[x] = UInt16(max(0, min(65535, src[row + x] * 65535 + 0.5)))
                    }
                }
            }
            return
        }
        guard let cg = createCGImage(image, from: bounds, format: format, colorSpace: colorSpace) else { return }
        let bpp = cg.isGrayPlane ? 1 : 4
        let bytes = cg.portableImage.bytes
        bytes.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            for y in 0..<cg.height {
                memcpy(bitmap + y * rowBytes, srcBase + y * cg.bytesPerRow, cg.width * bpp)
            }
        }
    }
}

/// Decodes camera RAW files through the host's registered LibRaw backend. Capability flags and defaults
/// come from that engine; upstream's importer and controls consume the same CIRAWFilter interface.
public final class CIRAWFilter: @unchecked Sendable {
    public var exposure: Float = 0
    public var neutralTemperature: Float = 5000
    public var neutralTint: Float = 0
    public var boostAmount: Float = 1
    public var luminanceNoiseReductionAmount: Float = 0
    public var isLensCorrectionEnabled = false
    public var isHighlightRecoveryEnabled = false
    public var isLuminanceNoiseReductionSupported: Bool { raw.capabilities.supportsNoiseReduction }
    public var isLensCorrectionSupported: Bool { raw.capabilities.supportsLensCorrection }
    public var isHighlightRecoverySupported: Bool { raw.capabilities.supportsHighlightRecovery }
    public var scaleFactor: Float = 1
    public var isDraftModeEnabled = false
    private let raw: RawDecoding.Handle

    /// Opens (and unpacks, once per file) through the host's LibRaw decoder; nil without one or for an unreadable file.
    public init?(imageURL: URL) {
        guard let handle = RawDecoding.open(imageURL) else { return nil }
        raw = handle
        neutralTemperature = handle.asShotTemperature
        neutralTint = handle.asShotTint
        luminanceNoiseReductionAmount = handle.capabilities.noiseReduction
        isLensCorrectionEnabled = handle.capabilities.lensCorrection
        isHighlightRecoveryEnabled = handle.capabilities.highlightRecovery
    }

    public var nativeSize: CGSize { CGSize(width: raw.width, height: raw.height) }

    /// Developed with the current settings: draft (half-size, no demosaic) when asked and scaled to half or less.
    public var outputImage: CIImage? {
        let scale = min(1, max(0.01, scaleFactor))
        guard let developed = raw.develop(exposure: exposure, temperature: neutralTemperature, tint: neutralTint,
                                          boost: boostAmount, scale: scale, draft: isDraftModeEnabled,
                                          noiseReduction: luminanceNoiseReductionAmount, lensCorrection: isLensCorrectionEnabled,
                                          highlightRecovery: isHighlightRecoveryEnabled) else { return nil }
        RawDecoding.releaseIfConsumed(raw)
        guard let provider = CGDataProvider(data: Data(developed.bytes) as CFData),
              let image = CGImage(width: developed.width, height: developed.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: developed.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return CIImage(node: .bitmap(image))
    }
}

// MARK: - CIImageProcessorKernel

public final class CIImageProcessorInput {
    public let region: CGRect
    public let metalTexture: MTLTexture?
    public init(region: CGRect, metalTexture: MTLTexture?) {
        self.region = region
        self.metalTexture = metalTexture
    }
}

public final class CIImageProcessorOutput {
    public let region: CGRect
    public let metalTexture: MTLTexture?
    public let metalCommandBuffer: MTLCommandBuffer?
    public init(region: CGRect, metalTexture: MTLTexture?, metalCommandBuffer: MTLCommandBuffer?) {
        self.region = region
        self.metalTexture = metalTexture
        self.metalCommandBuffer = metalCommandBuffer
    }
}

open class CIImageProcessorKernel {
    open class var outputFormat: CIFormat { .RGBAh }
    open class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    open class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    open class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                            output: CIImageProcessorOutput) throws {}

    open class func apply(withExtent extent: CGRect, inputs: [CIImage]?, arguments: [String: Any]?) throws -> CIImage {
        let rect = extent.integral
        guard !rect.isNull, !rect.isEmpty, rect.width >= 1, rect.height >= 1 else { return .empty() }
        let nodes = (inputs ?? []).map { $0.cropped(to: rect).node }
        return CIImage(node: .crop(.processor(self, nodes, arguments ?? [:], rect), rect))
    }
}
