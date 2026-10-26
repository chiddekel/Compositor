import XCTest
import CoreGraphics
import CoreImage

final class LensCoreImageTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func testAreaMaximumUsesRequestedExtentAndKeepsHDRPrecision() {
        let values: [Float16] = [0.25, 0, 0, 1, 0.5, 0, 0, 1, 8, 0, 0, 1,
                               1.5, 0, 0, 1, 2.25, 0, 0, 1, 9, 0, 0, 1]
        let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 24,
                            size: CGSize(width: 3, height: 2), format: .RGBAh, colorSpace: nil)
        let maximum = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect:
            CGRect(x: 0, y: 0, width: 2, height: 2))])
        XCTAssertEqual(maximum.extent, CGRect(x: 0, y: 0, width: 1, height: 1))
        var peak: Float = 0
        context.render(maximum, toBitmap: &peak, rowBytes: 4, bounds: maximum.extent, format: .Rf, colorSpace: nil)
        XCTAssertEqual(peak, 2.25)
    }

    func testRedFloatRenderKeepsRowsAndPadding() {
        let values: [Float16] = [0.25, 0, 0, 1, 0.5, 0, 0, 1, 1.5, 0, 0, 1, 2.25, 0, 0, 1]
        let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
                            size: CGSize(width: 2, height: 2), format: .RGBAh, colorSpace: nil)
        var output = [Float](repeating: -99, count: 6)
        context.render(image, toBitmap: &output, rowBytes: 12, bounds: image.extent, format: .Rf, colorSpace: nil)
        XCTAssertEqual(output, [0.25, 0.5, -99, 1.5, 2.25, -99])
    }

    func testAreaMaximumDoesNotConvertLinearLightTwice() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let maximum = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var peak: Float = 0
        CIContext().render(maximum, toBitmap: &peak, rowBytes: 4, bounds: maximum.extent, format: .Rf, colorSpace: nil)
        XCTAssertEqual(peak, 0.214041, accuracy: 0.00001)
    }

    func testMaximumMorphologyUsesADisc() throws {
        var buffer = PixelBuffer(width: 7, height: 7)
        for y in 0..<7 { for x in 0..<7 { buffer[x, y] = (0, 0, 0, 255) } }
        buffer[3, 3] = (255, 255, 255, 255)
        let image = CIImage(cgImage: CGImage(buffer))
        let dilated = image.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2])
        let bytes = try XCTUnwrap(context.createCGImage(dilated, from: image.extent)).portableImage.bytes
        for y in 0..<7 { for x in 0..<7 {
            let expected: UInt8 = (x - 3) * (x - 3) + (y - 3) * (y - 3) <= 4 ? 255 : 0
            XCTAssertEqual(bytes[(y * 7 + x) * 4], expected, "(\(x), \(y))")
        } }
        var whole = [Float](repeating: 0, count: 49), tile = [Float](repeating: 0, count: 12)
        context.render(dilated, toBitmap: &whole, rowBytes: 28, bounds: image.extent, format: .Rf, colorSpace: nil)
        context.render(dilated, toBitmap: &tile, rowBytes: 12, bounds: CGRect(x: 2, y: 1, width: 3, height: 4), format: .Rf, colorSpace: nil)
        for y in 0..<4 { for x in 0..<3 { XCTAssertEqual(tile[y * 3 + x], whole[(y + 2) * 7 + x + 2]) } }
    }

    func testHalfFloatBitmapRoundTripPreservesHDRAndRowOrder() {
        let samples: [Float16] = [2, 0.25, 0.5, 1, 0.1, 3, 0.2, 1]
        let data = samples.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 8, size: CGSize(width: 1, height: 2), format: .RGBAh, colorSpace: nil)
        var result = [UInt16](repeating: 0, count: 8)
        context.render(image, toBitmap: &result, rowBytes: 8, bounds: image.extent, format: .RGBAh, colorSpace: nil)
        XCTAssertEqual(result, samples.map(\.bitPattern))
    }

    func testTransferFunctionsAreInverseAndLinearizeMidGray() throws {
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let linear = source.applyingFilter("CISRGBToneCurveToLinear")
        let output = try XCTUnwrap(context.createCGImage(linear, from: linear.extent))
        XCTAssertEqual(Int(output.portableImage.bytes[0]), 55, accuracy: 1)
        let restored = try XCTUnwrap(context.createCGImage(linear.applyingFilter("CILinearToSRGBToneCurve"), from: linear.extent))
        XCTAssertEqual(Int(restored.portableImage.bytes[0]), 128, accuracy: 1)
    }

    func testRectangleOpeningRemovesCompactLightButKeepsWideBand() throws {
        var buffer = PixelBuffer(width: 7, height: 7)
        for y in 0..<7 { for x in 0..<7 { buffer[x, y] = (0, 0, 0, 255) } }
        buffer[1, 3] = (255, 255, 255, 255)
        for y in 1...5 { buffer[5, y] = (255, 255, 255, 255) }
        let source = CIImage(cgImage: CGImage(buffer))
        let opened = source.applyingFilter("CIMorphologyRectangleMinimum", parameters: ["inputWidth": 1, "inputHeight": 3])
            .applyingFilter("CIMorphologyRectangleMaximum", parameters: ["inputWidth": 1, "inputHeight": 3])
        let result = try XCTUnwrap(context.createCGImage(opened, from: source.extent)).portableImage.bytes
        XCTAssertEqual(result[(3 * 7 + 1) * 4], 0)
        XCTAssertEqual(result[(3 * 7 + 5) * 4], 255)
    }

    func testToneCurveHonorsPerceptualInteriorControlPoint() throws {
        // A perceptual input of 0.5 is 0.214041 in the working space. The output point 0.25 becomes 0.050876.
        let source = CIImage(color: CIColor(red: 0.21404114048223255, green: 0.21404114048223255, blue: 0.21404114048223255))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let curve = source.applyingFilter("CIToneCurve", parameters: ["inputPoint2": CIVector(x: 0.5, y: 0.25)])
        let result = try XCTUnwrap(context.createCGImage(curve, from: source.extent))
        XCTAssertEqual(Int(result.portableImage.bytes[0]), 13, accuracy: 1)
    }
}
