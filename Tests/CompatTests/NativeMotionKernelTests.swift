import Foundation
import Compression
import CoreGraphics
@testable import CoreImage
import XCTest

final class NativeMotionKernelTests: XCTestCase {
    func testByteAndFloatSourcesKeepTheirSamplingPrecision() throws {
        let width = 9, height = 3
        var pixels = PixelBuffer(width: width, height: height)
        var values = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let white = x == 4
            pixels[x, y] = (white ? 255 : 0, white ? 255 : 0, white ? 255 : 0, 255)
            let i = (y * width + x) * 4
            values[i] = white ? 1 : 0; values[i + 1] = values[i]; values[i + 2] = values[i]; values[i + 3] = 1
        } }
        let bytes = values.withUnsafeBytes { Data($0) }
        let halves = values.map(Float16.init).withUnsafeBytes { Data($0) }
        let byteSource = CIImage(cgImage: CGImage(pixels))
        let floatSource = CIImage(bitmapData: bytes, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
        let halfSource = CIImage(bitmapData: halves, bytesPerRow: width * 8,
            size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: nil)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: true])
        func peak(_ source: CIImage) -> Float {
            let graph = source.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                .samplingLinear().clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 0.5, kCIInputAngleKey: 0.0])
            var output = [Float](repeating: 0, count: width * 4)
            output.withUnsafeMutableBytes {
                context.render(graph, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: 1, width: width, height: 1), format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            return output[4 * 4]
        }
        XCTAssertEqual(peak(byteSource), Float(174.3125 / 255), accuracy: 0.0000001)
        XCTAssertEqual(peak(floatSource), Float(175.0 / 256), accuracy: 0.0000001)
        XCTAssertEqual(peak(halfSource), Float(175.0 / 256), accuracy: 0.0000001)
    }

    func testByteSamplerVectorAndBoundaryPixelsAgree() {
        let bounds = CGRect(x: 0, y: 0, width: 25, height: 3)
        var input = Raster(rect: bounds)
        for y in 0..<3 { for x in 0..<25 {
            let i = input.index(x, y)
            input.data[i] = Float((x * 19 + y * 11) % 256) / 255
            input.data[i + 1] = Float((x * 47 + y * 31) % 256) / 255
            input.data[i + 2] = Float((x * 13 + y * 71) % 256) / 255
            input.data[i + 3] = 1
        } }
        for radius in [0.5, 1, 2, 10 / sqrt(12.0)] {
            let full = RasterFilters.motionBlur(input, radius: radius, angle: 0,
                output: CGRect(x: 0, y: 1, width: 25, height: 1), nativeSampling: true, byteSamples: true)
            for x in 0..<25 {
                let pixel = RasterFilters.motionBlur(input, radius: radius, angle: 0,
                    output: CGRect(x: x, y: 1, width: 1, height: 1), nativeSampling: true, byteSamples: true)
                for channel in 0..<4 { XCTAssertEqual(full.data[x * 4 + channel], pixel.data[channel], accuracy: 0.000001) }
            }
        }
    }

    func testByteSamplingFullHDMotionRemainsInteractive() throws {
        #if !DEBUG
        let width = 1920, height = 1080
        var pixels = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { pixels[x, y] = (UInt8(x % 251), UInt8(y % 251), 100, 255) } }
        let source = CIImage(cgImage: CGImage(pixels)).clampedToExtent()
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: true])
        for angle in [0.0, Double.pi / 2] {
            let graph = source.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 10 / sqrt(12.0), kCIInputAngleKey: angle])
            let start = Date()
            let image = try XCTUnwrap(context.createCGImage(graph, from: CGRect(x: 0, y: 0, width: width, height: height)))
            XCTAssertEqual(image.portableImage.bytes.count, width * height * 4)
            let elapsed = Date().timeIntervalSince(start)
            print("MOTION UNORM8 1920x1080 angle=\(angle): \(elapsed * 1000) ms")
            XCTAssertLessThan(elapsed, 0.5, "Native byte sampling must keep the desktop responsive")
        }
        #endif
    }

    private struct Reference: Decodable {
        let sourceCaptureSHA256: String
        let width: Int
        let inputs: [String: Data]
        let cases: [Sample]
        struct Sample: Decodable {
            let fixture: String
            let phase: Int
            let radius: Double
            let red: Data
            let alpha: Data
        }
    }

    private func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            stride(from: 0, to: data.count, by: 4).map {
                Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self).littleEndian)
            }
        }
    }

    func testDirectKernelsMatchNativeFloatSamplingAndTailMass() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-motion-direct-reference.json.gz")
        let gzip = try Data(contentsOf: url)
        XCTAssertEqual(Array(gzip.prefix(4)), [0x1f, 0x8b, 8, 0])
        let count = gzip.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: gzip.count - 4, as: UInt32.self).littleEndian) }
        var json = [UInt8](repeating: 0, count: count)
        let payload = gzip.dropFirst(10).dropLast(8)
        let decoded = payload.withUnsafeBytes {
            compression_decode_buffer(&json, count, $0.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
        }
        XCTAssertEqual(decoded, count)
        let reference = try JSONDecoder().decode(Reference.self, from: Data(json))
        XCTAssertEqual(reference.sourceCaptureSHA256, "0ab6c00bfb3d59c618081416e6c682dbe535298cc2d5c9fc248ff41012adc4b4")
        XCTAssertEqual(reference.cases.count, 384)
        let region = CGRect(x: 0, y: 0, width: reference.width, height: 1)
        var inputs: [String: Raster] = [:]
        for (key, bytes) in reference.inputs {
            let gray = floats(bytes)
            XCTAssertEqual(gray.count, reference.width)
            let source = Raster(rect: region, data: gray.flatMap { [$0, $0, $0, 1] })
            inputs[key] = source.clamped(to: region.insetBy(dx: -12, dy: 0))
        }
        var worstColor: Float = 0, worstAlpha: Float = 0
        for sample in reference.cases {
            let input = try XCTUnwrap(inputs["\(sample.fixture):\(sample.phase)"])
            let output = RasterFilters.motionBlur(input, radius: sample.radius, angle: 0, output: region,
                                                  nativeSampling: true, byteSamples: true)
            let red = floats(sample.red), alpha = floats(sample.alpha)
            XCTAssertEqual(red.count, reference.width); XCTAssertEqual(alpha.count, reference.width)
            for x in 0..<reference.width {
                worstColor = max(worstColor, abs(output.data[x * 4] - red[x]))
                worstAlpha = max(worstAlpha, abs(output.data[x * 4 + 3] - alpha[x]))
            }
        }
        XCTAssertLessThanOrEqual(worstColor, 1 / 1048576, "Native byte-texture sample precision must survive float rendering")
        XCTAssertLessThanOrEqual(worstAlpha, 1 / 65536, "Native finite kernel mass must survive float rendering")
    }
}
