import Foundation
import CoreGraphics
import CoreImage
import XCTest

final class GaussianRegionalReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let width: Int
        let height: Int
        let cachePoliciesMatched: Bool
        let cases: [Sample]
        struct Sample: Decodable {
            let fixture: String
            let radius: Double
            let bounds: [Double]
            let rgba: Data
            let rgbaFloat32: Data
        }
    }

    func testGaussianAffineRequestsMatchNativeRegionalBoundaries() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-gaussian-regional-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 12)
        XCTAssertTrue(reference.cachePoliciesMatched)
        let options: [[CIContextOption: Any]] = [
            [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()],
            [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]]
        for options in options {
            let context = CIContext(options: options)
            var fullImages: [String: (actual: [Float], expected: [Float])] = [:]
            for sample in reference.cases {
                var pixels = PixelBuffer(width: reference.width, height: reference.height)
                for y in 0..<reference.height { for x in 0..<reference.width {
                    if sample.fixture == "opaque-gradient" {
                        pixels[x, y] = (UInt8(x * 255 / (reference.width - 1)), UInt8(y * 255 / (reference.height - 1)), 100, 255)
                    } else {
                        XCTAssertEqual(sample.fixture, "impulse")
                        let value: UInt8 = x == reference.width / 2 && y == reference.height / 2 ? 255 : 0
                        pixels[x, y] = (value, value, value, value)
                    }
                } }
                let image = CIImage(cgImage: CGImage(pixels)).applyingGaussianBlur(sigma: sample.radius)
                    .transformed(by: CGAffineTransform(scaleX: 2, y: 1))
                let bounds = CGRect(x: sample.bounds[0], y: sample.bounds[1], width: sample.bounds[2], height: sample.bounds[3])
                let width = Int(bounds.width), height = Int(bounds.height)
                let label = "Native \(sample.fixture), sigma \(sample.radius), bounds \(bounds)"
                var actual = [Float](repeating: 0, count: width * height * 4)
                actual.withUnsafeMutableBytes { buffer in
                    context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                                   bounds: bounds, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                }
                XCTAssertTrue(actual.allSatisfy(\.isFinite), label)
                var expected = [Float](repeating: 0, count: sample.rgbaFloat32.count / 4)
                _ = expected.withUnsafeMutableBytes { sample.rgbaFloat32.copyBytes(to: $0) }
                XCTAssertEqual(actual.count, expected.count)
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                bytes.withUnsafeMutableBytes { buffer in
                    context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                                   bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                }
                let byteWorst = zip(bytes, sample.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(byteWorst, 1, label)
                let key = "\(sample.fixture)-\(sample.radius)"
                if width == reference.width * 2 {
                    fullImages[key] = (actual, expected)
                    continue
                }
                let full = try XCTUnwrap(fullImages[key])
                var worstDelta: Float = 0
                // Native interior requests can differ from cropping a larger render. Check that difference
                // directly, below a quarter byte, rather than asserting an independence native does not have.
                for y in 0..<height { for x in 0..<width { for channel in 0..<4 {
                    let at = (y * width + x) * 4 + channel
                    let fullY = reference.height - Int(bounds.maxY) + y
                    let fullAt = (fullY * reference.width * 2 + Int(bounds.minX) + x) * 4 + channel
                    let delta = (actual[at] - full.actual[fullAt]) - (expected[at] - full.expected[fullAt])
                    worstDelta = max(worstDelta, abs(delta))
                } } }
                XCTAssertLessThanOrEqual(worstDelta, 1 / 1024, label)
            }
        }
    }
}
