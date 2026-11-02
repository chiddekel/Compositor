import Foundation
import CoreGraphics
import CoreImage
import XCTest

final class NativeGaussianReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let width: Int
        let height: Int
        let cases: [Sample]
        struct Sample: Decodable {
            let fixture: String
            let sigma: Double
            let rgba: Data
        }
    }

    func testGaussianMatchesNativePixelCoverageAndTransparentBorders() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-gaussian-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 18)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let rect = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        for sample in reference.cases {
            var buffer = PixelBuffer(width: reference.width, height: reference.height)
            for y in 0..<reference.height { for x in 0..<reference.width {
                if sample.fixture == "opaque-gradient" {
                    buffer[x, y] = (UInt8(x * 255 / (reference.width - 1)), UInt8(y * 255 / (reference.height - 1)), 100, 255)
                } else {
                    XCTAssertEqual(sample.fixture, "impulse")
                    let value: UInt8 = x == reference.width / 2 && y == reference.height / 2 ? 255 : 0
                    buffer[x, y] = (value, value, value, value)
                }
            } }
            let image = CIImage(cgImage: CGImage(buffer)).applyingGaussianBlur(sigma: sample.sigma)
            let rendered = try XCTUnwrap(context.createCGImage(image, from: rect, format: .RGBA8,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
            let actual = rendered.portableImage.bytes
            let expected = [UInt8](sample.rgba)
            XCTAssertEqual(actual.count, expected.count)
            let worst = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1, "Native macOS \(sample.fixture), sigma \(sample.sigma)")
        }
    }
}
