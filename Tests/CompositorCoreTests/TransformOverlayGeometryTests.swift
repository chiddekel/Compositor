// TransformOverlayGeometryTests — portable port of Compositor/Rendering/
// TransformOverlay.swift's `TransformOverlayGeometry` (file-map tier: "Keep
// logic; replace Apple operations"). The macOS original is an NSView subclass
// whose `draw` is view paint; the portable slice is the handle geometry +
// `hit(_:)` point test the Qt overlay needs. Everything exercised here is pure
// CGPoint/LayerTransform/CanvasViewport geometry, matching the macOS math
// exactly (hit radius 10, rotation handle offset 28, corner/edge-midpoint order).

import XCTest
@testable import CompositorCore

final class TransformOverlayGeometryTests: XCTestCase {

    private let document = CGSize(width: 100, height: 80)

    private func viewport(at zoom: CGFloat, pan: CGSize = .zero) -> CanvasViewport {
        var viewport = CanvasViewport()
        viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 1, documentSize: document)
        viewport.setZoom(zoom, anchoredAt: .zero, documentSize: document)
        viewport.pan = pan
        return viewport
    }

    /// handle[i] in view space equals the layer handle[i] carried to view space.
    private func viewHandles(_ transform: LayerTransform, _ viewport: CanvasViewport) -> [CGPoint] {
        LayerTransform.handles.map { viewport.viewPoint(from: transform.point($0), documentSize: document) }
    }

    func testTransformHandlesFollowLayerCorners() {
        let transform = LayerTransform(origin: CGPoint(x: 10, y: 12), size: CGSize(width: 30, height: 20))
        let viewport = viewport(at: 1)
        let overlay = TransformOverlayGeometry(transform: transform, viewport: viewport, documentSize: document)
        XCTAssertTrue(overlay.showsRotation)
        XCTAssertEqual(overlay.handles.count, 8)
        XCTAssertEqual(overlay.handles, viewHandles(transform, viewport))
        // Top edge midpoint: handle[1] = half way between top corners.
        XCTAssertEqual(overlay.handles[1],
                       CGPoint(x: (overlay.handles[0].x + overlay.handles[2].x) / 2,
                               y: (overlay.handles[0].y + overlay.handles[2].y) / 2))
    }

    func testHitFindsCornerAndEdgeAndRotation() {
        // Large enough that corner handles are the unique nearest hit (midpoints are >= 10px away).
        let transform = LayerTransform(origin: CGPoint(x: 10, y: 12), size: CGSize(width: 120, height: 80))
        let viewport = viewport(at: 1)
        let overlay = TransformOverlayGeometry(transform: transform, viewport: viewport, documentSize: document)
        XCTAssertEqual(overlay.hit(overlay.handles[0]), .resize(0))
        XCTAssertEqual(overlay.hit(overlay.handles[4]), .resize(4))
        XCTAssertEqual(overlay.hit(overlay.rotationHandle), .rotate)
        XCTAssertEqual(overlay.hit(overlay.handles[1]), .resize(1))
        // A point on the top edge between its two corners hits the edge midpoint too.
        let mid = CGPoint(x: (overlay.handles[0].x + overlay.handles[2].x) / 2,
                          y: (overlay.handles[0].y + overlay.handles[2].y) / 2)
        XCTAssertEqual(overlay.hit(mid), .resize(1))
        // Midpoints of the right edge hit their resize handle, not the corner.
        let rightMid = CGPoint(x: (overlay.handles[2].x + overlay.handles[4].x) / 2,
                               y: (overlay.handles[2].y + overlay.handles[4].y) / 2)
        XCTAssertEqual(overlay.hit(rightMid), .resize(3))
        // Far away: no hit.
        XCTAssertNil(overlay.hit(CGPoint(x: 950, y: 700)))
    }

    func testRotationHandleSitsAboveTopEdge() {
        let transform = LayerTransform(origin: CGPoint(x: 10, y: 12), size: CGSize(width: 30, height: 20))
        let overlay = TransformOverlayGeometry(transform: transform, viewport: viewport(at: 1), documentSize: document)
        // Offset 28 outward from the top-right corner's direction of travel.
        let expected = CGPoint(x: overlay.handles[1].x + sin(transform.radians) * 28,
                               y: overlay.handles[1].y - cos(transform.radians) * 28)
        XCTAssertEqual(overlay.rotationHandle, expected)
    }

    func testDistortionHandlesHideRotation() {
        let corners = [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 15), CGPoint(x: 45, y: 50), CGPoint(x: 8, y: 45)]
        let viewport = viewport(at: 1)
        let overlay = TransformOverlayGeometry(corners: corners, viewport: viewport, documentSize: document)
        XCTAssertFalse(overlay.showsRotation)
        XCTAssertEqual(overlay.handles.count, 8)
        // Corner handles are the corners carried to view space; the midpoints lie between.
        XCTAssertEqual(overlay.handles[0], viewport.viewPoint(from: corners[0], documentSize: document))
        XCTAssertEqual(overlay.handles[2], viewport.viewPoint(from: corners[1], documentSize: document))
        XCTAssertEqual(overlay.handles[4], viewport.viewPoint(from: corners[2], documentSize: document))
        XCTAssertEqual(overlay.handles[6], viewport.viewPoint(from: corners[3], documentSize: document))
        XCTAssertEqual(overlay.handles[1],
                       CGPoint(x: (overlay.handles[0].x + overlay.handles[2].x) / 2,
                               y: (overlay.handles[0].y + overlay.handles[2].y) / 2))
        // Handle hits, including the hidden rotation position behaving as midpoint.
        XCTAssertEqual(overlay.hit(overlay.handles[1]), .resize(1))
        XCTAssertNil(overlay.hit(CGPoint(x: 900, y: 30)))
    }

    func testPanAndZoomMoveHandles() {
        let transform = LayerTransform(origin: CGPoint(x: 10, y: 12), size: CGSize(width: 30, height: 20))
        let zoomed = TransformOverlayGeometry(transform: transform, viewport: viewport(at: 2, pan: CGSize(width: 15, height: -8)), documentSize: document)
        let base = TransformOverlayGeometry(transform: transform, viewport: viewport(at: 1), documentSize: document)
        // The distance between two handles is zoom-independent of the pan/origin: a 2x
        // viewport doubles the gap between the same two document corners.
        func spread(_ h: [CGPoint]) -> CGSize {
            CGSize(width: h[4].x - h[0].x, height: h[4].y - h[0].y)
        }
        let s2 = spread(zoomed.handles), s1 = spread(base.handles)
        XCTAssertEqual(s2.width, s1.width * 2, accuracy: 0.000001)
        XCTAssertEqual(s2.height, s1.height * 2, accuracy: 0.000001)
    }
}