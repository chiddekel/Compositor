import Foundation
import CoreGraphics

extension RasterFilters {
    /// A separable Lanczos-3 reconstruction. Shrinking widens the source footprint to suppress aliasing.
    /// Normalize the complete footprint, including transparent pixels outside the source extent.
    static func lanczos(_ input: Raster, scaleX: Double, scaleY: Double, output region: CGRect) -> Raster {
        guard input.width > 0, input.height > 0 else { return Raster(rect: region) }
        if scaleX == 1 && scaleY == 1 { return input.cropped(to: region) }
        struct Tap {
            let index: Int
            let weight: Float
        }
        func coefficients(count: Int, origin: Double, sourceOrigin: Double, sourceCount: Int, scale: Double) -> [[Tap]] {
            let filterScale = min(1, scale), support = 3 / filterScale
            func sinc(_ x: Double) -> Double {
                if abs(x) < 1e-12 { return 1 }
                let angle = Double.pi * x
                return sin(angle) / angle
            }
            return (0..<count).map { offset in
                let center = (origin + Double(offset) + 0.5) / scale - sourceOrigin - 0.5
                if scale == 1 { return [Tap(index: Int(center.rounded()), weight: 1)].filter { $0.index >= 0 && $0.index < sourceCount } }
                let first = Int(ceil(center - support)), last = Int(floor(center + support))
                var total = 0.0, valid: [(Int, Double)] = []
                for index in first...last {
                    let distance = (Double(index) - center) * filterScale
                    guard abs(distance) < 3 else { continue }
                    let weight = sinc(distance) * sinc(distance / 3)
                    total += weight
                    if index >= 0 && index < sourceCount { valid.append((index, weight)) }
                }
                return valid.map { Tap(index: $0.0, weight: Float($0.1 / total)) }
            }
        }
        let width = Int(region.width), height = Int(region.height)
        let horizontal = coefficients(count: width, origin: Double(region.minX), sourceOrigin: Double(input.rect.minX),
                                      sourceCount: input.width, scale: scaleX)
        let vertical = coefficients(count: height, origin: Double(region.minY), sourceOrigin: Double(input.rect.minY),
                                    sourceCount: input.height, scale: scaleY)
        var temporary = [Float](repeating: 0, count: width * input.height * 4)
        var output = Raster(rect: region)
        input.data.withUnsafeBufferPointer { source in
            temporary.withUnsafeMutableBufferPointer { destination in
                for y in 0..<input.height {
                    for x in 0..<width {
                        let out = (y * width + x) * 4
                        for tap in horizontal[x] {
                            let at = (y * input.width + tap.index) * 4
                            for channel in 0..<4 { destination[out + channel] += source[at + channel] * tap.weight }
                        }
                    }
                }
            }
        }
        temporary.withUnsafeBufferPointer { source in
            output.data.withUnsafeMutableBufferPointer { destination in
                for y in 0..<height {
                    for tap in vertical[y] {
                        for x in 0..<(width * 4) {
                            destination[y * width * 4 + x] += source[tap.index * width * 4 + x] * tap.weight
                        }
                    }
                }
            }
        }
        return output
    }
}
