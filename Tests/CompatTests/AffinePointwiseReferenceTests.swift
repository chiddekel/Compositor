import Foundation
import CoreGraphics
import CoreImage
import XCTest

final class AffinePointwiseReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let width: Int
        let height: Int
        let rows: [Int]
        let cases: [Sample]
        struct Sample: Decodable {
            let fixture: String
            let filter: String
            let translationX: Double
            let extent: [Double]?
            let rectangle: [Double]?
            let rgbaFloat32: Data
        }
    }

    func testAffineSamplesBeforePointwiseColorOperations() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-affine-pointwise-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 56)
        let bounds = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        func rect(_ components: [Double]) -> CGRect {
            CGRect(x: components[0], y: components[1], width: components[2], height: components[3])
        }
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
            let input = CIImage(cgImage: CGImage(pixels))
            let prepared: CIImage
            switch sample.filter {
            case "CIAffineTransform": prepared = input
            case "unpremultiply-affine": prepared = input.unpremultiplyingAlpha()
            case "alpha-one-affine": prepared = input.settingAlphaOne(in: bounds)
            case "linear-affine": prepared = input.applyingFilter("CISRGBToneCurveToLinear")
            case "unpremultiply-alpha-one-affine": prepared = input.unpremultiplyingAlpha().settingAlphaOne(in: bounds)
            case "linear-alpha-one-affine":
                prepared = input.unpremultiplyingAlpha().settingAlphaOne(in: bounds).applyingFilter("CISRGBToneCurveToLinear")
            case "alpha-one-rectangle": prepared = input.settingAlphaOne(in: rect(try XCTUnwrap(sample.rectangle)))
            default: XCTFail("Unknown native recipe \(sample.filter)"); continue
            }
            let image = prepared.transformed(by: CGAffineTransform(translationX: sample.translationX, y: 0))
            let label = "\(sample.fixture) \(sample.filter), translation \(sample.translationX)"
            XCTAssertEqual(image.extent, sample.extent.map(rect) ?? .null, label)
            var rendered = [Float](repeating: 0, count: reference.width * reference.height * 4)
            rendered.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: reference.width * 16,
                               bounds: bounds, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            var expected = [Float](repeating: 0, count: sample.rgbaFloat32.count / 4)
            _ = expected.withUnsafeMutableBytes { sample.rgbaFloat32.copyBytes(to: $0) }
            let actual = reference.rows.flatMap { row in
                Array(rendered[(row * reference.width * 4)..<((row + 1) * reference.width * 4)])
            }
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertTrue(actual.allSatisfy(\.isFinite), label)
            let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1 / 255, label)
        }
    }
}
