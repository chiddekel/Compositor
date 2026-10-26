import Foundation
import CoreGraphics
@testable import CoreImage
import XCTest

final class LanczosReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let width: Int
        let height: Int
        let cases: [Sample]
        struct Sample: Decodable {
            let fixture: String
            let aspect: Double
            let extent: [Double]
            let rgba: Data
        }
    }

    func testScaleMatchesNativeReconstructionAndIntegralExtent() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-lanczos-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 14)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let rect = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
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
            let image = CIImage(cgImage: CGImage(pixels)).applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: 1.0, kCIInputAspectRatioKey: sample.aspect])
            XCTAssertEqual(image.extent, CGRect(x: sample.extent[0], y: sample.extent[1], width: sample.extent[2], height: sample.extent[3]))
            let output = try XCTUnwrap(context.createCGImage(image, from: rect, format: .RGBA8,
                                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
            let actual = output.portableImage.bytes, expected = [UInt8](sample.rgba)
            XCTAssertEqual(actual.count, expected.count)
            let worst = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
            // The captured native approximation differs from normalized Lanczos-3 by up to two byte levels.
            // The full application parity gate retains its own, stricter thresholds.
            XCTAssertLessThanOrEqual(worst, 2, "Native macOS \(sample.fixture), aspect \(sample.aspect)")
        }
    }

    func testReconstructionPreservesFloatOvershootAndMatchesCroppedRequests() {
        let extent = CGRect(x: -12, y: 7, width: 96, height: 72)
        var input = Raster(rect: extent)
        for pixel in 0..<(input.width * input.height) {
            input.data[pixel * 4] = 3
            input.data[pixel * 4 + 1] = -0.25
            input.data[pixel * 4 + 3] = 1
        }
        let region = extent.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)).integral
        let output = RasterFilters.lanczos(input, scaleX: 0.5, scaleY: 0.5, output: region)
        XCTAssertGreaterThan(output.data.max() ?? 0, 3)
        XCTAssertLessThan(output.data.min() ?? 0, -0.25)
        XCTAssertGreaterThan(stride(from: 3, to: output.data.count, by: 4).map { output.data[$0] }.max() ?? 0, 1)
        let tile = region.insetBy(dx: 3, dy: 4)
        let partial = RasterFilters.lanczos(input, scaleX: 0.5, scaleY: 0.5, output: tile)
        XCTAssertEqual(partial.data, output.cropped(to: tile).data)
        XCTAssertEqual(RasterFilters.lanczos(input, scaleX: 1, scaleY: 1, output: extent).data, input.data)
    }
}
