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

private struct Env { var linear: Bool }

private indirect enum Node {
    case source(Raster, CGRect)
    /// A bitmap kept as it is until something reads it (RAW output): rendering it unchanged hands the bitmap back
    /// without the float round trip, which for a very large RAW would cost more memory than the image itself.
    case bitmap(CGImage)
    case color(CIColor)
    /// CILinearGradient: color0 at point0 to color1 at point1 along their line, constant beyond either end.
    case linearGradient(CGPoint, CIColor, CGPoint, CIColor)
    case crop(Node, CGRect)
    case clamp(Node)
    case gaussian(Node, Double)
    case bloom(Node, Double, Double)          // radius, intensity
    case motion(Node, Double, Double)
    case matrix(Node, [[Float]], [Float])
    case colorClamp(Node, [Float], [Float])
    case cube(Node, Int, [Float])
    /// CIBlendWithMask family: input where the mask is on, background where it is off. `channel` is which part of the
    /// mask decides: 0 red (CIBlendWithRedMask), 3 alpha (CIBlendWithAlphaMask), 4 luminance (CIBlendWithMask).
    case blendMask(Node, Node, Node, Int)
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

    var extent: CGRect {
        switch self {
        case .source(_, let r): return r
        case .bitmap(let image): return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        case .color, .clamp, .linearGradient, .radialGradient, .tile: return infiniteExtent
        case .crop(let n, let r): return n.extent.intersection(r)
        case .gaussian(let n, let s): return n.extent.isInfiniteLike ? n.extent : n.extent.insetBy(dx: -ceil(s * 3), dy: -ceil(s * 3))
        case .bloom(let n, let r, _): return n.extent.isInfiniteLike ? n.extent : n.extent.insetBy(dx: -ceil(r * 3), dy: -ceil(r * 3))
        case .motion(let n, let r, _): return n.extent.isInfiniteLike ? n.extent : n.extent.insetBy(dx: -ceil(r), dy: -ceil(r))
        case .matrix(let n, _, _), .colorClamp(let n, _, _), .cube(let n, _, _): return n.extent
        case .blendMask(let n, _, _, _), .curves(let n, _, _): return n.extent
        case .over(let top, let bottom): return top.extent.union(bottom.extent)
        case .separable(let s, let b, _): return s.extent.union(b.extent)
        case .transform(let n, let t): return n.extent.applying(t)
        case .perspective(_, let pts, _):
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        case .upsample(let g, _, _, _): return g.extent
        }
    }

    var isRegionalFilter: Bool {
        switch self {
        case .gaussian: return true
        case .crop(let node, _): return node.isRegionalFilter
        default: return false
        }
    }

    /// Computes `region` (integral, in CI coordinates). Outside the node's extent the result is transparent.
    func eval(_ region: CGRect, _ env: Env) -> Raster {
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
            var out = Raster(rect: region)
            for y in 0..<out.height { for x in 0..<out.width {
                let sx = Int(region.minX) + x - Int(inner.rect.minX), sy = Int(region.minY) + y - Int(inner.rect.minY)
                let p = inner.clamped(sx, sy), o = out.index(x, y)
                out.data[o] = p.0; out.data[o + 1] = p.1; out.data[o + 2] = p.2; out.data[o + 3] = p.3
            } }
            return out
        case .gaussian(let n, let sigma):
            let pad = ceil(sigma * 3)
            return RasterFilters.gaussian(n.eval(region.insetBy(dx: -pad, dy: -pad), env), sigma: sigma, output: region)
        case .bloom(let n, let radius, let intensity):
            // CIBloom: adds a blurred, intensity-scaled copy of the image back onto itself — a screen-like glow
            // that brightens highlights without touching midtones/shadows much (their blurred neighborhood is dark).
            let pad = ceil(radius * 3)
            let source = n.eval(region, env)
            let blurred = RasterFilters.gaussian(n.eval(region.insetBy(dx: -pad, dy: -pad), env), sigma: radius, output: region)
            return RasterFilters.bloom(source, blurred: blurred, intensity: Float(intensity))
        case .motion(let n, let radius, let angle):
            let pad = ceil(radius) + 1
            return RasterFilters.motionBlur(n.eval(region.insetBy(dx: -pad, dy: -pad), env), radius: radius, angle: angle, output: region)
        case .matrix(let n, let rows, let bias):
            return RasterFilters.colorMatrix(n.eval(region, env), r: rows[0], g: rows[1], b: rows[2], a: rows[3], bias: bias)
        case .colorClamp(let n, let lo, let hi): return RasterFilters.colorClamp(n.eval(region, env), minimum: lo, maximum: hi)
        case .cube(let n, let dim, let data): return RasterFilters.colorCube(n.eval(region, env), dimension: dim, cube: data)
        case .blendMask(let n, let bg, let mask, let channel):
            return RasterFilters.blendWithMask(n.eval(region, env), background: bg.eval(region, env), mask: mask.eval(region, env),
                                               channel: channel)
        case .over(let top, let bottom):
            let s = top.eval(region, env)
            var out = bottom.eval(region, env)
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
            var out = n.eval(region, Env(linear: false))
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
                    for c in 0..<3 { out.data[i + c] = lookup(min(1, max(0, out.data[i + c] / alpha)), c) * alpha }
                }
                i += 4
            }
            if env.linear { Gamma.map(&out, Gamma.toLinear) }
            return out
        case .separable(let s, let b, let mode):
            // Separable blend modes (PDF 1.7 / W3C Compositing & Blending) are defined on non-linear perceptual
            // (sRGB) color components. When linear working space is active, evaluate inputs in sRGB and map the
            // blended result into linear space so the caller receives the linear values it expects.
            let sRGB_s = s.eval(region, Env(linear: false))
            let sRGB_b = b.eval(region, Env(linear: false))
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
            return RasterFilters.projective(input, inverse: m, output: region)
        case .perspective(let n, let target, let source):
            let e = (source ?? n.extent).integral
            guard !e.isInfiniteLike, !e.isNull, e.width >= 1, e.height >= 1 else { return Raster(rect: region) }
            let corners = [CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.minX, y: e.minY)]
            guard let h = RasterFilters.homography(from: target, to: corners) else { return Raster(rect: region) }
            // One pixel more around the source, so sampling at its edge reads what the input has there (a clamped
            // image's own edge pixels) rather than transparency.
            let read = e.insetBy(dx: -1, dy: -1)
            return RasterFilters.projective(n.eval(read, env), inverse: h, output: region)
        case .upsample(let g, let small, let spatial, let luma):
            return RasterFilters.edgePreserveUpsample(guide: g.eval(region, env), small: small.eval(small.extent.integral, env),
                                                      spatialSigma: spatial, lumaSigma: luma)
        }
    }
}

private extension CGRect {
    var isInfiniteLike: Bool { width > 4_000_000 || height > 4_000_000 }
    var integral32: CGRect { integral }
}

private let byteToFloatTable: [Float] = (0...255).map { Float($0) / 255.0 }

// MARK: - CIImage

public final class CIImage: @unchecked Sendable {
    fileprivate let node: Node
    public var extent: CGRect { node.extent }

    fileprivate init(node: Node) { self.node = node }

    public convenience init(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
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
                            // CGImage rows run top-down; CI rows run bottom-up.
                            let dst = (h - 1 - y) * w * 4
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
    public func clampedToExtent() -> CIImage { CIImage(node: .clamp(node)) }
    public func applyingGaussianBlur(sigma: Double) -> CIImage { sigma > 0 ? CIImage(node: .gaussian(node, sigma)) : self }
    public func transformed(by matrix: CGAffineTransform) -> CIImage { CIImage(node: .transform(node, matrix)) }
    public func samplingNearest() -> CIImage { self }

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
        var params = parameters
        params[kCIInputImageKey] = self
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
        "CIColorBlendMode", "CIColorBurnBlendMode", "CIColorClamp", "CIColorCube", "CIColorCurves",
        "CIColorDodgeBlendMode", "CIColorMatrix", "CIDarkenBlendMode", "CIDifferenceBlendMode", "CIDivideBlendMode",
        "CIEdgePreserveUpsampleFilter", "CIExclusionBlendMode", "CIGaussianBlur", "CIHardLightBlendMode",
        "CIHardMixBlendMode", "CIHueBlendMode", "CILanczosScaleTransform", "CILightenBlendMode",
        "CILinearBurnBlendMode", "CILinearDodgeBlendMode", "CILinearGradient", "CILinearLightBlendMode",
        "CILuminosityBlendMode", "CIMotionBlur", "CIMultiplyBlendMode", "CIOverlayBlendMode",
        "CIPerspectiveTransform", "CIPerspectiveTransformWithExtent", "CIPinLightBlendMode", "CIRadialGradient",
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
        if name == "CIRadialGradient" {
            let center = (inputs[kCIInputCenterKey] as? CIVector).map { CGPoint(x: $0[0], y: $0[1]) } ?? CGPoint(x: 150, y: 150)
            let r0 = (inputs["inputRadius0"] as? NSNumber)?.doubleValue ?? (inputs["inputRadius0"] as? Double) ?? 5
            let r1 = (inputs["inputRadius1"] as? NSNumber)?.doubleValue ?? (inputs["inputRadius1"] as? Double) ?? 100
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
        case "CIBloom": return CIImage(node: .bloom(input.node, number(kCIInputRadiusKey, 10), number(kCIInputIntensityKey, 0.5)))
        case "CIMotionBlur":
            return CIImage(node: .motion(input.node, number(kCIInputRadiusKey, 20), number(kCIInputAngleKey, 0)))
        case "CIColorMatrix":
            let rows = [vector("inputRVector", [1, 0, 0, 0]), vector("inputGVector", [0, 1, 0, 0]),
                        vector("inputBVector", [0, 0, 1, 0]), vector("inputAVector", [0, 0, 0, 1])]
            return CIImage(node: .matrix(input.node, rows, vector("inputBiasVector", [0, 0, 0, 0])))
        case "CIColorClamp":
            return CIImage(node: .colorClamp(input.node, vector("inputMinComponents", [0, 0, 0, 0]), vector("inputMaxComponents", [1, 1, 1, 1])))
        case "CIColorCube":
            guard let data = inputs["inputCubeData"] as? Data else { return nil }
            let dim = Int(number("inputCubeDimension", 2))
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return CIImage(node: .cube(input.node, dim, floats))
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
    /// Apple working-pixel format; recorded and ignored (evaluator stays float).
    public static let workingFormat = CIContextOption(key: "workingFormat")
}

public final class CIContext: @unchecked Sendable {
    private let linearWorkingSpace: Bool
    public init(options: [CIContextOption: Any]? = nil) {
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
        var raster = image.node.eval(region, Env(linear: linearWorkingSpace))
        if linearWorkingSpace { Gamma.map(&raster, Gamma.toSRGB) }
        return raster
    }

    public func createCGImage(_ image: CIImage, from rect: CGRect, format: CIFormat = .RGBA8, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let region = rect.integral
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

    public func render(_ image: CIImage, toBitmap bitmap: UnsafeMutableRawPointer, rowBytes: Int, bounds: CGRect,
                       format: CIFormat, colorSpace: CGColorSpace?) {
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
        let cgFormat: CIFormat = (format == .RGBAh || format == .RGBAf) ? .RGBA8 : format
        guard let cg = createCGImage(image, from: bounds, format: cgFormat, colorSpace: colorSpace) else { return }
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

/// Decodes and develops camera RAW files (`Compositor/IO/RawImporter.swift`). Apple's own RAWFilter has no open
/// equivalent bundled here yet — every initialiser fails, so `RawImporter` reports RAW files unreadable rather than
/// mis-decoding them. A real backend (e.g. LibRaw) would replace this file only; upstream's `RawImporter.swift` and
/// its UI stay unmodified either way.
public final class CIRAWFilter: @unchecked Sendable {
    public var exposure: Float = 0
    public var neutralTemperature: Float = 5000
    public var neutralTint: Float = 0
    public var boostAmount: Float = 1
    public var scaleFactor: Float = 1
    public var isDraftModeEnabled = false
    private let raw: RawDecoding.Handle

    /// Opens (and unpacks, once per file) through the host's LibRaw decoder; nil without one or for an unreadable file.
    public init?(imageURL: URL) {
        guard let handle = RawDecoding.open(imageURL) else { return nil }
        raw = handle
        neutralTemperature = handle.asShotTemperature
        neutralTint = handle.asShotTint
    }

    public var nativeSize: CGSize { CGSize(width: raw.width, height: raw.height) }

    /// Developed with the current settings: draft (half-size, no demosaic) when asked and scaled to half or less.
    public var outputImage: CIImage? {
        let scale = min(1, max(0.01, scaleFactor))
        guard let developed = raw.develop(exposure: exposure, temperature: neutralTemperature, tint: neutralTint,
                                          boost: boostAmount, scale: scale, draft: isDraftModeEnabled) else { return nil }
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
