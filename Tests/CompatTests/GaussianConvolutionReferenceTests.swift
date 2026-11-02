import Foundation
import CoreGraphics
@testable import CoreImage
import XCTest

final class GaussianConvolutionReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        struct Sample: Decodable {
            let fixture: String
            let clamped: Bool
            let radius: Double
            let workingFormat: String
            let rgbaFloatBase64: Data
        }
        let schema: Int, width: Int, height: Int
        let platform: String
        let inputs: [String: Data]
        let cases: [Sample]
    }

    private func loadReference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-gaussian-convolution-reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    func testSmallStencilMatchesNativeFloatColorsAndCoverage() throws {
        let reference = try loadReference()
        XCTAssertEqual(reference.schema, 2)
        XCTAssertEqual(reference.platform, "macOS")
        XCTAssertEqual(reference.cases.count, 48)
        let bounds = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        for sample in reference.cases {
            let half = sample.workingFormat == "RGBAh"
            let data = try XCTUnwrap(reference.inputs[sample.workingFormat + ":" + sample.fixture])
            let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let expected = sample.rgbaFloatBase64.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            XCTAssertEqual(values.count, reference.width * reference.height * 4)
            let source = Raster(rect: bounds, data: values)
            let halo = bounds.insetBy(dx: -ceil(sample.radius * 3), dy: -ceil(sample.radius * 3))
            let padded = sample.clamped ? source.clamped(to: halo) : source.cropped(to: halo)
            let actual = RasterFilters.gaussian(padded, sigma: sample.radius, output: bounds,
                sampling: .pixelArea, halfPrecision: half)
            XCTAssertEqual(actual.data.count, expected.count)
            let worst = zip(actual.data, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, half ? 0 : 0.000001,
                "Native \(sample.fixture), \(sample.workingFormat), radius \(sample.radius), clamped \(sample.clamped): \(worst)")
        }
    }

    func testContextWorkingFormatSelectsNativeImpulseArithmetic() throws {
        let reference = try loadReference()
        let bounds = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        let input = try XCTUnwrap(reference.inputs["RGBAh:impulse"])
        let bytes = input.withUnsafeBytes { buffer in buffer.bindMemory(to: Float.self).map { UInt8($0 * 255) } }
        let image = CIImage(bitmapData: Data(bytes), bytesPerRow: reference.width * 4,
            size: bounds.size, format: .RGBA8, colorSpace: nil)
        for sample in reference.cases where sample.fixture == "impulse" && !sample.clamped {
            for useDefault in sample.workingFormat == "RGBAh" ? [false, true] : [false] {
                var options: [CIContextOption: Any] = [.workingColorSpace: NSNull()]
                if !useDefault { options[.workingFormat] = sample.workingFormat == "RGBAh" ? CIFormat.RGBAh : CIFormat.RGBAf }
                let context = CIContext(options: options)
                let blurred = image.applyingGaussianBlur(sigma: sample.radius)
                var red = [Float](repeating: 0, count: reference.width * reference.height)
                red.withUnsafeMutableBytes { output in
                    context.render(blurred, toBitmap: output.baseAddress!, rowBytes: reference.width * 4,
                        bounds: bounds, format: .Rf, colorSpace: nil)
                }
                let expected = sample.rgbaFloatBase64.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let worst = red.enumerated().map { abs($0.element - expected[$0.offset * 4]) }.max() ?? 0
                XCTAssertLessThanOrEqual(worst, sample.workingFormat == "RGBAh" ? 0 : 0.000001,
                    "Context \(sample.workingFormat), default \(useDefault), radius \(sample.radius): \(worst)")
            }
        }
    }
}
