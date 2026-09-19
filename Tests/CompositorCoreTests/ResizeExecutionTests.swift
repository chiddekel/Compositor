import XCTest
@testable import CompositorCore

final class ResizeExecutionTests: XCTestCase {
    private func snapshot(width: Int = 8, height: Int = 4) throws -> ProjectSnapshot {
        var pixels = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<(width / 2) { pixels[x, y] = (255, 0, 0, 255) } }
        let image = RasterImage(PortableImage(pixels))
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Image"), origin: .zero)
        return try ProjectSnapshot(document: CanvasDocument(width: width, height: height, layers: [layer]), activeLayerID: layer.id)
    }

    func testAllCanvasAnchorsPreservePixelsRotationAndFlips() async throws {
        var doc = try snapshot(width: 64, height: 32).document()
        doc.layers[0].transform.rotation = 37
        doc.layers[0].transform.flipX = true
        let input = try ProjectSnapshot(document: doc, activeLayerID: doc.layers[0].id)
        let source = input.manifest.layers[0]
        for delta in [5, -5] {
            for anchor in 0...8 {
                let output = try await CanvasResizer.shared.resize(input,
                    to: CanvasSizeOptions(width: 64 + delta, height: 32 + delta, anchor: anchor))
                let layer = output.manifest.layers[0]
                let offsets = [0, delta == 5 ? 2 : -3, delta]
                XCTAssertEqual(layer.transform.origin.x, CGFloat(offsets[anchor % 3]))
                XCTAssertEqual(layer.transform.origin.y, CGFloat(offsets[anchor / 3]))
                XCTAssertEqual(layer.transform.size, source.transform.size)
                XCTAssertEqual(layer.transform.rotation, 37)
                XCTAssertTrue(layer.transform.flipX)
                XCTAssertEqual(layer.id, source.id)
                XCTAssertTrue(output.images[layer.id]?.image === input.images[layer.id]?.image)
            }
        }
    }

    func testColoredCanvasExtensionLeavesOldTransparencyAndPreservesUndo() async throws {
        let before = CanvasDocument(width: 4, height: 4)
        let input = try ProjectSnapshot(document: before, activeLayerID: nil)
        let output = try await CanvasResizer.shared.resize(input, to: CanvasSizeOptions(width: 8, height: 2,
            fill: CanvasExtensionColor(red: 1, green: 0, blue: 0)))
        XCTAssertEqual(output.manifest.layers.count, 1)
        let image = try XCTUnwrap(output.images.values.first).image.pixels
        XCTAssertEqual(RasterSample.rgbaNearest(image, fx: 0, fy: 0).r, 255)
        XCTAssertEqual(RasterSample.rgbaNearest(image, fx: 0, fy: 0).a, 255)
        XCTAssertEqual(RasterSample.rgbaNearest(image, fx: 3, fy: 0).a, 0)
        XCTAssertEqual(RasterSample.rgbaNearest(image, fx: 7, fy: 1).a, 255)
        let after = try output.document()
        let history = DocumentHistory()
        history.begin("Canvas Size", document: before, selection: nil)
        history.end(document: after, selection: nil)
        XCTAssertEqual(history.undo()?.document, before)
        XCTAssertEqual(history.redo()?.document, after)
    }

    func testTransparentCanvasResizeDoesNotAllocateAndShrinkDoesNotFill() async throws {
        let input = try ProjectSnapshot(document: CanvasDocument(width: 4, height: 4), activeLayerID: nil)
        let large = try await CanvasResizer.shared.resize(input, to: CanvasSizeOptions(width: 30_000, height: 30_000))
        XCTAssertTrue(large.images.isEmpty)
        let color = CanvasExtensionColor(red: 1, green: 1, blue: 1)
        let small = try await CanvasResizer.shared.resize(input, to: CanvasSizeOptions(width: 2, height: 2, fill: color))
        XCTAssertTrue(small.images.isEmpty)
        do {
            _ = try await CanvasResizer.shared.resize(input, to: CanvasSizeOptions(width: 30_000, height: 30_000, fill: color))
            XCTFail("Expected pixel budget rejection")
        } catch ProjectError.tooLarge { }
    }

    func testCanvasResizeMovesSeparateMaskPlacement() async throws {
        var doc = try snapshot().document()
        doc.layers[0].mask = LayerMask.solid(revealing: true)
        doc.layers[0].mask?.placement = LayerTransform(origin: CGPoint(x: -10, y: 12), size: CGSize(width: 4, height: 4))
        let input = try ProjectSnapshot(document: doc, activeLayerID: doc.layers[0].id)
        let output = try await CanvasResizer.shared.resize(input, to: CanvasSizeOptions(width: 12, height: 8))
        XCTAssertEqual(output.manifest.layers[0].maskPlacement?.origin, CGPoint(x: -8, y: 14))
        XCTAssertTrue(output.masks[doc.layers[0].id]?.image === input.masks[doc.layers[0].id]?.image)
    }

    func testImageResizeRetainsIDsTransparencyAndUndoSource() async throws {
        let input = try snapshot()
        let before = try input.document()
        let output = try await ImageResizer.shared.resize(input,
            to: ImageSizeOptions(width: 16, height: 12, resolution: 300, sampling: .nearest))
        XCTAssertEqual(output.manifest.activeLayerID, input.manifest.activeLayerID)
        XCTAssertEqual(output.manifest.resolution, 300)
        let layer = output.manifest.layers[0]
        let image = try XCTUnwrap(output.images[layer.id]).image.pixels
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 12)
        XCTAssertEqual(RasterSample.rgbaNearest(image, fx: 0, fy: 0).r, 255)
        XCTAssertEqual(RasterSample.rgbaNearest(image, fx: 15, fy: 0).a, 0)
        let history = DocumentHistory()
        history.begin("Image Size", document: before, selection: layer.id)
        history.end(document: try output.document(), selection: layer.id)
        let restored = try XCTUnwrap(history.undo()?.document)
        XCTAssertEqual(restored, before)
        XCTAssertTrue(restored.layers[0].asset?.image === before.layers[0].asset?.image)
    }

    func testResolutionOnlySharesRastersAndMasks() async throws {
        var doc = try snapshot().document()
        doc.layers[0].mask = LayerMask.solid(revealing: false)
        let input = try ProjectSnapshot(document: doc, activeLayerID: nil)
        let output = try await ImageResizer.shared.resize(input, to: ImageSizeOptions(width: 8, height: 4, resolution: 300))
        let id = doc.layers[0].id
        XCTAssertTrue(output.images[id]?.image === input.images[id]?.image)
        XCTAssertTrue(output.masks[id]?.image === input.masks[id]?.image)
        XCTAssertEqual(output.manifest.layers[0].transform, input.manifest.layers[0].transform)
        XCTAssertEqual(output.manifest.resolution, 300)
    }

    func testRotatedHiddenLayerScalesInDocumentAxes() async throws {
        var doc = try snapshot(width: 64, height: 32).document()
        doc.layers[0].isVisible = false
        doc.layers[0].transform = LayerTransform(origin: CGPoint(x: -16, y: 4), size: CGSize(width: 64, height: 32), rotation: 90)
        let input = try ProjectSnapshot(document: doc, activeLayerID: nil)
        let output = try await ImageResizer.shared.resize(input,
            to: ImageSizeOptions(width: 128, height: 96, resolution: 72, sampling: .nearest))
        let layer = output.manifest.layers[0]
        XCTAssertFalse(layer.isVisible)
        XCTAssertEqual(layer.transform.rotation, 0)
        XCTAssertEqual(layer.transform.size.width, 64, accuracy: 1)
        XCTAssertEqual(layer.transform.size.height, 192, accuracy: 1)
        XCTAssertLessThan(layer.transform.origin.y, 0)
        do {
            _ = try await ImageResizer.shared.resize(input, to: ImageSizeOptions(width: 30_000, height: 30_000, resolution: 72))
            XCTFail("Expected oversized output rejection")
        } catch ProjectError.tooLarge { }
    }

    func testDownsamplingIntegratesPixelAreaInsteadOfAliasing() async throws {
        var doc = try snapshot(width: 9, height: 9).document()
        var pixels = PixelBuffer(width: 9, height: 9)
        for y in 0..<9 { for x in 0..<9 { pixels[x, y] = (x % 3 == 1 ? 255 : 0, 0, 0, 255) } }
        let image = RasterImage(PortableImage(pixels))
        doc.layers[0].asset = ImportedImage(image: image, thumbnail: image, name: "Stripes")
        let input = try ProjectSnapshot(document: doc, activeLayerID: nil)
        let output = try await ImageResizer.shared.resize(input, to: ImageSizeOptions(width: 3, height: 3, resolution: 72))
        let result = try XCTUnwrap(output.images[doc.layers[0].id]).image.pixels
        for y in 0..<3 { for x in 0..<3 {
            let pixel = RasterSample.rgbaNearest(result, fx: CGFloat(x), fy: CGFloat(y))
            XCTAssertEqual(pixel.r, 85, accuracy: 1)
            XCTAssertEqual(pixel.a, 255)
        } }
    }

    func testSnapshotMappingRejectsMissingAssetsAndPreservesMaskFlags() throws {
        var doc = try snapshot().document()
        doc.layers[0].mask = LayerMask.solid(revealing: true)
        doc.layers[0].mask?.isEnabled = false
        doc.layers[0].mask?.isLinked = false
        let input = try ProjectSnapshot(document: doc, activeLayerID: doc.layers[0].id)
        XCTAssertEqual(try input.document(), doc)
        XCTAssertThrowsError(try ProjectSnapshot(manifest: input.manifest, images: [:], masks: input.masks).document())
        XCTAssertThrowsError(try ProjectSnapshot(manifest: input.manifest, images: input.images, masks: [:]).document())
    }

    func testV7ManifestRoundTripPreservesShapeAdjustmentAndMaskPlacement() throws {
        var doc = try snapshot().document()
        let image = try XCTUnwrap(doc.layers[0].asset).image
        doc.layers[0].shape = LayerShape(style: LayerShapeStyle(kind: .rectangle, red: 1, green: 0,
            blue: 0, cornerRadius: 2), image: image)
        doc.layers[0].mask = LayerMask.solid(revealing: false)
        doc.layers[0].mask?.placement = LayerTransform(origin: CGPoint(x: 3, y: -2), size: CGSize(width: 8, height: 4))
        doc.layers[0].mask?.isLinked = false
        var adjustment = ImageLayer(name: "Exposure", blankSize: doc.size)
        adjustment.adjustment = LayerAdjustment(kind: .exposure)
        adjustment.adjustment?.exposure = ExposureSettings(exposure: 1)
        doc.layers.append(adjustment)
        let input = try ProjectSnapshot(document: doc, activeLayerID: adjustment.id)
        let data = try JSONEncoder().encode(input.manifest)
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        XCTAssertEqual(manifest.version, 7)
        let restored = try ProjectSnapshot(manifest: manifest, images: input.images, masks: input.masks).document()
        XCTAssertEqual(restored, doc)
        XCTAssertEqual(manifest.layers[0].shape?.cornerRadius, 2)
        XCTAssertEqual(manifest.layers[0].maskPlacement?.origin, CGPoint(x: 3, y: -2))
        XCTAssertEqual(manifest.layers[0].maskLinked, false)
        XCTAssertEqual(manifest.layers[1].adjustment?.exposure.exposure, 1)
    }
}
