import XCTest
import CoreGraphics
import CoreImage
@testable import Compositor

final class LensBackendTests: XCTestCase {
    func testThresholdHundredKeepsTheStrongSourceAndRejectsSmallGlints() throws {
        let width = 400, height = 240
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 290, y: 110, width: 20, height: 20))
        context.fill(CGRect(x: 78, y: 48, width: 5, height: 5))
        let image = try XCTUnwrap(context.makeImage())
        func run(_ threshold: Double) throws -> CGImage {
            var settings = FilterSettings()
            settings.lens.effect = .starburst
            settings.lens.threshold = threshold
            settings.lens.starPoints = 4
            settings.lens.starAngle = 0
            settings.lens.starAmount = 100
            return try PixelFilter.run(FilterJob(kind: .lensEffects, image: image, settings: settings,
                scale: 1, selection: nil, mapping: .identity))
        }
        func green(_ image: CGImage, _ x: Int, _ y: Int) throws -> Int {
            let read = try BrushRaster.context(width: width, height: height, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: read)
            return Int(try XCTUnwrap(read.data).assumingMemoryBound(to: UInt8.self)[y * read.bytesPerRow + x * 4 + 1])
        }
        let low = try run(95), high = try run(100)
        XCTAssertGreaterThan(try green(low, 90, 50), try green(high, 90, 50) + 5)
        XCTAssertGreaterThan(try green(high, 320, 120), try green(image, 320, 120) + 10)
    }

    func testEveryAperturePreservesConstantHDRIncludingEdges() throws {
        let gpu = try XCTUnwrap(MetalBokeh.shared)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let extent = CGRect(x: 0, y: 0, width: 5, height: 3)
        let image = CIImage(color: CIColor(red: 2, green: 0.5, blue: 3, alpha: 1)).cropped(to: extent)
        for shape in BokehShape.allCases {
            for ring in [0.0, 1.0] {
                let blurred = try gpu.blur(image, extent: extent, radius: 2, shape: shape, ring: ring)
                var samples = [UInt16](repeating: 0, count: 5 * 3 * 4)
                context.render(blurred, toBitmap: &samples, rowBytes: 5 * 8, bounds: extent, format: .RGBAh, colorSpace: nil)
                let expected: [Float] = [2, 0.5, 3, 1]
                for index in samples.indices {
                    XCTAssertEqual(Float(Float16(bitPattern: samples[index])), expected[index % 4], accuracy: 0.005,
                                   "\(shape), ring \(ring), sample \(index)")
                }
            }
        }
    }
}
