// OVERRIDE for Compositor/Rendering/GPUCanvas.swift (excluded from the Linux build).
//
// Metal → Vulkan: `GPUCanvasRenderer.shared` drives tip `EditorCanvas.drawOnGPU`. Constraint: look, feel,
// and UX must match Mac (sRGB, orientation, sampling, brush response) — not API-only stubs. The CI
// placement/present path is not yet GPU↔CPU pixel-parity on Linux, so `shared` stays nil unless
// COMPOSITOR_FORCE_GPU_CANVAS=1 (smoke / parity work). Default canvas is Core Graphics (same look as
// Mac failover). CompRenderer's Vulkan composite via SkiaBridge is independent and stays on.

import Foundation
import AppKit
import CoreGraphics
import CoreImage
import Metal

/// Stand-in for QuartzCore's Metal layer: stores drawable size and the last presented frame for diagnostics.
final class CAMetalLayer {
    var drawableSize = CGSize.zero
    var contentsScale: CGFloat = 1
    var lastPresented: CGImage?
}

@MainActor final class GPUCanvasRenderer {
    /// Non-nil when Vulkan (or FORCE) is available — same gate as tip's Metal device check.
    /// Non-failable construction: Swift `init?()` + `@MainActor` static let segfaults under swift-testing on Linux.
    static let shared: GPUCanvasRenderer? = GPUCanvasRenderer.vulkanAvailable() ? GPUCanvasRenderer() : nil

    let space: CGColorSpace
    let context: CIContext
    let device: MTLDevice
    let queue: MTLCommandQueue

    private struct Key: Hashable { let id: ObjectIdentifier; let level: Int }
    private struct Entry {
        let source: AnyObject
        let image: CIImage
        var used: Int
        var keep: Int
    }
    private var textures: [Key: Entry] = [:]
    private var frame = 0
    private let keepFrames = 90
    private var strokes: [ObjectIdentifier: (stroke: BrushStroke, image: CIImage, written: [CGPoint: ObjectIdentifier], used: Int)] = [:]

    private init() {
        space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // Match tip: sRGB working space, no intermediate cache — same color feel as Mac Metal CIContext.
        context = CIContext(options: [.workingColorSpace: space as Any, .cacheIntermediates: false])
        device = MTLDevice()
        queue = MTLCommandQueue()
    }

    private static func vulkanAvailable() -> Bool {
        // UX/look gate: the CI placement/present path must pixel-match Core Graphics (GPUCanvasTests)
        // before drawOnGPU is the default. Until then only COMPOSITOR_FORCE_GPU_CANVAS opts in — for
        // API smoke (GPUCanvasLinuxTests) and intentional parity work. CompRenderer's Vulkan blit is
        // independent and stays available via SkiaBridge.
        if ProcessInfo.processInfo.environment["COMPOSITOR_CPU_CANVAS"] == "1" { return false }
        if UserDefaults.standard.bool(forKey: "CompositorCPUCanvas") { return false }
        return ProcessInfo.processInfo.environment["COMPOSITOR_FORCE_GPU_CANVAS"] == "1"
    }

    private func release(keepingLastFrame: Bool) {
        let last = frame - 1
        textures = keepingLastFrame ? textures.filter { $0.value.used >= last } : [:]
        strokes = keepingLastFrame ? strokes.filter { $0.value.used >= last } : [:]
    }

    func image(_ image: CGImage, level: Int = 0, mask: Bool = false, transient: Bool = false) -> CIImage? {
        texture(image, level: level, mask: mask, transient: transient, drawing: true)
    }

    private func texture(_ image: CGImage, level: Int, mask: Bool, transient: Bool, drawing: Bool) -> CIImage? {
        let key = Key(id: ObjectIdentifier(image), level: transient ? 0 : level)
        let keep = transient ? 1 : drawing || level > 0 ? keepFrames : 0
        if var entry = textures[key] {
            entry.used = frame
            entry.keep = max(entry.keep, keep)
            textures[key] = entry
            if transient, level > 0 { return Self.reduced(entry.image, width: image.width, height: image.height, level: level) }
            return entry.image
        }
        let made: CIImage?
        if level == 0 || transient {
            made = upload(image, mask: mask)
        } else if let larger = texture(image, level: level - 1, mask: mask, transient: false, drawing: false) {
            made = Self.reduced(larger, width: image.width, height: image.height, level: level)
        } else { made = nil }
        guard let made else { return nil }
        textures[key] = Entry(source: image, image: made, used: frame, keep: keep)
        if transient, level > 0 { return Self.reduced(made, width: image.width, height: image.height, level: level) }
        return made
    }

    private func upload(_ image: CGImage, mask: Bool) -> CIImage? {
        if mask {
            // Gray mask → red channel CIImage
            guard let copy = try? Self.grayCopy(image), let cg = copy.makeImage() else { return nil }
            return CIImage(cgImage: cg)
        }
        return CIImage(cgImage: image)
    }

    func cachedLevels(of image: CGImage) -> [Int] {
        textures.keys.filter { $0.id == ObjectIdentifier(image) }.map(\.level).sorted()
    }

    func image(_ stroke: BrushStroke, base: CIImage?) -> CIImage? {
        let id = ObjectIdentifier(stroke)
        var written: [CGPoint: ObjectIdentifier] = [:]
        var current: CIImage
        if let known = strokes[id] {
            current = known.image
            written = known.written
        } else {
            let grid = CGRect(x: 0, y: 0, width: stroke.width, height: stroke.height)
            let edge = stroke.maskBackground
            var start = (stroke.isMask ? CIImage(color: CIColor(red: edge, green: edge, blue: edge)) : CIImage.clear).cropped(to: grid)
            if let base {
                let placed = base.clampedToExtent().transformed(by: CGAffineTransform(
                    scaleX: stroke.sourceRect.width / base.extent.width, y: stroke.sourceRect.height / base.extent.height)
                    .concatenating(CGAffineTransform(translationX: stroke.sourceRect.minX, y: stroke.sourceRect.minY)))
                start = placed.cropped(to: stroke.sourceRect).composited(over: start)
            }
            current = start
        }
        for patch in stroke.patches {
            let key = patch.rect.origin, identity = ObjectIdentifier(patch.image)
            guard written[key] != identity else { continue }
            guard let tile = upload(patch.image, mask: stroke.isMask) else { continue }
            let placed = tile.transformed(by: CGAffineTransform(translationX: patch.rect.minX, y: patch.rect.minY))
            current = placed.composited(over: current)
            written[key] = identity
        }
        strokes[id] = (stroke, current, written, frame)
        return current
    }

    func image(_ raster: RasterSnapshot, level: Int = 0) -> CIImage? {
        let grid = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
        var start = (raster.isMask ? CIImage(color: CIColor(red: 1, green: 1, blue: 1)) : CIImage.clear).cropped(to: grid)
        if let base = raster.base, let img = upload(base, mask: raster.isMask) {
            start = img.transformed(by: CGAffineTransform(translationX: raster.baseRect.minX, y: raster.baseRect.minY))
                .composited(over: start)
        }
        for patch in raster.patches {
            guard let tile = upload(patch.image, mask: raster.isMask) else { continue }
            start = tile.transformed(by: CGAffineTransform(translationX: patch.rect.minX, y: patch.rect.minY))
                .composited(over: start)
        }
        return level == 0 ? start : Self.reduced(start, width: raster.width, height: raster.height, level: level)
    }

    func endFrame() {
        frame += 1
        textures = textures.filter { frame - $0.value.used < $0.value.keep }
        strokes = strokes.filter { frame - $0.value.used < keepFrames }
    }

    func present(_ image: CIImage, in layer: CAMetalLayer) {
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        // Tip Metal path flips CI bottom-up → top-left for the drawable. Linux CoreImage createCGImage
        // already emits top-left rows; draw into the flipped NSGraphicsContext so Qt/canvas match Mac look.
        let rendered = image.cropped(to: bounds)
        guard let cg = context.createCGImage(rendered, from: bounds) else { return }
        layer.lastPresented = cg
        if let dest = NSGraphicsContext.current?.cgContext {
            dest.saveGState()
            dest.interpolationQuality = .none
            let scale = max(layer.contentsScale, 1)
            let drawRect = CGRect(x: 0, y: 0, width: size.width / scale, height: size.height / scale)
            dest.draw(cg, in: drawRect)
            dest.restoreGState()
        }
        endFrame()
    }

    static func size(_ width: Int, _ height: Int, level: Int) -> CGSize {
        CGSize(width: max(1, (width + (1 << level) - 1) >> level), height: max(1, (height + (1 << level) - 1) >> level))
    }

    static func grayCopy(_ image: CGImage) throws -> CGContext {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }

    static func reduced(_ full: CIImage, width: Int, height: Int, level: Int) -> CIImage {
        let w = max(1, (width + (1 << level) - 1) >> level), h = max(1, (height + (1 << level) - 1) >> level)
        let sx = CGFloat(w) / CGFloat(width), sy = CGFloat(h) / CGFloat(height)
        return full.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
}

final class MetalCanvasView: NSView {
    let metalLayer = CAMetalLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func fit(scale: CGFloat) {
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}

@MainActor struct GPUPlacement {
    /// Document pixels to frame pixels (y down).
    let mapping: CGAffineTransform
    /// Frame pixels per document pixel.
    let scale: CGFloat
    let renderer: GPUCanvasRenderer

    /// `source` (an image or a painted raster, `width` × `height` pixels) placed where `transform` puts it. Large
    /// reductions draw from a sharp smaller copy; pixel for pixel, or with Nearest sampling, pixels are copied.
    func place(width: Int, height: Int, transform: LayerTransform, mask: Bool = false,
               source: (Int) -> CIImage?) -> CIImage? {
        guard width > 0, height > 0 else { return nil }
        let factor = transform.size.width * scale / CGFloat(width)
        let level = transform.sampling == .nearest ? 0 : DownsampleCache.level(for: factor)
        guard let image = source(level) else { return nil }
        // The grid `level` halvings down, rounded up as the reductions are — known here, since an image that's
        // transparent at its edges can have a smaller extent than its grid.
        let reduced = CGSize(width: max(1, (width + (1 << level) - 1) >> level), height: max(1, (height + (1 << level) - 1) >> level))
        let toFull = CGAffineTransform(scaleX: CGFloat(width) / reduced.width, y: CGFloat(height) / reduced.height)
        let toFrame = BrushRaster.pixelToDocument(transform, width: width, height: height).concatenating(mapping)
        let upright = transform.radians == 0 && abs(abs(factor) - 1) < 0.001 && level == 0
        let sampled = transform.sampling == .nearest || upright ? image.samplingNearest() : image
        // Sampled up to its edge with its own edge pixels, and then cut to the layer's outline, as Core Graphics draws an
        // image into a rectangle. Smoothed against the transparency past its edge instead, a small image stretched over
        // a layer — a new mask is a single pixel — would come out faded all over.
        let placed = sampled.clampedToExtent().transformed(by: toFull.concatenating(toFrame))
        let grid = CGRect(x: 0, y: 0, width: width, height: height)
        if toFrame.b == 0, toFrame.c == 0 { return placed.cropped(to: grid.applying(toFrame)) }
        // Turned, the outline is drawn at about screen size before it's turned, so its edges soften over one screen pixel
        // whatever the image's size.
        let sx = max(1, hypot(toFrame.a, toFrame.b)), sy = max(1, hypot(toFrame.c, toFrame.d))
        let outline = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width) * sx, height: CGFloat(height) * sy))
            .transformed(by: CGAffineTransform(scaleX: 1 / sx, y: 1 / sy).concatenating(toFrame))
        return GPUBlend.masked(placed, by: outline)
    }

    /// `image`, shown through `transform`, taken in perspective so its corners land on `corners` (document points, handle
    /// order) — `DistortWarp.warp` for a convex shape, done here at full size rather than on the CPU for every move.
    func warp(_ image: CGImage, transform: LayerTransform, corners: [CGPoint], mask: Bool = false) -> CIImage? {
        guard DistortWarp.isConvex(corners) else { return nil }
        let target = DistortWarp.imageCorners(corners.map { $0.applying(mapping) }, flipX: transform.flipX, flipY: transform.flipY)
        let xs = [target.topLeft.x, target.topRight.x, target.bottomRight.x, target.bottomLeft.x]
        let ys = [target.topLeft.y, target.topRight.y, target.bottomRight.y, target.bottomLeft.y]
        let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        let level = transform.sampling == .nearest ? 0 : DownsampleCache.level(for: span / CGFloat(max(image.width, image.height)))
        guard let source = renderer.image(image, level: level, mask: mask) else { return nil }
        // Core Image's top edge is the image's last row here, where y counts down the rows.
        func taken(_ image: CIImage, extent: CGRect) -> CIImage {
            image.applyingFilter("CIPerspectiveTransformWithExtent", parameters: [
                "inputExtent": CIVector(cgRect: extent),
                "inputTopLeft": CIVector(cgPoint: target.bottomLeft), "inputTopRight": CIVector(cgPoint: target.bottomRight),
                "inputBottomRight": CIVector(cgPoint: target.topRight), "inputBottomLeft": CIVector(cgPoint: target.topLeft)])
        }
        let size = CGSize(width: max(1, (image.width + (1 << level) - 1) >> level), height: max(1, (image.height + (1 << level) - 1) >> level))
        let sampled = transform.sampling == .nearest ? source.samplingNearest() : source
        // Carried past its edges and cut to the shape, drawn at screen size (see `place`).
        let outlineSide = max(span, 1)
        let outline = taken(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: outlineSide, height: outlineSide)),
                            extent: CGRect(x: 0, y: 0, width: outlineSide, height: outlineSide))
        return GPUBlend.masked(taken(sampled.clampedToExtent(), extent: CGRect(origin: .zero, size: size)), by: outline)
    }

    func place(_ image: CGImage, transform: LayerTransform, mask: Bool = false) -> CIImage? {
        place(width: image.width, height: image.height, transform: transform, mask: mask) {
            renderer.image(image, level: $0, mask: mask)
        }
    }

    /// An image that changes from frame to frame (`width` × `height`, at its extent's origin), placed like `place`, with
    /// its reductions computed as it's drawn.
    func place(live image: CIImage, width: Int, height: Int, transform: LayerTransform) -> CIImage? {
        // Transparent to the grid's edge, so the edge pixels carried past it are the grid's own.
        let grid = CGRect(x: 0, y: 0, width: width, height: height)
        let full = image.cropped(to: grid).composited(over: CIImage.clear.cropped(to: grid))
        return place(width: width, height: height, transform: transform) { level in
            level == 0 ? full : GPUCanvasRenderer.reduced(full, width: width, height: height, level: level)
        }
    }

    func place(transient image: CGImage, transform: LayerTransform, mask: Bool = false) -> CIImage? {
        place(width: image.width, height: image.height, transform: transform, mask: mask) {
            renderer.image(image, level: $0, mask: mask, transient: true)
        }
    }

    func place(_ raster: RasterSnapshot, transform: LayerTransform) -> CIImage? {
        place(width: raster.width, height: raster.height, transform: transform, mask: raster.isMask) {
            renderer.image(raster, level: $0)
        }
    }
}

nonisolated enum GPUBlend {
    /// `top` composited over `bottom` in `mode`.
    static func blend(_ top: CIImage, over bottom: CIImage, mode: LayerBlendMode) -> CIImage {
        guard let name = filterName(mode) else { return top.composited(over: bottom) }
        return top.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: bottom])
    }

    static func filterName(_ mode: LayerBlendMode) -> String? {
        if let name = mode.coreImageFilter { return name }
        switch mode {
        case .normal: return nil
        case .darken: return "CIDarkenBlendMode"
        case .multiply: return "CIMultiplyBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .hardLight: return "CIHardLightBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        case .exclusion: return "CIExclusionBlendMode"
        case .hue: return "CIHueBlendMode"
        case .saturation: return "CISaturationBlendMode"
        case .color: return "CIColorBlendMode"
        case .luminosity: return "CILuminosityBlendMode"
        default: return nil
        }
    }

    /// `image` shown only where `mask` (values in red) is on, and nothing elsewhere — past the mask's edges too, as a
    /// Core Graphics clip to a mask does.
    static func masked(_ image: CIImage, by mask: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                 kCIInputMaskImageKey: mask])
    }

    /// `image` at `opacity`.
    static func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }
}

nonisolated enum GPUAdjustment {
    /// `image` adjusted, laid out in frame pixels: `scale` frame pixels per document pixel, and `mapping` from document
    /// pixels to the frame (for Grain, whose pattern belongs to the document).
    static func apply(_ adjustment: LayerAdjustment, to image: CIImage, scale: CGFloat, mapping: CGAffineTransform) -> CIImage? {
        switch adjustment.kind {
        case .levels:
            guard !adjustment.levels.isIdentity else { return image }
            // Enough entries that stepping between them stays well under one 8-bit level.
            let size = 1024, step = Double(size - 1)
            let curve = (0..<size).flatMap { index in
                [LevelsChannel.red, .green, .blue].map { Float(adjustment.levels.apply(Double(index) / step, channel: $0)) }
            }
            return image.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": curve.withUnsafeBufferPointer { Data(buffer: $0) },
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            ])
        case .hsv:
            return image.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": HueSaturationFilter.dimension,
                "inputCubeData": HueSaturationFilter.cube(adjustment.resolvedHSV),
            ])
        case .curves, .blackWhite, .colorBalance, .exposure, .gradientMap, .invert:
            guard let cube = cube(for: adjustment) else { return nil }
            return image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": cube])
        case .gaussianBlur:
            // Not clamped, as on the Core Graphics canvas: the blur spreads past the pixels' edges.
            return image.applyingGaussianBlur(sigma: adjustment.gaussianRadius * scale)
        case .motionBlur:
            // Core Image's angle turns counterclockwise with y up; the frame's y points down.
            return image.applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: adjustment.resolvedMotionDistance * scale * PixelFilter.motionRadiusPerPixel,
                kCIInputAngleKey: -adjustment.resolvedMotionAngle * .pi / 180,
            ])
        case .addNoise:
            return GPUNoise.addNoise(to: image, mapping: mapping, amount: Float(min(400, max(0.1, adjustment.resolvedNoiseAmount))),
                                     gaussian: adjustment.resolvedNoiseGaussian,
                                     monochromatic: adjustment.resolvedNoiseMonochromatic, seed: adjustment.resolvedNoiseSeed)
        case .grain:
            return GPUNoise.addGrain(to: image, grain: adjustment.grain, scale: scale, mapping: mapping)
        }
    }

    // MARK: Color lookups

    /// Points per axis of the lookups for adjustments that change each color on its own, as Hue/Saturation's.
    static let dimension = 33
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cubes: [(adjustment: LayerAdjustment, data: Data)] = []

    /// A lookup for an adjustment that changes each color on its own, made by running the adjustment itself over every
    /// point of the lattice — so the GPU canvas shows what export makes, with nothing worked out twice.
    static func cube(for adjustment: LayerAdjustment) -> Data? {
        if let known = lock.withLock({ cubes.first { $0.adjustment == adjustment }?.data }) { return known }
        let n = dimension, width = n * n
        guard let lattice = try? BrushRaster.context(width: width, height: n, mask: false), let pixels = lattice.data else { return nil }
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        func level(_ i: Int) -> UInt8 { UInt8((Double(i) * 255 / Double(n - 1)).rounded()) }
        // Red along each row, green across blocks of rows' columns, blue down the rows: the order the lookup reads.
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = b * lattice.bytesPerRow + (g * n + r) * 4
            bytes[i] = level(r); bytes[i + 1] = level(g); bytes[i + 2] = level(b); bytes[i + 3] = 255
        } } }
        guard let source = lattice.makeImage(), let adjusted = try? adjustment.apply(source),
              let out = try? BrushRaster.copy(adjusted), let result = out.data else { return nil }
        let values = result.assumingMemoryBound(to: UInt8.self)
        var floats = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = b * out.bytesPerRow + (g * n + r) * 4, o = ((b * n + g) * n + r) * 4
            floats[o] = Float(values[i]) / 255; floats[o + 1] = Float(values[i + 1]) / 255; floats[o + 2] = Float(values[i + 2]) / 255
        } } }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.withLock {
            cubes.removeAll { $0.adjustment == adjustment }
            cubes.insert((adjustment, data), at: 0)
            if cubes.count > 16 { cubes.removeLast() }
        }
        return data
    }
}

extension CIContext {
    /// Linux stand-in for `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` used by GPUCanvasTests.
    func render(_ image: CIImage, to texture: MTLTexture, commandBuffer: MTLCommandBuffer, bounds: CGRect,
                colorSpace: CGColorSpace?) {
        _ = (commandBuffer, colorSpace)
        guard let cg = createCGImage(image, from: bounds) else { return }
        let w = texture.width, h = texture.height
        guard let copy = try? BrushRaster.copy(cg), let data = copy.data else { return }
        let bpp = 4
        let count = min(texture.rgbaBytes.count, w * h * bpp)
        // Tip textures are top-left; BrushRaster.copy matches that.
        texture.rgbaBytes.withUnsafeMutableBytes { dest in
            guard let base = dest.baseAddress else { return }
            if copy.bytesPerRow == w * bpp {
                memcpy(base, data, count)
            } else {
                for row in 0..<h {
                    memcpy(base.advanced(by: row * w * bpp), data.advanced(by: row * copy.bytesPerRow), w * bpp)
                }
            }
        }
    }
}

