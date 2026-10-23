// CGImage.prefetch: a raster a data provider supplies lazily (a committed brush stroke's RasterSnapshot) is resolved on
// a background queue, once, so the first draw that needs it doesn't pay for it.

import CoreGraphics
import Foundation
import XCTest

final class ImagePrefetchTests: XCTestCase {
    private final class Source {
        let lock = NSLock()
        var reads = 0
        var threads: [Bool] = []   // whether each read ran on the main thread
        var pixels: [UInt8]
        init(width: Int, height: Int) {
            pixels = (0..<(width * height * 4)).map { UInt8($0 % 251) }
        }
    }

    private func lazyImage(_ source: Source, width: Int, height: Int) -> CGImage? {
        let info = Unmanaged.passRetained(source).toOpaque()
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: { info in
            let source = Unmanaged<Source>.fromOpaque(info!).takeUnretainedValue()
            source.lock.lock(); source.reads += 1; source.threads.append(Thread.isMainThread); source.lock.unlock()
            return source.pixels.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!) }
        }, releaseBytePointer: { _, _ in }, getBytesAtPosition: nil, releaseInfo: { info in
            if let info { Unmanaged<Source>.fromOpaque(info).release() }
        })
        guard let provider = CGDataProvider(directInfo: info, size: off_t(width * height * 4), callbacks: &callbacks) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func waitForReads(_ source: Source, atLeast count: Int) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            source.lock.lock(); let reads = source.reads; source.lock.unlock()
            if reads >= count { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func testPrefetchResolvesALazyRasterOffTheMainThreadOnce() throws {
        let source = Source(width: 64, height: 48)
        let image = try XCTUnwrap(lazyImage(source, width: 64, height: 48))
        XCTAssertEqual(source.reads, 0, "the provider is read only when the pixels are needed")
        image.prefetch()
        image.prefetch()   // a second request while the first is under way or done adds nothing
        waitForReads(source, atLeast: 1)
        XCTAssertEqual(image.nativeImage.bytes, source.pixels)
        Thread.sleep(forTimeInterval: 0.05)
        source.lock.lock(); defer { source.lock.unlock() }
        XCTAssertEqual(source.reads, 1, "the draw found the prefetched pixels")
        XCTAssertEqual(source.threads, [false], "resolved on a background queue")
    }

    func testPrefetchLeavesResolvedAndFilterImagesAlone() {
        let resolved = CGImage(PortableImage(PixelBuffer(width: 4, height: 4)))
        resolved.prefetch()
        XCTAssertEqual(resolved.nativeImage.width, 4)

        let lock = NSLock()
        var regionCalls = 0
        let filtered = CGImage(width: 32, height: 32, isGray: false) { rect in
            lock.lock(); regionCalls += 1; lock.unlock()
            return PortableImage(PixelBuffer(width: Int(rect.width), height: Int(rect.height)))
        }
        filtered.prefetch()
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(regionCalls, 0, "a filter result renders only the regions drawn, never the whole image up front")
    }
}
