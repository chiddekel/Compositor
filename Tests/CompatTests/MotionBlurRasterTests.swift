import CoreGraphics
import Foundation
import XCTest
@testable import CoreImage

final class MotionBlurRasterTests: XCTestCase {
    func testRegionalRenderIncludesSamplesBeyondTheFormerUniformRadius() throws {
        var pixels = PixelBuffer(width: 65, height: 65)
        for y in 0..<65 { pixels[40, y] = (255, 255, 255, 255) }
        let image = CIImage(cgImage: CGImage(pixels)).applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: 4.0, kCIInputAngleKey: 0.0,
        ])
        XCTAssertLessThanOrEqual(image.extent.minX, -12)
        XCTAssertGreaterThanOrEqual(image.extent.maxX, 77)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let full = try XCTUnwrap(context.createCGImage(image, from: CGRect(x: 0, y: 0, width: 65, height: 65),
                                                     format: .RGBA8, colorSpace: space))
        let tile = try XCTUnwrap(context.createCGImage(image, from: CGRect(x: 32, y: 32, width: 1, height: 1),
                                                     format: .RGBA8, colorSpace: space))
        let index = 32 * full.bytesPerRow + 32 * 4
        let expected = Array(full.portableImage.bytes[index..<(index + 4)])
        XCTAssertGreaterThan(expected[3], 0, "A source two standard deviations away still contributes")
        XCTAssertEqual(Array(tile.portableImage.bytes.prefix(4)), expected,
                       "Regional evaluation must request the entire weighted sampling footprint")
    }

    func testRadiusMatchesTheStandardDeviationUsedByUpstreamDistanceCalibration() {
        // PixelFilter maps a streak distance d to radius d / sqrt(12): radius is its standard deviation.
        // Measuring the impulse's second moment independently detects a shorter, uniform sample interval.
        let region = CGRect(x: 0, y: 0, width: 129, height: 129)
        var input = Raster(rect: region)
        let center = input.index(64, 64)
        for channel in 0..<4 { input.data[center + channel] = 1 }
        for radius in [2.0, 4.0, 8.0] {
            for angle in [0.0, Double.pi / 4, Double.pi / 2, -Double.pi / 4] {
                let output = RasterFilters.motionBlur(input, radius: radius, angle: angle, output: region)
                var mass = 0.0, major = 0.0, minor = 0.0
                for y in 0..<output.height { for x in 0..<output.width {
                    let alpha = Double(output.data[output.index(x, y) + 3])
                    let u = Double(x - 64) * cos(angle) + Double(y - 64) * sin(angle)
                    let v = -Double(x - 64) * sin(angle) + Double(y - 64) * cos(angle)
                    mass += alpha; major += alpha * u * u; minor += alpha * v * v
                } }
                XCTAssertEqual(mass, 1, accuracy: 0.00001)
                XCTAssertEqual(major / mass, radius * radius, accuracy: max(0.3, radius * radius * 0.06),
                               "radius=\(radius), angle=\(angle): Motion Blur must retain upstream's distance calibration")
                XCTAssertLessThan(minor / mass, 0.3, "Interpolation may soften the line by a fraction of a pixel")
            }
        }
    }

    // Scalar weighted-line convolution checks the SIMD sampler, including transparent borders and
    // bilinear interpolation. The impulse moments above independently enforce radius calibration.
    private func reference(_ input: Raster, radius: Double, angle: Double, region: CGRect) -> Raster {
        guard radius > 0 else { return input.cropped(to: region) }
        var output = Raster(rect: region)
        let reach = Int(ceil(radius * 3))
        func cumulative(_ distance: Double) -> Double { (1 + erf(distance / (radius * sqrt(2)))) / 2 }
        let weights = (-reach...reach).map { tap -> Double in
            let lower = tap == -reach ? 0 : cumulative(Double(tap) - 0.5)
            let upper = tap == reach ? 1 : cumulative(Double(tap) + 0.5)
            return upper - lower
        }
        let total = weights.reduce(0, +)
        for y in 0..<output.height {
            for x in 0..<output.width {
                let cx = Double(region.minX - input.rect.minX) + Double(x) + 0.5
                let cy = Double(region.minY - input.rect.minY) + Double(y) + 0.5
                var sum: (Float, Float, Float, Float) = (0, 0, 0, 0)
                for tap in -reach...reach {
                    let s = Double(tap), weight = Float(weights[tap + reach] / total)
                    let pixel = input.bilinear(cx + s * cos(angle), cy + s * sin(angle))
                    sum.0 += pixel.0 * weight; sum.1 += pixel.1 * weight; sum.2 += pixel.2 * weight; sum.3 += pixel.3 * weight
                }
                let i = output.index(x, y)
                output.data[i] = sum.0; output.data[i + 1] = sum.1
                output.data[i + 2] = sum.2; output.data[i + 3] = sum.3
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
