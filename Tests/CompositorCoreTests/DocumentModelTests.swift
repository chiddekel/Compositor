// Tests for the portable document-model core: ImageLayer, CanvasDocument,
// NavigationTool, LayerBlendMode, ImportedImage/RasterImage, LayerMask placement
// math, LayerShape, TransformEdit/FloatingTransform, and the portable selection
// substrate (PortablePath/DocumentSelection/SelectionClip/DragBox).
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class DocumentModelTests: XCTestCase {

    private func raster(_ w: Int, _ h: Int) -> RasterImage {
        RasterImage(PortableImage(PixelBuffer(width: w, height: h, fill: 0)))
    }

    // MARK: RasterImage / ImportedImage

    func testRasterImageIdentity() {
        let a = raster(2, 2), b = raster(2, 2)
        XCTAssertTrue(a === a)
        XCTAssertFalse(a === b)  // distinct instances, like CGImage
    }

    func testImportedImageDimensions() {
        let img = ImportedImage(image: raster(10, 20), thumbnail: raster(4, 4), name: "x")
        XCTAssertEqual(img.image.width, 10)
        XCTAssertEqual(img.image.height, 20)
        XCTAssertEqual(img.name, "x")
    }

    // MARK: ImageLayer

    func testImageLayerEqualityUsesAssetIdentity() {
        let r = raster(4, 4)
        let asset = ImportedImage(image: r, thumbnail: r, name: "a")
        var l1 = ImageLayer(asset: asset, origin: .zero)
        var l2 = l1
        XCTAssertTrue(l1 == l2)  // same asset instance
        // A different asset instance (even with equal pixels) breaks identity, as on macOS.
        let asset2 = ImportedImage(image: raster(4, 4), thumbnail: r, name: "a")
        l2.asset = asset2
        XCTAssertFalse(l1 == l2)
        l1.name = "renamed"; l2.asset = asset; l2.name = "renamed"
        XCTAssertTrue(l1 == l2)
    }

    func testImageLayerBlankInit() {
        let layer = ImageLayer(name: "Layer 1", blankSize: CGSize(width: 100, height: 50))
        XCTAssertNil(layer.asset)
        XCTAssertEqual(layer.size, CGSize(width: 100, height: 50))
        XCTAssertEqual(layer.origin, .zero)
    }

    func testImageLayerMaskTransformDefaultsToLayer() {
        let layer = ImageLayer(name: "x", blankSize: CGSize(width: 10, height: 10))
        XCTAssertEqual(layer.maskTransform, layer.transform)
    }

    // MARK: CanvasDocument

    func testCanvasDocumentValidDimension() {
        XCTAssertEqual(CanvasDocument.validDimension("100"), 100)
        XCTAssertNil(CanvasDocument.validDimension("0"))
        XCTAssertNil(CanvasDocument.validDimension("40000"))
        XCTAssertNil(CanvasDocument.validDimension("abc"))
    }

    func testCanvasDocumentSize() {
        let doc = CanvasDocument(width: 200, height: 100)
        XCTAssertEqual(doc.size, CGSize(width: 200, height: 100))
        XCTAssertEqual(doc.resolution, 72)
        XCTAssertTrue(doc.layers.isEmpty)
    }

    // MARK: NavigationTool

    func testNavigationToolClassification() {
        XCTAssertTrue(NavigationTool.brush.isBrushTool)
        XCTAssertTrue(NavigationTool.cloneStamp.isBrushTool)
        XCTAssertFalse(NavigationTool.move.isBrushTool)
        XCTAssertTrue(NavigationTool.marquee.isSelectionTool)
        XCTAssertTrue(NavigationTool.wand.isSelectionTool)
        XCTAssertFalse(NavigationTool.brush.isSelectionTool)
    }

    func testNavigationToolEveryCaseHasSymbolAndLabel() {
        for tool in NavigationTool.allCases {
            XCTAssertFalse(tool.symbol.isEmpty)
            XCTAssertFalse(tool.label.isEmpty)
        }
    }

    // MARK: LayerBlendMode

    func testLayerBlendModeCases() {
        XCTAssertEqual(LayerBlendMode.allCases.count, 13)
        XCTAssertEqual(LayerBlendMode.normal.rawValue, "Normal")
    }

    // MARK: LayerMask placement math

    func testLayerMaskPlacementLinkedCarriesWithLayer() {
        let r = raster(8, 8)
        let asset = ImportedImage(image: r, thumbnail: r, name: "mask")
        let mask = LayerMask(asset: asset)  // linked, placement nil (covers the layer)
        let old = LayerTransform(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 8, height: 8))
        let new = LayerTransform(origin: CGPoint(x: 10, y: 0), size: CGSize(width: 8, height: 8))
        // Covering the layer (placement nil) and linked: follows a plain move, staying nil.
        XCTAssertNil(mask.placement(movingLayer: old, to: new))
    }

    func testLayerMaskUniformReturnsNil() {
        let r = raster(1, 1)
        let asset = ImportedImage(image: r, thumbnail: r, name: "solid")
        let mask = LayerMask(asset: asset)
        let old = LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1))
        XCTAssertNil(mask.placement(movingLayer: old, to: old))
    }

    func testLayerMaskReplacingKeepsPlacementAndLink() {
        let r = raster(8, 8)
        let asset = ImportedImage(image: r, thumbnail: r, name: "m")
        var mask = LayerMask(asset: asset)
        mask.isEnabled = false
        mask.isLinked = false
        mask.placement = LayerTransform(origin: CGPoint(x: 5, y: 5), size: CGSize(width: 8, height: 8))
        let r2 = raster(8, 8)
        let replaced = mask.replacing(ImportedImage(image: r2, thumbnail: r2, name: "m"))
        XCTAssertEqual(replaced.isEnabled, false)
        XCTAssertEqual(replaced.isLinked, false)
        XCTAssertEqual(replaced.placement, mask.placement)
    }

    // MARK: LayerShape

    func testLayerShapeLoadedNilUnlessBoth() {
        XCTAssertNil(LayerShape.loaded(nil, image: raster(2, 2)))
        let style = LayerShapeStyle(kind: .rectangle, red: 1, green: 0, blue: 0, cornerRadius: 0)
        XCTAssertNil(LayerShape.loaded(style, image: nil))
        XCTAssertNotNil(LayerShape.loaded(style, image: raster(2, 2)))
    }

    func testLayerShapeStyleColor() {
        let style = LayerShapeStyle(kind: .ellipse, red: 0.2, green: 0.4, blue: 0.6, cornerRadius: 5)
        XCTAssertEqual(style.color, PaletteColor(red: 0.2, green: 0.4, blue: 0.6))
    }

    func testImageLayerLiveShape() {
        let r = raster(4, 4)
        let asset = ImportedImage(image: r, thumbnail: r, name: "s")
        var layer = ImageLayer(asset: asset, origin: .zero)
        let style = LayerShapeStyle(kind: .rectangle, red: 1, green: 1, blue: 1, cornerRadius: 0)
        layer.shape = LayerShape(style: style, image: r)
        XCTAssertNotNil(layer.liveShape)  // asset.image === shape.image
        layer.shape = LayerShape(style: style, image: raster(4, 4))  // different image instance
        XCTAssertNil(layer.liveShape)
    }

    // MARK: Selection substrate

    func testPortablePathBoundingBox() {
        let r = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(PortablePath.rectangle(r).boundingBox, r)
        XCTAssertEqual(PortablePath.ellipse(r).boundingBox, r)
        let poly = PortablePath.polygon([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 2, y: 8)])
        XCTAssertEqual(poly.boundingBox, CGRect(x: 0, y: 0, width: 10, height: 8))
    }

    func testDocumentSelectionEmpty() {
        XCTAssertTrue(DocumentSelection(path: .polygon([])).isEmpty)
        XCTAssertTrue(DocumentSelection(path: .rectangle(.null)).isEmpty)
        XCTAssertFalse(DocumentSelection(path: .rectangle(CGRect(x: 0, y: 0, width: 5, height: 5))).isEmpty)
    }

    func testDocumentSelectionClipClampsToCanvas() {
        let sel = DocumentSelection(path: .rectangle(CGRect(x: -5, y: -5, width: 20, height: 20)))
        let clip = sel.clip(canvas: CGSize(width: 10, height: 10))
        XCTAssertNil(clip.coverage)  // coverage is the raster milestone (nil)
        // Region is the inset-by-1 box intersected with the canvas.
        XCTAssertEqual(clip.rect, CGRect(x: -6, y: -6, width: 20, height: 20).integral
            .intersection(CGRect(origin: .zero, size: CGSize(width: 10, height: 10))))
    }

    func testDocumentSelectionClipEmptyReturnsZero() {
        let clip = DocumentSelection(path: .rectangle(.null)).clip(canvas: CGSize(width: 10, height: 10))
        XCTAssertEqual(clip.rect, .zero)
        XCTAssertNil(clip.coverage)
    }

    func testDragBoxRect() {
        let r = DragBox.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 4), square: false, fromCenter: false)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 10, height: 4))
        let sq = DragBox.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 4), square: true, fromCenter: false)
        XCTAssertEqual(sq.width, 10); XCTAssertEqual(sq.height, 10)
        let centered = DragBox.rect(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 10, y: 10), square: false, fromCenter: true)
        XCTAssertEqual(centered, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    // MARK: TransformEdit / FloatingTransform

    func testTransformEditDefaults() {
        let t = LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4))
        let edit = TransformEdit(layerID: UUID(), draft: t, persistent: false)
        XCTAssertNil(edit.floating)
        XCTAssertNil(edit.corners)
        XCTAssertFalse(edit.mask)
        XCTAssertNil(edit.group)
        XCTAssertFalse(edit.persistent)
    }

    func testFloatingTransformCarriesBefore() {
        let doc = CanvasDocument(width: 10, height: 10)
        let id = UUID()
        let f = FloatingTransform(sourceID: id, before: doc, beforeActive: nil,
                                  original: LayerTransform(origin: .zero, size: CGSize(width: 2, height: 2)),
                                  pixelSize: CGSize(width: 2, height: 2))
        XCTAssertEqual(f.sourceID, id)
        XCTAssertEqual(f.before.width, 10)
    }
}