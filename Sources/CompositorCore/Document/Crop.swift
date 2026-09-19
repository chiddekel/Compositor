// Portable port of Compositor/Document/Crop.swift's geometry (file-map tier: "Keep
// logic; replace Apple operations"). Ported verbatim: `CropGeometry`, `CropDrag`,
// and `CropSnap` — the crop frame's snapping, validity, and drag math. These are
// pure CGRect/CGPoint/CGFloat and `LayerTransform`/`TransformDrag` geometry.
//
// Omitted (model + raster milestone): the `EditorSession` extension —
// `transformSnapTargets`/`snappedMove`/`cropSnapTargets` read the live document and
// `DistortWarp.corners(of:)` of every layer; `visibleCropRect`/`cropRatio`/
// `cancelCrop`/`changeCropRatio`/`commitCrop` drive `EditorSession` state and
// `CanvasResizer` (a CGContext resample). The portable geometry they rely on is
// here; the document/state wiring is the Qt-side controller milestone.
//
// SOLID: the value types keep their responsibilities and contracts (snapped/valid
// crop rectangles and a drag that updates them); the Apple API surface (EditorSession
// state, CanvasResizer raster) is exchanged. The macOS original stays the source of
// truth.

import Foundation

nonisolated enum CropGeometry {
    static func snapped(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized
        let x = rect.minX.rounded(), y = rect.minY.rounded()
        return CGRect(x: x, y: y, width: max(1, rect.maxX.rounded() - x), height: max(1, rect.maxY.rounded() - y))
    }
    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && (1...30_000).contains(rect.width) && (1...30_000).contains(rect.height)
            && abs(rect.minX) <= 1_000_000 && abs(rect.minY) <= 1_000_000
    }
    /// A frame dragged from `start` to `end` — or, `symmetric` (Option), grown out from `start` as its center.
    static func create(from start: CGPoint, to end: CGPoint, ratio: CGFloat?, symmetric: Bool = false) -> CGRect {
        var dx = end.x - start.x, dy = end.y - start.y
        if let ratio {
            if abs(dx) > abs(dy) * ratio { dy = (dy < 0 ? -1 : 1) * abs(dx) / ratio }
            else { dx = (dx < 0 ? -1 : 1) * abs(dy) * ratio }
        }
        if symmetric {
            return snapped(CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2))
        }
        return snapped(CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy)))
    }
}

struct CropDrag {
    enum Mode { case create, move, resize(Int) }
    let start: CGPoint
    let original: CGRect
    let mode: Mode
    /// `symmetric` (Option held) keeps the frame's center fixed: the opposite edges move with the dragged ones.
    func updated(to point: CGPoint, ratio: CGFloat?, symmetric: Bool = false) -> CGRect {
        switch mode {
        case .create: return CropGeometry.create(from: start, to: point, ratio: ratio, symmetric: symmetric)
        case .move: return CropGeometry.snapped(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y))
        case .resize(let index):
            let transform = LayerTransform(origin: original.origin, size: original.size)
            let drag = TransformDrag(original: transform, start: start, mode: .resize(index))
            let next = drag.updated(to: point, lockRatio: ratio != nil, shift: false, option: symmetric)
            return CropGeometry.snapped(CGRect(origin: next.origin, size: next.size))
        }
    }
}

/// Crop edges snap to nearby layer and canvas edges while dragging.
nonisolated struct CropSnap {
    /// Document x and y positions to snap to.
    let xs: [CGFloat]
    let ys: [CGFloat]
    /// How close, in document pixels, an edge must come to snap.
    let tolerance: CGFloat

    private func nearest(_ value: CGFloat, in targets: [CGFloat]) -> CGFloat? {
        var best: CGFloat?
        for target in targets where abs(target - value) <= tolerance {
            if let current = best, abs(current - value) <= abs(target - value) { continue }
            best = target
        }
        return best
    }

    /// Moving the frame snaps its closest edges and keeps its size; creating or resizing snaps only the
    /// edges on the side being dragged — mirrored about the center when `symmetric`. With a fixed ratio only
    /// moves snap, so the ratio stays exact.
    func apply(_ rect: CGRect, drag: CropDrag, point: CGPoint, ratio: CGFloat?, symmetric: Bool = false) -> CGRect {
        guard tolerance > 0 else { return rect }
        let horizontal: Bool, vertical: Bool
        switch drag.mode {
        case .move:
            func shift(_ edges: [CGFloat], _ targets: [CGFloat]) -> CGFloat {
                edges.compactMap { edge in nearest(edge, in: targets).map { $0 - edge } }.min { abs($0) < abs($1) } ?? 0
            }
            return rect.offsetBy(dx: shift([rect.minX, rect.maxX], xs), dy: shift([rect.minY, rect.maxY], ys))
        case .create:
            guard ratio == nil else { return rect }
            horizontal = true; vertical = true
        case .resize(let index):
            guard ratio == nil else { return rect }
            let handle = LayerTransform.handles[index]
            horizontal = handle.x != 0.5; vertical = handle.y != 0.5
        }
        var result = rect
        // The dragged edge is the one on the pointer's side.
        if horizontal {
            if abs(point.x - result.minX) <= abs(point.x - result.maxX) {
                if let x = nearest(result.minX, in: xs), x < result.maxX { result = CGRect(x: x, y: result.minY, width: result.maxX - x, height: result.height) }
            } else if let x = nearest(result.maxX, in: xs), x > result.minX { result.size.width = x - result.minX }
        }
        if vertical {
            if abs(point.y - result.minY) <= abs(point.y - result.maxY) {
                if let y = nearest(result.minY, in: ys), y < result.maxY { result = CGRect(x: result.minX, y: y, width: result.width, height: result.maxY - y) }
            } else if let y = nearest(result.maxY, in: ys), y > result.minY { result.size.height = y - result.minY }
        }
        if symmetric {
            // The snapped (dragged) edge sets the half size; the opposite edge mirrors it about the center.
            var center = CGPoint(x: drag.original.midX, y: drag.original.midY)
            if case .create = drag.mode { center = drag.start }
            if horizontal {
                let half = point.x >= center.x ? result.maxX - center.x : center.x - result.minX
                if half >= 0.5 { result.origin.x = center.x - half; result.size.width = half * 2 }
            }
            if vertical {
                let half = point.y >= center.y ? result.maxY - center.y : center.y - result.minY
                if half >= 0.5 { result.origin.y = center.y - half; result.size.height = half * 2 }
            }
        }
        return result
    }
}