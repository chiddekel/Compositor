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
        // NaNs do not form an ordering for the queue; preserve the sequential filter's behavior for them.
        if input.data.contains(where: \.isNaN) {
            return sequentialMorphology(input, width: width, height: height, maximum: maximum, region: region)
        }
        let rx = width / 2, ry = height / 2
        if rx == 0 && ry == 0 { return input.cropped(to: region) }
        let ow = Int(region.width), oh = Int(region.height)
        guard ow > 0, oh > 0 else { return Raster(rect: region) }
        let ox = Int(region.minX - input.rect.minX), oy = Int(region.minY - input.rect.minY)
        let firstRow = oy - ry, rows = oh + 2 * ry
        // Only this strip feeds the requested output; no horizontal work is needed elsewhere.
        var horizontal = [Float](repeating: 0, count: ow * rows * 4)
        var queue = [Int](repeating: 0, count: max(input.width, rows))
        input.data.withUnsafeBufferPointer { source in
            horizontal.withUnsafeMutableBufferPointer { target in
                queue.withUnsafeMutableBufferPointer { indices in
                    for y in 0..<rows {
                        let start = source.baseAddress! + (firstRow + y) * input.width * 4
                        let destination = target.baseAddress! + y * ow * 4
                        if rx == 0 {
                            destination.update(from: start + ox * 4, count: ow * 4)
                        } else {
                            for channel in 0..<4 {
                                slidingExtrema(start + channel, count: input.width, stride: 4,
                                               first: ox, outputCount: ow, radius: rx, maximum: maximum,
                                               destination: destination + channel, destinationStride: 4,
                                               queue: indices.baseAddress!)
                            }
                        }
                    }
                }
            }
        }
        if ry == 0 { return Raster(rect: region, data: horizontal) }
        var output = Raster(rect: region)
        horizontal.withUnsafeBufferPointer { source in
            output.data.withUnsafeMutableBufferPointer { target in
                queue.withUnsafeMutableBufferPointer { indices in
                    for x in 0..<ow {
                        for channel in 0..<4 {
                            slidingExtrema(source.baseAddress! + x * 4 + channel, count: rows, stride: ow * 4,
                                           first: ry, outputCount: oh, radius: ry, maximum: maximum,
                                           destination: target.baseAddress! + x * 4 + channel,
                                           destinationStride: ow * 4, queue: indices.baseAddress!)
                        }
                    }
                }
            }
        }
        return output
    }

    /// Each source position enters and leaves the monotone queue at most once, regardless of window size.
    private static func slidingExtrema(_ source: UnsafePointer<Float>, count: Int, stride: Int,
                                       first: Int, outputCount: Int, radius: Int, maximum: Bool,
                                       destination: UnsafeMutablePointer<Float>, destinationStride: Int,
                                       queue: UnsafeMutablePointer<Int>) {
        var head = 0, tail = 0, next = max(0, first - radius)
        for output in 0..<outputCount {
            let center = first + output
            let left = max(0, center - radius), right = min(count - 1, center + radius)
            while head < tail && queue[head] < left { head += 1 }
            while next <= right {
                let value = source[next * stride]
                while head < tail {
                    let previous = source[queue[tail - 1] * stride]
                    var discard = maximum ? previous <= value : previous >= value
                    // Equal signed zeros compare alike but their selected bit pattern is observable in float output.
                    if previous == 0, value == 0, previous.bitPattern != value.bitPattern {
                        let chosen = maximum ? max(previous, value) : min(previous, value)
                        discard = chosen.bitPattern == value.bitPattern
                    }
                    if !discard { break }
                    tail -= 1
                }
                queue[tail] = next; tail += 1; next += 1
            }
            destination[output * destinationStride] = source[queue[head] * stride]
        }
    }

    private static func sequentialMorphology(_ input: Raster, width: Int, height: Int, maximum: Bool, region: CGRect) -> Raster {
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

    /// Natural cubic spline through Core Image's five perceptual control points.
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
