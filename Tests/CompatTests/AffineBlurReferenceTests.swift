import Foundation
import CoreGraphics
import CoreImage
import XCTest

final class AffineBlurReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let width: Int
        let height: Int
        let cases: [Sample]
        struct Sample: Decodable {
            let fixture: String
            let filter: String
            let radius: Double
            let translationX: Double?
            let scaleX: Double?
            let aspectRatio: Double?
            let extent: [Double]
            let rgba: Data
        }
    }

    func testBlurredIntermediatesUseNativeAffineSampling() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-affine-blur-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 24)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let bounds = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
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
            var image = CIImage(cgImage: CGImage(pixels))
            switch sample.filter {
            case "lanczos-gaussian-roundtrip":
                let aspect = try XCTUnwrap(sample.aspectRatio)
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1.0, kCIInputAspectRatioKey: aspect])
                    .applyingGaussianBlur(sigma: sample.radius).transformed(by: CGAffineTransform(scaleX: 1 / aspect, y: 1))
            case "gaussian-affine":
                image = image.applyingGaussianBlur(sigma: sample.radius)
                    .transformed(by: CGAffineTransform(translationX: try XCTUnwrap(sample.translationX), y: 0))
            case "gaussian-magnified":
                image = image.applyingGaussianBlur(sigma: sample.radius)
                    .transformed(by: CGAffineTransform(scaleX: try XCTUnwrap(sample.scaleX), y: 1))
            default: XCTFail("Unknown native recipe \(sample.filter)"); continue
            }
            let label = "\(sample.fixture) \(sample.filter), radius \(sample.radius), aspect \(sample.aspectRatio ?? 1)"
            XCTAssertEqual(image.extent, CGRect(x: sample.extent[0], y: sample.extent[1], width: sample.extent[2], height: sample.extent[3]), label)
            let rendered = try XCTUnwrap(context.createCGImage(image, from: bounds, format: .RGBA8,
                                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
            let actual = rendered.portableImage.bytes, expected = [UInt8](sample.rgba)
            XCTAssertEqual(actual.count, expected.count)
            let worst = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1, label)
        }
    }
}
