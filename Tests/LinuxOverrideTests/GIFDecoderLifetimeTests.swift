import Foundation
import XCTest
import CoreGraphics
import ImageIO
import Glibc
@testable import Compositor

final class GIFDecoderLifetimeTests: XCTestCase {
    func testSequentialFrameReadsReuseTheSourceAndReleaseIt() throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"])
        let library = try XCTUnwrap(dlopen(path, RTLD_NOW | RTLD_LOCAL))
        defer { dlclose(library) }
        typealias Reads = @convention(c) (UnsafeMutableRawPointer?) -> UInt64
        let reads = unsafeBitCast(try XCTUnwrap(dlsym(library, "compositor_qt_imageio_animation_reads")), to: Reads.self)
        for count in [128, 256] {
            let sink = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(sink, "com.compuserve.gif", count, nil))
            let image = CGImage(PortableImage(width: 1, height: 1, kind: .rgba, bytesPerRow: 4, bytes: [255, 0, 0, 255]))
            for _ in 0..<count { CGImageDestinationAddImage(destination, image, nil) }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            var source: GIFSource? = try GIFDecoder.source(sink as Data, name: "Scaling")
            // Upstream owns the lazy reader now; observe its lifetime through the serialized accessor.
            weak var reader: CGImageSource?
            try XCTUnwrap(source).withReader { reader = $0 }
            let before = reads(nil)
            for index in 0..<count {
                let animation = GIFAnimation(source: try XCTUnwrap(source))
                let decoded = try GIFDecoder.frame(animation, index: index, name: "Scaling")
                XCTAssertEqual(decoded.image.width, 1)
            }
            XCTAssertEqual(reads(nil) - before, UInt64(count))
            source = nil
            XCTAssertNil(reader)
        }
    }
}
