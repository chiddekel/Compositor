import Foundation
import CoreGraphics
import CoreImage
import XCTest

final class SamplingChoiceTests: XCTestCase {
    func testLinearOverridesNearestAndTheLastChoiceWins() throws {
        let image = CIImage(bitmapData: Data([0, 0, 0, 255, 255, 255, 255, 255]), bytesPerRow: 8,
                            size: CGSize(width: 2, height: 1), format: .RGBA8, colorSpace: nil)
        let bounds = CGRect(x: 0, y: 0, width: 4, height: 1)
        for software in [true, false] {
            let context = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: software])
            func pixels(_ input: CIImage) throws -> [Float] {
                let scaled = input.transformed(by: CGAffineTransform(scaleX: 2, y: 1))
                var result = [Float](repeating: 0, count: 16)
                context.render(scaled, toBitmap: &result, rowBytes: 64, bounds: bounds, format: .RGBAf, colorSpace: nil)
                return result
            }
            let smooth = try pixels(image.clampedToExtent())
            let nearest = image.samplingNearest().cropped(to: image.extent).clampedToExtent()
            let sharp = try pixels(nearest)
            XCTAssertNotEqual(smooth, sharp)
            XCTAssertEqual(try pixels(nearest.samplingLinear()), smooth)
            XCTAssertEqual(try pixels(nearest.samplingLinear().samplingNearest()), sharp)
            XCTAssertEqual(try pixels(nearest.samplingLinear().cropped(to: image.extent).clampedToExtent()), smooth)
        }
    }
}
