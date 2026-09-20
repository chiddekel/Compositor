// Portable port of Compositor/Document/MagicWand.swift (file-map tier:
// "Keep logic; replace Apple operations"). Ported verbatim: `WandSampleSize`,
// `WandSettings`, and the `MagicWand.Failure` error enum.
//
// Now also ported: `MagicWand.select` and `EditorSession.magicWand`/`wandSample`.
// The C matching kernel (`wand_mask`, Compositor/Rendering/WandPixels.c) is
// reproduced here as a Swift flood against the portable raster (the same run-filling
// scanline stack, the same rounded block-average reference color, the same
// per-channel clamped tolerance including alpha); the C `wand_trace` outline is the
// portable `MaskTracing.outline`. The CGContext drawing backend is exchanged for the
// CPU `DocumentRenderer`/`LayerRenderer` composite, and the CGPath boolean
// union/subtraction in `applySelection` is exchanged for per-pixel coverage combine
// followed by a re-outline. macOS runs the match off the main thread; the headless
// core's synchronous command yields the same pixels and the same one-undo-step edit.
//
// Parity notes vs. the macOS original:
//   - `MaskTracing.outline` returns one corner list per loop; the wand's traced
//     CGMutablePath kept each loop as its own subpath (holes wound counterclockwise).
//     `PortablePath.polygon` holds a single loop, so a donut selection fills its hole.
//     Coverage-derived combine (add/subtract) similarly re-traces from one mask;
//     subtract-then-re-outline keeps the outer boundary, so common subtract cases
//     (carve a small region out of a large one) are exact where it matters only.
//   - `Failure.memory` is unreachable in Swift (no malloc); retained for API parity.
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface (CGImage/CGContext/CGPath tracing) is exchanged. The macOS original stays
// the source of truth.

import Foundation

nonisolated enum WandSampleSize: Int, CaseIterable, Sendable {
    case point, threeByThree, fiveByFive
    var title: String { ["Point Sample", "3 by 3 Average", "5 by 5 Average"][rawValue] }
    /// Pixels either side of the click that are averaged into the color to match.
    var radius: Int { rawValue }
}

/// The Magic Wand's options-bar settings.
nonisolated struct WandSettings: Equatable, Sendable {
    /// How far (0–255) each channel may differ from the sampled color and still be selected.
    var tolerance = 32
    var sampleSize = WandSampleSize.point
    /// Only similar pixels connected to the clicked one, rather than every similar pixel.
    var contiguous = true
    /// Read the visible composite rather than just the active layer.
    var sampleAllLayers = false
}

/// Selects pixels similar to a clicked one.
nonisolated enum MagicWand {
    enum Failure: LocalizedError {
        case tooDetailed, memory
        var errorDescription: String? {
            switch self {
            case .tooDetailed: "That selection is too detailed to outline. Try a different Tolerance, or turn on Contiguous."
            case .memory: "There isn’t enough memory to make that selection."
            }
        }
    }

    /// Outlines with more pixel edges than this are refused: the path would be too
    /// slow to draw (the C `wand_edge_limit`).
    static let edgeLimit = 8_000_000

    /// Matches and outlines pixels similar to the one under `point` (document pixels),
    /// read as canonical premultiplied RGBA. Verbatim match semantics of the C
    /// `wand_mask` kernel: the reference color is the average over the
    /// `(2 * radius + 1)`² sample square around the seed, clipped to the image and
    /// rounded `(sum + samples / 2) / samples`; a pixel matches when every channel,
    /// alpha included, differs from it by at most `tolerance`. Contiguous fills
    /// 4-connected from the seed (nothing when the seed itself doesn't match),
    /// otherwise scans every pixel. Returns nil when nothing matches (the caller then
    /// erases a New selection, like an empty lasso click).
    static func select(in image: RasterImage, at point: CGPoint, settings: WandSettings) throws -> PortablePath? {
        let pixels = image.pixels
        let width = pixels.width, height = pixels.height
        let bytes = pixels.bytes
        guard point.x.isFinite, point.y.isFinite, width > 0, height > 0 else { return nil }
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let radius = settings.sampleSize.radius
        let x0 = max(x - radius, 0), x1 = min(x + radius, width - 1)
        let y0 = max(y - radius, 0), y1 = min(y + radius, height - 1)
        var sums = [0, 0, 0, 0], samples = 0
        for py in y0...y1 {
            let row = py * width * 4
            for px in x0...x1 {
                let i = row + px * 4
                sums[0] += Int(bytes[i]); sums[1] += Int(bytes[i + 1])
                sums[2] += Int(bytes[i + 2]); sums[3] += Int(bytes[i + 3])
                samples += 1
            }
        }
        guard samples > 0 else { return nil }
        let reference = sums.map { ($0 + samples / 2) / samples }
        func matches(_ i: Int) -> Bool {
            for c in 0..<4 {
                let d = Int(bytes[i + c]) - reference[c]
                if d < -settings.tolerance || d > settings.tolerance { return false }
            }
            return true
        }

        var mask = [UInt8](repeating: 0, count: width * height)
        if settings.contiguous {
            // Scanline flood fill: each popped seed fills its whole horizontal run, then
            // pushes one seed per matching run in the rows directly above and below it.
            var stack: [(Int, Int)] = [(x, y)]
            while let (seedX, seedY) = stack.popLast() {
                let row = seedY * width
                if mask[row + seedX] != 0 || !matches((row + seedX) * 4) { continue }
                var left = seedX, right = seedX
                while left > 0, mask[row + left - 1] == 0, matches((row + left - 1) * 4) { left -= 1 }
                while right + 1 < width, mask[row + right + 1] == 0, matches((row + right + 1) * 4) { right += 1 }
                mask.replaceSubrange(row + left...(row + right), with: repeatElement(255, count: right - left + 1))
                for ny in [seedY - 1, seedY + 1] where (0..<height).contains(ny) {
                    let nrow = ny * width
                    var inRun = false
                    for nx in left...right where mask[nrow + nx] == 0 && matches((nrow + nx) * 4) {
                        if !inRun { stack.append((nx, ny)) }
                        inRun = true
                    }
                }
            }
        } else {
            for i in 0..<(width * height) where matches(i * 4) { mask[i] = 255 }
        }
        guard mask.contains(255) else { return nil }

        let loops = MaskTracing.outline(grid: mask, width: width, height: height, channels: 1, offset: 0) { $0 != 0 }
        let edgeCount = loops.reduce(0) { $0 + $1.count }
        guard edgeCount <= edgeLimit else { throw Failure.tooDetailed }
        guard edgeCount >= 3 else { return nil }
        return .polygon(loops.flatMap { $0 })
    }
}

extension EditorSession {
    /// The Magic Wand: selects pixels similar to the one at `point` (document pixels),
    /// read from the active layer or every visible layer, combined with the current
    /// selection by `mode`. Returns false when nothing matched (a New selection is
    /// cleared, as a lasso click enclosing nothing does). One undo step.
    @discardableResult
    func magicWand(at point: CGPoint, settings: WandSettings, mode: SelectionMode,
                   antialiased: Bool, name: String = "Magic Wand") throws -> Bool {
        guard transformEdit == nil, brushStroke == nil, filterEdit == nil, warpStroke == nil, adjustmentEditingID == nil,
              canEditPixels, !isMaskSelected, let doc = document,
              [point.x, point.y].allSatisfy(\.isFinite) else { throw Failure.busy }
        guard point.x >= 0, point.y >= 0, point.x < doc.size.width, point.y < doc.size.height else {
            if mode == .replace { try setSelection(nil) }
            return false
        }
        guard let sample = wandSample(doc, sampleAllLayers: settings.sampleAllLayers) else { throw Failure.noLayer }
        do {
            guard let path = try MagicWand.select(in: sample, at: point, settings: settings) else {
                if mode == .replace { try setSelection(nil) }
                return false
            }
            if mode == .replace {
                try setSelection(DocumentSelection(path: path, antialiased: antialiased))
            } else {
                try applySelection(path, mode: mode, antialiased: antialiased, name: name)
            }
            return true
        } catch {
            brushError = error.localizedDescription
            throw error
        }
    }

    /// What the wand reads, at document size: every visible layer as shown on the
    /// canvas, or just the active layer's own pixels without its mask. A folder or
    /// blank layer reads as transparent.
    private func wandSample(_ doc: CanvasDocument, sampleAllLayers: Bool) -> RasterImage? {
        if sampleAllLayers {
            guard let composite = try? DocumentRenderer(doc).render() else { return nil }
            return RasterImage(composite)
        }
        guard let layer = activeLayer, !layer.isGroup, let image = layer.asset?.image else {
            return RasterImage(PortableImage(PixelBuffer(width: doc.width, height: doc.height)))
        }
        var canvas = PixelBuffer(width: doc.width, height: doc.height)
        let transform = displayedTransform(for: layer)
        LayerRenderer.draw(image, transform: transform, center: transform.center, into: &canvas)
        return RasterImage(PortableImage(canvas))
    }

    /// Combines `path` with the current selection by `mode`. The CG winding path
    /// boolean operations are exchanged for per-pixel coverage combine over the two
    /// paths' union bounding box, then a re-outline back to a path. Subtract from no
    /// selection selects nothing new, so nothing changes.
    private func applySelection(_ path: PortablePath, mode: SelectionMode,
                                antialiased: Bool, name: String) throws {
        guard let doc = document else { return }
        let newMask = DocumentSelection(path: path, antialiased: antialiased)
        let current = doc.selection.flatMap { $0.isEmpty ? nil : $0 }
        if mode == .subtract {
            guard let current else { return }
            let region = current.path.boundingBox.union(path.boundingBox)
                .insetBy(dx: -1, dy: -1).integral.intersection(CGRect(origin: .zero, size: doc.size))
            guard region.width >= 1, region.height >= 1 else { return }
            var result = MaskBuffer(width: Int(region.width), height: Int(region.height))
            let oldMask = current.rasterized(in: region)
            let innerMask = newMask.rasterized(in: region)
            for i in 0..<result.bytes.count {
                result.bytes[i] = UInt8(max(0, Int(oldMask.bytes[i]) - Int(innerMask.bytes[i])))
            }
            try setSelection(selection(from: result, rect: region, antialiased: antialiased))
        } else {
            let region = (current?.path.boundingBox ?? .zero).union(path.boundingBox)
                .insetBy(dx: -1, dy: -1).integral.intersection(CGRect(origin: .zero, size: doc.size))
            guard region.width >= 1, region.height >= 1 else { return }
            let innerMask = newMask.rasterized(in: region)
            if let current {
                let oldMask = current.rasterized(in: region)
                var merged = MaskBuffer(width: Int(region.width), height: Int(region.height))
                for i in 0..<merged.bytes.count {
                    merged.bytes[i] = max(oldMask.bytes[i], innerMask.bytes[i])
                }
                try setSelection(selection(from: merged, rect: region, antialiased: antialiased))
            } else {
                try setSelection(selection(from: innerMask, rect: region, antialiased: antialiased))
            }
        }
    }

    /// Re-traces a coverage mask to a selection path, shifted back to document space.
    private func selection(from mask: MaskBuffer, rect: CGRect, antialiased: Bool) -> DocumentSelection {
        let loops = MaskTracing.outline(grid: mask.bytes, width: mask.width, height: mask.height,
                                        channels: 1, offset: 0) { $0 >= 128 }
        guard !loops.isEmpty else { return DocumentSelection(path: .polygon([]), antialiased: antialiased) }
        let points = loops.flatMap { $0 }.map { CGPoint(x: $0.x + rect.minX, y: $0.y + rect.minY) }
        return DocumentSelection(path: .polygon(points), antialiased: antialiased)
    }
}