// Tests for the FloatingSelection transform merge and the Option-drag duplicate
// transform (port of macOS FloatingSelection.swift and the EditorSession
// beginSelectionTransform/mergeFloatingTransform/beginDuplicateTransform paths).
// Pin the unchanged macOS behavior on Linux. Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class SelectionTransformTests: XCTestCase {

    private func makeRedLayer(width: Int = 40, height: Int = 40) -> ImageLayer {
        var p = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { p[x, y] = (255, 0, 0, 255) } }
        let red = RasterImage(PortableImage(p))
        return ImageLayer(asset: ImportedImage(image: red, thumbnail: red, name: "Red"), origin: .zero)
    }

    private func makeBlueDocument() -> (CanvasDocument, ImageLayer) {
        var bg = PixelBuffer(width: 100, height: 60)
        for y in 0..<60 { for x in 0..<100 { bg[x, y] = (0, 0, 255, 255) } }
        let blue = RasterImage(PortableImage(bg))
        let back = ImageLayer(asset: ImportedImage(image: blue, thumbnail: blue, name: "Back"), origin: .zero)
        return (CanvasDocument(width: 100, height: 60), back)
    }

    private func px(_ image: PortableImage, _ x: Int, _ y: Int) -> [Int] {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return [] }
        let i = (y * image.width + x) * 4
        return [Int(image.bytes[i]), Int(image.bytes[i + 1]), Int(image.bytes[i + 2]), Int(image.bytes[i + 3])]
    }

    func testFloatingTransformMergesAsOneUndoStep() throws {
        // Cmd-T on a selection: the selected pixels float, move, and merge back into
        // their layer as one "Transform Selection" undo step; the selection rides along.
        let session = EditorSession()
        var doc = CanvasDocument(width: 100, height: 60)
        let layer = makeRedLayer()
        doc.layers = [layer]
        doc.selection = DocumentSelection(path: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)), antialiased: true)
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(layer.id)
        XCTAssertTrue(session.canTransformSelection)
        session.transformCommand()
        // A floating layer sits above the source one, which lost its selected pixels.
        let floatingID = session.activeLayerID
        XCTAssertNotEqual(floatingID, layer.id)
        XCTAssertEqual(session.document?.layers.count, 2)
        XCTAssertEqual(session.document?.layers[1].name, "Floating Selection")
        let sourceAfterLift = session.document!.layers[0].asset!.image.pixels
        XCTAssertEqual(px(sourceAfterLift, 5, 5), [255, 0, 0, 255])
        XCTAssertEqual(px(sourceAfterLift, 15, 15), [0, 0, 0, 0])
        // Drag the floating pixels down (whole pixels).
        let draft = session.transformEdit!.draft
        var moved = draft
        moved.origin.y += 12
        session.previewTransform(moved)
        let count = session.history.undoCount
        session.commitTransform()
        XCTAssertNil(session.transformEdit)
        XCTAssertEqual(session.history.undoCount, count + 1)
        XCTAssertEqual(session.document?.layers.count, 1)
        XCTAssertEqual(session.activeLayerID, layer.id)
        let merged = session.document!.layers[0].asset!.image.pixels
        // The moved pixels now live deeper in the source layer (the cut left a hole at
        // the original spot, exactly as the CG cut+composite does); untouched red stays put.
        XCTAssertEqual(px(merged, 15, 15), [0, 0, 0, 0])       // hole: pixels moved away
        XCTAssertEqual(px(merged, 15, 22), [255, 0, 0, 255])   // moved pixels land here
        XCTAssertEqual(px(merged, 15, 5), [255, 0, 0, 255])
        // The selection moved with the pixels.
        let selection = try XCTUnwrap(session.document?.selection)
        XCTAssertEqual(selection.path.boundingBox.origin.y, 22, accuracy: 1)
        try session.undo()
        XCTAssertEqual(session.document?.layers.count, 1)
        XCTAssertNotNil(session.document?.selection)
        let restored = session.document!.layers[0].asset!.image.pixels
        XCTAssertEqual(px(restored, 5, 5), [255, 0, 0, 255])
        XCTAssertEqual(px(restored, 15, 15), [255, 0, 0, 255])
    }

    func testFloatingTransformCancelRestoresExactly() throws {
        let session = EditorSession()
        var doc = CanvasDocument(width: 100, height: 60)
        let layer = makeRedLayer()
        doc.layers = [layer]
        doc.selection = DocumentSelection(path: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)), antialiased: true)
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(layer.id)
        let count = session.history.undoCount
        session.transformCommand()
        session.cancelTransform()
        XCTAssertNil(session.transformEdit)
        XCTAssertEqual(session.history.undoCount, count)
        XCTAssertEqual(session.document?.layers.count, 1)
        XCTAssertEqual(px(session.document!.layers[0].asset!.image.pixels, 15, 15), [255, 0, 0, 255])
    }

    func testFloatingTransformLiftsActiveLayerPixelsOnly() throws {
        // renderSelectedPixels renders exactly the active layer, not the document:
        // a blue background underneath must not leak into the lifted pixels.
        let session = EditorSession()
        var doc = CanvasDocument(width: 100, height: 60)
        let (_, back) = makeBlueDocument()
        let layer = makeRedLayer()
        doc.layers = [back, layer]
        doc.selection = DocumentSelection(path: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)), antialiased: true)
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(layer.id)
        session.transformCommand()
        let floating = session.document!.layers[2].asset!.image.pixels
        XCTAssertEqual(px(floating, 2, 2), [255, 0, 0, 255])   // selected red pixels lifted
        XCTAssertEqual(px(floating, 18, 18), [255, 0, 0, 255])
    }

    func testDuplicateTransformMovesCopyAsOneUndoStep() throws {
        let session = EditorSession()
        var doc = CanvasDocument(width: 100, height: 60)
        let layer = makeRedLayer()
        doc.layers = [layer]
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(layer.id)
        session.beginDuplicateTransform()
        XCTAssertEqual(session.document?.layers.count, 2)
        XCTAssertNotEqual(session.document?.layers[1].id, layer.id)
        XCTAssertNotNil(session.transformEdit)
        let draft = session.transformEdit!.draft
        var moved = draft
        moved.origin.x += 30
        session.previewTransform(moved)
        let count = session.history.undoCount
        session.commitTransform()
        XCTAssertNil(session.transformEdit)
        XCTAssertNil(session.transformDuplicate)
        XCTAssertEqual(session.history.undoCount, count + 1)
        XCTAssertEqual(session.document?.layers.count, 2)
        XCTAssertEqual(session.activeLayerID, session.document?.layers[1].id)
        XCTAssertEqual(session.document?.layers[1].transform.origin.x ?? -1, 30, accuracy: 0.001)
        try session.undo()
        XCTAssertEqual(session.document?.layers.count, 1)
        XCTAssertEqual(session.document?.layers[0].transform.origin.x ?? -1, 0, accuracy: 0.001)
    }

    func testDuplicateTransformCancelRemovesCopy() throws {
        let session = EditorSession()
        var doc = CanvasDocument(width: 100, height: 60)
        let layer = makeRedLayer()
        doc.layers = [layer]
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(layer.id)
        let count = session.history.undoCount
        session.beginDuplicateTransform()
        session.cancelTransform()
        XCTAssertNil(session.transformEdit)
        XCTAssertNil(session.transformDuplicate)
        XCTAssertEqual(session.history.undoCount, count)
        XCTAssertEqual(session.document?.layers.count, 1)
        XCTAssertEqual(session.activeLayerID, layer.id)
    }

    func testFloatingMergeGrowsLayerForPixelsPastItsEdge() throws {
        // Moving floating pixels past the layer's own edge grows the layer's grid:
        // the moved pixels land outside the original 40x40 bounds.
        let session = EditorSession()
        var doc = CanvasDocument(width: 100, height: 60)
        let layer = makeRedLayer()
        doc.layers = [layer]
        doc.selection = DocumentSelection(path: .rectangle(CGRect(x: 30, y: 30, width: 10, height: 10)), antialiased: true)
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(layer.id)
        session.transformCommand()
        let draft = session.transformEdit!.draft
        var moved = draft
        moved.origin.y += 10   // now ends at y=50, past the layer's 40 rows
        session.previewTransform(moved)
        session.commitTransform()
        let merged = session.document!.layers[0].asset!.image.pixels
        XCTAssertEqual(merged.height, 50)
        XCTAssertEqual(px(merged, 35, 40), [255, 0, 0, 255])
        XCTAssertEqual(px(merged, 35, 43), [255, 0, 0, 255])
        XCTAssertEqual(px(merged, 31, 31), [0, 0, 0, 0])   // hole: the original cut spot stays transparent
    }

    func testRenderSelectedPixelsMaskPathUsesMaskTone() throws {
        // The `mask: true` branch renders a layer mask's coverage: a full white mask
        // over the selection gives white pixels at full alpha.
        let session = EditorSession()
        var doc = CanvasDocument(width: 100, height: 60)
        var layer = makeRedLayer()
        var maskP = MaskBuffer(width: 20, height: 20)
        for y in 0..<20 { for x in 0..<20 { maskP[x, y] = 255 } }
        let maskImage = RasterImage(PortableImage(maskP))
        layer.mask = LayerMask(asset: ImportedImage(image: maskImage, thumbnail: maskImage, name: "Layer Mask"))
        doc.layers = [layer]
        doc.selection = DocumentSelection(path: .rectangle(CGRect(x: 5, y: 5, width: 10, height: 10)), antialiased: true)
        session.replaceCurrentDocument(doc)
        let rendered = try XCTUnwrap(session.renderSelectedPixels(from: layer, mask: true))
        XCTAssertEqual(rendered.region, CGRect(x: 5, y: 5, width: 10, height: 10))
        XCTAssertEqual(px(rendered.image.pixels, 0, 0), [255, 255, 255, 255])
    }

    func testSelectionTransformPreviewKeepsUntouchedRed() throws {
        // The part of the source layer that was NOT selected is untouched by the merge.
        let session = EditorSession()
        var doc = CanvasDocument(width: 100, height: 60)
        let layer = makeRedLayer()
        doc.layers = [layer]
        doc.selection = DocumentSelection(path: .rectangle(CGRect(x: 2, y: 2, width: 6, height: 6)), antialiased: true)
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(layer.id)
        session.transformCommand()
        let draft = session.transformEdit!.draft
        var moved = draft
        moved.origin.x += 4
        session.previewTransform(moved)
        let count = session.history.undoCount
        session.commitTransform()
        XCTAssertEqual(session.history.undoCount, count + 1)
        let merged = session.document!.layers[0].asset!.image.pixels
        XCTAssertEqual(px(merged, 30, 20), [255, 0, 0, 255])  // untouched red outside the selection
        XCTAssertEqual(px(merged, 26, 22), [255, 0, 0, 255])  // moved selection pixels
    }
}