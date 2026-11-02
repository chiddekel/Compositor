import XCTest
import CoreGraphics
@testable import ImageIO

final class AnimatedGIFCodecTests: XCTestCase {
    private func image(_ bytes: [UInt8]) -> CGImage {
        CGImage(PortableImage(width: 2, height: 1, kind: .rgba, bytesPerRow: 8, bytes: bytes))
    }

    func testFramesKeepTimingTransparencyAndOpaqueBlack() throws {
        let sink = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(sink, "com.compuserve.gif", 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]])
        let frames = [image([255, 0, 0, 255, 0, 0, 0, 255]), image([0, 0, 255, 255, 0, 0, 0, 0])]
        for (index, frame) in frames.enumerated() {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: index == 0 ? 0.04 : 0.16]])
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertFalse(CGImageDestinationFinalize(destination))
        let metadata = try XCTUnwrap(GIFMetadata(sink as Data))
        XCTAssertEqual(metadata.delays, [0.04, 0.16])
        XCTAssertEqual(metadata.loopCount, 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(sink as Data, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let second = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 1, nil))
        XCTAssertEqual(first.portableImage.bytes, [255, 0, 0, 255, 0, 0, 0, 255])
        XCTAssertEqual(second.portableImage.bytes, [0, 0, 255, 255, 0, 0, 0, 0])
        XCTAssertNil(CGImageSourceCreateImageAtIndex(source, 2, nil))
    }

    func testTruncatedBlocksAreRejectedAndIncompleteDestinationsFail() throws {
        let encoded = try XCTUnwrap(PortableGIFEncoder().encodeFrames([(image([0, 0, 0, 255, 0, 0, 0, 0]), 0.1)], loopCount: nil))
        for length in 0..<encoded.count { XCTAssertNil(GIFMetadata(encoded.prefix(length))) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(NSMutableData(), "com.compuserve.gif", 2, nil))
        CGImageDestinationAddImage(destination, image([0, 0, 0, 255, 0, 0, 0, 0]), nil)
        XCTAssertFalse(CGImageDestinationFinalize(destination))
    }
}
