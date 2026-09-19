// Portable replacement for the CoreImage Gaussian blur paths in
// Compositor/Document/BlurTool.swift and Filters.swift (file-map tier: "replace
// named CoreImage filters with Skia/OpenCV/custom kernels").
//
// `CIImage.applyingGaussianBlur` is an exact Gaussian. This kernel is the
// standard 3-pass box approximation (Kovesi's ideal box sizes), which matches a
// Gaussian closely and runs in O(w·h) per pass regardless of sigma — the exact
// kernel would be O(w·h·sigma) and a 30-sigma stroke on a 4K canvas would
// stall the tool. Each box pass is a sliding-window sum (O(1) per pixel).
//
// ponytail: 3-box approximation diverges from CI's exact Gaussian by small
// per-pixel amounts; switch to the exact separable kernel (or Skia) if the
// ENG-10 fixture comparison shows visible drift.
//
// Edge handling mirrors the two CI call sites:
//   - `.transparent`: samples outside the buffer count as zero (the layer blur
//     path, which crops back to extent after blurring).
//   - `.clamp`: edge pixels extend outward (CI clampedToExtent, the mask blur
//     path, so blurring near a mask's edge doesn't pull in the wrong tone).

import Foundation

nonisolated enum GaussianBlur {

    enum Edges { case transparent, clamp }

    /// Blur a premultiplied RGBA buffer in place. Color and alpha move together
    /// (premultiplied blur), so transparent padding contributes nothing.
    static func apply(_ pixels: inout PixelBuffer, sigma: Double, edges: Edges = .transparent) {
        guard sigma > 0 else { return }
        var rgba = pixels.bytes
        blurPasses(&rgba, width: pixels.width, height: pixels.height, channels: 4, sigma: sigma, edges: edges)
        pixels = PixelBuffer(width: pixels.width, height: pixels.height, bytes: rgba)
    }

    /// Blur a grayscale (mask) buffer in place.
    static func apply(_ mask: inout MaskBuffer, sigma: Double, edges: Edges = .clamp) {
        guard sigma > 0 else { return }
        var gray = mask.bytes
        blurPasses(&gray, width: mask.width, height: mask.height, channels: 1, sigma: sigma, edges: edges)
        mask = MaskBuffer(width: mask.width, height: mask.height, bytes: gray)
    }

    // MARK: - Box-blur machinery

    /// Kovesi's ideal box sizes for a 3-pass Gaussian approximation of `sigma`.
    private static func boxSizes(sigma: Double) -> [Int] {
        let passes = 3
        let wIdeal = (12.0 * sigma * sigma / Double(passes) + 1.0).squareRoot()
        var wl = wIdeal.rounded(.down)
        if wl.truncatingRemainder(dividingBy: 2) == 0 { wl -= 1 }
        let wu = wl + 2
        let mIdeal = (12.0 * sigma * sigma - Double(passes) * wl * wl - 4.0 * Double(passes) * wl - 3.0 * Double(passes))
            / (-4.0 * wl - 4.0)
        let m = Int(mIdeal.rounded())
        return (0..<passes).map { $0 < m ? Int(wl) : Int(wu) }
    }

    private static func blurPasses(_ data: inout [UInt8], width: Int, height: Int,
                                   channels: Int, sigma: Double, edges: Edges) {
        guard width > 0, height > 0 else { return }
        var work = [Float](repeating: 0, count: width * height * channels)
        for i in 0..<work.count { work[i] = Float(data[i]) }
        for radius in boxSizes(sigma: sigma) where radius > 0 {
            boxPass(&work, width: width, height: height, channels: channels, radius: radius / 2, edges: edges)
        }
        for i in 0..<work.count { data[i] = u8(work[i]) }
    }

    /// One horizontal+vertical box pass (radius = half window). Sliding-window:
    /// each output pixel is the average of a (2r+1) run, updated in O(1).
    private static func boxPass(_ work: inout [Float], width: Int, height: Int,
                                channels: Int, radius r: Int, edges: Edges) {
        guard r > 0 else { return }
        var temp = [Float](repeating: 0, count: work.count)
        horizontal(work, into: &temp, width: width, height: height, channels: channels, radius: r, edges: edges)
        vertical(temp, into: &work, width: width, height: height, channels: channels, radius: r, edges: edges)
    }

    private static func horizontal(_ src: [Float], into dst: inout [Float],
                                   width: Int, height: Int, channels: Int, radius r: Int, edges: Edges) {
        if width <= 1 {
            dst = src
            return
        }
        let rowLen = width * channels
        for y in 0..<height {
            let row = y * rowLen
            // Seed the window sum for x = 0.
            var acc = [Float](repeating: 0, count: channels)
            for k in -r...r {
                let sx = sampleIndex(k, limit: width, edges: edges)
                if sx >= 0 { for c in 0..<channels { acc[c] += src[row + sx * channels + c] } }
            }
            let div = Float(2 * r + 1)
            for x in 0..<width {
                for c in 0..<channels { dst[row + x * channels + c] = acc[c] / div }
                // Slide: add the entering sample, remove the leaving one.
                let entering = sampleIndex(x + r + 1, limit: width, edges: edges)
                let leaving = sampleIndex(x - r, limit: width, edges: edges)
                for c in 0..<channels {
                    if entering >= 0 { acc[c] += src[row + entering * channels + c] }
                    if leaving >= 0 { acc[c] -= src[row + leaving * channels + c] }
                }
            }
        }
    }

    private static func vertical(_ src: [Float], into dst: inout [Float],
                                 width: Int, height: Int, channels: Int, radius r: Int, edges: Edges) {
        if height <= 1 {
            dst = src
            return
        }
        let rowLen = width * channels
        for x in 0..<width {
            let col = x * channels
            var acc = [Float](repeating: 0, count: channels)
            for k in -r...r {
                let sy = sampleIndex(k, limit: height, edges: edges)
                if sy >= 0 { for c in 0..<channels { acc[c] += src[sy * rowLen + col + c] } }
            }
            let div = Float(2 * r + 1)
            for y in 0..<height {
                for c in 0..<channels { dst[y * rowLen + col + c] = acc[c] / div }
                let entering = sampleIndex(y + r + 1, limit: height, edges: edges)
                let leaving = sampleIndex(y - r, limit: height, edges: edges)
                for c in 0..<channels {
                    if entering >= 0 { acc[c] += src[entering * rowLen + col + c] }
                    if leaving >= 0 { acc[c] -= src[leaving * rowLen + col + c] }
                }
            }
        }
    }

    /// Index of a sample at `i` in `0..<limit`; -1 when it must count as zero
    /// (`.transparent`), or the clamped edge index (`.clamp`).
    @inline(__always)
    private static func sampleIndex(_ i: Int, limit: Int, edges: Edges) -> Int {
        if i >= 0 && i < limit { return i }
        switch edges {
        case .clamp: return min(limit - 1, max(0, i))
        case .transparent: return -1
        }
    }

    @inline(__always)
    private static func u8(_ v: Float) -> UInt8 {
        if v.isNaN { return 0 }
        if v <= 0 { return 0 }
        if v >= 255 { return 255 }
        return UInt8(v + 0.5)
    }
}
