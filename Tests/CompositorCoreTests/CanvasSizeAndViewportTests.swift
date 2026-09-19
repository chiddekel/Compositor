// Tests for the portable ports of CanvasSize.swift and CanvasViewport.swift. These
// pin the unchanged macOS logic so the port is proven equivalent on Linux. Run
// in-sandbox: swift test (under swift6//25.08).

import XCTest
@testable import CompositorCore

final class CanvasSizeTests: XCTestCase {

    func testPixelsUnitRoundTrip() {
        var draft = CanvasSizeDraft(width: 100, height: 200, resolution: 72)
        draft.unit = .pixels
        draft.set(150, widthAxis: true)
        XCTAssertEqual(draft.width, 150)
        XCTAssertEqual(draft.displayed(widthAxis: true), 150)
    }

    func testPercentUnit() {
        var draft = CanvasSizeDraft(width: 100, height: 200, resolution: 72)
        draft.unit = .percent
        draft.set(50, widthAxis: true)  // 50% of 100 -> 50 px
        XCTAssertEqual(draft.width, 50, accuracy: 1e-9)
        XCTAssertEqual(draft.displayed(widthAxis: true), 50, accuracy: 1e-9)
    }

    func testInchesUnit() {
        var draft = CanvasSizeDraft(width: 100, height: 200, resolution: 72)
        draft.unit = .inches
        draft.set(2, widthAxis: true)  // 2 in * 72 dpi = 144 px
        XCTAssertEqual(draft.width, 144, accuracy: 1e-9)
        XCTAssertEqual(draft.displayed(widthAxis: true), 2, accuracy: 1e-9)
    }

    func testLockedAspectKeepsRatio() {
        var draft = CanvasSizeDraft(width: 100, height: 200, resolution: 72)
        draft.locked = true
        draft.set(150, widthAxis: true)
        XCTAssertEqual(draft.width, 150, accuracy: 1e-9)
        // height follows the original 200/100 ratio.
        XCTAssertEqual(draft.height, 300, accuracy: 1e-9)
    }

    func testAnchorOffsetPutsExtraPixelRightAndBottom() {
        // anchor 4 is center (row-major 0..8): extra split evenly via floor.
        let opts = CanvasSizeOptions(width: 110, height: 220, anchor: 4)
        let offset = opts.offset(fromWidth: 100, height: 200)
        XCTAssertEqual(offset.x, 5)   // floor((110-100)*1/2) = 5
        XCTAssertEqual(offset.y, 10)  // floor((220-200)*1/2) = 10
    }

    func testExplicitContentOffsetOverridesAnchor() {
        let opts = CanvasSizeOptions(width: 110, height: 220, anchor: 4,
                                     contentOffset: CGPoint(x: -3, y: 7))
        XCTAssertEqual(opts.offset(fromWidth: 100, height: 200), CGPoint(x: -3, y: 7))
    }

    func testValidityBounds() {
        var draft = CanvasSizeDraft(width: 100, height: 200, resolution: 72)
        XCTAssertTrue(draft.valid)
        draft.width = 0
        XCTAssertFalse(draft.valid)
        draft.width = 100; draft.height = 40_000
        XCTAssertFalse(draft.valid)
    }
}

final class CanvasViewportTests: XCTestCase {

    private func sizedViewport(view: CGSize, document: CGSize, backingScale: CGFloat = 1) -> CanvasViewport {
        var vp = CanvasViewport()
        vp.resize(to: view, backingScale: backingScale, documentSize: document)
        return vp
    }

    func testFitZoomScalesDocumentIntoView() {
        var vp = CanvasViewport()
        vp.resize(to: CGSize(width: 200, height: 200), backingScale: 1, documentSize: CGSize(width: 400, height: 400))
        // 200-96 = 104 px of room; fit zoom = 104/400 = 0.26.
        XCTAssertEqual(vp.zoom, 0.26, accuracy: 1e-9)
        XCTAssertTrue(vp.followsFit)
    }

    func testZoomAnchorPreservesDocumentPoint() {
        var vp = CanvasViewport()
        vp.resize(to: CGSize(width: 500, height: 500), backingScale: 1, documentSize: CGSize(width: 100, height: 100))
        let anchor = CGPoint(x: 250, y: 250)
        let before = vp.documentPoint(from: anchor, documentSize: CGSize(width: 100, height: 100))
        vp.setZoom(2.0, anchoredAt: anchor, documentSize: CGSize(width: 100, height: 100))
        let after = vp.documentPoint(from: anchor, documentSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(after.x, before.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
    }

    func testDocumentRectAndPointRoundTrip() {
        var vp = CanvasViewport()
        vp.resize(to: CGSize(width: 400, height: 400), backingScale: 1, documentSize: CGSize(width: 100, height: 100))
        let p = CGPoint(x: 25, y: 30)
        let view = vp.viewPoint(from: p, documentSize: CGSize(width: 100, height: 100))
        let back = vp.documentPoint(from: view, documentSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
    }

    func testZoomClampedToRange() {
        var vp = CanvasViewport()
        vp.resize(to: CGSize(width: 400, height: 400), backingScale: 1, documentSize: CGSize(width: 100, height: 100))
        vp.setZoom(1000, anchoredAt: CGPoint(x: 200, y: 200), documentSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(vp.zoom, CanvasViewport.zoomRange.upperBound, accuracy: 1e-9)
    }
}