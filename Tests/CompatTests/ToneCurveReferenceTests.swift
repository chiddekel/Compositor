import Foundation
import CoreGraphics
import CoreImage
import XCTest

final class ToneCurveReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let width: Int
        let height: Int
        let rows: [Int]
        let cases: [Sample]
        struct Sample: Decodable {
            let fixture: String
            let profile: String
            let sourceGain: Double
            let points: [[Double]]
            let rgba: Data
            let rgbaFloat32: Data
        }
    }

    func testNativePerceptualCurvesAndIdentityHDR() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-tone-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 16)
        let bounds = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
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
            let gain = sample.sourceGain
            let source = CIImage(cgImage: CGImage(pixels)).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            let filter = try XCTUnwrap(CIFilter(name: "CIToneCurve"))
            filter.setValue(source, forKey: kCIInputImageKey)
            for (index, point) in sample.points.enumerated() {
                filter.setValue(CIVector(x: point[0], y: point[1]), forKey: "inputPoint\(index)")
            }
            let image = try XCTUnwrap(filter.outputImage)
            let label = "Native \(sample.fixture) \(sample.profile), RGB gain \(gain)"
            let rendered = try XCTUnwrap(context.createCGImage(image, from: bounds, format: .RGBA8,
                                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
            let bytes = rendered.portableImage.bytes, expectedBytes = [UInt8](sample.rgba)
            XCTAssertEqual(bytes.count, expectedBytes.count)
            let byteWorst = zip(bytes, expectedBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(byteWorst, 1, label)
            var floats = [Float](repeating: 0, count: reference.width * reference.height * 4)
            floats.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: reference.width * 16,
                               bounds: bounds, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            var expected = [Float](repeating: 0, count: sample.rgbaFloat32.count / 4)
            _ = expected.withUnsafeMutableBytes { sample.rgbaFloat32.copyBytes(to: $0) }
            let actual = reference.rows.flatMap { row in Array(floats[(row * reference.width * 4)..<((row + 1) * reference.width * 4)]) }
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertTrue(actual.allSatisfy(\.isFinite), label)
            let floatWorst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(floatWorst, 1 / 255, label)
        }
    }
}
