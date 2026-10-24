import Foundation

/// CPU execution of the aperture gather used by MetalBokeh. Half floats keep highlights above white intact.
enum BokehCompute {
    static func execute(_ encoder: MTLComputeCommandEncoder) throws {
        guard encoder.ended, let input = encoder.textures[0], let output = encoder.textures[1],
              let data = encoder.bytes[0], data.count >= 20,
              input.pixelFormat == .rgba16Float, output.pixelFormat == .rgba16Float,
              input.width > 0, input.height > 0, input.width == output.width, input.height == output.height,
              input.rgbaBytes.count == input.width * input.height * 8 else {
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
                Float(Float16(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)))
            }
        }
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        let reachX = Int(ceil(radius)), reachY = Int(ceil(radius * (shape == 2 ? 1.62 : 1)))
        var result = [UInt16](repeating: 0, count: pixels.count)
        for y in 0..<height {
            for x in 0..<width {
                let mx = (Float(x) + 0.5 - Float(width) * 0.5) / (Float(max(width, height)) * 0.5)
                let my = (Float(y) + 0.5 - Float(height) * 0.5) / (Float(max(width, height)) * 0.5)
                let outward = min(1, sqrt(mx * mx + my * my))
                var sum = SIMD4<Float>.zero
                var total: Float = 0
                for dy in -reachY...reachY {
                    for dx in -reachX...reachX {
                        let ox = Float(dx) / radius, oy = Float(dy) / radius
                        let d: Float
                        switch shape {
                        case 1: d = max(abs(ox) * 0.866025 + abs(oy) * 0.5, abs(oy)) / 0.866025 * 0.93
                        case 2: d = sqrt(ox * ox + oy * oy * 0.62 * 0.62)
                        case 3:
                            let cx = ox + mx * outward * 1.25, cy = oy + my * outward * 1.25
                            d = max(sqrt(ox * ox + oy * oy), sqrt(cx * cx + cy * cy))
                        default: d = sqrt(ox * ox + oy * oy)
                        }
                        let inside = 1 - smooth(1 - 1 / radius, 1, d)
                        if inside <= 0 { continue }
                        let weight = inside * (1 + ring * 2.5 * smooth(0.6, 0.97, d))
                        let index = (min(height - 1, max(0, y + dy)) * width + min(width - 1, max(0, x + dx))) * 4
                        sum += SIMD4(pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]) * weight
                        total += weight
                    }
                }
                for c in 0..<4 { result[(y * width + x) * 4 + c] = Float16(sum[c] / max(total, 1e-5)).bitPattern }
            }
        }
        output.rgbaBytes = result.withUnsafeBytes { Array($0) }
    }
}
