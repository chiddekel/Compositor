import Foundation
import CoreGraphics
@testable import CoreImage
import XCTest

final class RasterCropTests: XCTestCase {
    func testCropPreservesChannelBitsAndInitializesEveryPaddingPixel() {
        let bounds = CGRect(x: -3, y: 7, width: 7, height: 5)
        let values: [UInt32] = [0, 0x80000000, 0x3E99999A, 0x40000000,
                               0xBF800000, 0x00000001, 0x7FC01234, 0x7F800000]
        let data = (0..<(7 * 5 * 4)).map { Float(bitPattern: values[$0 % values.count]) }
        let source = Raster(rect: bounds, data: data)
        for x in -5...5 {
            for y in 5...13 {
                for size in [CGSize(width: 0, height: 0), CGSize(width: 1, height: 1),
                             CGSize(width: 3, height: 2), CGSize(width: 9, height: 7)] {
                    let region = CGRect(origin: CGPoint(x: x, y: y), size: size)
                    let output = source.cropped(to: region)
                    XCTAssertEqual(output.rect, region)
                    XCTAssertEqual(output.data.count, Int(size.width * size.height) * 4)
                    for row in 0..<Int(size.height) {
                        for column in 0..<Int(size.width) {
                            let sx = x + column + 3, sy = y + row - 7
                            for channel in 0..<4 {
                                let expected: UInt32 = (0..<7).contains(sx) && (0..<5).contains(sy)
                                    ? data[(sy * 7 + sx) * 4 + channel].bitPattern : 0
                                XCTAssertEqual(output.data[(row * Int(size.width) + column) * 4 + channel].bitPattern, expected)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(source.data.map(\.bitPattern), data.map(\.bitPattern))
    }
}
