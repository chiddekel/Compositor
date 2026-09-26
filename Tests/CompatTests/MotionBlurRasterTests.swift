import CoreGraphics
import Foundation
import XCTest
@testable import CoreImage

final class MotionBlurRasterTests: XCTestCase {
    // Independent copy of the former scalar algorithm, including transparent borders
    // and bilinear interpolation. The optimized path must retain its pixels.
    private func reference(_ input: Raster, radius: Double, angle: Double, region: CGRect) -> Raster {
        var output = Raster(rect: region)
        let taps = max(1, Int(ceil(radius * 2)))
        for y in 0..<output.height {
            for x in 0..<output.width {
                let cx = Double(region.minX - input.rect.minX) + Double(x) + 0.5
                let cy = Double(region.minY - input.rect.minY) + Double(y) + 0.5
                var sum: (Float, Float, Float, Float) = (0, 0, 0, 0)
                for tap in 0...taps {
                    let s = (Double(tap) / Double(taps) * 2 - 1) * radius
                    let pixel = input.bilinear(cx + s * cos(angle), cy + s * sin(angle))
                    sum.0 += pixel.0; sum.1 += pixel.1; sum.2 += pixel.2; sum.3 += pixel.3
                }
                let i = output.index(x, y), n = Float(taps + 1)
                output.data[i] = sum.0 / n; output.data[i + 1] = sum.1 / n
                output.data[i + 2] = sum.2 / n; output.data[i + 3] = sum.3 / n
            }
        }
        return output
    }

    func testMatchesScalarAtAnglesFractionalRadiiAndTransparentEdges() {
        for size in [CGSize(width: 1, height: 1), CGSize(width: 3, height: 2), CGSize(width: 49, height: 37)] {
            var input = Raster(rect: CGRect(origin: CGPoint(x: -7, y: 11), size: size))
            for i in input.data.indices { input.data[i] = Float((i * 37 + 13) % 251) / 250 }
            for radius in [0, 0.3, 10 / sqrt(12.0), 8.25, 577.35] {
                for angle in [0, 0.001, Double.pi / 4, Double.pi / 2, -1.1, Double.pi] {
                    let region = input.rect.insetBy(dx: -2, dy: -3)
                    let expected = reference(input, radius: radius, angle: angle, region: region)
                    let actual = RasterFilters.motionBlur(input, radius: radius, angle: angle, output: region)
                    let difference = zip(expected.data, actual.data).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertLessThanOrEqual(difference, 0.000002, "size=\(size), radius=\(radius), angle=\(angle)")
                }
            }
        }
    }

    func testDefaultFullHDRenderDoesNotBlockForSeconds() {
        #if !DEBUG
        var input = Raster(rect: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        for i in input.data.indices { input.data[i] = Float(i % 251) / 250 }
        for angle in [0.0, Double.pi / 4, Double.pi / 2] {
            let start = Date()
            let image = RasterFilters.motionBlur(input, radius: 10 / sqrt(12.0), angle: angle, output: input.rect)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(image.data.count, input.data.count)
            XCTAssertGreaterThan(image.data[4 * (540 * 1920 + 960)], 0)
            print("MOTION 1920x1080 angle=\(angle): \(elapsed * 1000) ms")
            XCTAssertLessThan(elapsed, 0.5, "Default Motion Blur must not monopolize the desktop for seconds")
        }
        #endif
    }
}
