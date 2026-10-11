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
}
