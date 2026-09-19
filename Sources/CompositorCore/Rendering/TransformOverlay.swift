// Portable port of Compositor/Rendering/TransformOverlay.swift's
// `TransformOverlayGeometry` (file-map tier: "Keep logic; replace Apple
// operations"). Ported verbatim: the 8 transform handles on a layer's bounding
// box, the rotation handle offset, the distortion's corner/edge handles, and
// `hit(_:)` — the resize/rotate "what did I grab" test the Qt overlay uses.
// Pure `CGPoint`/`LayerTransform`/`CanvasViewport`/`TransformDrag.Mode` geometry.
//
// Omitted (Qt milestone):
//   - `resizeCursor(for:)` — returns an `NSCursor`; the Qt host supplies its own
//     cursor art from the same `TransformDrag.Mode`.
//   - The `OverlayView` (NSView drawing, snap guides, selection dash, transform
//     handles, gradient line, crop rect) — Qt widgets.
//
// SOLID: the geometry keeps its responsibilities and contracts (handle placement,
// hit boundaries); the Apple API surface (NSCursor, NSView) is exchanged. The
// macOS original stays the source of truth — including its two `init`s, which map
// to the two transform styles (free transform vs distortion).

import Foundation

struct TransformOverlayGeometry: Equatable {
    let handles: [CGPoint]
    let rotationHandle: CGPoint
    /// A distortion has no single rotation, so its rotation handle is hidden.
    let showsRotation: Bool

    init(transform: LayerTransform, viewport: CanvasViewport, documentSize: CGSize) {
        handles = LayerTransform.handles.map { viewport.viewPoint(from: transform.point($0), documentSize: documentSize) }
        rotationHandle = CGPoint(x: handles[1].x + sin(transform.radians) * 28,
                                 y: handles[1].y - cos(transform.radians) * 28)
        showsRotation = true
    }

    /// Handles for a distortion: its four corners (document pixels) and the midpoints of its edges.
    init(corners: [CGPoint], viewport: CanvasViewport, documentSize: CGSize) {
        let view = corners.map { viewport.viewPoint(from: $0, documentSize: documentSize) }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        handles = [view[0], middle(view[0], view[1]), view[1], middle(view[1], view[2]),
                   view[2], middle(view[2], view[3]), view[3], middle(view[3], view[0])]
        rotationHandle = handles[1]
        showsRotation = false
    }

    func hit(_ point: CGPoint) -> TransformDrag.Mode? {
        func near(_ other: CGPoint) -> Bool { hypot(point.x - other.x, point.y - other.y) <= 10 }
        if showsRotation, near(rotationHandle) { return .rotate }
        if let index = handles.firstIndex(where: near) { return .resize(index) }
        for (start, end, handle) in [(0, 2, 1), (2, 4, 3), (4, 6, 5), (6, 0, 7)] {
            let a = handles[start], b = handles[end]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }
            let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
            if (0...1).contains(t), hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= 10 {
                return .resize(handle)
            }
        }
        return nil
    }
}