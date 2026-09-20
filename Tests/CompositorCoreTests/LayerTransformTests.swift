// Tests for the portable LayerTransform math, TransformDrag, TransformSnap, and
// the pure BrushRaster math. Pin the unchanged macOS transform logic on Linux.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class LayerTransformTests: XCTestCase {

    private func transform(origin: CGPoint = .zero, size: CGSize = CGSize(width: 10, height: 10),
                           rotation: CGFloat = 0, flipX: Bool = false, flipY: Bool = false) -> LayerTransform {
        var t = LayerTransform(origin: origin, size: size)
        t.rotation = rotation
        t.flipX = flipX
        t.flipY = flipY
        return t
    }

    func testPointMapsUnitCorners() {
        let t = transform(origin: CGPoint(x: 100, y: 100), size: CGSize(width: 10, height: 10))
        // unit (0,0) -> top-left corner, (1,1) -> bottom-right, (0.5,0.5) -> center.
        XCTAssertEqual(t.point(CGPoint(x: 0, y: 0)), CGPoint(x: 100, y: 100))
        XCTAssertEqual(t.point(CGPoint(x: 1, y: 1)), CGPoint(x: 110, y: 110))
        XCTAssertEqual(t.point(CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 105, y: 105))
    }

    func testContainsAxisAligned() {
        let t = transform(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 10, height: 10))
        XCTAssertTrue(t.contains(CGPoint(x: 5, y: 5)))
        XCTAssertFalse(t.contains(CGPoint(x: 20, y: 20)))
    }

    func testRoundedSnapsWholePixelsAndDegrees() {
        var t = transform(origin: CGPoint(x: 1.4, y: 2.6), size: CGSize(width: 10.3, height: 9.7))
        t.rotation = 45.6
        let r = t.rounded()
        XCTAssertEqual(r.origin, CGPoint(x: 1, y: 3))
        XCTAssertEqual(r.size, CGSize(width: 10, height: 10))
        XCTAssertEqual(r.rotation, 46)
    }

    func testScaledToPercentKeepsCenter() {
        let t = transform(origin: CGPoint(x: 100, y: 100), size: CGSize(width: 10, height: 10))
        let s = t.scaled(toPercent: 200, pixelSize: CGSize(width: 10, height: 10))
        XCTAssertEqual(s.size, CGSize(width: 20, height: 20))
        XCTAssertEqual(s.center, t.center)
    }

    func testFollowingPlainMoveCarriesOrigin() {
        let old = transform(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 10, height: 10))
        let new = transform(origin: CGPoint(x: 5, y: 7), size: CGSize(width: 10, height: 10))
        let self_t = transform(origin: CGPoint(x: 100, y: 100), size: CGSize(width: 10, height: 10))
        let carried = self_t.following(from: old, to: new)
        XCTAssertEqual(carried.origin, CGPoint(x: 105, y: 107))
    }

    func testIsValidBounds() {
        XCTAssertTrue(transform().isValid)
        var t = transform(size: CGSize(width: 0, height: 10))
        XCTAssertFalse(t.isValid)
    }

    func testTransformDragMove() {
        let original = transform(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 10, height: 10))
        let drag = TransformDrag(original: original, start: CGPoint(x: 0, y: 0), mode: .move)
        let next = drag.updated(to: CGPoint(x: 3, y: 4), lockRatio: false, shift: false)
        XCTAssertEqual(next.origin, CGPoint(x: 3, y: 4))
    }

    func testTransformSnapOffsetPicksNearestTarget() {
        let box = CGRect(x: 0, y: 0, width: 10, height: 10)
        let result = TransformSnap.offset(for: box, xs: [12], ys: [], tolerance: 5)
        XCTAssertEqual(result.offset.width, 2)  // move minX 0 -> 2 to reach target 12 at center? min(2..)
        XCTAssertNotNil(result.x)
    }

    func testBrushRasterFalloffEndpoints() {
        XCTAssertEqual(BrushRaster.falloff(0), 1, accuracy: 1e-9)
        XCTAssertEqual(BrushRaster.falloff(1), 0, accuracy: 1e-9)
        // Mid-range is between 0 and 1 and monotonic-ish (positive).
        let mid = BrushRaster.falloff(0.5)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, 1)
    }

    func testBrushRasterPixelToDocumentIdentityAtCenter() {
        // A 1x1 layer placed at origin/size (0,0,1,1), no rotation/flip: maps the
        // unit square's center (0.5,0.5) back to the layer center.
        var t = LayerTransform(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 1, height: 1))
        t.flipX = false; t.flipY = false; t.rotation = 0
        let m = BrushRaster.pixelToDocument(t, width: 1, height: 1)
        let mapped = CGPoint(x: 0.5, y: 0.5).applying(m)
        XCTAssertEqual(mapped.x, t.center.x, accuracy: 1e-9)
        XCTAssertEqual(mapped.y, t.center.y, accuracy: 1e-9)
    }
}