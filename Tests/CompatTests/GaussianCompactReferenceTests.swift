import Foundation
import CoreGraphics
@testable import CoreImage
import XCTest

final class GaussianCompactReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        struct Sample: Decodable {
            let fixture: String, workingFormat: String, sampling: String
            let radius: Double
            let clamped: Bool
            let rgbaFloatBase64: Data
        }
        let schema: Int, width: Int, height: Int, unqualifiedControls: Int
        let platform: String
        let inputs: [String: Data]
        let cases: [Sample]
    }

    private func loadReference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-gaussian-compact-reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    func testCompactByteAndFloatSamplersMatchNativeControls() throws {
        let reference = try loadReference()
        XCTAssertEqual(reference.schema, 1)
        XCTAssertEqual(reference.platform, "macOS")
        XCTAssertEqual(reference.cases.count, 234)
        XCTAssertEqual(reference.unqualifiedControls, 18)
        let bounds = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        for sample in reference.cases {
            let bytes = try XCTUnwrap(reference.inputs[sample.workingFormat + ":" + sample.fixture])
            let input = Raster(rect: bounds, data: bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
            let halo = bounds.insetBy(dx: -1, dy: -1)
            let padded = sample.clamped ? input.clamped(to: halo) : input.cropped(to: halo)
            let actual = RasterFilters.gaussian(padded, sigma: sample.radius, output: bounds,
                sampling: .pixelArea, compactSampling: sample.sampling == "byte" ? .byte : .float)
            let expected = sample.rgbaFloatBase64.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            XCTAssertEqual(actual.data.count, expected.count)
            let worst = zip(actual.data, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 0.000001,
                "Native \(sample.fixture), \(sample.workingFormat), radius \(sample.radius), clamped \(sample.clamped): \(worst)")
        }
    }

    func testContextKeepsFiniteByteSamplingAndConvertsFloatWorkingClamp() throws {
        let reference = try loadReference()
        let bounds = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        let source = try XCTUnwrap(reference.inputs["RGBAf:impulse"])
        let pixels = source.withUnsafeBytes { buffer in buffer.bindMemory(to: Float.self).map { UInt8($0 * 255) } }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: reference.width * 4,
            size: bounds.size, format: .RGBA8, colorSpace: nil)
        for sample in reference.cases where sample.fixture == "impulse" {
            let context = CIContext(options: [.workingColorSpace: NSNull(),
                .workingFormat: sample.workingFormat == "RGBAh" ? CIFormat.RGBAh : CIFormat.RGBAf])
            let input = sample.clamped ? image.clampedToExtent() : image
            let blurred = input.applyingGaussianBlur(sigma: sample.radius)
            if !sample.clamped {
                let support = RasterFilters.nativeGaussianSupport(sample.radius)
                XCTAssertEqual(blurred.extent, bounds.insetBy(dx: -support, dy: -support))
            }
            var red = [Float](repeating: 0, count: reference.width * reference.height)
            red.withUnsafeMutableBytes {
                context.render(blurred, toBitmap: $0.baseAddress!, rowBytes: reference.width * 4,
                    bounds: bounds, format: .Rf, colorSpace: nil)
            }
            let expected = sample.rgbaFloatBase64.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let worst = red.enumerated().map { abs($0.element - expected[$0.offset * 4]) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 0.000001,
                "Context \(sample.workingFormat), radius \(sample.radius), clamped \(sample.clamped): \(worst)")
        }
    }
}
