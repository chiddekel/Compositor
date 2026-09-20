// Tests for the ported Clone Stamp geometry helpers
// (`cloneStrokeOffset` / `cloneSamplePoint`), freed from `EditorSession` state.

import XCTest
@testable import CompositorCore

final class CloneStampTests: XCTestCase {

    func testStrokeOffsetNilWithoutSource() {
        XCTAssertNil(cloneStrokeOffset(at: CGPoint(x: 5, y: 5), source: nil, offset: nil, settings: CloneSettings()))
    }

    func testStrokeOffsetUnalignedRunsFromBrushToSource() {
        var s = CloneSettings(); s.aligned = false
        let off = cloneStrokeOffset(at: CGPoint(x: 10, y: 20), source: CGPoint(x: 3, y: 7), offset: CGSize(width: 100, height: 100), settings: s)
        // Unaligned ignores any stored offset and recomputes from brush→source, rounded.
        XCTAssertEqual(off?.width, -7)
        XCTAssertEqual(off?.height, -13)
    }

    func testStrokeOffsetAlignedKeepsStoredOffset() {
        let s = CloneSettings()  // aligned = true
        let off = cloneStrokeOffset(at: CGPoint(x: 10, y: 20), source: CGPoint(x: 3, y: 7),
                                    offset: CGSize(width: 4, height: 5), settings: s)
        XCTAssertEqual(off?.width, 4)
        XCTAssertEqual(off?.height, 5)
    }

    func testStrokeOffsetAlignedFallsBackToBrushToSourceWhenNoStoredOffset() {
        let s = CloneSettings()
        let off = cloneStrokeOffset(at: CGPoint(x: 10.4, y: 20.6), source: CGPoint(x: 2, y: 5),
                                    offset: nil, settings: s)
        XCTAssertEqual(off?.width, -8)   // (2 - 10.4).rounded = -8
        XCTAssertEqual(off?.height, -16) // (5 - 20.6).rounded = -16
    }

    func testSamplePointNilWithoutSource() {
        XCTAssertNil(cloneSamplePoint(for: CGPoint(x: 1, y: 1), source: nil, offset: nil, settings: CloneSettings(), strokeActive: false))
    }

    func testSamplePointReturnsSourceWhenNoOffsetAndNoStroke() {
        let s = CloneSettings()
        let p = cloneSamplePoint(for: CGPoint(x: 10, y: 10), source: CGPoint(x: 3, y: 3), offset: nil, settings: s, strokeActive: false)
        XCTAssertEqual(p?.x, 3)
        XCTAssertEqual(p?.y, 3)
    }

    func testSamplePointUsesOffsetWhenAlignedOrStrokeActive() {
        let p = cloneSamplePoint(for: CGPoint(x: 10, y: 10), source: CGPoint(x: 0, y: 0),
                                 offset: CGSize(width: 4, height: 5), settings: CloneSettings(), strokeActive: false)
        XCTAssertEqual(p?.x, 14)
        XCTAssertEqual(p?.y, 15)
    }

    func testSamplePointUsesOffsetWhenUnalignedButStrokeActive() {
        var s = CloneSettings(); s.aligned = false
        let p = cloneSamplePoint(for: CGPoint(x: 10, y: 10), source: CGPoint(x: 0, y: 0),
                                 offset: CGSize(width: 4, height: 5), settings: s, strokeActive: true)
        XCTAssertEqual(p?.x, 14)
        XCTAssertEqual(p?.y, 15)
    }

    func testSamplePointIgnoresOffsetWhenUnalignedAndNoStroke() {
        var s = CloneSettings(); s.aligned = false
        let p = cloneSamplePoint(for: CGPoint(x: 10, y: 10), source: CGPoint(x: 3, y: 3),
                                 offset: CGSize(width: 4, height: 5), settings: s, strokeActive: false)
        // Unaligned with no active stroke shows the source itself, not the offset.
        XCTAssertEqual(p?.x, 3)
        XCTAssertEqual(p?.y, 3)
    }
}