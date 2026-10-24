import Foundation

/// Regional operations used by Core Image's optical filters.
enum LensRaster {
    /// A circular dilation, using sliding horizontal maxima for each span of the disc. Work grows with the radius,
    /// rather than with the area of a new disc searched at every output pixel.
    static func discMaximum(_ input: Raster, radius: Double, region: CGRect) -> Raster {
        guard radius > 0 else { return input.cropped(to: region) }
        let reach = Int(floor(radius))
        let spans = (-reach...reach).map { dy in
            (dy, Int(floor(sqrt(max(0, radius * radius - Double(dy * dy))))))
        }
        var output = Raster(rect: region, data: [Float](repeating: -.infinity,
            count: Int(region.width) * Int(region.height) * 4))
        let ox = Int(region.minX - input.rect.minX), oy = Int(region.minY - input.rect.minY)
        var deque = [Int](repeating: 0, count: input.width)
        for y in 0..<output.height {
            for (dy, halfWidth) in spans {
                let row = (y + oy + dy) * input.width * 4
                for channel in 0..<4 {
                    var head = 0, tail = 0
                    for x in (ox - halfWidth)...(ox + output.width - 1 + halfWidth) {
                        while head < tail && deque[head] < x - 2 * halfWidth { head += 1 }
                        let value = input.data[row + x * 4 + channel]
                        while head < tail && input.data[row + deque[tail - 1] * 4 + channel] <= value { tail -= 1 }
                        deque[tail] = x; tail += 1
                        let center = x - halfWidth
                        if center >= ox {
                            let index = output.index(center - ox, y) + channel
                            output.data[index] = max(output.data[index], input.data[row + deque[head] * 4 + channel])
                        }
                    }
                }
            }
        }
        return output
    }

    static func morphology(_ input: Raster, width: Int, height: Int, maximum: Bool, region: CGRect) -> Raster {
        // Separable rectangle: the vertical pass consumes the horizontal extrema.
        var horizontal = input
        for y in 0..<input.height {
            for x in 0..<input.width {
                for c in 0..<4 {
                    var value: Float = maximum ? -.infinity : .infinity
                    for dx in -(width / 2)...(width / 2) {
                        let sample = input.data[input.index(min(input.width - 1, max(0, x + dx)), y) + c]
                        value = maximum ? max(value, sample) : min(value, sample)
                    }
                    horizontal.data[horizontal.index(x, y) + c] = value
                }
            }
        }
        var output = Raster(rect: region)
        let ox = Int(region.minX - input.rect.minX), oy = Int(region.minY - input.rect.minY)
        for y in 0..<output.height {
            for x in 0..<output.width {
                for c in 0..<4 {
                    var value: Float = maximum ? -.infinity : .infinity
                    for dy in -(height / 2)...(height / 2) {
                        let sample = horizontal.data[horizontal.index(x + ox, y + oy + dy) + c]
                        value = maximum ? max(value, sample) : min(value, sample)
                    }
                    output.data[output.index(x, y) + c] = value
                }
            }
        }
        return output
    }

    /// Natural cubic spline through Core Image's five control points, tabulated for the existing curve evaluator.
    static func toneTable(_ points: [CGPoint]) -> [Float] {
        let x = points.map { Double($0.x) }, y = points.map { Double($0.y) }
        guard x.allSatisfy(\.isFinite), y.allSatisfy(\.isFinite), (1..<5).allSatisfy({ x[$0] > x[$0 - 1] }) else {
            return (0...1024).flatMap { Array(repeating: Float($0) / 1024, count: 3) }
        }
        var second = [Double](repeating: 0, count: 5), u = second
        for i in 1..<4 {
            let span = x[i + 1] - x[i - 1], fraction = (x[i] - x[i - 1]) / span
            let p = fraction * second[i - 1] + 2
            second[i] = (fraction - 1) / p
            let slope = (y[i + 1] - y[i]) / (x[i + 1] - x[i]) - (y[i] - y[i - 1]) / (x[i] - x[i - 1])
            u[i] = (6 * slope / span - fraction * u[i - 1]) / p
        }
        for i in stride(from: 3, through: 0, by: -1) { second[i] = second[i] * second[i + 1] + u[i] }
        return (0...1024).flatMap { index -> [Float] in
            let at = min(x[4], max(x[0], Double(index) / 1024))
            let i = min(3, max(0, (0..<4).last(where: { x[$0] <= at }) ?? 0))
            let h = x[i + 1] - x[i], a = (x[i + 1] - at) / h, b = (at - x[i]) / h
            let v = a * y[i] + b * y[i + 1] + ((a * a * a - a) * second[i] + (b * b * b - b) * second[i + 1]) * h * h / 6
            return Array(repeating: Float(min(1, max(0, v))), count: 3)
        }
    }
}
