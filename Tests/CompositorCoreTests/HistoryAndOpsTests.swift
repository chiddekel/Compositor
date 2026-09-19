// Tests for the portable LayerTransform.mirrored, CloneSettings, GradientSettings,
// and DocumentHistory (undo/redo/trim). Pin the unchanged macOS logic on Linux.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class HistoryAndOpsTests: XCTestCase {

    // MARK: LayerTransform.mirrored

    func testMirroredHorizontalFlipsXAndOriginAcrossAxis() {
        let t = LayerTransform(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 10, height: 10))
        let m = t.mirrored(horizontally: true, across: 100)
        XCTAssertTrue(m.flipX != t.flipX)
        // origin.x = 2*axis - center.x - size.width/2 = 200 - 5 - 5 = 190
        XCTAssertEqual(m.origin.x, 190, accuracy: 1e-9)
        XCTAssertEqual(m.origin.y, 0)
        XCTAssertEqual(m.rotation, -0)
    }

    func testMirroredVerticalNegatesRotation() {
        var t = LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4))
        t.rotation = 30
        let m = t.mirrored(horizontally: false, across: 10)
        XCTAssertEqual(m.rotation, -30)
        XCTAssertTrue(m.flipY != t.flipY)
    }

    // MARK: CloneSettings

    func testCloneSettingsDefaults() {
        let c = CloneSettings()
        XCTAssertTrue(c.aligned)
        XCTAssertFalse(c.sampleAllLayers)
    }

    // MARK: GradientSettings

    func testGradientSettingsDefaults() {
        let g = GradientSettings()
        XCTAssertEqual(g.shape, .linear)
        XCTAssertEqual(g.style, .foregroundToTransparent)
        XCTAssertFalse(g.reversed)
        XCTAssertEqual(g.opacity, 1)
    }

    func testGradientStyleCases() {
        XCTAssertEqual(GradientStyle.allCases.count, 2)
        XCTAssertEqual(GradientShape.allCases.count, 2)
    }

    // MARK: DocumentHistory

    private func doc(_ w: Int = 10, _ h: Int = 10) -> CanvasDocument {
        CanvasDocument(width: w, height: h)
    }

    func testHistoryEmptyCannotUndoRedo() {
        let h = DocumentHistory()
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
        XCTAssertFalse(h.isModified)
    }

    func testHistoryBeginEndRecordsEdit() {
        let h = DocumentHistory()
        var d = doc()
        h.begin("Add Layer", document: d, selection: nil)
        d.layers.append(ImageLayer(name: "L", blankSize: d.size))
        h.end(document: d, selection: nil)
        XCTAssertTrue(h.canUndo)
        XCTAssertEqual(h.undoName, "Add Layer")
        XCTAssertTrue(h.isModified)
        XCTAssertEqual(h.undoCount, 1)
    }

    func testHistoryNoOpEditNotRecorded() {
        let h = DocumentHistory()
        let d = doc()
        h.begin("Noop", document: d, selection: nil)
        h.end(document: d, selection: nil)  // document unchanged
        XCTAssertFalse(h.canUndo)
    }

    func testHistoryUndoRedoRoundTrip() {
        let h = DocumentHistory()
        var d = doc()
        h.begin("Edit", document: d, selection: nil)
        d.layers.append(ImageLayer(name: "L", blankSize: d.size))
        h.end(document: d, selection: nil)
        let before = h.undo()
        XCTAssertEqual(before?.document?.layers.count, 0)
        XCTAssertFalse(h.canUndo)
        XCTAssertTrue(h.canRedo)
        let after = h.redo()
        XCTAssertEqual(after?.document?.layers.count, 1)
    }

    func testHistoryMarkSavedClearsModified() {
        let h = DocumentHistory()
        var d = doc()
        h.begin("Edit", document: d, selection: nil)
        d.layers.append(ImageLayer(name: "L", blankSize: d.size))
        h.end(document: d, selection: nil)
        XCTAssertTrue(h.isModified)
        h.markSaved()
        XCTAssertFalse(h.isModified)
    }

    func testHistoryNestedBeginEndOneEdit() {
        let h = DocumentHistory()
        var d = doc()
        h.begin("Outer", document: d, selection: nil)
        h.begin("Inner", document: d, selection: nil)  // nested
        d.layers.append(ImageLayer(name: "L", blankSize: d.size))
        h.end(document: d, selection: nil)
        h.end(document: d, selection: nil)
        XCTAssertEqual(h.undoCount, 1)  // one entry, named by the outer
        XCTAssertEqual(h.undoName, "Outer")
    }

    func testHistoryTrimEnforcesEntryLimit() {
        let h = DocumentHistory(entryLimit: 3)
        var d = doc()
        for i in 0..<5 {
            h.begin("Edit \(i)", document: d, selection: nil)
            d.layers.append(ImageLayer(name: "L\(i)", blankSize: d.size))
            h.end(document: d, selection: nil)
        }
        XCTAssertLessThanOrEqual(h.undoCount, 3)
    }

    func testHistoryResetClears() {
        let h = DocumentHistory()
        var d = doc()
        h.begin("Edit", document: d, selection: nil)
        d.layers.append(ImageLayer(name: "L", blankSize: d.size))
        h.end(document: d, selection: nil)
        h.reset()
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.isModified)
    }

    func testHistoryRetainedBytesExcludesLiveDocument() {
        let h = DocumentHistory()
        let pixels = PortableImage(PixelBuffer(width: 4, height: 4, fill: 0))
        let img = RasterImage(pixels)
        let asset = ImportedImage(image: img, thumbnail: img, name: "x")
        var d = doc(4, 4)
        h.begin("Add", document: d, selection: nil)
        d.layers.append(ImageLayer(asset: asset, origin: .zero))
        h.end(document: d, selection: nil)
        // The live document holds the same image instance, so it is excluded from retained bytes.
        XCTAssertEqual(h.retainedBytes(current: d), 0)
        // Drop the image from the live document: history still holds it → retained.
        h.begin("Remove", document: d, selection: nil)
        d.layers.removeAll()
        h.end(document: d, selection: nil)
        XCTAssertGreaterThan(h.retainedBytes(current: d), 0)
    }
}