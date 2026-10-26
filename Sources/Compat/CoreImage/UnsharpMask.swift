import Foundation

extension RasterFilters {
    /// Add high-frequency color detail while retaining the source's coverage and floating-point range.
    static func unsharp(_ source: Raster, blurred: Raster, intensity: Float) -> Raster {
        guard intensity.isFinite, intensity != 0 else { return source }
        precondition(source.rect == blurred.rect && source.data.count == blurred.data.count)
        var output = source
        for pixel in stride(from: 0, to: source.data.count, by: 4) {
            guard source.data[pixel + 3] > 0 else { continue }
            for channel in 0..<3 {
                let value = source.data[pixel + channel]
                output.data[pixel + channel] = value + (value - blurred.data[pixel + channel]) * intensity
            }
        }
        return output
    }
}
