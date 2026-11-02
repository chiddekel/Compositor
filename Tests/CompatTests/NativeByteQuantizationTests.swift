import Foundation
import CoreGraphics
@testable import CoreImage
import XCTest

final class NativeByteQuantizationTests: XCTestCase {
    private struct Reference: Decodable {
        struct Sample: Decodable {
            let value: Double
            let float32Bits: String
            let byte: UInt8
        }
        let schema: Int
        let platform: String
        let nativeComponentsChecked: Int, floatScalingMismatches: Int, doubleScalingMismatches: Int
        let samples: [Sample]
    }

    private func loadReference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-rgba8-quantization-reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    func testByteConversionPreservesNativeMidpointSide() throws {
        let reference = try loadReference()
        XCTAssertEqual(reference.schema, 1)
        XCTAssertEqual(reference.platform, "macOS")
        XCTAssertEqual(reference.nativeComponentsChecked, 3_247_104)
        XCTAssertEqual(reference.floatScalingMismatches, 332)
        XCTAssertEqual(reference.doubleScalingMismatches, 0)
        for sample in reference.samples {
            let bits = try XCTUnwrap(UInt32(sample.float32Bits, radix: 16))
            let value = Float(bitPattern: bits)
            XCTAssertEqual(Double(value), sample.value)
            XCTAssertEqual(PixelQuantization.unorm8(value), sample.byte, "Native bits \(sample.float32Bits)")
        }
    }

    func testPublicRGBAAndAlphaOutputsKeepNativeByteValues() throws {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        for sample in try loadReference().samples {
            let value = CGFloat(sample.value)
            let opaque = CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1)).cropped(to: bounds)
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes {
                context.render(opaque, toBitmap: $0.baseAddress!, rowBytes: 4, bounds: bounds, format: .RGBA8, colorSpace: nil)
            }
            XCTAssertEqual(bytes, [sample.byte, sample.byte, sample.byte, 255], "RGBA8 native bits \(sample.float32Bits)")
            let alpha = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: value)).cropped(to: bounds)
            var plane: UInt8 = 0
            context.render(alpha, toBitmap: &plane, rowBytes: 1, bounds: bounds, format: .A8, colorSpace: nil)
            XCTAssertEqual(plane, sample.byte, "A8 native bits \(sample.float32Bits)")
        }
    }
}
