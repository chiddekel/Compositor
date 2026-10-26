import Foundation
import Compression
import CoreGraphics
import CoreImage
import XCTest

final class NativeMotionPyramidTests: XCTestCase {
    func testRegionalPyramidUsesTheFullFrameSamplingGrid() throws {
        var pixels = PixelBuffer(width: 41, height: 29)
        for y in 0..<29 { for x in 0..<41 {
            pixels[x, y] = (UInt8((x * 17 + y * 23) % 256), UInt8(y * 8), 100, 255)
        } }
        let source = CIImage(cgImage: CGImage(pixels)).transformed(by: CGAffineTransform(translationX: -7, y: 11))
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: true])
        let bounds = CGRect(x: -23, y: -17, width: 101, height: 83)
        let tiles = [CGRect(x: -23, y: -17, width: 1, height: 1), CGRect(x: -9, y: 3, width: 13, height: 11),
                     CGRect(x: 21, y: 32, width: 9, height: 7), CGRect(x: 77, y: 65, width: 1, height: 1)]
        for radius in [3.25, 3.99, 35 / sqrt(12.0), 17, 35] {
            for degrees in [0.0, 90, -35, 35, 0.125] {
                let graph = source.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: degrees * .pi / 180])
                let full = try XCTUnwrap(context.createCGImage(graph, from: bounds)).portableImage.bytes
                for tile in tiles {
                    let actual = try XCTUnwrap(context.createCGImage(graph, from: tile)).portableImage.bytes
                    let firstRow = Int(bounds.maxY - tile.maxY), firstColumn = Int(tile.minX - bounds.minX)
                    var expected: [UInt8] = []
                    for row in 0..<Int(tile.height) {
                        let start = ((firstRow + row) * Int(bounds.width) + firstColumn) * 4
                        expected.append(contentsOf: full[start..<(start + Int(tile.width) * 4)])
                    }
                    XCTAssertEqual(actual, expected, "radius \(radius), degrees \(degrees), tile \(tile)")
                }
            }
        }
    }

    private struct Reference: Decodable {
        let sourceCaptureSHA256: String
        let width: Int
        let inputs: [String: Data]
        let cases: [Sample]
        struct Sample: Decodable {
            let fixture: String
            let phase: Int
            let radius: Double
            let gray: Data
        }
    }

    func testReductionTransitionsMatchNativeScanlines() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-motion-pyramid-reference.json.gz")
        let gzip = try Data(contentsOf: url)
        XCTAssertEqual(Array(gzip.prefix(4)), [0x1f, 0x8b, 8, 0])
        let count = gzip.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: gzip.count - 4, as: UInt32.self).littleEndian) }
        var json = [UInt8](repeating: 0, count: count)
        let payload = gzip.dropFirst(10).dropLast(8)
        let decoded = payload.withUnsafeBytes {
            compression_decode_buffer(&json, count, $0.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
        }
        XCTAssertEqual(decoded, count)
        let reference = try JSONDecoder().decode(Reference.self, from: Data(json))
        XCTAssertEqual(reference.sourceCaptureSHA256, "0ab6c00bfb3d59c618081416e6c682dbe535298cc2d5c9fc248ff41012adc4b4")
        XCTAssertEqual(reference.cases.count, 2640)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: true])
        var sources: [String: CIImage] = [:]
        for (key, bytes) in reference.inputs {
            XCTAssertEqual(bytes.count, reference.width * 4)
            var pixels = PixelBuffer(width: reference.width, height: 8)
            for y in 0..<8 { for x in 0..<reference.width {
                pixels[x, y] = (bytes[x * 4], bytes[x * 4 + 1], bytes[x * 4 + 2], bytes[x * 4 + 3])
            } }
            sources[key] = CIImage(cgImage: CGImage(pixels)).clampedToExtent()
        }
        for sample in reference.cases {
            let source = try XCTUnwrap(sources["\(sample.fixture):\(sample.phase)"])
            let image = source.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: sample.radius, kCIInputAngleKey: 0.0])
            let output = try XCTUnwrap(context.createCGImage(image, from: CGRect(x: 0, y: 3, width: reference.width, height: 1),
                                                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
            let actual = output.portableImage.bytes
            XCTAssertEqual(sample.gray.count, reference.width)
            var worst = 0
            for x in 0..<reference.width {
                for channel in 0..<3 { worst = max(worst, abs(Int(actual[x * 4 + channel]) - Int(sample.gray[x]))) }
                XCTAssertEqual(actual[x * 4 + 3], 255)
            }
            XCTAssertLessThanOrEqual(worst, 1, "Native \(sample.fixture), phase \(sample.phase), radius \(sample.radius)")
        }
    }
}
