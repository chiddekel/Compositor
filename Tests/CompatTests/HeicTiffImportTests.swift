// HeicTiffImportTests — HEIC and TIFF read through ImageIO's host codecs (host/QtImageIO.cpp: Qt's TIFF plugin, libheif
// for HEIF), as an import reads them: the format recognized, the size and the pixels kept.

import CoreGraphics
import XCTest
import ImageIO
@testable import ImageIO

final class HeicTiffImportTests: XCTestCase {
    /// An opaque 64 x 32 gradient: wide, so a codec that swaps width and height shows it.
    private func gradient() -> CGImage {
        var buffer = PixelBuffer(width: 64, height: 32)
        for y in 0..<32 { for x in 0..<64 { buffer[x, y] = (UInt8(x * 4), UInt8(y * 8), 128, 255) } }
        return CGImage(buffer)
    }

    private func roundTrip(_ type: String) throws -> (type: String?, image: CGImage) {
        guard ImageCodecRegistry.host != nil || ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] != nil else {
            throw XCTSkip("no host image codecs (COMPOSITOR_IMAGEIO_BACKEND)")
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, gradient(), nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { throw XCTSkip("\(type): no encoder in this build") }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as Data as CFData, nil))
        return (CGImageSourceGetType(source) as String?, try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    private func assertGradient(_ image: CGImage, tolerance: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.width, 64, file: file, line: line)
        XCTAssertEqual(image.height, 32, file: file, line: line)
        let bytes = image.portableImage.bytes
        for (x, y) in [(0, 0), (63, 0), (0, 31), (40, 20), (63, 31)] {
            let o = (y * 64 + x) * 4
            XCTAssertEqual(Int(bytes[o]), x * 4, accuracy: tolerance, "red at \(x),\(y)", file: file, line: line)
            XCTAssertEqual(Int(bytes[o + 1]), y * 8, accuracy: tolerance, "green at \(x),\(y)", file: file, line: line)
            XCTAssertEqual(Int(bytes[o + 3]), 255, file: file, line: line)
        }
    }

    func testTIFFImportsLosslessly() throws {
        let (type, image) = try roundTrip("public.tiff")
        XCTAssertEqual(type, "public.tiff")
        assertGradient(image, tolerance: 0)
    }

    func testHEICImportsUprightAtItsSize() throws {
        let (type, image) = try roundTrip("public.heic")
        XCTAssertEqual(type, "public.heic")
        // HEVC is lossy even at its best quality: the colors land close, the geometry exactly.
        assertGradient(image, tolerance: 12)
    }
}
