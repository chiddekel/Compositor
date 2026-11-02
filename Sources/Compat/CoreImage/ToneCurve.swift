import Foundation

extension RasterFilters {
    /// CIToneCurve operates in a perceptual version of the working space. Native captures match sRGB's
    /// transfer around the spline; CIColorCurves has its own table-space semantics and does not use this path.
    static func toneCurve(_ input: Raster, table: [Float]) -> Raster {
        guard table.count >= 6, table.count % 3 == 0 else { return input }
        let count = table.count / 3, scale = Float(count - 1)
        var output = input
        for pixel in stride(from: 0, to: output.data.count, by: 4) {
            let alpha = input.data[pixel + 3]
            guard alpha > 0 else { continue }
            for channel in 0..<3 {
                let encoded = Gamma.toSRGB(input.data[pixel + channel] / alpha)
                let position = min(scale, max(0, encoded * scale))
                let index = min(count - 2, Int(position)), fraction = position - Float(index)
                let value = table[index * 3 + channel] * (1 - fraction) + table[(index + 1) * 3 + channel] * fraction
                output.data[pixel + channel] = Gamma.toLinear(value) * alpha
            }
        }
        return output
    }
}
