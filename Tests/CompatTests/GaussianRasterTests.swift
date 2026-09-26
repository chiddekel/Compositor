import Foundation
import CoreGraphics
import XCTest
@testable import CoreImage

final class GaussianRasterTests: XCTestCase {
    func testRegionalGaussianMatchesWholePixelsAcrossTileEdgesAndImageBorders() throws {
        let width = 530, height = 390
        var buffer = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let alpha = UInt8(128 + (x + y) % 128)
            buffer[x, y] = (UInt8(x % 128), UInt8(y % 128), 70, alpha)
        } }
        let graph = CIImage(cgImage: CGImage(buffer)).applyingGaussianBlur(sigma: 4.2)
        let bounds = CGRect(x: -13, y: -11, width: width, height: height)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        for format in [CIFormat.RGBA8, .L8, .A8] {
            let whole = try XCTUnwrap(context.createCGImage(graph, from: bounds, format: format)).portableImage
            let regional = try XCTUnwrap(context.createCGImage(graph, from: bounds, format: format))
            XCTAssertTrue(regional.supportsRegionRendering)
            for rect in [CGRect(x: 0, y: 0, width: 23, height: 28),
                         CGRect(x: 250, y: 250, width: 37, height: 60),
                         CGRect(x: 500, y: 360, width: 30, height: 30)] {
                let expected = try XCTUnwrap(whole.cropping(to: rect)).bytes
                let actual = try XCTUnwrap(regional.cropping(to: rect)).bytes
                XCTAssertEqual(actual.count, expected.count)
                XCTAssertEqual(zip(actual, expected).filter { $0 != $1 }.count, 0)
            }
        }
    }

    func testDeferredImageReusesTilesAndStillMaterializesAllPixels() throws {
        var requests: [CGRect] = []
        let image = CGImage(width: 1024, height: 768, isGray: true) { rect in
            requests.append(rect)
            let w = Int(rect.width), h = Int(rect.height)
            let bytes = (0..<(w * h)).map { UInt8((Int(rect.minX) + $0 % w + Int(rect.minY) + $0 / w) % 251) }
            return PortableImage(width: w, height: h, kind: .mask, bytesPerRow: w, bytes: bytes)
        }
        XCTAssertTrue(requests.isEmpty)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: 250, y: 250, width: 20, height: 20)))
        XCTAssertEqual(crop.bytes[0], UInt8(500 % 251))
        XCTAssertEqual(crop.bytes.last, UInt8(538 % 251))
        XCTAssertEqual(requests.count, 4)
        _ = image.cropping(to: CGRect(x: 254, y: 254, width: 10, height: 10))
        XCTAssertEqual(requests.count, 4, "The overlapping crop reuses immutable filter tiles")
        XCTAssertEqual(image.cropping(to: CGRect(x: 0, y: 0, width: 1024, height: 768))?.bytes.count, 1024 * 768)
        XCTAssertEqual(requests.last, CGRect(x: 0, y: 0, width: 1024, height: 768))
        let count = requests.count
        _ = image.cropping(to: CGRect(x: 700, y: 500, width: 10, height: 10))
        XCTAssertEqual(requests.count, count, "Once materialized, crops use the full snapshot")
    }

    func testRegionalCacheEvictsOldTilesWithoutChangingPixels() throws {
        var calls = 0
        let image = CGImage(width: 2048, height: 1024, isGray: true) { rect in
            calls += 1
            let value = UInt8((Int(rect.minX) / 64 + Int(rect.minY) / 64) % 251)
            return PortableImage(width: Int(rect.width), height: Int(rect.height), kind: .mask,
                bytesPerRow: Int(rect.width), bytes: [UInt8](repeating: value, count: Int(rect.width * rect.height)))
        }
        let origin = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(image.cropping(to: origin)?.bytes, [0])
        XCTAssertEqual(image.cropping(to: origin)?.bytes, [0])
        XCTAssertEqual(calls, 1)
        for index in 1...256 {
            let rect = CGRect(x: (index % 32) * 64, y: (index / 32) * 64, width: 1, height: 1)
            XCTAssertEqual(image.cropping(to: rect)?.bytes, [UInt8((index % 32 + index / 32) % 251)])
        }
        XCTAssertEqual(calls, 257)
        XCTAssertEqual(image.cropping(to: origin)?.bytes, [0])
        XCTAssertEqual(calls, 258, "An evicted tile is recomputed from the immutable source")
    }

    func testClippedTransformedDrawingMatchesMaterializedGaussian() throws {
        var buffer = PixelBuffer(width: 530, height: 390)
        for y in 0..<390 { for x in 0..<530 { buffer[x, y] = (UInt8(x % 251), UInt8(y % 251), 20, 255) } }
        let bounds = CGRect(x: 0, y: 0, width: 530, height: 390)
        let graph = CIImage(cgImage: CGImage(buffer)).applyingGaussianBlur(sigma: 4)
        let filter = CIContext(options: [.workingColorSpace: NSNull()])
        let regional = try XCTUnwrap(filter.createCGImage(graph, from: bounds))
        let whole = CGImage(try XCTUnwrap(filter.createCGImage(graph, from: bounds)).portableImage)
        func draw(_ image: CGImage) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 70, height: 60, bitsPerComponent: 8,
                bytesPerRow: 70 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.clip(to: CGRect(x: 5, y: 4, width: 58, height: 50))
            context.translateBy(x: -240, y: -160)
            context.rotate(by: 0.03)
            context.scaleBy(x: 1.1, y: 0.9)
            context.interpolationQuality = .medium
            context.draw(image, in: bounds)
            return try XCTUnwrap(context.makeImage()).bytes
        }
        let actual = try draw(regional), expected = try draw(whole)
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertLessThanOrEqual(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max()!, 1)
    }

    func testLargeGaussianPreservesConstantInterior() {
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let input = Raster(rect: rect, data: [Float](repeating: 0.5, count: 1920 * 1080 * 4))
        let start = ContinuousClock.now
        let output = RasterFilters.gaussian(input, sigma: 25.6, output: rect)
        print("Gaussian 1920x1080 sigma 25.6: \(ContinuousClock.now - start)")
        for c in 0..<4 { XCTAssertEqual(output.data[(540 * 1920 + 960) * 4 + c], 0.5, accuracy: 0.000001) }
        XCTAssertLessThan(output.data[0], 0.2, "Transparent margins must still soften the corner")
    }

    func testParallelGaussianMatchesScalarConvolutionIncludingTransparentMargins() {
        for (width, height) in [(1, 1), (3, 2), (49, 37)] {
            var input = Raster(rect: CGRect(x: -7, y: 11, width: width, height: height))
            for i in input.data.indices { input.data[i] = Float((i * 37 + 19) % 251) / 251 }
            for sigma in [0.7, 2.3, 8.0, 25.6] {
                let radius = Int(ceil(sigma * 3))
                var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
                let total = kernel.reduce(0, +)
                kernel = kernel.map { $0 / total }
                // Independent scalar oracle: separate sums for every channel and explicit zero borders.
                var horizontal = input.data.map { _ in Float(0) }
                var expected = horizontal
                for y in 0..<height { for x in 0..<width { for c in 0..<4 {
                    for k in -radius...radius where (0..<width).contains(x + k) {
                        horizontal[(y * width + x) * 4 + c] += input.data[(y * width + x + k) * 4 + c] * kernel[k + radius]
                    }
                } } }
                for y in 0..<height { for x in 0..<width { for c in 0..<4 {
                    for k in -radius...radius where (0..<height).contains(y + k) {
                        expected[(y * width + x) * 4 + c] += horizontal[((y + k) * width + x) * 4 + c] * kernel[k + radius]
                    }
                } } }
                let actual = RasterFilters.gaussian(input, sigma: sigma, output: input.rect)
                XCTAssertEqual(actual.rect, input.rect)
                XCTAssertEqual(actual.data.count, expected.count)
                for i in expected.indices { XCTAssertEqual(actual.data[i], expected[i], accuracy: 0.000001) }
                // Cropping preserves the same coordinate origin and pixels.
                let reference = Raster(rect: input.rect, data: expected)
                for region in [CGRect(x: -7, y: 11, width: 1, height: 1),
                               CGRect(x: -7 + width / 2, y: 11 + height / 2, width: 3, height: 4),
                               CGRect(x: -9, y: 9, width: width + 4, height: height + 4),
                               CGRect(x: 100, y: 100, width: 2, height: 2)] {
                    let cropped = RasterFilters.gaussian(input, sigma: sigma, output: region)
                    let expectedCrop = reference.cropped(to: region)
                    XCTAssertEqual(cropped.rect, region)
                    XCTAssertEqual(cropped.data.count, expectedCrop.data.count)
                    for i in expectedCrop.data.indices {
                        XCTAssertEqual(cropped.data[i], expectedCrop.data[i], accuracy: 0.000001)
                    }
                }
            }
        }
    }

    func testLargeKernelMatchesScalarAcrossFFTBlocksAndRegionalFallback() {
        // Non-power-of-two sizes cross overlap-save blocks in both directions.
        // Narrow rasters also exercise a mixture of FFT and direct passes.
        for (width, height) in [(513, 277), (3, 513), (513, 3)] {
            var input = Raster(rect: CGRect(x: -7, y: 11, width: width, height: height))
            for i in input.data.indices { input.data[i] = Float((i * 37 + 19) % 251) / 251 }
            for sigma in [16.0, 25.6, 80.0] {
                let radius = Int(ceil(sigma * 3))
                var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
                let total = kernel.reduce(0, +)
                kernel = kernel.map { $0 / total }
                var horizontal = input.data.map { _ in Float(0) }
                var expected = horizontal
                for y in 0..<height { for x in 0..<width {
                    for k in max(-radius, -x)...min(radius, width - x - 1) { for c in 0..<4 {
                        horizontal[(y * width + x) * 4 + c] += input.data[(y * width + x + k) * 4 + c] * kernel[k + radius]
                    } }
                } }
                for y in 0..<height { for x in 0..<width {
                    for k in max(-radius, -y)...min(radius, height - y - 1) { for c in 0..<4 {
                        expected[(y * width + x) * 4 + c] += horizontal[((y + k) * width + x) * 4 + c] * kernel[k + radius]
                    } }
                } }
                let reference = Raster(rect: input.rect, data: expected)
                for region in [input.rect, input.rect.insetBy(dx: -2, dy: -3),
                               CGRect(x: 243, y: 250, width: 64, height: 64),
                               CGRect(x: 4, y: 12, width: 300, height: 260)] {
                    let actual = RasterFilters.gaussian(input, sigma: sigma, output: region)
                    let wanted = reference.cropped(to: region)
                    let error = zip(actual.data, wanted.data).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertLessThan(error, 0.000002, "size=\(width)x\(height), sigma=\(sigma), region=\(region)")
                }
            }
        }
    }
}
