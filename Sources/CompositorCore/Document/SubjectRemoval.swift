// Portable port of Compositor/Document/SubjectRemoval.swift
// SOLID Architecture (ISP & DIP):
// - ForegroundSegmenter: segregated interface for foreground/subject segmentation.
// - MatteRefiner: segregated interface for edge-aware alpha matte refinement.
// - SubjectRemovalService: dependency-inversion container with injectable providers.
// - ContrastBoundarySegmenter & GuidedMatteRefiner: modular concrete implementations.

import Foundation

/// Interface for subject/foreground segmentation backends (SOLID - ISP & DIP).
/// Decouples higher-level workflows from concrete segmentation inference engines
/// (Vision, CoreML, OpenCV DNN, or heuristic boundary analysis).
protocol ForegroundSegmenter: Sendable {
    /// Segments foreground from the given RGBA image.
    /// Returns a normalized coverage mask (255 = full foreground, 0 = background).
    func segmentForeground(
        in image: PortableImage,
        selection: SelectionClip?,
        pixelToDocument: CGAffineTransform
    ) throws -> MaskBuffer
}

/// Interface for edge-aware alpha matte refinement (SOLID - ISP & DIP).
/// Decouples matte refinement algorithms from caller components.
protocol MatteRefiner: Sendable {
    func refine(
        mask: MaskBuffer,
        guide: PortableImage,
        radius: Double,
        limit: CGFloat
    ) throws -> MaskBuffer
}

/// Matte refiner implementation based on the He/Sun/Tang Guided Filter.
struct GuidedMatteRefiner: MatteRefiner {
    init() {}

    public func refine(
        mask: MaskBuffer,
        guide: PortableImage,
        radius: Double,
        limit: CGFloat
    ) throws -> MaskBuffer {
        let width = mask.width
        let height = mask.height
        guard width > 0, height > 0, guide.width > 0, guide.height > 0 else {
            throw SubjectRemoval.Failure.invalidImage
        }

        // Convert mask to RGBA grayscale so GuidedMatte.resampleLuma can process it safely
        var maskRGBA = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let val = mask.bytes[i]
            let at = i * 4
            maskRGBA[at] = val
            maskRGBA[at + 1] = val
            maskRGBA[at + 2] = val
            maskRGBA[at + 3] = 255
        }
        let maskImage = PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: width * 4, bytes: maskRGBA)
        let effectiveRadius = max(1.0, radius)

        let refinedRaster = try GuidedMatte.refine(
            mask: RasterImage(maskImage),
            guide: RasterImage(guide),
            radius: effectiveRadius,
            limit: limit
        )
        let refinedPixels = refinedRaster.pixels

        var out = MaskBuffer(width: width, height: height)
        let rowBytes = refinedPixels.bytesPerRow
        for y in 0..<height {
            let row = y * rowBytes
            for x in 0..<width {
                out[x, y] = refinedPixels.bytes[row + x * 4]
            }
        }
        return out
    }
}

/// Heuristic boundary/contrast segmenter for environments where a heavy offline ML model is not loaded.
struct ContrastBoundarySegmenter: ForegroundSegmenter {
    init() {}

    func segmentForeground(
        in image: PortableImage,
        selection: SelectionClip?,
        pixelToDocument: CGAffineTransform
    ) throws -> MaskBuffer {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw SubjectRemoval.Failure.invalidImage }

        if let selection {
            return PixelAdjust.coverage(selection, width: width, height: height, pixelToDocument: pixelToDocument)
        }

        var buffer = MaskBuffer(width: width, height: height)
        let pixels = image.bytes

        // If the image already has varying alpha, use alpha channel directly as coarse mask
        var hasTransparent = false
        for y in 0..<height {
            let row = y * image.bytesPerRow
            for x in 0..<width {
                if pixels[row + x * 4 + 3] < 250 {
                    hasTransparent = true
                    break
                }
            }
            if hasTransparent { break }
        }

        if hasTransparent {
            for y in 0..<height {
                let row = y * image.bytesPerRow
                for x in 0..<width {
                    buffer[x, y] = pixels[row + x * 4 + 3]
                }
            }
            return buffer
        }

        // Fully opaque image: sample outer border pixels to model background color
        var bgR: Double = 0, bgG: Double = 0, bgB: Double = 0
        var borderCount = 0

        func sampleBorderPixel(x: Int, y: Int) {
            let at = y * image.bytesPerRow + x * 4
            let a = Double(pixels[at + 3])
            if a > 0 {
                bgR += (Double(pixels[at]) * 255.0 / a)
                bgG += (Double(pixels[at + 1]) * 255.0 / a)
                bgB += (Double(pixels[at + 2]) * 255.0 / a)
                borderCount += 1
            }
        }

        for x in 0..<width {
            sampleBorderPixel(x: x, y: 0)
            if height > 1 { sampleBorderPixel(x: x, y: height - 1) }
        }
        if height > 2 {
            for y in 1..<(height - 1) {
                sampleBorderPixel(x: 0, y: y)
                if width > 1 { sampleBorderPixel(x: width - 1, y: y) }
            }
        }

        if borderCount > 0 {
            bgR /= Double(borderCount)
            bgG /= Double(borderCount)
            bgB /= Double(borderCount)
        }

        let centerX = Double(width) / 2.0
        let centerY = Double(height) / 2.0
        let maxDist = sqrt(centerX * centerX + centerY * centerY)

        for y in 0..<height {
            let row = y * image.bytesPerRow
            let dy = Double(y) - centerY
            for x in 0..<width {
                let at = row + x * 4
                let a = Double(pixels[at + 3])
                let r = a > 0 ? Double(pixels[at]) * 255.0 / a : 0
                let g = a > 0 ? Double(pixels[at + 1]) * 255.0 / a : 0
                let b = a > 0 ? Double(pixels[at + 2]) * 255.0 / a : 0

                let colorDiff = sqrt((r - bgR) * (r - bgR) + (g - bgG) * (g - bgG) + (b - bgB) * (b - bgB))
                let dx = Double(x) - centerX
                let distToCenter = sqrt(dx * dx + dy * dy)
                let centerBonus = maxDist > 0 ? max(0.0, 1.0 - distToCenter / maxDist) * 30.0 : 0.0

                let score = colorDiff + centerBonus
                if score > 35.0 {
                    let alphaVal = min(255.0, max(0.0, (score - 35.0) * 8.0))
                    buffer[x, y] = UInt8(alphaVal)
                } else {
                    buffer[x, y] = 0
                }
            }
        }

        return buffer
    }
}

/// Central dependency-inversion container for foreground segmentation and matte refinement.
final class SubjectRemovalService: @unchecked Sendable {
    static let shared = SubjectRemovalService()

    private let lock = NSLock()
    private var _segmenter: (any ForegroundSegmenter)? = nil
    private var _refiner: any MatteRefiner = GuidedMatteRefiner()
    private let _fallbackSegmenter = ContrastBoundarySegmenter()

    init(segmenter: (any ForegroundSegmenter)? = nil, refiner: any MatteRefiner = GuidedMatteRefiner()) {
        self._segmenter = segmenter
        self._refiner = refiner
    }

    /// The active foreground segmenter. If nil, automated filter execution throws FilterError.modelMissing.
    var segmenter: (any ForegroundSegmenter)? {
        get { lock.lock(); defer { lock.unlock() }; return _segmenter }
        set { lock.lock(); defer { lock.unlock() }; _segmenter = newValue }
    }

    /// The active matte refiner.
    var refiner: any MatteRefiner {
        get { lock.lock(); defer { lock.unlock() }; return _refiner }
        set { lock.lock(); defer { lock.unlock() }; _refiner = newValue }
    }

    /// Generates the refined subject mask.
    func subjectMask(
        image: PortableImage,
        under existing: PortableImage?,
        selection: SelectionClip? = nil,
        pixelToDocument: CGAffineTransform = .identity,
        settings: FilterSettings = FilterSettings(),
        requireModel: Bool = false
    ) throws -> MaskBuffer {
        lock.lock()
        let activeSegmenter = _segmenter
        let activeRefiner = _refiner
        lock.unlock()

        guard let segmenterToUse = activeSegmenter ?? (requireModel ? nil : _fallbackSegmenter) else {
            throw FilterError.modelMissing
        }

        let coarse = try segmenterToUse.segmentForeground(in: image, selection: selection, pixelToDocument: pixelToDocument)
        var refined = coarse
        if settings.backgroundQuality == .advanced && settings.refineEdges > 0 {
            let radius = max(1.0, settings.refineEdges)
            refined = try activeRefiner.refine(mask: coarse, guide: image, radius: radius, limit: 1400)
        }

        // Post-processing: contrast adjustment if configured
        if settings.backgroundQuality == .advanced && settings.matteContrast > 0 {
            let strength = settings.matteContrast / 100.0
            let slope = 1.0 / max(0.02, 1.0 - strength * 0.98)
            let bias = (1.0 - slope) / 2.0
            for i in 0..<(refined.width * refined.height) {
                let v = Double(refined.bytes[i]) / 255.0
                let adjusted = min(1.0, max(0.0, slope * v + bias))
                refined.bytes[i] = UInt8(min(255.0, max(0.0, adjusted * 255.0 + 0.5)))
            }
        }

        guard let existing else { return refined }
        var combined = MaskBuffer(width: refined.width, height: refined.height)
        let count = refined.width * refined.height
        for i in 0..<count {
            let exVal: Int = existing.kind == .mask ? Int(existing.bytes[i]) : Int(existing.bytes[i * 4])
            let refVal: Int = Int(refined.bytes[i])
            let product = (exVal * refVal + 127) / 255
            combined.bytes[i] = UInt8(clamping: product)
        }
        return combined
    }

    /// Renders the image with background keyed out (made transparent)
    func run(
        _ image: PortableImage,
        settings: FilterSettings = FilterSettings(),
        selection: SelectionClip? = nil,
        pixelToDocument: CGAffineTransform = .identity,
        requireModel: Bool = false
    ) throws -> PortableImage {
        let mask = try subjectMask(
            image: image,
            under: nil,
            selection: selection,
            pixelToDocument: pixelToDocument,
            settings: settings,
            requireModel: requireModel
        )
        var outBytes = image.bytes
        let width = image.width
        let height = image.height
        for y in 0..<height {
            let row = y * image.bytesPerRow
            for x in 0..<width {
                let m = Int(mask[x, y])
                let at = row + x * 4
                let a = Int(outBytes[at + 3])
                let newA = (a * m + 127) / 255
                outBytes[at] = UInt8((Int(outBytes[at]) * m + 127) / 255)
                outBytes[at + 1] = UInt8((Int(outBytes[at + 1]) * m + 127) / 255)
                outBytes[at + 2] = UInt8((Int(outBytes[at + 2]) * m + 127) / 255)
                outBytes[at + 3] = UInt8(newA)
            }
        }
        return PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: image.bytesPerRow, bytes: outBytes)
    }
}

/// Static facade preserving backwards-compatibility and fluent call sites.
nonisolated enum SubjectRemoval {
    enum Failure: LocalizedError {
        case noSubject
        case invalidImage
        var errorDescription: String? {
            switch self {
            case .noSubject:
                return "No foreground subject was detected in this layer. Try an image with a more distinct subject."
            case .invalidImage:
                return "The layer image is invalid or has zero dimensions."
            }
        }
    }

    static func subjectMask(
        image: PortableImage,
        under existing: PortableImage?,
        selection: SelectionClip? = nil,
        pixelToDocument: CGAffineTransform = .identity,
        settings: FilterSettings = FilterSettings(),
        requireModel: Bool = false
    ) throws -> MaskBuffer {
        try SubjectRemovalService.shared.subjectMask(
            image: image,
            under: existing,
            selection: selection,
            pixelToDocument: pixelToDocument,
            settings: settings,
            requireModel: requireModel
        )
    }

    static func run(
        _ image: PortableImage,
        settings: FilterSettings = FilterSettings(),
        selection: SelectionClip? = nil,
        pixelToDocument: CGAffineTransform = .identity,
        requireModel: Bool = false
    ) throws -> PortableImage {
        try SubjectRemovalService.shared.run(
            image,
            settings: settings,
            selection: selection,
            pixelToDocument: pixelToDocument,
            requireModel: requireModel
        )
    }
}
