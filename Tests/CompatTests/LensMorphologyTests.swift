import Foundation
@testable import CoreImage
import XCTest

final class LensMorphologyTests: XCTestCase {
    private func reference(_ input: Raster, width: Int, height: Int, maximum: Bool, region: CGRect) -> Raster {
        var result = Raster(rect: region)
        let ox = Int(region.minX - input.rect.minX), oy = Int(region.minY - input.rect.minY)
        for y in 0..<result.height {
            for x in 0..<result.width {
                for channel in 0..<4 {
                    var value: Float = maximum ? -.infinity : .infinity
                    for dy in -(height / 2)...(height / 2) {
                        for dx in -(width / 2)...(width / 2) {
                            let sx = min(input.width - 1, max(0, x + ox + dx))
                            let sample = input.data[input.index(sx, y + oy + dy) + channel]
                            value = maximum ? max(value, sample) : min(value, sample)
                        }
                    }
                    result.data[result.index(x, y) + channel] = value
                }
            }
        }
        return result
    }

    func testRectangleExtremaMatchIndependentTwoDimensionalWindows() {
        let values: [Float] = [-4, -0.0, 0, 0.125, 1 / 3, 1, 8, .leastNonzeroMagnitude, -.infinity, .infinity]
        let bounds = CGRect(x: -11, y: 23, width: 13, height: 19)
        let input = Raster(rect: bounds, data: (0..<(13 * 19 * 4)).map { values[($0 * 17 + $0 / 13) % values.count] })
        for maximum in [true, false] {
            for width in [1, 2, 3, 8, 31, 301] {
                for height in [1, 2, 5, 9] {
                    for slice in [CGRect(x: 0, y: height / 2, width: 13, height: 5),
                                  CGRect(x: 3, y: 7, width: 5, height: 3)] {
                        let region = slice.offsetBy(dx: bounds.minX, dy: bounds.minY)
                        let expected = reference(input, width: width, height: height, maximum: maximum, region: region)
                        let actual = LensRaster.morphology(input, width: width, height: height, maximum: maximum, region: region)
                        XCTAssertEqual(actual.data.map(\.bitPattern), expected.data.map(\.bitPattern),
                                       "maximum=\(maximum), \(width)×\(height), \(slice)")
                    }
                }
            }
        }
    }

    func testNaNsAndSignedZeroKeepSequentialExtremaBehavior() {
        let region = CGRect(x: 0, y: 2, width: 7, height: 3)
        for values: [Float] in [[0, -0.0], [-0.0, 0], [0, -0.0, 0], [-0.0, 0, -0.0],
                               [.nan], [.nan, -0.0, 0, 2, -.infinity]] {
            let input = Raster(rect: CGRect(x: 0, y: 0, width: 7, height: 7),
                               data: (0..<(7 * 7 * 4)).map { values[$0 % values.count] })
            for maximum in [true, false] {
                let expected = reference(input, width: 5, height: 5, maximum: maximum, region: region)
                let actual = LensRaster.morphology(input, width: 5, height: 5, maximum: maximum, region: region)
                XCTAssertEqual(actual.data.map(\.bitPattern), expected.data.map(\.bitPattern))
            }
        }
    }

    func testLongVerticalWindowKeepsCroppedChannelPositions() {
        let input = Raster(rect: CGRect(x: -4, y: -160, width: 9, height: 317),
                           data: (0..<(9 * 317 * 4)).map { Float(($0 * 31) % 101) - 51 })
        let region = CGRect(x: -2, y: -10, width: 5, height: 7)
        for maximum in [true, false] {
            let expected = reference(input, width: 7, height: 301, maximum: maximum, region: region)
            let actual = LensRaster.morphology(input, width: 7, height: 301, maximum: maximum, region: region)
            XCTAssertEqual(actual.data.map(\.bitPattern), expected.data.map(\.bitPattern))
        }
    }

    func testRepresentativeLongWindowTiming() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMPOSITOR_MORPHOLOGY_BENCHMARK"] == "1")
        let input = Raster(rect: CGRect(x: 0, y: 0, width: 640, height: 384),
                           data: (0..<(640 * 384 * 4)).map { Float(($0 * 197) % 1009) / 100 })
        let region = CGRect(x: 150, y: 3, width: 320, height: 320)
        let start = DispatchTime.now().uptimeNanoseconds
        let actual = LensRaster.morphology(input, width: 301, height: 1, maximum: true, region: region)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let expected = reference(input, width: 301, height: 1, maximum: true, region: region)
        XCTAssertEqual(actual.data.map(\.bitPattern), expected.data.map(\.bitPattern))
        print("MORPHOLOGY width=301 input=640x384 output=320x320 nanoseconds=\(elapsed)")
    }
}
