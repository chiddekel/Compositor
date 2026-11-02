import Foundation

/// CPU execution of the aperture gather used by MetalBokeh. Half floats keep highlights above white intact.
enum BokehCompute {
    static func execute(_ encoder: MTLComputeCommandEncoder) throws {
        guard encoder.ended, let input = encoder.textures[0], let output = encoder.textures[1],
              let data = encoder.bytes[0], data.count >= 48,
              [.rgba16Float, .rgba32Float].contains(input.pixelFormat),
              [.rgba16Float, .rgba32Float].contains(output.pixelFormat),
              input.width > 0, input.height > 0, output.width > 0, output.height > 0,
              input.rgbaBytes.count == input.width * input.height * input.bytesPerPixel else {
            throw NSError(domain: "Compositor.BokehCompute", code: 1)
        }
        func value(_ offset: Int) -> Float {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        }
        let radius = max(value(0), 0.5), ring = value(8)
        let shape = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard radius.isFinite, radius <= 20, ring.isFinite, shape <= 3 else {
            throw NSError(domain: "Compositor.BokehCompute", code: 2)
        }
        let width = input.width, height = input.height
        let pixels: [Float] = input.rgbaBytes.withUnsafeBytes { bytes in
            (0..<(width * height * 4)).map {
                input.pixelFormat == .rgba16Float
                    ? Float(Float16(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)))
                    : bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self)
            }
        }
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        let reachX = Int(ceil(radius)), reachY = Int(ceil(radius * (shape == 2 ? 1.62 : 1)))
        let rw = value(24), rh = value(28)
        let outX = value(32), outY = value(36), inX = value(40), inY = value(44)
        guard rw > 0, rh > 0, stride(from: 16, through: 44, by: 4).allSatisfy({ value($0).isFinite }) else {
            throw NSError(domain: "Compositor.BokehCompute", code: 3)
        }
        func weight(_ dx: Int, _ dy: Int, _ mx: Float, _ my: Float) -> Float {
            let ox = Float(dx) / radius, oy = Float(dy) / radius
            let d: Float
            switch shape {
            case 1: d = max(abs(ox) * 0.866025 + abs(oy) * 0.5, abs(oy)) / 0.866025 * 0.93
            case 2: d = sqrt(ox * ox + oy * oy * 0.62 * 0.62)
            case 3:
                let outward = min(1, sqrt(mx * mx + my * my))
                let cx = ox + mx * outward * 1.25, cy = oy + my * outward * 1.25
                d = max(sqrt(ox * ox + oy * oy), sqrt(cx * cx + cy * cy))
            default: d = sqrt(ox * ox + oy * oy)
            }
            let inside = 1 - smooth(1 - 1 / radius, 1, d)
            return inside <= 0 ? 0 : inside * (1 + ring * 2.5 * smooth(0.6, 0.97, d))
        }
        // The upstream encoder dispatches discWeights before bokeh; the CPU adapter shares the same table.
        let columns = reachX * 2 + 1
        var table = [Float](repeating: 0, count: columns * (reachY * 2 + 1))
        if shape != 3 {
            for dy in -reachY...reachY { for dx in -reachX...reachX {
                table[(dy + reachY) * columns + dx + reachX] = weight(dx, dy, 0, 0)
            } }
            encoder.buffers[1]?.data = table.withUnsafeBytes { Data($0) }
        }
        var result = [Float](repeating: 0, count: output.width * output.height * 4)
        for y in 0..<output.height {
            for x in 0..<output.width {
                let mx = (outX - value(16) + Float(x) + 0.5 - rw * 0.5) / (max(rw, rh) * 0.5)
                let my = (value(20) + rh - outY + Float(y) + 0.5 - rh * 0.5) / (max(rw, rh) * 0.5)
                var sum = SIMD4<Float>.zero
                var total: Float = 0
                for dy in -reachY...reachY {
                    for dx in -reachX...reachX {
                        let weight = shape == 3 ? weight(dx, dy, mx, my)
                            : table[(dy + reachY) * columns + dx + reachX]
                        if weight <= 0 { continue }
                        let index = (min(height - 1, max(0, Int(inY - outY) + y + dy)) * width + min(width - 1, max(0, Int(outX - inX) + x + dx))) * 4
                        sum += SIMD4(pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]) * weight
                        total += weight
                    }
                }
                for c in 0..<4 { result[(y * output.width + x) * 4 + c] = sum[c] / max(total, 1e-5) }
            }
        }
        output.rgbaBytes = output.pixelFormat == .rgba16Float
            ? result.map { Float16($0) }.withUnsafeBytes { Array($0) }
            : result.withUnsafeBytes { Array($0) }
    }
}
