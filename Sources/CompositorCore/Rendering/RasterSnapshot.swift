// Portable port of Compositor/Rendering/RasterSnapshot.swift (file-map tier:
// "Apple replacement/adaptation: Keep immutable tile replacement/lazy
// materialization; implement portable buffers").
//
// Kept verbatim: the sparse-tile replacement algorithm (old patches split at
// new-tile edges via 256px spatial buckets so the display list stays disjoint
// and flat), base sharing with untouched tiles, the lazy single materialization
// under a lock (bytes exist only when a consumer asks, never on mouse-up), and
// the halving-grid `alignment` invariant (ENG-11: carried across commits so
// patches never shift between zoom levels — see TiledLayerRenderer).
//
// Replaced: CGImage/CGContext with the canonical buffers. `makeImage` still
// materializes once and shares the same byte array (Swift Array CoW) instead
// of CGDataProvider zero-copy wrapping. `draw(in:context:)` becomes
// `rendered(width:height:in:)`: nearest-neighbour sampling, the exact math of
// `BrushRaster.draw` with `.none` interpolation on macOS (including the
// mask-expansion white fill outside the base).
//
// The macOS original stays the source of truth for behavior.

import Foundation

/// Immutable sparse raster. Paint commits share untouched tiles with their source.
/// A contiguous backing buffer is materialized only when a consumer (export or an
/// image-processing operation) actually requests its bytes, never on mouse-up.
nonisolated final class RasterSnapshot: @unchecked Sendable {
    let width: Int
    let height: Int
    let base: RasterImage?
    let baseRect: CGRect
    let patches: [BrushPatch]
    let isMask: Bool
    /// Where this raster's halving grids start (see `TiledLayerRenderer`): its base's origin, or for a raster
    /// painted from nothing, the grid of the stroke that made it — carried across commits so they never shift.
    let alignment: CGPoint
    private var bytesPerPixel: Int { isMask ? 1 : 4 }
    private let lock = NSLock()
    private var materialized: PortableImage?

    init(width: Int, height: Int, base: RasterImage?, baseRect: CGRect, patches: [BrushPatch], isMask: Bool = false, alignment: CGPoint? = nil) {
        self.width = width
        self.height = height
        self.base = base
        self.baseRect = baseRect
        self.patches = patches
        self.isMask = isMask
        self.alignment = alignment ?? baseRect.origin
    }

    /// New patches are complete replacement tiles, including transparent pixels.
    /// Split older patches at their edges to keep the display list disjoint and flat.
    static func replacing(source: ImportedImage?, sourceRect: CGRect, patches new: [BrushPatch], crop: CGRect, isMask: Bool = false) -> RasterSnapshot {
        let old = source?.raster
        let dx = sourceRect.minX - crop.minX, dy = sourceRect.minY - crop.minY
        var patches = (old?.patches ?? []).map {
            BrushPatch(rect: $0.rect.offsetBy(dx: dx, dy: dy), image: $0.image)
        }
        let additions = new.map { BrushPatch(rect: $0.rect.offsetBy(dx: -crop.minX, dy: -crop.minY), image: $0.image) }
        // Spatial indexing keeps the handoff proportional to touched tiles, rather
        // than comparing every old tile with every new tile on a large document.
        func cells(_ rect: CGRect) -> [SIMD2<Int>] {
            guard !rect.isEmpty else { return [] }
            var result: [SIMD2<Int>] = []
            for y in Int(floor(rect.minY / 256))...Int(ceil(rect.maxY / 256) - 1) {
                for x in Int(floor(rect.minX / 256))...Int(ceil(rect.maxX / 256) - 1) { result.append(SIMD2(x, y)) }
            }
            return result
        }
        var buckets: [SIMD2<Int>: [Int]] = [:]
        for (index, addition) in additions.enumerated() {
            for cell in cells(addition.rect) { buckets[cell, default: []].append(index) }
        }
        patches = patches.flatMap { patch -> [BrushPatch] in
            let candidates = Set(cells(patch.rect).flatMap { buckets[$0] ?? [] })
            var pieces = [patch]
            for index in candidates {
                let addition = additions[index]
                pieces = pieces.flatMap { piece -> [BrushPatch] in
                    let overlap = piece.rect.intersection(addition.rect)
                    guard !overlap.isNull, !overlap.isEmpty else { return [piece] }
                    let r = piece.rect
                    let rects = [CGRect(x: r.minX, y: r.minY, width: r.width, height: overlap.minY - r.minY),
                        CGRect(x: r.minX, y: overlap.maxY, width: r.width, height: r.maxY - overlap.maxY),
                        CGRect(x: r.minX, y: overlap.minY, width: overlap.minX - r.minX, height: overlap.height),
                        CGRect(x: overlap.maxX, y: overlap.minY, width: r.maxX - overlap.maxX, height: overlap.height)]
                    return rects.compactMap { rect in
                        guard rect.width > 0, rect.height > 0,
                              let image = piece.image.cropping(to: rect.offsetBy(dx: -r.minX, dy: -r.minY)) else { return nil }
                        return BrushPatch(rect: rect, image: image)
                    }
                }
            }
            return pieces
        }
        patches += additions
        let bounds = CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
        patches = patches.compactMap { patch in
            let rect = patch.rect.intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { return nil }
            if rect == patch.rect { return patch }
            guard let image = patch.image.cropping(to: rect.offsetBy(dx: -patch.rect.minX, dy: -patch.rect.minY)) else { return nil }
            return BrushPatch(rect: rect, image: image)
        }
        return RasterSnapshot(width: Int(crop.width), height: Int(crop.height), base: old?.base ?? (old == nil ? source?.image : nil),
            baseRect: old?.baseRect.offsetBy(dx: dx, dy: dy) ?? sourceRect.offsetBy(dx: -crop.minX, dy: -crop.minY), patches: patches, isMask: isMask,
            alignment: CGPoint(x: sourceRect.minX + (old?.alignment.x ?? 0) - crop.minX, y: sourceRect.minY + (old?.alignment.y ?? 0) - crop.minY))
    }

    /// Point lookup in raster coordinates (the inner loop of `rendered`):
    /// the one disjoint patch covering the point, else the base, else the
    /// out-of-base fill (white for masks, transparent for images).
    private func sample(u: CGFloat, v: CGFloat) -> [UInt8] {
        let bpp = bytesPerPixel
        var value: [UInt8]
        if isMask { value = [255] } else { value = [0, 0, 0, 0] }
        for patch in patches where patch.rect.contains(CGPoint(x: u, y: v)) {
            let fx = u - patch.rect.minX, fy = v - patch.rect.minY
            if isMask {
                value[0] = RasterSample.grayNearest(patch.image, fx: fx, fy: fy)
            } else {
                let s = RasterSample.rgbaNearest(patch.image, fx: fx, fy: fy)
                value = [s.r, s.g, s.b, s.a]
            }
            return value
        }
        if let base, baseRect.contains(CGPoint(x: u, y: v)) {
            let pixels = base.pixels
            let fx = (u - baseRect.minX) / baseRect.width * CGFloat(pixels.width) - 0.5
            let fy = (v - baseRect.minY) / baseRect.height * CGFloat(pixels.height) - 0.5
            if isMask {
                value[0] = RasterSample.grayNearest(pixels, fx: fx, fy: fy)
            } else {
                let s = RasterSample.rgbaNearest(pixels, fx: fx, fy: fy)
                value = [s.r, s.g, s.b, s.a]
            }
        }
        _ = bpp
        return value
    }

    /// One pixel for a consumer that samples tile-locally (brush tile allocation,
    /// heal regions): never materializes the full raster.
    func pixel(u: CGFloat, v: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let v4 = sample(u: u, v: v)
        return (v4[0], v4[1], v4[2], v4[3])
    }
    func grayPixel(u: CGFloat, v: CGFloat) -> UInt8 {
        sample(u: u, v: v)[0]
    }

    /// The raster's pixels resampled to `width` × `height`, nearest-neighbour
    /// (the `BrushRaster.draw` `.none`-interpolation contract). A mask raster
    /// fills white outside its base and patches (mask expansion reveals pixels).
    func rendered(width: Int, height: Int) -> PortableImage {
        precondition(width > 0 && height > 0)
        let bpp = bytesPerPixel
        // Canonical tile contract (plan §1): 8-bit premultiplied RGBA sRGB,
        // explicit byte stride == width * bytesPerPixel, explicit dimensions,
        // immutable once committed into a PortableImage (its fields are `let`).
        let stride = width * bpp
        var out = [UInt8](repeating: 0, count: height * stride)
        // Dest pixel center -> raster coordinate.
        for py in 0..<height {
            for px in 0..<width {
                let u = (CGFloat(px) + 0.5) * CGFloat(self.width) / CGFloat(width)
                let v = (CGFloat(py) + 0.5) * CGFloat(self.height) / CGFloat(height)
                let value = sample(u: u, v: v)
                let o = (py * width + px) * bpp
                for b in 0..<bpp { out[o + b] = value[b] }
            }
        }
        return PortableImage(width: width, height: height, kind: isMask ? .mask : .rgba, bytesPerRow: stride, bytes: out)
    }

    /// A lazy image over this raster (the macOS zero-copy CGDataProvider wrap):
    /// materializes at most once, on first pixel read — never on mouse-up.
    func makeImage() -> RasterImage {
        RasterImage(width: width, height: height, bytesPerRow: width * bytesPerPixel) { [weak self] in
            guard let self else {
                return PortableImage(MaskBuffer(width: 1, height: 1))
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            if let materialized { return materialized }
            let image = self.rendered(width: self.width, height: self.height)
            self.materialized = image
            return image
        }
    }

    var hasMaterializedPixels: Bool {
        lock.lock()
        defer { lock.unlock() }
        return materialized != nil
    }

    func thumbnail() throws -> PortableImage {
        let factor = min(1, 96 / CGFloat(max(width, height)))
        let w = max(1, Int(CGFloat(width) * factor)), h = max(1, Int(CGFloat(height) * factor))
        return rendered(width: w, height: h)
    }
}
