// Portable port of Compositor/Document/Filters.swift's execution layer (file-map
// tier: "Apple replacement/adaptation: Keep settings/validation/preview
// transactions; replace named CoreImage filters with Skia/OpenCV/custom
// kernels"). The settings structs (`FilterKind`/`FilterSettings`) are already
// ported in Filters.swift; this file adds the pieces the header there marked
// omitted: `FilterJob` and `PixelFilter.run`/`trimmed`.
//
// Kernel reuse (the "Keep" C kernels, via CompositorKernels): `levels_apply`
// (curves, exposure), `adjust_gradient_map`, `adjust_grain`, `noise_add`,
// `lens_distort`, `content_fill`, `brush_alpha_bounds`. Gaussian blur runs on
// the portable `GaussianBlur` (CI replacement). Selection blending runs on the
// portable `PixelAdjust.blend`.
//
// Divergences from the macOS backend (documented for the ENG-10 parity pass):
//   - Motion Blur: an even streak smear along the angle (the Photoshop
//     semantics the macOS comment describes), where CI tapers like a Gaussian.
//   - Remove Background: throws `FilterError.modelMissing` until the offline
//     segmentation milestone lands (the plan forbids a silently degraded edit).

import Foundation
import CompositorKernels

nonisolated struct FilterJob: @unchecked Sendable {
    let kind: FilterKind
    let image: PortableImage
    let settings: FilterSettings
    /// Pixels in `image` per original layer pixel, so a downscaled preview blurs proportionally less.
    let scale: CGFloat
    let selection: SelectionClip?
    let mapping: CGAffineTransform
    /// Add Noise's random pattern: the same seed gives the same grain.
    var seed: UInt32 = 0
}

nonisolated enum FilterError: LocalizedError {
    case modelMissing
    var errorDescription: String? {
        switch self {
        case .modelMissing: "Background removal needs its offline model, which is not installed. See Diagnostics for how to get it."
        }
    }
}

nonisolated enum PixelFilter {
    /// `CIMotionBlur`'s radius per pixel of streak length. Photoshop smears evenly along the whole
    /// distance; Core Image tapers like a Gaussian whose spread is about its radius (measured on a
    /// single dot). An even streak of length d spreads d / √12, so this radius matches its spread.
    static let motionRadiusPerPixel = 1 / 12.0.squareRoot()
    static let lensStrength = 0.35

    /// `image` cropped to the pixels that are actually there, with the transform that keeps them in place: a blur
    /// is given generous room to spread, and whatever it leaves empty is cut away again.
    static func trimmed(_ image: PortableImage, placed: LayerTransform) throws -> (image: PortableImage, transform: LayerTransform) {
        guard image.kind == .rgba else { return (image, placed) }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var edges = [Int](repeating: 0, count: 4)
        image.bytes.withUnsafeBufferPointer { ptr in
            brush_alpha_bounds(ptr.baseAddress!, image.width, image.height, image.bytesPerRow, &edges)
        }
        let crop = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        guard crop.width >= 1, crop.height >= 1, crop != full, let cropped = image.cropping(to: crop) else {
            return (image, placed)
        }
        var result = placed
        result.size = CGSize(width: crop.width * placed.size.width / full.width,
                             height: crop.height * placed.size.height / full.height)
        let toDocument = BrushRaster.pixelToDocument(placed, width: image.width, height: image.height)
        let middle = CGPoint(x: crop.midX, y: crop.midY).applying(toDocument)
        result.origin = CGPoint(x: middle.x - result.size.width / 2, y: middle.y - result.size.height / 2)
        return (cropped, result)
    }

    static func run(_ job: FilterJob) throws -> PortableImage {
        // Reject masks before the RGBA C kernels can read beyond their storage.
        guard job.image.kind == .rgba, job.scale.isFinite, job.scale > 0, job.scale <= 1 else {
            throw ProjectError.invalid
        }
        let settings = job.settings.normalized
        let width = job.image.width, height = job.image.height
        let image: PortableImage
        switch job.kind {
        case .curves:
            image = try settings.curves.apply(job.image)
        case .exposure:
            image = try settings.exposure.apply(job.image)
        case .gradientMap:
            image = try settings.gradientMap.apply(job.image)
        // Grain sits in layer pixels; the job's seed gives each application its own pattern.
        case .grain:
            image = try settings.grain.apply(job.image, unitsPerPixel: 1 / job.scale, seed: job.seed)
        case .removeBackground:
            image = try SubjectRemoval.run(job.image, settings: settings, selection: job.selection,
                                           pixelToDocument: job.mapping, requireModel: true)
        case .contentAwareFill:
            image = try ContentFill.run(job)
        case .gaussianBlur:
            var pixels = PixelBuffer(width: width, height: height, bytes: job.image.bytes)
            // Not clamped: a blur softens the layer's edges and spreads into the room
            // made for it, rather than smearing the border outwards.
            GaussianBlur.apply(&pixels, sigma: settings.radius * job.scale, edges: .transparent)
            image = PortableImage(pixels)
        case .motionBlur:
            image = try motionBlur(job.image, settings: settings, scale: job.scale)
        case .addNoise:
            var bytes = job.image.bytes
            bytes.withUnsafeMutableBufferPointer { ptr in
                noise_add(ptr.baseAddress!, width, height, width * 4,
                          Float(settings.amount), settings.gaussian ? 1 : 0,
                          settings.monochromatic ? 1 : 0, job.seed)
            }
            image = PortableImage(width: width, height: height, kind: .rgba,
                                  bytesPerRow: width * 4, bytes: bytes)
        case .lensCorrection:
            // The warp is relative to the image's own size, so a downscaled preview bends the same way.
            var out = [UInt8](repeating: 0, count: width * height * 4)
            job.image.bytes.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    lens_distort(src.baseAddress!, dst.baseAddress!, width, height, width * 4,
                                 settings.distortion / 100 * lensStrength)
                }
            }
            image = PortableImage(width: width, height: height, kind: .rgba,
                                  bytesPerRow: width * 4, bytes: out)
        }
        guard let selection = job.selection else { return image }
        let coverage = PixelAdjust.coverage(selection, width: width, height: height, pixelToDocument: job.mapping)
        return PixelAdjust.blend(image, over: job.image, through: coverage)
    }

    /// An even streak smear along the angle (Photoshop semantics; see the
    /// `motionRadiusPerPixel` note for how CI's taper differs).
    private static func motionBlur(_ source: PortableImage, settings: FilterSettings, scale: CGFloat) throws -> PortableImage {
        let width = source.width, height = source.height
        guard source.kind == .rgba else { throw ProjectError.invalid }
        let distance = settings.distance * scale
        guard distance >= 1 else { return source }
        // CI's y axis points up, so its counterclockwise angle matches Photoshop's;
        // in the top-left buffer space the direction vector is therefore:
        let angle = settings.angle * .pi / 180
        let dx = cos(angle), dy = -sin(angle)
        let steps = max(1, Int(distance.rounded(.up)))
        var out = [Float](repeating: 0, count: width * height * 4)
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps) - 0.5
            let ox = Int((dx * distance * t).rounded(.towardZero))
            let oy = Int((dy * distance * t).rounded(.towardZero))
            for y in 0..<height {
                let sy = y + oy
                guard sy >= 0, sy < height else { continue }
                for x in 0..<width {
                    let sx = x + ox
                    guard sx >= 0, sx < width else { continue }
                    let s = (sy * width + sx) * 4, d = (y * width + x) * 4
                    for k in 0..<4 { out[d + k] += Float(source.bytes[s + k]) }
                }
            }
        }
        let divisor = Float(steps + 1)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<bytes.count {
            let v = out[i] / divisor
            bytes[i] = v <= 0 ? 0 : v >= 255 ? 255 : UInt8(v + 0.5)
        }
        return PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: width * 4, bytes: bytes)
    }
}

// MARK: - Settings image application (the macOS `apply(_ image:)` members)

extension CurvesSettings {
    func apply(_ image: PortableImage) throws -> PortableImage {
        guard isValid, image.kind == .rgba else { throw ProjectError.invalid }
        let table = (1...3).flatMap { channel in (0...255).map { Float(value(value(Double($0), channel: channel), channel: 0) / 255) } }
        var bytes = image.bytes
        bytes.withUnsafeMutableBufferPointer { ptr in
            levels_apply(ptr.baseAddress!, image.width * image.height, table)
        }
        return PortableImage(width: image.width, height: image.height, kind: .rgba,
                             bytesPerRow: image.bytesPerRow, bytes: bytes)
    }
}

extension ExposureSettings {
    func apply(_ image: PortableImage) throws -> PortableImage {
        guard isValid, image.kind == .rgba else { throw ProjectError.invalid }
        let tables = Array([[Float]](repeating: table, count: 3).joined())
        var bytes = image.bytes
        bytes.withUnsafeMutableBufferPointer { ptr in
            levels_apply(ptr.baseAddress!, image.width * image.height, tables)
        }
        return PortableImage(width: image.width, height: image.height, kind: .rgba,
                             bytesPerRow: image.bytesPerRow, bytes: bytes)
    }
}

extension GradientMapSettings {
    func apply(_ image: PortableImage) throws -> PortableImage {
        guard isValid, image.kind == .rgba else { throw ProjectError.invalid }
        let (dark, light) = ends
        let table: [UInt8] = (0...255).flatMap { index -> [UInt8] in
            let t = Double(index) / 255
            return [dark.red + (light.red - dark.red) * t, dark.green + (light.green - dark.green) * t,
                    dark.blue + (light.blue - dark.blue) * t].map { UInt8(min(255, max(0, ($0 * 255).rounded()))) }
        }
        var bytes = image.bytes
        bytes.withUnsafeMutableBufferPointer { ptr in
            adjust_gradient_map(ptr.baseAddress!, image.width, image.height, image.bytesPerRow, table)
        }
        return PortableImage(width: image.width, height: image.height, kind: .rgba,
                             bytesPerRow: image.bytesPerRow, bytes: bytes)
    }
}

extension GrainSettings {
    /// `origin` and `unitsPerPixel` place the image's pixels in document space (a whole layer at 1:1 is
    /// origin zero, one unit per pixel); `seed` replaces the stored pattern when given.
    func apply(_ image: PortableImage, origin: CGPoint = .zero, unitsPerPixel: CGFloat = 1, seed: UInt32? = nil) throws -> PortableImage {
        guard isValid, unitsPerPixel.isFinite, unitsPerPixel > 0, image.kind == .rgba else { throw ProjectError.invalid }
        guard amount > 0 else { return image }
        let pattern = seed ?? self.seed
        var bytes = image.bytes
        bytes.withUnsafeMutableBufferPointer { ptr in
            adjust_grain(ptr.baseAddress!, image.width, image.height, image.bytesPerRow,
                         amount, size, roughness, pattern,
                         Double(origin.x), Double(origin.y), Double(unitsPerPixel))
        }
        return PortableImage(width: image.width, height: image.height, kind: .rgba,
                             bytesPerRow: image.bytesPerRow, bytes: bytes)
    }
}

// MARK: - ContentFill (kernel glue)

nonisolated enum ContentFill {
    enum Failure: LocalizedError {
        case noSource
        var errorDescription: String? { "Not enough unselected, opaque image pixels to synthesize a fill. Use a smaller selection with some surrounding image." }
    }

    static func run(_ job: FilterJob) throws -> PortableImage {
        guard let selection = job.selection else { throw Failure.noSource }
        let w = job.image.width, h = job.image.height
        // Selection coverage on the image's own grid: the clip rect mapped through
        // the inverse placement (the CG path-fill the macOS original did).
        let coverage = PixelAdjust.coverage(selection, width: w, height: h, pixelToDocument: job.mapping)
        var pixels = job.image.bytes
        var mask = coverage.bytes
        var result: Int32 = -1
        pixels.withUnsafeMutableBufferPointer { p in
            mask.withUnsafeMutableBufferPointer { m in
                result = content_fill(p.baseAddress!, w * 4, m.baseAddress!, w, Int32(w), Int32(h))
            }
        }
        guard result != 0 else { throw Failure.noSource }
        guard result == 1 else { throw ProjectError.invalid }
        return PortableImage(width: w, height: h, kind: .rgba, bytesPerRow: w * 4, bytes: pixels)
    }
}
