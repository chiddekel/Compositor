import Foundation

extension RasterFilters {
    /// Add high-frequency color detail while retaining the source's coverage and floating-point range.
    static func unsharp(_ source: Raster, blurred: Raster, intensity: Float) -> Raster {
        guard intensity.isFinite, intensity != 0 else { return source }
        precondition(source.rect == blurred.rect && source.data.count == blurred.data.count)
        var output = source
        for pixel in stride(from: 0, to: source.data.count, by: 4) {
            guard source.data[pixel + 3] > 0 else { continue }
            // Native unsharp compares straight colors, then retains source coverage.
            // Blur coverage alone must not become high-frequency color detail.
            let coverage = blurred.data[pixel + 3]
            let scale = coverage > 0 ? source.data[pixel + 3] / coverage : 0
            for channel in 0..<3 {
                let value = source.data[pixel + channel]
                output.data[pixel + channel] = value + (value - blurred.data[pixel + channel] * scale) * intensity
            }
        }
        return output
    }
}
