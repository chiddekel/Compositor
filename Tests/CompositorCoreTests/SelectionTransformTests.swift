// Tests for `PortablePath.applying(_:)` / `copy(using:)` and `PixelMove.movedSelection`.
// These cover the ported selection-transform geometry that the macOS original drew
// from `CGPath.copy(using:)`.

import XCTest
@testable import CompositorCore

final class SelectionTransformTests: XCTestCase {

    // MARK: PortablePath.applying / copy(using:)

    func testRectanglePathTranslatedByCopyUsing() {
        let path = PortablePath.rectangle(CGRect(x: 10, y: 20, width: 50, height: 30))
        var t = CGAffineTransform(translationX: 5, y: -7)
        let moved = path.copy(using: &t)
        // The inout transform is left unchanged.
        XCTAssertEqual(t.a, 1); XCTAssertEqual(t.tx, 5)
        if case .rectangle(let r) = moved {
            XCTAssertEqual(r.minX, 15, accuracy: 1e-6)
            XCTAssertEqual(r.minY, 13, accuracy: 1e-6)
            XCTAssertEqual(r.width, 50, accuracy: 1e-6)
            XCTAssertEqual(r.height, 30, accuracy: 1e-6)
        } else { XCTFail("expected rectangle") }
    }

    func testEllipsePathTranslated() {
        let path = PortablePath.ellipse(CGRect(x: 0, y: 0, width: 10, height: 10))
        let moved = path.applying(CGAffineTransform(translationX: 3, y: 4))
        if case .ellipse(let r) = moved {
            XCTAssertEqual(r.minX, 3, accuracy: 1e-6)
            XCTAssertEqual(r.minY, 4, accuracy: 1e-6)
        } else { XCTFail("expected ellipse") }
    }

    func testRoundedRectPathPreservesCornerRadius() {
        let path = PortablePath.roundedRect(CGRect(x: 0, y: 0, width: 20, height: 20), cornerRadius: 4)
        let moved = path.applying(CGAffineTransform(translationX: 1, y: 2))
        if case .roundedRect(let r, let radius) = moved {
            XCTAssertEqual(r.minX, 1, accuracy: 1e-6)
            XCTAssertEqual(r.minY, 2, accuracy: 1e-6)
            XCTAssertEqual(radius, 4, accuracy: 1e-6)
        } else { XCTFail("expected roundedRect") }
    }

    func testPolygonPathTransformsEachVertex() {
        let path = PortablePath.polygon([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)])
        let moved = path.applying(CGAffineTransform(translationX: 2, y: 3))
        if case .polygon(let points) = moved {
            XCTAssertEqual(points.count, 3)
            XCTAssertEqual(points[0].x, 2, accuracy: 1e-6)
            XCTAssertEqual(points[0].y, 3, accuracy: 1e-6)
            XCTAssertEqual(points[2].x, 12, accuracy: 1e-6)
            XCTAssertEqual(points[2].y, 13, accuracy: 1e-6)
        } else { XCTFail("expected polygon") }
    }

    func testPathIdentityTransformIsUnchanged() {
        let path = PortablePath.rectangle(CGRect(x: 1, y: 2, width: 3, height: 4))
        let moved = path.applying(CGAffineTransform.identity)
        XCTAssertEqual(moved, path)
    }

    // MARK: PixelMove.movedSelection

    func testPixelMoveMovedSelectionShiftsByOffset() throws {
        let layer = ImageLayer(name: "L", blankSize: CGSize(width: 64, height: 64))
        let raster = try BrushStroke(layer: layer, mask: false, settings: BrushSettings(), canvas: CGSize(width: 64, height: 64))
        let origin = DocumentSelection(path: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)))
        let move = PixelMove(raster: raster, origin: origin, duplicate: false)
        move.offset = CGSize(width: 5, height: -3)
        let moved = move.movedSelection
        if case .rectangle(let r) = moved.path {
            XCTAssertEqual(r.minX, 15, accuracy: 1e-6)
            XCTAssertEqual(r.minY, 7, accuracy: 1e-6)
            XCTAssertEqual(r.width, 20, accuracy: 1e-6)
            XCTAssertEqual(r.height, 20, accuracy: 1e-6)
        } else { XCTFail("expected rectangle") }
        // origin is untouched — movedSelection is a derived copy.
        if case .rectangle(let r) = origin.path {
            XCTAssertEqual(r.minX, 10)
        } else { XCTFail("origin changed shape") }
    }

    func testPixelMoveZeroOffsetReturnsOriginPath() throws {
        let layer = ImageLayer(name: "L", blankSize: CGSize(width: 64, height: 64))
        let raster = try BrushStroke(layer: layer, mask: false, settings: BrushSettings(), canvas: CGSize(width: 64, height: 64))
        let origin = DocumentSelection(path: .ellipse(CGRect(x: 4, y: 4, width: 8, height: 8)), antialiased: false)
        let move = PixelMove(raster: raster, origin: origin, duplicate: true)
        let moved = move.movedSelection
        XCTAssertEqual(moved.path, origin.path)
        XCTAssertEqual(moved.antialiased, false)
        XCTAssertEqual(move.duplicate, true)
    }
}