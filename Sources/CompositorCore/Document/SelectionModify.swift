// Portable port of `EditorSession.expandSelection(by:)` / `contractSelection(by:)` from
// Compositor/Document/Selection.swift. The macOS version strokes the CGPath and does
// path booleans; the portable `PortablePath` has no booleans, so the same result is
// produced on the raster: rasterize the outline, grow or shrink it by a true Euclidean
// disc of radius `amount` (exact distance transform) and re-trace it with the
// marching-squares outline. Contracting also erodes away from the canvas edges, and
// contracting past the middle leaves an explicit empty selection, as on macOS.

import Foundation

extension EditorSession {
    func expandSelection(by amount: Int) throws { try resizeSelection(by: amount, name: "Expand Selection") }
    func contractSelection(by amount: Int) throws { try resizeSelection(by: -amount, name: "Contract Selection") }

    private func resizeSelection(by delta: Int, name: String) throws {
        guard let doc = document, let current = selection, !current.isEmpty, delta != 0, abs(delta) <= 500 else { return }
        let radius = abs(delta)
        let canvas = CGRect(origin: .zero, size: doc.size)
        let region = current.path.boundingBox.insetBy(dx: -CGFloat(radius + 1), dy: -CGFloat(radius + 1))
            .integral.intersection(canvas)
        guard region.width >= 1, region.height >= 1 else { return }
        let w = Int(region.width), h = Int(region.height)
        let mask = current.rasterized(in: region)
        // One unselected pixel of padding so contraction also pulls away from the canvas edges.
        let pw = w + 2, ph = h + 2
        let inf = 1e20
        var sq = [Double](repeating: inf, count: pw * ph)
        let expanding = delta > 0
        for y in 0..<ph {
            for x in 0..<pw {
                let inside = x >= 1 && y >= 1 && x <= w && y <= h && mask.bytes[(y - 1) * w + (x - 1)] >= 128
                // Sources are what we measure the distance to: selected pixels when growing, unselected when shrinking.
                if inside == expanding { sq[y * pw + x] = 0 }
            }
        }
        EditorSession.squaredDistanceTransform(&sq, width: pw, height: ph)
        var result = MaskBuffer(width: w, height: h)
        let limit = Double(radius * radius)
        for y in 0..<h {
            for x in 0..<w {
                let d = sq[(y + 1) * pw + (x + 1)]
                let selected = expanding ? d <= limit : d > limit
                result.bytes[y * w + x] = selected ? 255 : 0
            }
        }
        try setSelection(selection(from: result, rect: region, antialiased: current.antialiased), name: name)
    }

    /// Felzenszwalb–Huttenlocher exact squared Euclidean distance transform, in place.
    static func squaredDistanceTransform(_ grid: inout [Double], width: Int, height: Int) {
        func pass(_ f: [Double]) -> [Double] {
            let n = f.count
            var d = [Double](repeating: 0, count: n), v = [Int](repeating: 0, count: n), z = [Double](repeating: 0, count: n + 1)
            var k = 0
            z[0] = -1e30; z[1] = 1e30
            if n > 1 {
                for q in 1..<n {
                    var s = 0.0
                    while true {
                        let p = v[k]
                        s = ((f[q] + Double(q * q)) - (f[p] + Double(p * p))) / Double(2 * q - 2 * p)
                        if s <= z[k] && k > 0 { k -= 1 } else { break }
                    }
                    k += 1
                    v[k] = q; z[k] = s; z[k + 1] = 1e30
                }
            }
            k = 0
            for q in 0..<n {
                while z[k + 1] < Double(q) { k += 1 }
                let dq = Double(q - v[k])
                d[q] = dq * dq + f[v[k]]
            }
            return d
        }
        for x in 0..<width {
            let column = pass((0..<height).map { grid[$0 * width + x] })
            for y in 0..<height { grid[y * width + x] = column[y] }
        }
        for y in 0..<height {
            let row = pass(Array(grid[(y * width)..<((y + 1) * width)]))
            for x in 0..<width { grid[y * width + x] = row[x] }
        }
    }
}
