import CoreGraphics
import CoreImage
import CompositorKernels
import Foundation
import Testing
@testable import Compositor

/// Upstream's GPUNoise now compiles unchanged: its Metal kernels run as Vulkan raster operations 8 (add_noise) and
/// 9 (add_grain), or their CPU twins when Vulkan is off. Both must give the pattern NoisePixels.c / adjust_grain make
/// for export, at the same document positions, so the live canvas and the exported file show the same grain.
/// Run with COMPOSITOR_COREIMAGE_BACKEND=vulkan and =cpu to cover both paths.
// Regression: QA C5 — GPUNoise's Vulkan/CPU port had no coverage against the export kernels
// Found by /qa on 2026-10-19
// Report: .gstack/qa-reports/run-20261019T185317Z/qa-report-gpunoise-2026-10-19.md
@MainActor
struct GPUNoiseParityTests {
    static let width = 37, height = 23
    /// The frame region the image covers, and the canvas mapping (frame = document × scale + offset).
    static let origin = CGPoint(x: 5, y: 9)
    static let mapping = CGAffineTransform(translationX: -13.4, y: 6.7)

    /// Premultiplied RGBA, top row first: color ramps, a translucent band and a transparent corner.
    static func pixels() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let a: Int = x < 4 && y < 4 ? 0 : (y % 7 == 3 ? 128 : 255)
                let r = x * 255 / (width - 1), g = y * 255 / (height - 1), b = (x + y) * 4 % 256
                bytes[i] = UInt8(r * a / 255); bytes[i + 1] = UInt8(g * a / 255); bytes[i + 2] = UInt8(b * a / 255)
                bytes[i + 3] = UInt8(a)
            }
        }
        return bytes
    }

    static func image(_ bytes: [UInt8]) throws -> CIImage {
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    /// The frame's pixels, top row first, as the GPU canvas's sRGB context draws them.
    static func render(_ image: CIImage) throws -> [UInt8] {
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))
        let cg = try #require(context.createCGImage(image, from: rect))
        let copy = try BrushRaster.copy(cg)
        let data = try #require(copy.data)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            memcpy(&out[y * width * 4], data + y * copy.bytesPerRow, width * 4)
        }
        return out
    }

    /// Runs a C kernel with row r at frame y = minY + r, as GPUNoise's kernels index the frame.
    static func reference(_ kernel: (UnsafeMutablePointer<UInt8>) -> Void) -> [UInt8] {
        var bytes = pixels()
        let row = width * 4
        func flip() {
            for y in 0..<(height / 2) {
                for k in 0..<row { bytes.swapAt(y * row + k, (height - 1 - y) * row + k) }
            }
        }
        flip()
        bytes.withUnsafeMutableBufferPointer { kernel($0.baseAddress!) }
        flip()
        return bytes
    }

    static func compare(_ actual: [UInt8], _ expected: [UInt8], _ label: String) {
        let input = pixels()
        var worst = 0, changed = 0, off: [String] = []
        for i in 0..<actual.count {
            let difference = abs(Int(actual[i]) - Int(expected[i]))
            worst = max(worst, difference)
            if expected[i] != input[i] { changed += 1 }
            if difference > 2, off.count < 4 {
                off.append("pixel (\(i / 4 % width), row \(i / 4 / width)) channel \(i % 4): \(actual[i]) vs \(expected[i]) from \(input[i])")
            }
        }
        #expect(changed > actual.count / 8, "\(label): the reference added no visible noise")
        // Float against 8-bit arithmetic: a level of rounding; a mirrored or shifted pattern differs by tens.
        #expect(worst <= 2, "\(label): differs from the export kernel by up to \(worst) levels; \(off)")
        for i in stride(from: 3, to: actual.count, by: 4) {
            #expect(actual[i] == input[i], "\(label): alpha changed at byte \(i)")
        }
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func noiseMatchesExportKernel(gaussian: Bool, monochromatic: Bool) throws {
        let seed: UInt32 = 0x5EED_1234
        let result = try #require(GPUNoise.addNoise(to: try Self.image(Self.pixels()), mapping: Self.mapping, amount: 40,
                                                    gaussian: gaussian, monochromatic: monochromatic, seed: seed))
        let expected = Self.reference { p in
            noise_add_at(p, Self.width, Self.height, Self.width * 4, 40, gaussian ? 1 : 0, monochromatic ? 1 : 0, seed,
                         Int64(floor(-Self.mapping.tx)) + Int64(Self.origin.x), Int64(floor(-Self.mapping.ty)) + Int64(Self.origin.y))
        }
        Self.compare(try Self.render(result), expected, "noise gaussian=\(gaussian) mono=\(monochromatic)")
    }

    @Test(arguments: [1.0, 2.5])
    func grainMatchesExportKernel(scale: Double) throws {
        var grain = GrainSettings()
        grain.amount = 60; grain.size = 2; grain.roughness = 40; grain.seed = 77
        let result = try #require(GPUNoise.addGrain(to: try Self.image(Self.pixels()), grain: grain, scale: scale,
                                                    mapping: Self.mapping))
        let expected = Self.reference { p in
            adjust_grain(p, Self.width, Self.height, Self.width * 4, grain.amount, max(grain.size, 0.01), grain.roughness,
                         grain.seed, (Self.origin.x - Self.mapping.tx) / scale, (Self.origin.y - Self.mapping.ty) / scale, 1 / scale)
        }
        Self.compare(try Self.render(result), expected, "grain scale=\(scale)")
    }
}
