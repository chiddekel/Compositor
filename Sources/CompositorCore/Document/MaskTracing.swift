// Portable port of Compositor/Document/MaskTracing.swift's outline algorithm
// (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim: the
// marching-squares edge-following and corner-reduction that turn a pixel mask
// into selection-outline polygons. Outer boundaries run clockwise and holes
// counterclockwise, so a winding fill reproduces exactly the traced pixels.
//
// On macOS `trace` rasterizes a `CGImage` into a `CGContext` byte buffer, then
// reads the gray/alpha bytes; here the caller passes the already-extracted byte
// grid (`grid`, `width`, `height`, `channels`, `offset`), so the pure graph
// algorithm is reachable without `CGContext`/`CGImage`. The macOS `trace` returns
// one `CGPath` with a subpath per loop; `PortablePath` is a single path, so this
// port returns `[[CGPoint]]` — one array of corners per closed loop. Wrapping a
// loop into `PortablePath.polygon` (and representing outer + holes together) is
// the path-raster milestone.
//
// Omitted (raster + CGPath + model milestone):
//   - `darkPixels(in: CGImage)` / `opaquePixels(in: CGImage)` — the `CGContext`
//     rasterize-and-read-bytes step; the Skia/CPU raster milestone extracts the
//     grid instead, then calls `outline(...)`.
//   - `EditorSession.loadMaskSelection`/`loadLayerSelection` — they trace a
//     layer/mask `CGImage`, map the outline to document space with
//     `BrushRaster.pixelToDocument`, and apply it as a selection; they need
//     `PortablePath.copy(using:)` (deferred) and `EditorSession` state. Model +
//     path milestone.
//
// SOLID: the outline algorithm keeps its responsibility and contract (a pixel
// grid → a set of corner polygons with correct winding); the Apple API surface
// (CGContext/CGImage rasterize, CGPath build, EditorSession state) is exchanged.
// The macOS original stays the source of truth.

import Foundation

nonisolated enum MaskTracing {
    /// Outline loops, in the image's top-left pixel coordinates, of pixels whose gray value (or
    /// alpha) passes `test`. Outer boundaries run clockwise and holes counterclockwise, so the
    /// winding fill rule reproduces exactly the traced pixels. Empty when none pass.
    ///
    /// - Parameters:
    ///   - grid: row-major byte buffer of length `width * height * channels`.
    ///   - channels: bytes per pixel (1 for a gray bitmap, 4 for RGBA).
    ///   - offset: byte index within each pixel to test (0 for gray, 3 for premultiplied-last alpha).
    static func outline(grid: [UInt8], width: Int, height: Int, channels: Int, offset: Int,
                         test: (UInt8) -> Bool) -> [[CGPoint]] {
        guard width > 0, height > 0, channels > 0, offset >= 0, offset < channels,
              grid.count >= width * height * channels else { return [] }
        func selected(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && test(grid[(y * width + x) * channels + offset])
        }
        // Directed unit edges between selected and unselected pixels, keyed by start vertex.
        let stride = width + 1
        var outgoing: [Int: [Int]] = [:]
        func edge(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { outgoing[y0 * stride + x0, default: []].append(y1 * stride + x1) }
        for y in 0..<height {
            for x in 0..<width where selected(x, y) {
                if !selected(x, y - 1) { edge(x, y, x + 1, y) }
                if !selected(x + 1, y) { edge(x + 1, y, x + 1, y + 1) }
                if !selected(x, y + 1) { edge(x + 1, y + 1, x, y + 1) }
                if !selected(x - 1, y) { edge(x, y + 1, x, y) }
            }
        }
        guard !outgoing.isEmpty else { return [] }
        var loops: [[CGPoint]] = []
        while let start = outgoing.keys.first {
            var loop: [Int] = []
            var current = start
            repeat {
                guard var ends = outgoing[current], let end = ends.popLast() else { break }
                outgoing[current] = ends.isEmpty ? nil : ends
                loop.append(current)
                current = end
            } while current != start
            // Keep only corners: drop vertices that continue in a straight line.
            var corners: [CGPoint] = []
            for (index, vertex) in loop.enumerated() {
                let previous = loop[(index + loop.count - 1) % loop.count], following = loop[(index + 1) % loop.count]
                let inX = vertex % stride - previous % stride, inY = vertex / stride - previous / stride
                let outX = following % stride - vertex % stride, outY = following / stride - vertex / stride
                if inX != outX || inY != outY { corners.append(CGPoint(x: vertex % stride, y: vertex / stride)) }
            }
            guard corners.count >= 3 else { continue }
            loops.append(corners)
        }
        return loops
    }

    /// Outline of a gray mask's pixels darker than 50% gray (the hidden areas of a mask).
    /// `grayGrid` is a single-byte-per-pixel row-major buffer of length `width * height`.
    static func darkOutline(grayGrid: [UInt8], width: Int, height: Int) -> [[CGPoint]] {
        outline(grid: grayGrid, width: width, height: height, channels: 1, offset: 0) { $0 < 128 }
    }

    /// Outline of an image's pixels that are at least 50% opaque.
    /// `alphaGrid` is the alpha channel as a row-major byte buffer of length `width * height`.
    static func opaqueOutline(alphaGrid: [UInt8], width: Int, height: Int) -> [[CGPoint]] {
        outline(grid: alphaGrid, width: width, height: height, channels: 1, offset: 0) { $0 >= 128 }
    }
}