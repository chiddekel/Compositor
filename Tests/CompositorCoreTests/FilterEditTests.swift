import XCTest
@testable import CompositorCore

final class FilterEditTests: XCTestCase {
    private func document(width: Int = 8, height: Int = 8) -> CanvasDocument {
        let raster = RasterImage(PortableImage(PixelBuffer(width: width, height: height, fill: 0x804020ff)))
        let layer = ImageLayer(asset: ImportedImage(image: raster, thumbnail: raster, name: "Original"),
                               origin: CGPoint(x: 10, y: 12))
        return CanvasDocument(width: max(64, width), height: max(64, height), layers: [layer])
    }

    private func edit(_ document: CanvasDocument, kind: FilterKind = .addNoise,
                      settings: FilterSettings = FilterSettings()) throws -> FilterEdit {
        try FilterEdit(kind: kind, documentID: document.id, layer: document.layers[0],
                       selection: nil, settings: settings, seed: 123)
    }

    func testPreviewCancelLeavesDocumentAndHistoryUntouched() throws {
        let doc = document()
        let original = doc
        let history = DocumentHistory()
        let panel = try edit(doc)
        let request = try panel.makePreviewRequest()
        let rendered = try PixelFilter.run(request.job)
        XCTAssertTrue(panel.acceptPreview(rendered, for: request))
        XCTAssertNotNil(panel.previewImage(for: doc.layers[0].id))
        panel.preview = false
        XCTAssertNil(panel.previewImage(for: doc.layers[0].id))
        panel.cancel()
        XCTAssertFalse(panel.acceptPreview(rendered, for: request))
        XCTAssertThrowsError(try panel.makePreviewRequest())
        XCTAssertEqual(doc, original)
        XCTAssertFalse(history.isModified)
        XCTAssertFalse(history.canUndo)
    }

    func testOlderPreviewAndDifferentPanelCannotOverwriteCurrentSettings() throws {
        let doc = document()
        let panel = try edit(doc)
        let other = try edit(doc)
        let old = try panel.makePreviewRequest()
        var settings = FilterSettings()
        settings.amount = 90
        try panel.update(settings)
        let latest = try panel.makePreviewRequest()
        let expected = try PixelFilter.run(latest.job)
        XCTAssertTrue(panel.acceptPreview(expected, for: latest))
        XCTAssertFalse(panel.acceptPreview(try PixelFilter.run(old.job), for: old))
        XCTAssertFalse(other.acceptPreview(expected, for: latest))
        XCTAssertEqual(panel.preparedPreview, expected)
    }

    func testCommitMakesExactlyOneUndoStepAndUsesPreviewNoiseSeed() throws {
        var doc = document()
        let original = doc
        let history = DocumentHistory()
        let panel = try edit(doc)
        let request = try panel.makePreviewRequest()
        let expected = try PixelFilter.run(request.job)
        XCTAssertTrue(try panel.commit(document: &doc, activeLayerID: doc.layers[0].id, history: history))
        XCTAssertEqual(doc.layers[0].asset?.image.pixels, expected)
        XCTAssertEqual(doc.layers[0].name, "Original")
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertTrue(history.isModified)
        XCTAssertEqual(history.undo()?.document, original)
        XCTAssertFalse(history.isModified)
        XCTAssertEqual(history.redo()?.document, doc)
        XCTAssertThrowsError(try panel.commit(document: &doc, activeLayerID: nil, history: history))
    }

    func testIdentityFilterPreservesRedoAndImageIdentity() throws {
        var doc = document()
        let history = DocumentHistory()
        history.begin("Rename", document: doc, selection: nil)
        doc.layers[0].name = "Renamed"
        history.end(document: doc, selection: nil)
        doc = try XCTUnwrap(history.undo()?.document)
        let before = doc
        let panel = try edit(doc, kind: .lensCorrection)
        XCTAssertFalse(try panel.commit(document: &doc, activeLayerID: nil, history: history))
        XCTAssertEqual(doc, before)
        XCTAssertTrue(history.canRedo)
        XCTAssertFalse(history.isModified)
    }

    func testDeletedReplacedMovedAndOtherDocumentTargetsAreRejected() throws {
        for change in 0..<4 {
            var doc = document()
            let panel = try edit(doc)
            let history = DocumentHistory()
            switch change {
            case 0: doc.layers.removeAll()
            case 1: doc.layers[0].asset = document().layers[0].asset
            case 2: doc.layers[0].transform.origin.x += 1
            default: doc = CanvasDocument(width: doc.width, height: doc.height, layers: doc.layers)
            }
            let before = doc
            XCTAssertThrowsError(try panel.commit(document: &doc, activeLayerID: nil, history: history)) {
                guard case FilterEdit.Failure.staleTarget = $0 else { return XCTFail("Expected a stale target") }
            }
            XCTAssertEqual(doc, before)
            XCTAssertFalse(history.canUndo)
        }
    }

    func testFailedFilterDoesNotModifyDocumentOrDiscardPanel() throws {
        var doc = document()
        let before = doc
        let history = DocumentHistory()
        let panel = try edit(doc, kind: .contentAwareFill)
        XCTAssertThrowsError(try panel.commit(document: &doc, activeLayerID: nil, history: history))
        XCTAssertEqual(doc, before)
        XCTAssertFalse(panel.isClosed)
        XCTAssertFalse(history.canUndo)
    }

    func testBlurGrowsGridKeepsRotatedFlippedCenterAndCarriesDisabledMask() throws {
        var doc = document()
        doc.layers[0].transform.rotation = 30
        doc.layers[0].transform.flipX = true
        let mask = PortableImage(MaskBuffer(width: 8, height: 8, fill: 255))
        doc.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: mask), isEnabled: false, isLinked: false)
        let original = doc
        let panel = try edit(doc, kind: .gaussianBlur)
        XCTAssertGreaterThan(try XCTUnwrap(panel.grownImage).width, 8)
        XCTAssertEqual(panel.grownTransform?.center.x ?? 0, doc.layers[0].transform.center.x, accuracy: 0.0001)
        var larger = FilterSettings()
        larger.radius = 3
        try panel.update(larger)
        let grownWidth = panel.grownImage?.width
        try panel.update(FilterSettings())
        XCTAssertEqual(panel.grownImage?.width, grownWidth, "Reducing blur does not rebuild the padded source")
        let history = DocumentHistory()
        XCTAssertTrue(try panel.commit(document: &doc, activeLayerID: nil, history: history))
        let layer = doc.layers[0]
        XCTAssertGreaterThan(layer.asset?.image.width ?? 0, 8)
        XCTAssertEqual(layer.transform.rotation, 30)
        XCTAssertTrue(layer.transform.flipX)
        XCTAssertEqual(layer.mask?.asset.image.width, layer.asset?.image.width)
        XCTAssertEqual(layer.mask?.asset.image.height, layer.asset?.image.height)
        XCTAssertEqual(layer.mask?.isEnabled, false)
        XCTAssertEqual(layer.mask?.isLinked, false)
        XCTAssertTrue(try XCTUnwrap(layer.mask).asset.image.pixels.bytes.allSatisfy { $0 == 255 })
        XCTAssertEqual(history.undo()?.document, original)
    }

    func testPreviewIsBoundedButNoiseKeepsFullResolution() throws {
        let doc = document(width: 2050, height: 2)
        let blur = try edit(doc, kind: .gaussianBlur)
        let request = try blur.makePreviewRequest()
        XCTAssertEqual(request.job.image.width, FilterEdit.previewLimit)
        XCTAssertLessThan(request.job.scale, 1)
        let noise = try edit(doc)
        XCTAssertEqual(try noise.makePreviewRequest().job.image.width, 2050)
        XCTAssertEqual(try noise.makePreviewRequest().job.scale, 1)
    }

    func testGrowingToSelectionPreservesOriginalPixelDocumentLocation() throws {
        let doc = document()
        let layer = doc.layers[0]
        let area = CGRect(x: 0, y: 0, width: 32, height: 32)
        let panel = try FilterEdit(kind: .contentAwareFill, documentID: doc.id, layer: layer,
            selection: nil, settings: FilterSettings(), growingTo: area)
        let pixels = try XCTUnwrap(panel.grownImage)
        let placement = try XCTUnwrap(panel.grownTransform)
        XCTAssertEqual(placement.origin, .zero)
        XCTAssertEqual(pixels.width, 32)
        XCTAssertEqual(RasterSample.rgbaNearest(pixels, fx: 10, fy: 12).r, 128)
        XCTAssertEqual(RasterSample.rgbaNearest(pixels, fx: 0, fy: 0).a, 0)
        XCTAssertThrowsError(try FilterEdit(kind: .contentAwareFill, documentID: doc.id, layer: layer,
            selection: nil, settings: FilterSettings(), growingTo: CGRect(x: 0, y: 0, width: 30_001, height: 10)))
    }

    func testMaskPlacementPreservesBorderToneAndDisabledState() throws {
        let source = PortableImage(MaskBuffer(width: 2, height: 1, bytes: [0, 255]))
        var mask = LayerMask(asset: try LayerMask.asset(from: source))
        let placed = LayerTransform(origin: CGPoint(x: 2, y: 0), size: CGSize(width: 2, height: 1))
        let target = LayerTransform(origin: .zero, size: CGSize(width: 6, height: 1))
        let output = try XCTUnwrap(mask.clipImage(placement: placed, over: target, width: 6, height: 1))
        XCTAssertEqual(output.pixels.bytes, [255, 255, 0, 255, 255, 255])
        mask.isEnabled = false
        XCTAssertNil(mask.clipImage(placement: placed, over: target, width: 6, height: 1))
    }
}
