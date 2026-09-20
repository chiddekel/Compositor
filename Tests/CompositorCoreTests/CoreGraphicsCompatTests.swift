// Tests for the CoreGraphicsCompat CGContext shim (plan §3, §4). Verify the
// CG-shaped drawing surface routes through an injected render closure and
// falls back to the pure-Swift LayerRenderer when no device is registered.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class CoreGraphicsCompatTests: XCTestCase {

    private func makeRedImage(_ w: Int, _ h: Int) -> PortableImage {
        var buf = PixelBuffer(width: w, height: h)
        for y in 0..<h { for x in 0..<w { buf[x, y] = (255, 0, 0, 255) } }
        return PortableImage(buf)
    }

    func testDrawWithIdentityClosureCopiesPixels() {
        let img = makeRedImage(2, 2)
        let ctx = CGContextCompat(width: 2, height: 2) { src, dst, w, h in
            let n = w * h * 4
            for i in 0..<n { dst[i] = src[i] }
            return 0
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        let out = ctx.makeImage()
        XCTAssertEqual(out.bytes, img.bytes)
    }

    func testDrawFallsBackToSwiftWhenClosureReturnsNonZero() {
        let img = makeRedImage(2, 2)
        // Closure "fails" (device lost, plan §6); Swift fallback must draw red.
        let ctx = CGContextCompat(width: 2, height: 2) { _, _, _, _ in -2 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        let out = ctx.makeImage()
        for p in 0..<4 {
            let i = p * 4
            XCTAssertEqual(out.bytes[i], 255, "red channel at \(p)")
            XCTAssertEqual(out.bytes[i + 3], 255, "alpha at \(p)")
        }
    }

    func testDrawFallsBackToSwiftWithNoClosure() {
        let img = makeRedImage(1, 1)
        let ctx = CGContextCompat(width: 1, height: 1, render: nil)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let out = ctx.makeImage()
        XCTAssertEqual(out.bytes[0], 255)
        XCTAssertEqual(out.bytes[3], 255)
    }

    func testNonIdentityRectUsesSwiftFallback() {
        let img = makeRedImage(2, 2)
        // A capturing closure cannot be converted to a C function pointer, so
        // use a non-capturing "always fail" closure: if the Skia path ran it
        // would return 0 and the test would see copied bytes; the Swift
        // fallback draws a scaled red rect into the 4x4 context instead.
        let ctx = CGContextCompat(width: 4, height: 4) { _, _, _, _ in -1 }
        // Scaled rect -> not identity -> Swift path, closure must not run.
        ctx.draw(img, in: CGRect(x: 1, y: 1, width: 2, height: 2))
        let out = ctx.makeImage()
        // Swift fallback draws red into the placed rect; pixels at (1,1)
        // should be red, pixels at (0,0) should be transparent.
        let i00 = 0 * 4
        XCTAssertEqual(out.bytes[i00 + 3], 0, "corner alpha is transparent")
        // Inside the placed rect the Swift LayerRenderer drew red.
        let i11 = (1 * 4 + 1) * 4
        XCTAssertEqual(out.bytes[i11], 255, "red at (1,1)")
        XCTAssertEqual(out.bytes[i11 + 3], 255, "alpha at (1,1)")
    }
}