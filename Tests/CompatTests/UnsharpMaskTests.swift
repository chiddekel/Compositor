import Foundation
import CoreGraphics
@testable import CoreImage
import XCTest

final class UnsharpMaskTests: XCTestCase {
    func testDetailRetainsHDRNegativeChannelsAndSourceCoverage() {
        let bounds = CGRect(x: -2, y: 3, width: 3, height: 1)
        let source = Raster(rect: bounds, data: [2, -0.25, 0.5, 1, 0.2, 0.3, 0.4, 0.5, 0, 0, 0, 0])
        let blurred = Raster(rect: bounds, data: [1, 0, 0.25, 0.8, 0.1, 0.2, 0.3, 0.7, 0.2, 0.3, 0.4, 0.1])
        let result = RasterFilters.unsharp(source, blurred: blurred, intensity: 2)
        XCTAssertEqual(Array(result.data[0..<4]), [4, -0.75, 1, 1])
        XCTAssertEqual(result.data[7], 0.5)
        XCTAssertEqual(Array(result.data[8..<12]), [0, 0, 0, 0])
        XCTAssertEqual(RasterFilters.unsharp(source, blurred: blurred, intensity: 0).data.map(\.bitPattern),
                       source.data.map(\.bitPattern))
    }

    func testFilterSupportsDefaultsAndZeroIntensityIsIdentity() throws {
        XCTAssertNotNil(CIFilter(name: "CIUnsharpMask"))
        let bounds = CGRect(x: 0, y: 0, width: 20, height: 12)
        let image = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1)).cropped(to: bounds)
        let sharpened = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputIntensityKey: 0])
        XCTAssertEqual(sharpened.extent, image.extent)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])
        XCTAssertEqual(try XCTUnwrap(context.createCGImage(sharpened, from: bounds)).portableImage.bytes,
                       try XCTUnwrap(context.createCGImage(image, from: bounds)).portableImage.bytes)
    }

    func testUnsharpRequestsReadTheirHaloAndMatchTiles() throws {
        let width = 32, height = 20
        var image = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let value: UInt8 = x < width / 2 ? 77 : 178
            image[x, y] = (value, value, value, 255)
        } }
        let bounds = CGRect(x: -7, y: 4, width: width, height: height)
        let input = CIImage(cgImage: CGImage(image)).transformed(by: CGAffineTransform(translationX: -7, y: 4))
        let sharpened = input.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 2, kCIInputIntensityKey: 2])
        let context = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])
        let full = try XCTUnwrap(context.createCGImage(sharpened, from: bounds)).portableImage
        let tile = CGRect(x: 5, y: 8, width: 8, height: 6)
        let partial = try XCTUnwrap(context.createCGImage(sharpened, from: tile)).portableImage
        for y in 0..<partial.height { for x in 0..<partial.width { for channel in 0..<4 {
            let a = partial.bytes[y * partial.bytesPerRow + x * 4 + channel]
            let b = full.bytes[(height - (Int(tile.minY - bounds.minY) + partial.height) + y) * full.bytesPerRow
                + (Int(tile.minX - bounds.minX) + x) * 4 + channel]
            XCTAssertEqual(a, b)
        } } }
        XCTAssertLessThan(full.bytes[10 * full.bytesPerRow + 14 * 4], 77)
        XCTAssertGreaterThan(full.bytes[10 * full.bytesPerRow + 17 * 4], 178)
        XCTAssertEqual(full.bytes[10 * full.bytesPerRow + 2 * 4], 77)
    }
}
