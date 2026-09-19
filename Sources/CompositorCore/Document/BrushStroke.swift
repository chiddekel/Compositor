// Portable port of Compositor/Document/BrushStroke.swift (file-map tier: "Apple
// replacement/adaptation: Keep sampling/smoothing and tile algorithm; replace
// CGContext/CGImage storage and paint operations").
//
// Kept verbatim (pure math): the centripetal Catmull–Rom sampling with the
// provisional-tail erase/redraw protocol, dab spacing, 256px touched-tile
// allocation with the allocated-bounds memory guard, the coverage-then-recompose
// publish pipeline (original + color × coverage × opacity), selection clipping,
// clone/erase/healing-wash semantics, gradient/fill/clear canvas passes, and the
// lift/move selected-pixels protocol. `BrushCommit` (flatten + alpha-bounds crop
// + thumbnail) is kept as a plain type; the actor isolation of the macOS
// original is a host-thread decision and returns with the async host milestone.
//
// Replaced: CGContext/CGImage with the canonical `PixelBuffer`/`MaskBuffer`/
// `PortableImage` substrate and direct per-pixel math in top-left document
// coordinates (the CGContext y-flip existed only to make CG draw top-left; the
// buffers already are). The C kernels (`brush_alpha_bounds`, `spot_heal`,
// `heal_coverage_bounds`) are called through the CompositorKernels module — the
// same .c files the C++ host builds, one implementation on both sides.
//
// Omitted:
//   - The GPU path (`MetalBrushCoverage`): macOS keeps Metal; the Linux Vulkan
//     backend lands as a `BrushCoverageComputing` implementation at the host
//     composition root (SOLID open/closed), not inside this file. This engine is
//     the CPU contract the GPU backend must reproduce (ENG-10/ENG-11 fixtures).
//   - `stamp`/`gridTip` tip caches: on macOS they bought back CG resampling
//     cost; here dabs are computed procedurally per pixel (distance-field
//     coverage), the same math with no resample step.
//     ponytail: un-measured procedural dabs may cost more than blitted tips for
//     very wide brushes; revisit with the brush benchmark after the Skia/Vulkan
//     milestone, not before.
//   - `RasterSnapshot` integration in `paintSnapshot` (a tile cache for redraw);
//     the flatten here produces the same committed pixels, the cache is the
//     renderer milestone.
//
// The macOS original stays the source of truth for behavior.

import Foundation
import CompositorKernels

// MARK: - Raster sampling helpers (top-left, canonical buffers)

enum RasterSample {
    /// Nearest-neighbour sample (CG `.none`). `fx`/`fy` are source-space
    /// coordinates; outside the image returns transparent/0.
    static func rgbaNearest(_ image: PortableImage, fx: CGFloat, fy: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let x = Int(floor(fx)), y = Int(floor(fy))
        guard image.kind == .rgba, x >= 0, y >= 0, x < image.width, y < image.height else { return (0, 0, 0, 0) }
        let i = y * image.bytesPerRow + x * 4
        return (image.bytes[i], image.bytes[i + 1], image.bytes[i + 2], image.bytes[i + 3])
    }

    /// Gray sample of a mask-kind image (or the alpha channel of an RGBA one).
    static func grayNearest(_ image: PortableImage, fx: CGFloat, fy: CGFloat) -> UInt8 {
        let x = Int(floor(fx)), y = Int(floor(fy))
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return 0 }
        let i = y * image.bytesPerRow + x * image.bytesPerPixel
        return image.bytes[i]
    }

    static func grayNearest(_ mask: MaskBuffer, fx: CGFloat, fy: CGFloat) -> UInt8 {
        let x = Int(floor(fx)), y = Int(floor(fy))
        guard x >= 0, y >= 0, x < mask.width, y < mask.height else { return 0 }
        return mask[x, y]
    }

    /// Bilinear sample of premultiplied RGBA (CG `.low`/`.medium` box-class
    /// resampling). Coordinates outside the image sample transparent.
    static func rgbaBilinear(_ image: PortableImage, fx: CGFloat, fy: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard image.kind == .rgba else { return (0, 0, 0, 0) }
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - CGFloat(x0), ty = fy - CGFloat(y0)
        func sample(_ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
            guard x >= 0, y >= 0, x < image.width, y < image.height else { return (0, 0, 0, 0) }
            let i = y * image.bytesPerRow + x * 4
            return (Float(image.bytes[i]), Float(image.bytes[i + 1]), Float(image.bytes[i + 2]), Float(image.bytes[i + 3]))
        }
        let a = sample(x0, y0), b = sample(x0 + 1, y0), c = sample(x0, y0 + 1), d = sample(x0 + 1, y0 + 1)
        let w00 = Float((1 - tx) * (1 - ty)), w10 = Float(tx * (1 - ty))
        let w01 = Float((1 - tx) * ty), w11 = Float(tx * ty)
        func mix(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> UInt8 {
            let v = a * w00 + b * w10 + c * w01 + d * w11
            return v <= 0 ? 0 : v >= 255 ? 255 : UInt8(v + 0.5)
        }
        return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2), mix(a.3, b.3, c.3, d.3))
    }

    static func grayBilinear(_ image: PortableImage, fx: CGFloat, fy: CGFloat) -> UInt8 {
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - CGFloat(x0), ty = fy - CGFloat(y0)
        func sample(_ x: Int, _ y: Int) -> Float {
            guard x >= 0, y >= 0, x < image.width, y < image.height else { return 0 }
            return Float(image.bytes[y * image.bytesPerRow + x * image.bytesPerPixel])
        }
        let v = sample(x0, y0) * Float((1 - tx) * (1 - ty)) + sample(x0 + 1, y0) * Float(tx * (1 - ty))
            + sample(x0, y0 + 1) * Float((1 - tx) * ty) + sample(x0 + 1, y0 + 1) * Float(tx * ty)
        return v <= 0 ? 0 : v >= 255 ? 255 : UInt8(v + 0.5)
    }

    /// Box-filter downsample to at most `maxSide` (thumbnail quality class).
    static func thumbnail(_ image: PortableImage, maxSide: Int = 96) -> PortableImage {
        let factor = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * factor)), h = max(1, Int(CGFloat(image.height) * factor))
        let bpp = image.bytesPerPixel
        var out = [UInt8](repeating: 0, count: w * h * bpp)
        for dy in 0..<h {
            let sy0 = dy * image.height / h, sy1 = max(sy0 + 1, (dy + 1) * image.height / h)
            for dx in 0..<w {
                let sx0 = dx * image.width / w, sx1 = max(sx0 + 1, (dx + 1) * image.width / w)
                var acc = [Float](repeating: 0, count: bpp)
                let count = Float((sx1 - sx0) * (sy1 - sy0))
                for sy in sy0..<sy1 {
                    for sx in sx0..<sx1 {
                        let i = sy * image.bytesPerRow + sx * bpp
                        for b in 0..<bpp { acc[b] += Float(image.bytes[i + b]) }
                    }
                }
                let o = (dy * w + dx) * bpp
                for b in 0..<bpp { out[o + b] = UInt8(min(255, acc[b] / count + 0.5)) }
            }
        }
        return PortableImage(width: w, height: h, kind: image.kind, bytesPerRow: w * bpp, bytes: out)
    }
}

extension ImportedImage {
    /// Mask-style asset from raw mask pixels (the `LayerMask.asset(from:)` macOS
    /// helper): the image is the mask itself, thumbnail is a downsample.
    init(mask pixels: PortableImage, name: String) {
        self.init(image: RasterImage(pixels), thumbnail: RasterImage(RasterSample.thumbnail(pixels)), name: name)
    }
}

// MARK: - BrushStroke (portable CPU engine)

/// Only touched 256px tiles allocate writable pixels. Snapshots copy at most
/// those tiles, never the entire layer on a mouse-move event.
final class BrushStroke {
    let layer: ImageLayer
    let isMask: Bool
    let width: Int
    let height: Int
    let settings: BrushSettings
    let canvas: CGRect
    let pixelToDocument: CGAffineTransform
    let sourceRect: CGRect
    let paintTransform: LayerTransform
    private let source: PortableImage?
    private let paintGray: UInt8
    private let paintRGB: (r: UInt8, g: UInt8, b: UInt8)
    var pixelLimit = 100_000_000
    /// Limits every edit to the document selection; nil when nothing is selected.
    var selectionClip: SelectionClip?
    /// Clone Stamp: a document-size image to copy from, and the offset from each painted point to its source.
    var clone: (image: PortableImage, offset: CGSize)?
    /// A Blur stroke: `clone` holds the layer blurred, painted in place through the tip.
    var isBlur = false
    /// The clone sample replaces what's under the tip rather than drawing over it, so it can also clear pixels.
    var replacesWithClone = false
    /// The undo name, when the stroke's kind doesn't say it.
    var editName: String?
    private var allocatedBounds: CGRect?
    private var previous: CGPoint?
    private var samples: [CGPoint] = []
    /// Provisional-tail coverage backup: the tiles touched (set) and their saved
    /// coverage (dict; absent from the dict = the tile had no coverage yet, so
    /// `removeTail` zeroes it — the tri-state of the macOS `CGImage?` backup).
    private var tailBackupTiles = Set<Int>()
    private var tailBackupBuffers: [Int: MaskBuffer] = [:]
    private var distanceToNext: CGFloat = 0
    private(set) var dirtyDocumentRect: CGRect?
    private final class Tile {
        let rect: CGRect
        var pixels: PixelBuffer
        var maskPixels: MaskBuffer
        var image: PortableImage?
        let base: PortableImage
        init(rect: CGRect, pixels: PixelBuffer, maskPixels: MaskBuffer, base: PortableImage) {
            self.rect = rect
            self.pixels = pixels
            self.maskPixels = maskPixels
            self.base = base
        }
    }
    private var tiles: [Int: Tile] = [:]
    /// Per-tile grayscale coverage. Soft tips accumulate paint within the stroke;
    /// hard tips keep their antialiased silhouette. Each tile is recomposed as original
    /// + color × coverage × opacity, preserving the stroke-wide opacity cap.
    private var coverage: [Int: MaskBuffer] = [:]
    /// Tile edge in layer pixels. Wider tiles were measured to be no faster for wide
    /// brushes and slower for narrow ones.
    static let tileSize = 256
    /// The part of each tile the stroke touched since the last publish, in tile-local pixels.
    private var dirtyTiles: [Int: CGRect] = [:]
    var patches: [BrushPatch] {
        tiles.values.compactMap { tile in tile.image.map { BrushPatch(rect: tile.rect, image: $0) } }
    }

    init(layer: ImageLayer, mask: Bool, settings: BrushSettings, canvas: CGSize) throws {
        self.layer = layer
        isMask = mask
        self.settings = settings
        self.canvas = CGRect(origin: .zero, size: canvas)
        // A mask on its own placement is painted in its own pixel grid; otherwise the grid is the layer's.
        let placedMask = mask ? layer.mask.flatMap { mask in mask.placement.map { (mask.asset.image.pixels, $0) } } : nil
        let base = placedMask?.1 ?? layer.transform
        let originalWidth = placedMask?.0.width ?? layer.asset?.image.width ?? Int(layer.size.width.rounded())
        let originalHeight = placedMask?.0.height ?? layer.asset?.image.height ?? Int(layer.size.height.rounded())
        let originalMapping = BrushRaster.pixelToDocument(base, width: originalWidth, height: originalHeight)
        let originalBounds = CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight)
        let extent = mask ? originalBounds : originalBounds.union(self.canvas.applying(originalMapping.inverted()).integral)
        width = Int(extent.width)
        height = Int(extent.height)
        sourceRect = originalBounds.offsetBy(dx: -extent.minX, dy: -extent.minY)
        pixelToDocument = originalMapping.translatedBy(x: extent.minX, y: extent.minY)
        var expanded = base
        expanded.size = CGSize(width: CGFloat(width) * base.size.width / CGFloat(originalWidth),
                               height: CGFloat(height) * base.size.height / CGFloat(originalHeight))
        let center = CGPoint(x: extent.midX, y: extent.midY).applying(originalMapping)
        expanded.origin = CGPoint(x: center.x - expanded.size.width / 2, y: center.y - expanded.size.height / 2)
        paintTransform = expanded
        guard (1...1_000_000_000).contains(width), (1...1_000_000_000).contains(height),
              (1...30_000).contains(originalWidth), (1...30_000).contains(originalHeight),
              settings.diameter.isFinite, (1...2000).contains(settings.diameter),
              settings.hardness.isFinite, (0...1).contains(settings.hardness),
              settings.opacity.isFinite, (0.01...1).contains(settings.opacity) else { throw ProjectError.tooLarge }
        func channel(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, v * 255 + 0.5))) }
        paintGray = channel(settings.red)
        paintRGB = (channel(settings.red), channel(settings.green), channel(settings.blue))
        source = mask ? layer.mask?.asset.image.pixels : layer.asset?.image.pixels
    }

    /// Mouse samples arrive sparsely, so dabs follow a smooth curve through them rather
    /// than straight chords. A curve piece needs the sample after it, so the newest piece
    /// is first drawn as a provisional straight tail (the stroke never trails the cursor),
    /// then erased and replaced by the curve when the next sample arrives or on `flush()`.
    func append(_ point: CGPoint) throws {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 10_000_000, abs(point.y) <= 10_000_000 else { return }
        guard samples.last != point else { return }
        var changed = removeTail()
        samples.append(point)
        if samples.count > 4 { samples.removeFirst() }
        let count = samples.count
        if count == 1 {
            try walk(to: point, changed: &changed)
        } else if count >= 3 {
            try curve(from: samples[count - 3], to: samples[count - 2],
                      before: samples[max(0, count - 4)], after: samples[count - 1], changed: &changed)
        }
        if count >= 2 { try drawTail(from: samples[count - 2], to: point, changed: &changed) }
        try publish(changed)
    }

    /// Replaces the provisional tail with the stroke's final curve piece. Safe to repeat.
    func flush() throws {
        var changed = removeTail()
        let count = samples.count
        if count >= 2 {
            try curve(from: samples[count - 2], to: samples[count - 1],
                      before: samples[max(0, count - 3)], after: samples[count - 1], changed: &changed)
            samples = [samples[count - 1]]
        }
        try publish(changed)
    }

    /// Draws a straight tail to the cursor, first saving the coverage it can touch and the
    /// dab spacing state, so `removeTail()` can put both back exactly.
    private func drawTail(from start: CGPoint, to end: CGPoint, changed: inout Set<Int>) throws {
        let reach = settings.diameter / 2 + 2
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -reach, dy: -reach).intersection(canvas)
        if !box.isNull, !box.isEmpty {
            let affected = box.applying(pixelToDocument.inverted()).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if !affected.isNull, !affected.isEmpty {
                let columns = (width + Self.tileSize - 1) / Self.tileSize
                for y in Int(affected.minY) / Self.tileSize...Int(ceil(affected.maxY) - 1) / Self.tileSize {
                    for x in Int(affected.minX) / Self.tileSize...Int(ceil(affected.maxX) - 1) / Self.tileSize {
                        let key = y * columns + x
                        tailBackupTiles.insert(key)
                        if let buffer = coverage[key] { tailBackupBuffers[key] = buffer }
                    }
                }
            }
        }
        let saved = (previous, distanceToNext)
        try walk(to: end, changed: &changed)
        (previous, distanceToNext) = saved
    }

    private func removeTail() -> Set<Int> {
        var restored = Set<Int>()
        for key in tailBackupTiles {
            guard var context = coverage[key], let tile = tiles[key] else { continue }
            if let backup = tailBackupBuffers[key] {
                for y in 0..<min(backup.height, context.height) {
                    for x in 0..<min(backup.width, context.width) {
                        context[x, y] = backup[x, y]
                    }
                }
            } else {
                for y in 0..<context.height {
                    for x in 0..<context.width { context[x, y] = 0 }
                }
            }
            coverage[key] = context
            dirtyTiles[key] = CGRect(origin: .zero, size: tile.rect.size)
            restored.insert(key)
        }
        tailBackupTiles = []
        tailBackupBuffers = [:]
        return restored
    }

    /// Centripetal Catmull–Rom between `start` and `end`: it passes through every sample
    /// without the loops or overshoot uniform splines make at uneven mouse speeds.
    private func curve(from start: CGPoint, to end: CGPoint, before: CGPoint, after: CGPoint, changed: inout Set<Int>) throws {
        func knot(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint) -> CGFloat { t + max(0.0001, sqrt(hypot(b.x - a.x, b.y - a.y))) }
        func mix(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat, _ t: CGFloat) -> CGPoint {
            let wa = (tb - t) / (tb - ta), wb = (t - ta) / (tb - ta)
            return CGPoint(x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb)
        }
        let t0: CGFloat = 0, t1 = knot(t0, before, start), t2 = knot(t1, start, end), t3 = knot(t2, end, after)
        let pieces = max(1, Int(ceil(hypot(end.x - start.x, end.y - start.y) / 2)))
        for index in 1...pieces {
            let t = t1 + (t2 - t1) * CGFloat(index) / CGFloat(pieces)
            let a1 = mix(before, start, t0, t1, t), a2 = mix(start, end, t1, t2, t), a3 = mix(end, after, t2, t3, t)
            let b1 = mix(a1, a2, t0, t2, t), b2 = mix(a2, a3, t1, t3, t)
            try walk(to: index == pieces ? end : mix(b1, b2, t1, t2, t), changed: &changed)
        }
    }

    /// Soft-tip deposition rate, shared with the continuous GPU integral.
    /// The software fallback lays actual dabs at this spacing.
    static func spacingFraction(_ hardness: CGFloat) -> CGFloat { hardness >= 1 ? 0.015 : 0.025 }

    /// Lays evenly spaced dabs along a straight run from the previous dab position.
    private func walk(to point: CGPoint, changed: inout Set<Int>) throws {
        let spacing = max(0.25, settings.diameter * Self.spacingFraction(settings.hardness))
        if let previous {
            let dx = point.x - previous.x, dy = point.y - previous.y
            let length = hypot(dx, dy)
            if length > 0 {
                var distance = distanceToNext
                while distance <= length {
                    try dab(CGPoint(x: previous.x + dx * distance / length, y: previous.y + dy * distance / length), changed: &changed)
                    distance += spacing
                }
                distanceToNext = distance - length
            }
        } else {
            try dab(point, changed: &changed)
            distanceToNext = spacing
        }
        previous = point
    }

    private func publish(_ changed: Set<Int>) throws {
        dirtyDocumentRect = nil
        let opacity = Float(settings.opacity)
        for key in changed {
            guard let tile = tiles[key], let cov = coverage[key] else { continue }
            let local = CGRect(origin: .zero, size: tile.rect.size)
            // Rebuild only the touched part of the tile; the rest is already correct.
            let dirty = (dirtyTiles[key] ?? local).integral.intersection(local)
            dirtyTiles[key] = nil
            guard !dirty.isNull, !dirty.isEmpty else { continue }
            let dx = Int(dirty.minX), dy = Int(dirty.minY)
            let dw = Int(ceil(dirty.maxX)) - dx, dh = Int(ceil(dirty.maxY)) - dy
            // Recompose from the tile's ORIGINAL content (base), never the current
            // pixels: each publish must be base + color × coverage × opacity, or a
            // stroke republished across mouse moves would stack opacity (the
            // stroke-wide cap lives in coverage, not in repeated compositing).
            let baseImage = tile.base
            let baseBPP = baseImage.bytesPerPixel
            let baseRow = baseImage.bytesPerRow
            for y in dy..<(dy + dh) {
                for x in dx..<(dx + dw) {
                    // Document-space coverage: selection clip × stroke coverage.
                    let doc = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(pixelToDocument)
                    var eff = Float(cov[x, y]) / 255
                    if let clip = selectionClip { eff *= selectionFactor(clip, at: doc) }
                    if isMask {
                        let base = Float(baseImage.bytes[y * baseRow + x * baseBPP])
                        if let clone, isBlur {
                            // Blur on a mask: the blurred sample (grayscale) through the coverage.
                            let fx = doc.x - clone.offset.width, fy = doc.y - clone.offset.height
                            let sample = Float(RasterSample.grayBilinear(clone.image, fx: fx, fy: fy))
                            tile.maskPixels[x, y] = blend8(sample * opacity * eff, base, opacity * eff)
                        } else {
                            tile.maskPixels[x, y] = blend8(Float(paintGray) * opacity * eff, base, opacity * eff)
                        }
                    } else {
                        let bi = (y * baseRow + x * 4)
                        let (brF, bgF, bbF, baF) = (Float(baseImage.bytes[bi]), Float(baseImage.bytes[bi + 1]),
                                                     Float(baseImage.bytes[bi + 2]), Float(baseImage.bytes[bi + 3]))
                        let out: (UInt8, UInt8, UInt8, UInt8)
                        if let clone {
                            // Clone Stamp: the sample, shifted by the source offset, painted through the coverage.
                            let fx = doc.x - clone.offset.width, fy = doc.y - clone.offset.height
                            let s = RasterSample.rgbaBilinear(clone.image, fx: fx, fy: fy)
                            out = (blend8(Float(s.r) * opacity * eff, brF, opacity * eff),
                                   blend8(Float(s.g) * opacity * eff, bgF, opacity * eff),
                                   blend8(Float(s.b) * opacity * eff, bbF, opacity * eff),
                                   blend8(Float(s.a) * opacity * eff, baF, opacity * eff))
                        } else if settings.healing {
                            // While painting, the area to heal shows as a dark wash, as in Photoshop;
                            // `heal()` rebuilds it from its surroundings when the stroke ends.
                            let wash = Float(Self.healingWashGray) * 0.45 * eff
                            out = (blend8(wash, brF, 0.45 * eff),
                                   blend8(wash, bgF, 0.45 * eff),
                                   blend8(wash, bbF, 0.45 * eff),
                                   blend8(0.45 * eff * 255, baF, 0.45 * eff))
                        } else if settings.erasing {
                            // Erasing takes the coverage out of the layer's alpha, leaving the pixels under it transparent.
                            out = (UInt8(brF * (1 - opacity * eff) + 0.5),
                                   UInt8(bgF * (1 - opacity * eff) + 0.5),
                                   UInt8(bbF * (1 - opacity * eff) + 0.5),
                                   UInt8(baF * (1 - opacity * eff) + 0.5))
                        } else {
                            out = (blend8(Float(paintRGB.r) * opacity * eff, brF, opacity * eff),
                                   blend8(Float(paintRGB.g) * opacity * eff, bgF, opacity * eff),
                                   blend8(Float(paintRGB.b) * opacity * eff, bbF, opacity * eff),
                                   blend8(opacity * eff * 255, baF, opacity * eff))
                        }
                        tile.pixels[x, y] = out
                    }
                }
            }
            tile.image = isMask ? PortableImage(tile.maskPixels) : PortableImage(tile.pixels)
            let rect = tile.rect.applying(pixelToDocument).intersection(canvas)
            if !rect.isNull {
                dirtyDocumentRect = dirtyDocumentRect.map { $0.union(rect) } ?? rect
            }
        }
    }

    /// `src + dst * (1 - a)` rounded — premultiplied source-over at factor `a`.
    @inline(__always)
    private func blend8(_ src: Float, _ dst: Float, _ a: Float) -> UInt8 {
        let v = src + dst * (1 - a)
        return v <= 0 ? 0 : v >= 255 ? 255 : UInt8(v + 0.5)
    }

    private static let healingWashGray: UInt8 = 31 // ~0.12 sRGB

    /// Selection coverage at a document point: 0 outside the clip rect, the
    /// coverage byte (nearest) inside, 1 when the clip has no coverage image.
    private func selectionFactor(_ clip: SelectionClip, at doc: CGPoint) -> Float {
        guard doc.x >= clip.rect.minX, doc.x < clip.rect.maxX,
              doc.y >= clip.rect.minY, doc.y < clip.rect.maxY else { return 0 }
        guard let cov = clip.coverage else { return 1 }
        return Float(RasterSample.grayNearest(cov, fx: doc.x - clip.rect.minX, fy: doc.y - clip.rect.minY)) / 255
    }

    private func dab(_ point: CGPoint, changed: inout Set<Int>) throws {
        let radius = settings.diameter / 2
        let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let clipped = circle.intersection(canvas)
        guard !clipped.isNull, !clipped.isEmpty else { return }
        let inverse = pixelToDocument.inverted()
        let pixelCanvas = canvas.applying(inverse)
        let affected = clipped.applying(inverse).intersection(pixelCanvas)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !affected.isNull, !affected.isEmpty else { return }
        let columns = (width + Self.tileSize - 1) / Self.tileSize
        let hard = settings.hardness >= 1
        let inner = radius * settings.hardness
        let softSpan = max(0.0001, radius - inner)
        for tileY in Int(affected.minY) / Self.tileSize...Int(ceil(affected.maxY) - 1) / Self.tileSize {
            for tileX in Int(affected.minX) / Self.tileSize...Int(ceil(affected.maxX) - 1) / Self.tileSize {
                let key = tileY * columns + tileX
                try allocateTile(key, x: tileX, y: tileY)
                guard let tile = tiles[key] else { continue }
                if coverage[key] == nil { coverage[key] = MaskBuffer(width: Int(tile.rect.width), height: Int(tile.rect.height)) }
                guard var cov = coverage[key] else { continue }
                let ox = Int(tile.rect.minX), oy = Int(tile.rect.minY)
                let startX = max(Int(affected.minX), ox), endX = min(Int(ceil(affected.maxX)), ox + Int(tile.rect.width))
                let startY = max(Int(affected.minY), oy), endY = min(Int(ceil(affected.maxY)), oy + Int(tile.rect.height))
                var touched = CGRect.null
                for y in startY..<endY {
                    for x in startX..<endX {
                        // Tip coverage from the document-space distance field: inside the
                        // hardness radius it is full, then the Gaussian falloff to the rim.
                        let doc = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(pixelToDocument)
                        let dist = hypot(doc.x - point.x, doc.y - point.y)
                        let tip: CGFloat
                        if hard {
                            tip = max(0, min(1, radius - dist + 0.5))
                        } else if dist <= inner {
                            tip = 1
                        } else if dist < radius {
                            tip = BrushRaster.falloff((dist - inner) / softSpan)
                        } else {
                            tip = 0
                        }
                        guard tip > 0 else { continue }
                        let lx = x - ox, ly = y - oy
                        // Accumulate within the stroke: hard tips lighten (silhouette),
                        // soft tips screen (deposition adds, never exceeds 1).
                        let current = Float(cov[lx, ly])
                        let tipF = Float(tip * 255)
                        let next: Float
                        if hard {
                            next = max(current, tipF)
                        } else {
                            next = current + tipF - current * tipF / 255
                        }
                        cov[lx, ly] = UInt8(min(255, next + 0.5))
                        touched = touched.isNull
                            ? CGRect(x: CGFloat(lx), y: CGFloat(ly), width: 1, height: 1)
                            : touched.union(CGRect(x: CGFloat(lx), y: CGFloat(ly), width: 1, height: 1))
                    }
                }
                coverage[key] = cov
                if !touched.isNull {
                    dirtyTiles[key] = dirtyTiles[key].map { $0.union(touched) } ?? touched
                    changed.insert(key)
                }
            }
        }
    }

    private func allocateTile(_ key: Int, x: Int, y: Int) throws {
        guard tiles[key] == nil else { return }
        let size = Self.tileSize
        let rect = CGRect(x: x * size, y: y * size, width: min(size, width - x * size), height: min(size, height - y * size))
        let nextBounds = allocatedBounds.map { $0.union(rect) } ?? (source == nil ? rect : sourceRect.union(rect))
        guard nextBounds.width <= 30_000, nextBounds.height <= 30_000,
              nextBounds.width * nextBounds.height <= CGFloat(pixelLimit) else { throw ProjectError.tooLarge }
        allocatedBounds = nextBounds
        let tw = Int(rect.width), th = Int(rect.height)
        var pixels = PixelBuffer(width: tw, height: th)
        var maskPixels = MaskBuffer(width: tw, height: th)
        // This tile's share of the source, nearest-neighbour (CG `.none` on macOS).
        // A uniform 1×1 mask is stretched over the whole grid by the same mapping.
        if let source {
            let scaleX = CGFloat(source.width) / sourceRect.width
            let scaleY = CGFloat(source.height) / sourceRect.height
            for py in 0..<th {
                for px in 0..<tw {
                    let fx = (CGFloat(px) + 0.5 + rect.minX - sourceRect.minX) * scaleX - 0.5
                    let fy = (CGFloat(py) + 0.5 + rect.minY - sourceRect.minY) * scaleY - 0.5
                    if isMask {
                        maskPixels[px, py] = RasterSample.grayNearest(source, fx: fx, fy: fy)
                    } else {
                        pixels[px, py] = RasterSample.rgbaNearest(source, fx: fx, fy: fy)
                    }
                }
            }
        }
        let base = isMask ? PortableImage(maskPixels) : PortableImage(pixels)
        tiles[key] = Tile(rect: rect, pixels: pixels, maskPixels: maskPixels, base: base)
    }

    // MARK: Canvas-wide passes

    /// Replaces this edit with a gradient over the whole canvas (or the selection),
    /// composited onto the original pixels. Redrawing restarts from each tile's original
    /// content, so moving the line never accumulates earlier previews.
    func fillGradient(_ shape: GradientShape, from start: CGPoint, to end: CGPoint,
                      colors: [PaletteColor], opacity: CGFloat) throws {
        guard colors.count >= 2 else { return }
        let c0 = colors[0], c1 = colors[colors.count - 1]
        let alpha = min(1, max(0, opacity))
        try paintCanvas { doc in
            let t: CGFloat
            switch shape {
            case .linear:
                let dx = end.x - start.x, dy = end.y - start.y
                let lengthSquared = dx * dx + dy * dy
                t = lengthSquared > 0 ? max(0, min(1, ((doc.x - start.x) * dx + (doc.y - start.y) * dy) / lengthSquared)) : 0
            case .radial:
                t = max(0, min(1, hypot(doc.x - start.x, doc.y - start.y) / max(0.0001, hypot(end.x - start.x, end.y - start.y))))
            }
            let mix: (CGFloat) -> CGFloat = { $0 } // placeholder to keep closure shape uniform
            _ = mix
            if isMask {
                let g0 = c0.red, g1 = c1.red
                return (PaletteColor(red: g0 + (g1 - g0) * t, green: 0, blue: 0), alpha)
            }
            return (PaletteColor(red: c0.red + (c1.red - c0.red) * t,
                                 green: c0.green + (c1.green - c0.green) * t,
                                 blue: c0.blue + (c1.blue - c0.blue) * t), alpha)
        }
    }

    /// Fills the selection (or the whole canvas) with a solid color.
    func fill(_ color: PaletteColor) throws {
        try paintCanvas { _ in (color, 1) }
    }

    /// Erases image pixels to transparency inside the selection, only where pixels exist.
    func clearPixels() throws {
        try paintCanvas(withinSource: true, erase: true) { _ in (PaletteColor.black, 1) }
    }

    /// Runs `paint` in document coordinates over every tile the canvas and selection
    /// cover (only the layer's existing pixels with `withinSource`), clipped to both,
    /// starting from each tile's original content. `paint` returns (color, alpha);
    /// `erase` composites the alpha out instead of over.
    private func paintCanvas(withinSource: Bool = false, erase: Bool = false,
                             _ paint: (CGPoint) -> (PaletteColor, CGFloat)) throws {
        var area = canvas
        if let selectionClip { area = area.intersection(selectionClip.rect) }
        guard !area.isNull, !area.isEmpty else { return }
        let inverse = pixelToDocument.inverted()
        var affected = area.applying(inverse).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        if withinSource { affected = affected.intersection(sourceRect) }
        guard !affected.isNull, !affected.isEmpty else { return }
        let columns = (width + Self.tileSize - 1) / Self.tileSize
        for y in Int(affected.minY) / Self.tileSize...Int(ceil(affected.maxY) - 1) / Self.tileSize {
            for x in Int(affected.minX) / Self.tileSize...Int(ceil(affected.maxX) - 1) / Self.tileSize {
                let key = y * columns + x
                try allocateTile(key, x: x, y: y)
                guard let tile = tiles[key] else { continue }
                let tw = Int(tile.rect.width), th = Int(tile.rect.height)
                // Canvas passes restart from each tile's original content (the
                // macOS clear-then-redraw-base semantics) so preview redraws never
                // accumulate.
                let baseImage = tile.base
                let baseRow = baseImage.bytesPerRow
                let baseBPP = baseImage.bytesPerPixel
                for py in 0..<th {
                    for px in 0..<tw {
                        let doc = CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5).applying(pixelToDocument)
                        guard canvas.contains(doc) else { continue }
                        var factor: Float = 1
                        if let clip = selectionClip { factor = selectionFactor(clip, at: doc) }
                        guard factor > 0 else { continue }
                        let (color, alpha) = paint(doc)
                        let eff = Float(min(1, max(0, alpha))) * factor
                        let bi = py * baseRow + px * baseBPP
                        if isMask {
                            let base = Float(baseImage.bytes[bi])
                            if erase {
                                tile.maskPixels[px, py] = UInt8(base * (1 - eff) + 0.5)
                            } else {
                                tile.maskPixels[px, py] = blend8(Float(color.red) * eff * 255, base, eff)
                            }
                        } else {
                            let (brF, bgF, bbF, baF) = (Float(baseImage.bytes[bi]), Float(baseImage.bytes[bi + 1]),
                                                        Float(baseImage.bytes[bi + 2]), Float(baseImage.bytes[bi + 3]))
                            if erase {
                                tile.pixels[px, py] = (UInt8(brF * (1 - eff) + 0.5),
                                                       UInt8(bgF * (1 - eff) + 0.5),
                                                       UInt8(bbF * (1 - eff) + 0.5),
                                                       UInt8(baF * (1 - eff) + 0.5))
                            } else {
                                tile.pixels[px, py] = (blend8(Float(color.red) * eff * 255, brF, eff),
                                                       blend8(Float(color.green) * eff * 255, bgF, eff),
                                                       blend8(Float(color.blue) * eff * 255, bbF, eff),
                                                       blend8(eff * 255, baF, eff))
                            }
                        }
                    }
                }
                tile.image = isMask ? PortableImage(tile.maskPixels) : PortableImage(tile.pixels)
            }
        }
        dirtyDocumentRect = canvas
    }

    // MARK: Moving selected pixels

    /// Selected image pixels cut out of the layer, in layer pixel coordinates.
    private var lifted: (image: PortableImage, rect: CGRect)?
    private var moveTiles = Set<Int>()

    /// Cuts the selected pixels out of the original image. False when nothing is lifted.
    func liftSelection() throws -> Bool {
        guard !isMask, let source, let selectionClip, selectionClip.coverage != nil else { return false }
        let inverse = pixelToDocument.inverted()
        let region = selectionClip.rect.applying(inverse).integral.intersection(sourceRect)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return false }
        let w = Int(region.width), h = Int(region.height)
        var buffer = PixelBuffer(width: w, height: h)
        let scaleX = CGFloat(source.width) / sourceRect.width
        let scaleY = CGFloat(source.height) / sourceRect.height
        for y in 0..<h {
            for x in 0..<w {
                let doc = CGPoint(x: CGFloat(x) + 0.5 + region.minX, y: CGFloat(y) + 0.5 + region.minY).applying(pixelToDocument)
                let f = selectionFactor(selectionClip, at: doc)
                let fx = (CGFloat(x) + 0.5 + region.minX - sourceRect.minX) * scaleX - 0.5
                let fy = (CGFloat(y) + 0.5 + region.minY - sourceRect.minY) * scaleY - 0.5
                let s = RasterSample.rgbaNearest(source, fx: fx, fy: fy)
                buffer[x, y] = (UInt8(Float(s.r) * f + 0.5), UInt8(Float(s.g) * f + 0.5),
                                UInt8(Float(s.b) * f + 0.5), UInt8(Float(s.a) * f + 0.5))
            }
        }
        lifted = (PortableImage(buffer), region)
        return true
    }

    /// Rebuilds the affected tiles from the original: the selection becomes a transparent
    /// hole and the lifted pixels are placed `offset` document pixels away.
    func moveLifted(by offset: CGSize, duplicate: Bool = false) throws {
        guard let lifted, let selectionClip else { return }
        let inverse = pixelToDocument.inverted()
        let zero = CGPoint.zero.applying(inverse)
        let moved = CGPoint(x: offset.width, y: offset.height).applying(inverse)
        let target = lifted.rect.offsetBy(dx: moved.x - zero.x, dy: moved.y - zero.y)
        let whole = target.minX == target.minX.rounded() && target.minY == target.minY.rounded()
        let needed = lifted.rect.union(target).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        var keys = moveTiles
        if !needed.isNull, !needed.isEmpty {
            let columns = (width + Self.tileSize - 1) / Self.tileSize
            for y in Int(needed.minY) / Self.tileSize...Int(ceil(needed.maxY) - 1) / Self.tileSize {
                for x in Int(needed.minX) / Self.tileSize...Int(ceil(needed.maxX) - 1) / Self.tileSize {
                    let key = y * columns + x
                    try allocateTile(key, x: x, y: y)
                    keys.insert(key)
                }
            }
        }
        for key in keys {
            guard let tile = tiles[key] else { continue }
            let tw = Int(tile.rect.width), th = Int(tile.rect.height)
            for py in 0..<th {
                for px in 0..<tw {
                    let doc = CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5).applying(pixelToDocument)
                    let sel = selectionFactor(selectionClip, at: doc)
                    var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                    if tile.base.kind == .rgba {
                        let i = py * tile.base.bytesPerRow + px * 4
                        r = Float(tile.base.bytes[i]); g = Float(tile.base.bytes[i + 1])
                        b = Float(tile.base.bytes[i + 2]); a = Float(tile.base.bytes[i + 3])
                    }
                    // Cut the selection out of the original (not when duplicating).
                    if !duplicate {
                        let keep = 1 - sel
                        r *= keep; g *= keep; b *= keep; a *= keep
                    }
                    // Draw the lifted pixels at the target, nearest when whole-pixel
                    // (CG `.none`) else bilinear (CG `.high`; Lanczos-class on macOS —
                    // ponytail: bilinear diverges slightly at fractional offsets; switch
                    // to a Lanczos resampler in the Skia milestone if fixtures demand it).
                    let sx = CGFloat(px) + 0.5 + tile.rect.minX - target.minX - 0.5
                    let sy = CGFloat(py) + 0.5 + tile.rect.minY - target.minY - 0.5
                    if sx >= 0, sy >= 0, sx < CGFloat(lifted.image.width), sy < CGFloat(lifted.image.height) {
                        let s = whole
                            ? RasterSample.rgbaNearest(lifted.image, fx: sx, fy: sy)
                            : RasterSample.rgbaBilinear(lifted.image, fx: sx, fy: sy)
                        let sa = Float(s.a) / 255
                        r = Float(s.r) + r * (1 - sa)
                        g = Float(s.g) + g * (1 - sa)
                        b = Float(s.b) + b * (1 - sa)
                        a = Float(s.a) + a * (1 - sa)
                    }
                    tile.pixels[px, py] = (UInt8(max(0, min(255, r + 0.5))),
                                           UInt8(max(0, min(255, g + 0.5))),
                                           UInt8(max(0, min(255, b + 0.5))),
                                           UInt8(max(0, min(255, a + 0.5))))
                }
            }
            tile.image = PortableImage(tile.pixels)
        }
        moveTiles = keys
        dirtyDocumentRect = canvas
    }

    var committedBounds: CGRect { (allocatedBounds ?? sourceRect).integral }
    var committedTransform: LayerTransform { transform(for: committedBounds) }
    func transform(for bounds: CGRect) -> LayerTransform {
        let center = CGPoint(x: bounds.midX, y: bounds.midY).applying(pixelToDocument)
        var result = paintTransform
        result.size = CGSize(width: bounds.width * paintTransform.size.width / CGFloat(width),
                             height: bounds.height * paintTransform.size.height / CGFloat(height))
        result.origin = CGPoint(x: center.x - result.size.width / 2, y: center.y - result.size.height / 2)
        return result
    }

    /// Spot Healing, once the stroke ends: rebuilds the painted area from nearby texture
    /// (`HealPixels.c`) and writes it into the stroke's tiles, so the usual commit applies it as
    /// one undo step. Reads the layer's original pixels, never the dark wash shown while painting.
    func heal() throws {
        guard settings.healing, !isMask else { return }
        var painted: CGRect?
        for (key, cov) in coverage {
            guard let tile = tiles[key] else { continue }
            var edges = [Int](repeating: 0, count: 4)
            cov.withUnsafeBytes { ptr in
                heal_coverage_bounds(ptr, cov.width, cov.height, cov.bytesPerRow, &edges)
            }
            guard edges[2] > edges[0], edges[3] > edges[1] else { continue }
            let rect = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
                .offsetBy(dx: tile.rect.minX, dy: tile.rect.minY)
            painted = painted.map { $0.union(rect) } ?? rect
        }
        guard let painted, let source else { return }
        // Room for the kernel's patch search, which looks up to about three spot-widths away.
        let reach = (max(painted.width, painted.height) + 32) * 3.2
        let region = painted.insetBy(dx: -reach, dy: -reach)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        let w = Int(region.width), h = Int(region.height)
        guard w > 0, h > 0 else { return }
        var pixels = PixelBuffer(width: w, height: h)
        var painting = MaskBuffer(width: w, height: h)
        let scaleX = CGFloat(source.width) / sourceRect.width
        let scaleY = CGFloat(source.height) / sourceRect.height
        // Original pixels + stroke coverage, both placed into the heal region.
        for py in 0..<h {
            for px in 0..<w {
                let fx = (CGFloat(px) + 0.5 + region.minX - sourceRect.minX) * scaleX - 0.5
                let fy = (CGFloat(py) + 0.5 + region.minY - sourceRect.minY) * scaleY - 0.5
                pixels[px, py] = RasterSample.rgbaNearest(source, fx: fx, fy: fy)
            }
        }
        for (key, cov) in coverage {
            guard let tile = tiles[key] else { continue }
            for py in 0..<cov.height {
                for px in 0..<cov.width {
                    let gx = px + Int(tile.rect.minX) - Int(region.minX)
                    let gy = py + Int(tile.rect.minY) - Int(region.minY)
                    guard gx >= 0, gy >= 0, gx < w, gy < h else { continue }
                    painting[gx, gy] = max(painting[gx, gy], cov[px, py])
                }
            }
        }
        let mode = Int32(SpotHealingMode.allCases.firstIndex(of: settings.healingMode) ?? 0)
        var rgba = pixels.bytes
        var gray = painting.bytes
        var result: Int32 = -1
        rgba.withUnsafeMutableBufferPointer { rgbaPtr in
            gray.withUnsafeMutableBufferPointer { grayPtr in
                result = spot_heal(rgbaPtr.baseAddress!, grayPtr.baseAddress!, w, h, pixels.bytesPerRow,
                                   Float(settings.opacity), mode, UInt32.random(in: .min ... .max))
            }
        }
        guard result == 0 else { throw ProjectError.tooLarge }
        pixels = PixelBuffer(width: w, height: h, bytes: rgba)
        let healed = PortableImage(pixels)
        // Write the healed region back into the stroke's tiles, from each tile's base.
        for key in coverage.keys {
            guard let tile = tiles[key] else { continue }
            let tw = Int(tile.rect.width), th = Int(tile.rect.height)
            for py in 0..<th {
                for px in 0..<tw {
                    let gx = px + Int(tile.rect.minX) - Int(region.minX)
                    let gy = py + Int(tile.rect.minY) - Int(region.minY)
                    guard gx >= 0, gy >= 0, gx < w, gy < h else { continue }
                    let i = gy * healed.bytesPerRow + gx * 4
                    var r = Float(healed.bytes[i]), g = Float(healed.bytes[i + 1])
                    var b = Float(healed.bytes[i + 2]), a = Float(healed.bytes[i + 3])
                    if let clip = selectionClip {
                        let doc = CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5).applying(pixelToDocument)
                        let f = selectionFactor(clip, at: doc)
                        r *= f; g *= f; b *= f; a *= f
                        if tile.base.kind == .rgba {
                            let bi = py * tile.base.bytesPerRow + px * 4
                            let keep = 1 - f
                            r += Float(tile.base.bytes[bi]) * keep
                            g += Float(tile.base.bytes[bi + 1]) * keep
                            b += Float(tile.base.bytes[bi + 2]) * keep
                            a += Float(tile.base.bytes[bi + 3]) * keep
                        }
                    }
                    tile.pixels[px, py] = (UInt8(max(0, min(255, r + 0.5))),
                                           UInt8(max(0, min(255, g + 0.5))),
                                           UInt8(max(0, min(255, b + 0.5))),
                                           UInt8(max(0, min(255, a + 0.5))))
                }
            }
            tile.image = PortableImage(tile.pixels)
        }
    }

    /// Painting only adds alpha. Existing content bounds remain valid, so only the
    /// changed 256px tiles need inspecting; there is no full-document bounds scan.
    func paintSnapshot() throws -> (asset: ImportedImage, transform: LayerTransform, bounds: CGRect) {
        var bounds: CGRect? = source == nil ? nil : sourceRect
        for tile in tiles.values where !isMask {
            var edges = [Int](repeating: 0, count: 4)
            tile.pixels.withUnsafeBytes { ptr in
                brush_alpha_bounds(ptr, tile.pixels.width, tile.pixels.height, tile.pixels.bytesPerRow, &edges)
            }
            guard edges[2] > edges[0], edges[3] > edges[1] else { continue }
            let rect = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
                .offsetBy(dx: tile.rect.minX, dy: tile.rect.minY)
            bounds = bounds.map { $0.union(rect) } ?? rect
        }
        let crop = bounds ?? committedBounds
        let (image, _) = try BrushCommit.render(input: commitInputForCrop(crop))
        return (ImportedImage(image: RasterImage(image),
                              thumbnail: RasterImage(RasterSample.thumbnail(image)),
                              name: layer.name),
                transform(for: crop), crop)
    }

    func commitInput() -> BrushCommit.Input {
        commitInputForCrop(committedBounds)
    }

    private func commitInputForCrop(_ bounds: CGRect) -> BrushCommit.Input {
        BrushCommit.Input(width: Int(bounds.width), height: Int(bounds.height), source: source,
            patches: patches.map { BrushPatch(rect: $0.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY), image: $0.image) },
            mask: isMask, name: layer.name, sourceRect: sourceRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
    }
}

// MARK: - BrushCommit

enum BrushCommit {
    struct Input: @unchecked Sendable {
        let width: Int, height: Int
        let source: PortableImage?
        let patches: [BrushPatch]
        let mask: Bool
        let name: String
        let sourceRect: CGRect
    }
    struct Output: @unchecked Sendable {
        let asset: ImportedImage
        let pixelBounds: CGRect
    }

    static func expandMask(_ asset: ImportedImage, for input: Input, croppedTo crop: CGRect) -> ImportedImage {
        if input.sourceRect == crop { return asset }
        let w = Int(crop.width), h = Int(crop.height)
        // New canvas area has no pre-existing mask restriction. Existing coverage stays aligned.
        var buffer = MaskBuffer(width: w, height: h, fill: 255)
        let mask = asset.image.pixels
        let srcW = CGFloat(mask.width), srcH = CGFloat(mask.height)
        for y in 0..<h {
            for x in 0..<w {
                let fx = CGFloat(x) + crop.minX - input.sourceRect.minX
                let fy = CGFloat(y) + crop.minY - input.sourceRect.minY
                // Outside the original mask grid the buffer stays at full white.
                guard fx >= 0, fy >= 0, fx < srcW, fy < srcH else { continue }
                buffer[x, y] = RasterSample.grayNearest(mask, fx: fx, fy: fy)
            }
        }
        return ImportedImage(mask: PortableImage(buffer), name: input.name)
    }

    /// Flattens source + patches into one image, crops to the nonzero-alpha bounds,
    /// and produces the thumbnail. Scan happens once here, never during pointer movement.
    static func render(input: Input) throws -> (PortableImage, CGRect) {
        let mask = input.mask
        var pixels = PixelBuffer(width: input.width, height: input.height)
        var grayPixels = MaskBuffer(width: input.width, height: input.height)
        func blit(_ image: PortableImage, in rect: CGRect) {
            let bx = Int(floor(rect.minX)), by = Int(floor(rect.minY))
            let bw = min(Int(rect.width.rounded(.up)), image.width)
            let bh = min(Int(rect.height.rounded(.up)), image.height)
            for y in 0..<bh {
                for x in 0..<bw {
                    let dx = bx + x, dy = by + y
                    guard dx >= 0, dy >= 0, dx < input.width, dy < input.height else { continue }
                    if mask {
                        grayPixels[dx, dy] = RasterSample.grayNearest(image, fx: CGFloat(x), fy: CGFloat(y))
                    } else if image.kind == .rgba {
                        let i = y * image.bytesPerRow + x * 4
                        pixels[dx, dy] = (image.bytes[i], image.bytes[i + 1], image.bytes[i + 2], image.bytes[i + 3])
                    }
                }
            }
        }
        if let source = input.source { blit(source, in: input.sourceRect) }
        for patch in input.patches { blit(patch.image, in: patch.rect) }
        let fullBounds = CGRect(x: 0, y: 0, width: input.width, height: input.height)
        var crop = fullBounds
        if !mask {
            var edges = [Int](repeating: 0, count: 4)
            pixels.withUnsafeBytes { ptr in
                brush_alpha_bounds(ptr, input.width, input.height, pixels.bytesPerRow, &edges)
            }
            if edges[2] > edges[0], edges[3] > edges[1] {
                crop = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
            }
        }
        let flattened = mask ? PortableImage(grayPixels) : PortableImage(pixels)
        let image: PortableImage
        if crop == fullBounds {
            image = flattened
        } else if let cropped = flattened.cropping(to: crop) {
            // A tight copy so small painted layers do not retain large empty buffers.
            image = cropped
        } else {
            image = mask ? PortableImage(MaskBuffer(width: 1, height: 1)) : PortableImage(PixelBuffer(width: 1, height: 1))
        }
        return (image, crop)
    }

    static func output(input: Input) throws -> Output {
        let (image, crop) = try render(input: input)
        let asset: ImportedImage
        if input.mask {
            asset = ImportedImage(mask: image, name: input.name)
        } else {
            asset = ImportedImage(image: RasterImage(image),
                                  thumbnail: RasterImage(RasterSample.thumbnail(image)),
                                  name: input.name)
        }
        return Output(asset: asset, pixelBounds: crop)
    }
}
