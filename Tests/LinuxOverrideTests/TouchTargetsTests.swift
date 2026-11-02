import Foundation
import Testing
@testable import Compositor

/// Finger-sized targets (TouchTargets): with a touchscreen driving the app, a transform handle takes the pointer from
/// further away than with a mouse, and goes back to the mouse's reach once a mouse is used again.
@MainActor
@Suite(.serialized) struct TouchTargetsTests {
    /// A 200 x 200 document's corners in view space run from (-100, -100) to (100, 100) at zoom 1.
    private let geometry = TransformOverlayGeometry(
        corners: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 200)],
        viewport: CanvasViewport(), documentSize: CGSize(width: 200, height: 200))
    /// 22 points left of the top-left corner: past a mouse's reach, within a finger's.
    private let nearCorner = CGPoint(x: -122, y: -100)

    @Test func aFingerReachesAHandleAMouseDoesNot() {
        defer { compositorSetTouchTargets(0) }
        compositorSetTouchTargets(0)
        #expect(geometry.hit(nearCorner) == nil)
        compositorSetTouchTargets(1)
        let grabbed: Bool = { if case .resize(0)? = geometry.hit(nearCorner) { return true }; return false }()
        #expect(grabbed)
        compositorSetTouchTargets(0)
        #expect(geometry.hit(nearCorner) == nil)
    }

    @Test func smallObjectsKeepADraggableInteriorAtActualPixels() {
        defer { compositorSetTouchTargets(0) }
        for touch in [Int32(0), Int32(1)] {
            compositorSetTouchTargets(touch)
            for size in [CGSize(width: 64, height: 32), CGSize(width: 32, height: 16)] {
                let transform = LayerTransform(origin: .zero, size: size)
                let geometries = [
                    TransformOverlayGeometry(transform: transform, viewport: CanvasViewport(), documentSize: size),
                    TransformOverlayGeometry(corners: [CGPoint.zero, CGPoint(x: size.width, y: 0),
                        CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)],
                        viewport: CanvasViewport(), documentSize: size)
                ]
                for geometry in geometries {
                    #expect(geometry.hit(.zero) == nil, "The center must move the object instead of grabbing an edge")
                    let topHandle = CGPoint(x: 0, y: -size.height / 2)
                    let resizes: Bool = { if case .resize(1)? = geometry.hit(topHandle) { return true }; return false }()
                    #expect(resizes, "The actual resize handle must remain usable")
                }
            }
        }
    }
}
