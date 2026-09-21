// Portable port of Compositor/Document/Selection.swift (file-map tier: "Apple
// replacement/adaptation: Keep selection math; replace graphics types/paths as
// needed"). The macOS `DocumentSelection`/`SelectionClip` carry a `CGPath` and a
// `CGImage` coverage. On Linux, `CGPath` is exchanged for `PortablePath` (an enum
// covering the outline kinds the selection tools produce) and `CGImage` coverage
// for `MaskBuffer?`. The selection math (`isEmpty`, the region `clip(canvas:)`
// computes, `DragBox.rect`, the modes) is ported verbatim; the *rasterization* of
// a path into coverage is the Skia/CPU raster milestone.
//
// Ported: `PortablePath`, `DocumentSelection` (path + antialiased + isEmpty +
// boundingBox + clip(canvas:)), `SelectionClip` (rect + coverage storage), the
// pure enums `LassoKind`/`SelectionMode`, and `DragBox.rect`.
//
// Omitted (raster milestone): `DocumentSelection.coverage(width:height:)` and
// `SelectionClip.apply(to:)` — both fill/clip a CGContext from the path. The
// `EditorSession` selection helpers are SwiftUI-bound (model milestone).
//
// SOLID: the value types keep their responsibilities and contracts; the Apple API
// surface (CGPath/CGImage/CGContext) is exchanged. The macOS original stays the
// source of truth.

import Foundation

/// A document-space selection outline, portable. The macOS original used `CGPath`
/// for arbitrary freehand outlines; this enum covers the outline kinds the
/// selection tools actually produce (rectangle, ellipse, rounded rectangle,
/// freehand polygon). Boolean selection ops are built on top of this by the
/// raster milestone; the geometry each kind covers is carried verbatim.
nonisolated enum PortablePath: Equatable, @unchecked Sendable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case roundedRect(CGRect, cornerRadius: CGFloat)
    case polygon([CGPoint])
    /// Several closed loops filled even-odd, so separate regions stay separate and holes stay holes.
    case contours([[CGPoint]])

    /// The path's bounding box in document pixels.
    var boundingBox: CGRect {
        switch self {
        case .rectangle(let r), .ellipse(let r), .roundedRect(let r, _): return r
        case .polygon(let points):
            return PortablePath.bounds(of: points)
        case .contours(let loops):
            return PortablePath.bounds(of: loops.flatMap { $0 })
        }
    }

    var isEmpty: Bool {
        switch self {
        case .rectangle(let r), .ellipse(let r), .roundedRect(let r, _): return r.isNull || r.isEmpty
        case .polygon(let points): return points.isEmpty
        case .contours(let loops): return loops.allSatisfy { $0.isEmpty }
        }
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The path transformed by `transform`. Matches CoreGraphics `CGPath.copy(using:)`
    /// for the outline kinds the selection tools produce: the rect/ellipse/rounded-rect
    /// cases transform their bounding rect (a rotated rect becomes a polygon-bounded
    /// outline on macOS; here the rect is carried through `CGRect.applying`, which maps
    /// it to its axis-aligned bounding box — sufficient for the translation-only moves
    /// the pixel-move tool issues), and the polygon case transforms each vertex.
    func applying(_ transform: CGAffineTransform) -> PortablePath {
        switch self {
        case .rectangle(let r): return .rectangle(r.applying(transform))
        case .ellipse(let r): return .ellipse(r.applying(transform))
        case .roundedRect(let r, let radius): return .roundedRect(r.applying(transform), cornerRadius: radius)
        case .polygon(let points): return .polygon(points.map { $0.applying(transform) })
        case .contours(let loops): return .contours(loops.map { $0.map { $0.applying(transform) } })
        }
    }

    /// Matches `CGPath.copy(using:)`: returns the path transformed by `transform`.
    /// The inout transform is left unchanged — our enum paths don't adjust it the way
    /// some CGPath element types do.
    func copy(using transform: inout CGAffineTransform) -> PortablePath { applying(transform) }
}

/// A document-space selection outline, clipped to the canvas. `nil` on the document
/// means no selection; a selection whose path is empty is an explicit empty selection,
/// which later edits must treat as "touch nothing", never as "touch everything".
nonisolated struct DocumentSelection: Equatable, @unchecked Sendable {
    let path: PortablePath
    var antialiased = true
    var isEmpty: Bool { path.isEmpty || path.boundingBox.isNull || path.boundingBox.isEmpty }

    /// Coverage for just the selected region of the canvas, ready to clip edits.
    /// The region math is verbatim; the coverage rasterization (filling the path to
    /// a `MaskBuffer`) is the Skia/CPU raster milestone, so `coverage` is nil here.
    func clip(canvas size: CGSize) -> SelectionClip {
        let region = path.boundingBox.insetBy(dx: -1, dy: -1).integral
            .intersection(CGRect(origin: .zero, size: size))
        guard !isEmpty, !region.isNull, region.width >= 1, region.height >= 1 else { return SelectionClip(rect: .zero, coverage: nil) }
        return SelectionClip(rect: region, coverage: rasterized(in: region))
    }
    // macOS also rasterizes the path to grayscale coverage here; that is the Skia/CPU
    // raster milestone.
}

/// Selection coverage for one region of the document. Applied as a clip, soft edges
/// blend partially; with no coverage (an empty selection) it clips everything away.
nonisolated struct SelectionClip: @unchecked Sendable {
    let rect: CGRect
    let coverage: MaskBuffer?
    // macOS also applies this clip to a CGContext here; that is the Skia/CPU raster
    // milestone.
}

nonisolated enum LassoKind: String, CaseIterable, Sendable {
    case freehand = "Freehand"
    case polygonal = "Polygonal"
    /// The Marquee's outlines; not offered in the Lasso's Freehand/Polygonal choice.
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    static let lassoChoices: [LassoKind] = [.freehand, .polygonal]
    static let marqueeChoices: [LassoKind] = [.rectangle, .ellipse]
}

nonisolated enum SelectionMode: String, CaseIterable, Sendable {
    case replace = "New"
    case add = "Add"
    case subtract = "Subtract"
}

/// The box a drag from `anchor` to `point` spans, in whole pixels. `square` evens the sides;
/// `fromCenter` grows the box around the anchor. Shared by the Marquee and the Shape tool.
nonisolated enum DragBox {
    static func rect(from anchor: CGPoint, to point: CGPoint, square: Bool, fromCenter: Bool) -> CGRect {
        var dx = point.x.rounded() - anchor.x, dy = point.y.rounded() - anchor.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return fromCenter
            ? CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
            : CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
    }
}

/// A lasso outline being drawn, in document pixels. `cursor` is the polygonal lasso's
/// rubber-band end point.
struct LassoDraft: Equatable {
    var points: [CGPoint]
    var cursor: CGPoint?
    let mode: SelectionMode
    let kind: LassoKind
    /// The Rectangular Marquee's starting corner (or center), in whole pixels.
    var anchor: CGPoint?
}
