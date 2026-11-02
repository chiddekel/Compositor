import Foundation

/// Executes the finishing shaders on float textures, preserving the upstream processor's coordinates and coverage.
enum FinishingCompute {
    static func execute(_ encoder: MTLComputeCommandEncoder) throws {
        let tonal = encoder.pipeline?.name == "tonalContrast"
        guard encoder.ended, let image = encoder.textures[0], let output = encoder.textures[tonal ? 2 : 1],
              let data = encoder.bytes[0], data.count >= 84,
              image.width > 0, image.height > 0, image.width == output.width, image.height == output.height,
              [.rgba16Float, .rgba32Float].contains(image.pixelFormat),
              [.rgba16Float, .rgba32Float].contains(output.pixelFormat),
              image.rgbaBytes.count == image.width * image.height * image.bytesPerPixel else {
            throw NSError(domain: "Compositor.FinishingCompute", code: 1)
        }
        func parameter(_ offset: Int) -> Float {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        }
        func pixels(_ texture: MTLTexture) -> [Float] {
            texture.rgbaBytes.withUnsafeBytes { bytes in
                (0..<(texture.width * texture.height * 4)).map {
                    texture.pixelFormat == .rgba16Float
                        ? Float(Float16(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)))
                        : bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self)
                }
            }
        }
        func clamp(_ value: Float) -> Float { min(1, max(0, value)) }
        func smooth(_ value: Float) -> Float { let t = clamp(value); return t * t * (3 - 2 * t) }
        func straight(_ values: [Float], _ i: Int) -> SIMD3<Float> {
            guard values[i + 3] > 0 else { return .zero }
            return SIMD3(min(1, values[i] / values[i + 3]), min(1, values[i + 1] / values[i + 3]),
                         min(1, values[i + 2] / values[i + 3]))
        }
        func luma(_ c: SIMD3<Float>) -> Float { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }
        let source = pixels(image)
        let blurred: [Float]
        if tonal {
            guard let base = encoder.textures[1], base.width == image.width, base.height == image.height,
                  [.rgba16Float, .rgba32Float].contains(base.pixelFormat),
                  base.rgbaBytes.count == base.width * base.height * base.bytesPerPixel else {
                throw NSError(domain: "Compositor.FinishingCompute", code: 2)
            }
            blurred = pixels(base)
        } else {
            guard parameter(8) > 0, parameter(12) > 0 else {
                throw NSError(domain: "Compositor.FinishingCompute", code: 3)
            }
            blurred = []
        }
        var result = source
        for y in 0..<image.height { for x in 0..<image.width {
            let i = (y * image.width + x) * 4, alpha = source[i + 3]
            guard alpha > 0 else { continue }
            let c = straight(source, i)
            let changed: SIMD3<Float>
            if tonal {
                guard blurred[i + 3] > 0 else { continue }
                let lum = luma(c), baseLum = luma(straight(blurred, i))
                let shadow = 1 - smooth((baseLum - 0.15) / 0.35)
                let highlight = smooth((baseLum - 0.5) / 0.35)
                let weight = (parameter(64) * shadow + parameter(68) * (1 - shadow - highlight)
                              + parameter(32) * highlight) / 100
                let delta = 0.18 * tanh((lum - baseLum) * 6) * weight * (parameter(16) / 50) * (4 * lum * (1 - lum))
                changed = SIMD3(clamp(c.x + delta), clamp(c.y + delta), clamp(c.z + delta))
            } else {
                let atX = parameter(72) + Float(x) + 0.5
                let atY = parameter(76) + parameter(80) * (Float(y) + 0.5)
                let nx = (atX - parameter(0)) / parameter(8) * 2 - 1
                let ny = (atY - parameter(4)) / parameter(12) * 2 - 1
                let square = max(abs(nx), abs(ny)), circle = sqrt(nx * nx + ny * ny) / sqrt(2)
                let distance = circle + (square - circle) * ((1 - parameter(24) / 100) * 0.5)
                let mask = smooth((distance - parameter(20) / 100 * 0.85) / max(0.05, parameter(28) / 100))
                let bright = clamp((luma(c) - 0.45) / 0.55)
                let effect = clamp(parameter(16) / 100) * mask * (1 - parameter(32) / 100 * bright)
                let color = SIMD3(clamp(parameter(48)), clamp(parameter(52)), clamp(parameter(56)))
                changed = c + (color - c) * effect
            }
            result[i] = changed.x * alpha; result[i + 1] = changed.y * alpha; result[i + 2] = changed.z * alpha
        } }
        output.rgbaBytes = output.pixelFormat == .rgba16Float
            ? result.map { Float16($0) }.withUnsafeBytes { Array($0) }
            : result.withUnsafeBytes { Array($0) }
    }
}
