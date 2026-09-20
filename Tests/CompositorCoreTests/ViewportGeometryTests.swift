// ViewportGeometryTests — portable port of CompositorTests/CompositorTests.swift
// (file-map test tier: "Keep assertions; port fixtures"). The macOS original uses
// Swift Testing + CoreGraphics; on Linux Foundation supplies CGPoint/CGSize/CGRect/
// CGFloat and the CanvasViewport geometry is already the portable port
// (Sources/CompositorCore/Rendering/CanvasViewport.swift). Assertions are kept
// verbatim; only the harness is XCTest instead of Swift Testing.
//
// 4 of the 5 original tests are portable. `limitsAndNewDocumentReset` is NOT
// portable here: it drives `session.viewport` / `session.zoom(to:)`, which are
// macOS UI-layer EditorSession extensions not present on the Linux core (the
// file-map "Rewrite Linux UI" tier owns them). The four below exercise pure
// viewport geometry with no AppKit/SwiftUI dependency.

import XCTest
@testable import CompositorCore

final class ViewportGeometryTests: XCTestCase {

    private let document = CGSize(width: 1920, height: 1080)

    func testDimensionValidation() {
        XCTAssertEqual(CanvasDocument.validDimension("0"), nil)
        XCTAssertEqual(CanvasDocument.validDimension("-1"), nil)
        XCTAssertEqual(CanvasDocument.validDimension("1.5"), nil)
        XCTAssertEqual(CanvasDocument.validDimension("30001"), nil)
        XCTAssertEqual(CanvasDocument.validDimension("9999999999999999999999"), nil)
        XCTAssertEqual(CanvasDocument.validDimension(" 1920 "), 1920)
        XCTAssertEqual(CanvasDocument.validDimension("30000"), 30000)
    }

    /// macOS `actualPixelsAndRoundTrip(backing:)` parameterized over [1, 2].
    func testActualPixelsAndRoundTrip() {
        for backing in [CGFloat(1), CGFloat(2)] {
            var viewport = CanvasViewport()
            viewport.resize(to: CGSize(width: 800, height: 600), backingScale: backing, documentSize: nil)
            for zoom in [CGFloat(0.25), 1, 3.75] {
                viewport.setZoom(zoom, anchoredAt: viewport.center, documentSize: document)
                viewport.translate(by: CGSize(width: 73.5, height: -44.25))
                let pixel = CGPoint(x: 183.25, y: 837.5)
                let viewPoint = viewport.viewPoint(from: pixel, documentSize: document)
                let result = viewport.documentPoint(from: viewPoint, documentSize: document)
                XCTAssertEqual(result.x, pixel.x, accuracy: 0.000001)
                XCTAssertEqual(result.y, pixel.y, accuracy: 0.000001)
                XCTAssertEqual(viewport.documentRect(document).width * backing,
                              document.width * zoom, accuracy: 0.000001)
            }
        }
    }

    func testZoomKeepsCursorPixelFixed() {
        var viewport = CanvasViewport()
        viewport.resize(to: CGSize(width: 1000, height: 700), backingScale: 2, documentSize: document)
        let anchor = CGPoint(x: 157, y: 221)
        let before = viewport.documentPoint(from: anchor, documentSize: document)
        viewport.setZoom(4, anchoredAt: anchor, documentSize: document)
        let after = viewport.documentPoint(from: anchor, documentSize: document)
        XCTAssertEqual(before.x, after.x, accuracy: 0.000001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.000001)
    }

    func testFitAndResizeModes() {
        var viewport = CanvasViewport()
        viewport.resize(to: CGSize(width: 800, height: 600), backingScale: 2, documentSize: document)
        let rect = viewport.documentRect(document)
        XCTAssertLessThanOrEqual(rect.width, 704.000001)
        XCTAssertLessThanOrEqual(rect.height, 504.000001)
        XCTAssertEqual(rect.midX, 400)
        XCTAssertEqual(rect.midY, 300)
        viewport.translate(by: CGSize(width: 60, height: -35))
        let before = viewport.documentPoint(from: viewport.center, documentSize: document)
        let zoom = viewport.zoom
        viewport.resize(to: CGSize(width: 1200, height: 800), backingScale: 1, documentSize: document)
        let after = viewport.documentPoint(from: viewport.center, documentSize: document)
        XCTAssertEqual(viewport.zoom, zoom)
        XCTAssertEqual(before.x, after.x, accuracy: 0.000001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.000001)
        viewport.fit(documentSize: document)
        XCTAssertEqual(viewport.pan, CGSize.zero)
        XCTAssertTrue(viewport.followsFit)
    }
}