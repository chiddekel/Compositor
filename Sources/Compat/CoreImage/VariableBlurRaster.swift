import Foundation
import CoreGraphics

/// Core Image's variable blur samples a reduction pyramid, blending its levels logarithmically.
enum VariableBlurRaster {
    private struct Taps {
        var indices: SIMD4<Int32>
        var weights: SIMD4<Float>
    }

    private static func levelCount(_ radius: Double) -> Int {
        min(6, max(1, Int(floor(log2(min(64, radius / 0.75)))) + 1))
    }

    static func extent(of input: CGRect) -> CGRect {
        guard !input.isNull, !input.isEmpty, !input.isInfinite else { return input }
        var reduced = input
        for _ in 0..<6 {
            reduced = reduced.applying(CGAffineTransform(scaleX: 0.5, y: 0.5))
                .insetBy(dx: -0.5, dy: -0.5).integral
        }
        return reduced.applying(CGAffineTransform(scaleX: 64, y: 64)).insetBy(dx: -128, dy: -128)
    }

    private static func regions(_ output: CGRect, levels: Int) -> [CGRect] {
        var regions = [CGRect](repeating: .zero, count: levels + 1)
        let scale = Double(1 << levels)
        let left = floor(output.minX / scale - 0.5), bottom = floor(output.minY / scale - 0.5)
        let right = ceil(output.maxX / scale - 0.5), top = ceil(output.maxY / scale - 0.5)
        // The last level receives a linear-sampling ROI. Its cubic lookups clamp to that buffer.
        // Earlier levels also supply the next reduction, which provides their extra sampling margin.
        regions[levels] = CGRect(x: left, y: bottom, width: right - left + 1, height: top - bottom + 1)
        for level in stride(from: levels - 1, through: 0, by: -1) {
            let child = regions[level + 1]
            let reduction = CGRect(x: child.minX * 2 - 1, y: child.minY * 2 - 1,
                                   width: child.width * 2 + 2, height: child.height * 2 + 2)
            if level == 0 {
                regions[level] = reduction.union(output)
            } else {
                let scale = Double(1 << level)
                let x0 = floor((output.minX + 0.5) / scale - 0.5) - 1
                let y0 = floor((output.minY + 0.5) / scale - 0.5) - 1
                let x1 = floor((output.maxX - 0.5) / scale - 0.5) + 2
                let y1 = floor((output.maxY - 0.5) / scale - 0.5) + 2
                regions[level] = reduction.union(CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))
            }
        }
        return regions
    }

    static func inputRegion(for output: CGRect, radius: Double) -> CGRect {
        guard radius.isFinite, radius > 0.75 else { return output }
        return regions(output, levels: levelCount(radius))[0]
    }

    private static func reduced(_ input: Raster, to region: CGRect) -> Raster {
        var output = Raster(rect: region)
        let kernel = [0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1, 0, 1, 1, 0]
        let originX = Int(input.rect.minX), originY = Int(input.rect.minY)
        for y in 0..<output.height { for x in 0..<output.width {
            let sx = (Int(region.minX) + x) * 2 - originX
            let sy = (Int(region.minY) + y) * 2 - originY
            var value = SIMD4<Float>.zero
            for dy in -1...2 { for dx in -1...2 {
                let weight = kernel[(dy + 1) * 4 + dx + 1]
                guard weight != 0, sx + dx >= 0, sx + dx < input.width,
                      sy + dy >= 0, sy + dy < input.height else { continue }
                let i = input.index(sx + dx, sy + dy)
                value += SIMD4(input.data[i], input.data[i + 1], input.data[i + 2], input.data[i + 3]) * Float(weight)
            } }
            let i = output.index(x, y)
            for channel in 0..<4 { output.data[i + channel] = value[channel] / 16 }
        } }
        return output
    }

    private static func taps(count: Int, origin: Double, scale: Double, sourceOrigin: Int, sourceCount: Int) -> [Taps] {
        (0..<count).map { offset in
            let position = (origin + Double(offset) + 0.5) / scale - 0.5
            let base = floor(position), t = position - base
            let w = [pow(1 - t, 3) / 6, (3 * t * t * t - 6 * t * t + 4) / 6,
                     (-3 * t * t * t + 3 * t * t + 3 * t + 1) / 6, t * t * t / 6]
            var result = Taps(indices: .zero, weights: .zero)
            for pair in [0, 2] {
                let total = w[pair] + w[pair + 1]
                let lookup = base + Double(pair - 1) + w[pair + 1] / total
                let lower = floor(lookup)
                let fraction = Float(((lookup - lower) * 256).rounded(.toNearestOrEven) / 256)
                result.indices[pair] = Int32(min(sourceCount - 1, max(0, Int(lower) - sourceOrigin)))
                result.indices[pair + 1] = Int32(min(sourceCount - 1, max(0, Int(lower) + 1 - sourceOrigin)))
                result.weights[pair] = Float(total) * (1 - fraction)
                result.weights[pair + 1] = Float(total) * fraction
            }
            return result
        }
    }

    static func render(_ input: Raster, mask: Raster, radius: Double, output region: CGRect) -> Raster {
        var output = input.cropped(to: region)
        guard radius.isFinite, radius > 0.75, output.width > 0, output.height > 0 else { return output }
        let levels = levelCount(radius), plan = regions(region, levels: levels)
        let mask = mask.cropped(to: region), pixels = output.width * output.height
        var lower = [UInt8](repeating: 0, count: pixels), fraction = [Float](repeating: 0, count: pixels)
        var highestUsed = 0
        for pixel in 0..<pixels {
            let i = pixel * 4
            // Native colored-mask controls select green, with half-float working precision.
            let gray = mask.data[i + 1]
            let intensity = gray.isFinite ? Double(Float(Float16(min(1, max(0, gray))))) : 0
            let position = intensity > 0 ? min(6, max(0, log2(intensity * radius / 0.75))) : 0
            lower[pixel] = UInt8(floor(position)); fraction[pixel] = Float(position - floor(position))
            highestUsed = max(highestUsed, Int(lower[pixel]) + (fraction[pixel] > 0 ? 1 : 0))
        }
        guard highestUsed > 0 else { return output }
        for pixel in 0..<pixels {
            let weight = lower[pixel] == 0 ? 1 - fraction[pixel] : 0
            for channel in 0..<4 { output.data[pixel * 4 + channel] *= weight }
        }
        var current = input
        for level in 1...highestUsed {
            current = reduced(current, to: plan[level])
            let scale = Double(1 << level)
            let xs = taps(count: output.width, origin: region.minX, scale: scale,
                          sourceOrigin: Int(current.rect.minX), sourceCount: current.width)
            let ys = taps(count: output.height, origin: region.minY, scale: scale,
                          sourceOrigin: Int(current.rect.minY), sourceCount: current.height)
            for y in 0..<output.height { for x in 0..<output.width {
                let pixel = y * output.width + x
                let weight = Int(lower[pixel]) == level ? 1 - fraction[pixel]
                    : Int(lower[pixel]) + 1 == level ? fraction[pixel] : 0
                guard weight > 0 else { continue }
                var value = SIMD4<Float>.zero
                for dy in 0..<4 { for dx in 0..<4 {
                    let i = current.index(Int(xs[x].indices[dx]), Int(ys[y].indices[dy]))
                    value += SIMD4(current.data[i], current.data[i + 1], current.data[i + 2], current.data[i + 3])
                        * (xs[x].weights[dx] * ys[y].weights[dy])
                } }
                for channel in 0..<4 { output.data[pixel * 4 + channel] += value[channel] * weight }
            } }
        }
        return output
    }
}
