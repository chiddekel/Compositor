// Tests for the portable RasterSnapshot (Compositor/Rendering/RasterSnapshot.swift
// port). Pin the kept macOS invariants on Linux, without the EditorSession shell
// the macOS suite leans on: sparse patch replacement with edge-splitting (the
// display list stays disjoint), lazy materialization (mouse-up never flattens),
// immutability across successive commits, mask expansion white fill, and the
// halving-grid alignment carry (ENG-11).
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

private func patch(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, value: UInt8) -> BrushPatch {
    BrushPatch(rect: CGRect(x: x, y: y, width: w, height: h),
               image: PortableImage(MaskBuffer(width: Int(w), height: Int(h), fill: value)))
}

private func rgbaPatch(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> BrushPatch {
    var pixels = PixelBuffer(width: Int(w), height: Int(h))
    for py in 0..<Int(h) { for px in 0..<Int(w) { pixels[px, py] = (r, g, b, a) } }
    return BrushPatch(rect: CGRect(x: x, y: y, width: w, height: h), image: PortableImage(pixels))
}

private func imported(_ pixels: PixelBuffer) -> ImportedImage {
    let portable = PortableImage(pixels)
    return ImportedImage(image: RasterImage(portable),
                         thumbnail: RasterImage(RasterSample.thumbnail(portable)),
                         name: "Imported")
}

final class RasterSnapshotTests: XCTestCase {

    func testMouseUpNeverFlattensAndSuccessiveStrokesStaySparse() throws {
        // 4000x4000 document, two successive 800px soft strokes: no commit
        // materializes the full raster (the macOS mouseUp invariant).
        let canvas = CGSize(width: 4000, height: 4000)
        let layer = ImageLayer(name: "Blank", blankSize: canvas)
        var settings = BrushSettings()
        settings.diameter = 800; settings.hardness = 0; settings.opacity = 1
        settings.red = 1; settings.green = 1; settings.blue = 1

        let first = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: canvas)
        try first.append(CGPoint(x: 800, y: 3200))
        try first.append(CGPoint(x: 800, y: 800))
        try first.flush()
        let snapshot1 = try first.paintSnapshot()
        let raster1 = try XCTUnwrap(snapshot1.asset.raster)
        XCTAssertFalse(raster1.hasMaterializedPixels, "mouse-up must not flatten the document")

        let layer2 = ImageLayer(id: layer.id, asset: snapshot1.asset, name: layer.name, isVisible: true,
                                transform: snapshot1.transform)
        let second = try BrushStroke(layer: layer2, mask: false, settings: settings, canvas: canvas)
        try second.append(CGPoint(x: 1600, y: 1600))
        try second.append(CGPoint(x: 2200, y: 2200))
        try second.flush()
        let snapshot2 = try second.paintSnapshot()
        let raster2 = try XCTUnwrap(snapshot2.asset.raster)
        XCTAssertFalse(raster1.hasMaterializedPixels, "the next stroke must not flatten the previous raster")
        XCTAssertFalse(raster2.hasMaterializedPixels)
        // The second raster shares untouched tiles: its base is the first raster's base
        // (nil here — painted from nothing) and it carries the first's patches forward.
        XCTAssertFalse(raster2.patches.isEmpty)
    }

    func testReplacingSplitsOldPatchesAtNewTileEdges() {
        // Old patch (0,0,100,100), new patch (50,50,100,100): the display list
        // must come out disjoint — the old patch survives only outside the overlap.
        let old = RasterSnapshot(width: 200, height: 200, base: nil,
                                 baseRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                 patches: [patch(0, 0, 100, 100, value: 100)])
        var sourceAsset = imported(PixelBuffer(width: 200, height: 200))
        sourceAsset.raster = old

        let newRaster = RasterSnapshot.replacing(source: sourceAsset,
                                                 sourceRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                                 patches: [patch(50, 50, 100, 100, value: 200)],
                                                 crop: CGRect(x: 0, y: 0, width: 200, height: 200),
                                                 isMask: true)
        // Disjoint: no two patches overlap.
        for i in 0..<newRaster.patches.count {
            for j in (i + 1)..<newRaster.patches.count {
                let overlap = newRaster.patches[i].rect.intersection(newRaster.patches[j].rect)
                XCTAssertTrue(overlap.isNull || overlap.isEmpty, "patches must stay disjoint and flat")
            }
        }
        let image = newRaster.rendered(width: 200, height: 200)
        // New patch wins inside the overlap.
        XCTAssertEqual(RasterSample.grayNearest(image, fx: 75, fy: 75), 200)
        // Old patch survives outside it.
        XCTAssertEqual(RasterSample.grayNearest(image, fx: 10, fy: 10), 100)
        // Untouched area is white (mask raster outside base and patches).
        XCTAssertEqual(RasterSample.grayNearest(image, fx: 180, fy: 180), 255)
    }

    func testMaterializedPixelsStayFrozenAcrossLaterCommits() throws {
        let canvas = CGSize(width: 256, height: 256)
        let layer = ImageLayer(name: "Blank", blankSize: canvas)
        var settings = BrushSettings()
        settings.diameter = 40; settings.hardness = 1; settings.opacity = 0.5
        settings.red = 1; settings.green = 0; settings.blue = 0
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: canvas)
        try stroke.append(CGPoint(x: 128, y: 128))
        try stroke.flush()
        let snapshot = try stroke.paintSnapshot()
        let raster = try XCTUnwrap(snapshot.asset.raster)
        let frozen = try raster.makeImage().pixels.bytes
        XCTAssertTrue(raster.hasMaterializedPixels)
        // A second stroke on the same layer builds a NEW raster; the frozen
        // materialized pixels of the first are untouched.
        let layer2 = ImageLayer(id: layer.id, asset: snapshot.asset, name: layer.name, isVisible: true,
                                transform: snapshot.transform)
        let stroke2 = try BrushStroke(layer: layer2, mask: false, settings: settings, canvas: canvas)
        try stroke2.append(CGPoint(x: 64, y: 64))
        try stroke2.flush()
        _ = try stroke2.paintSnapshot()
        XCTAssertEqual(try raster.makeImage().pixels.bytes, frozen, "committed rasters are immutable")
    }

    func testRenderedOneToOneMatchesDirectPixelsAndThumbnailScales() throws {
        var pixels = PixelBuffer(width: 64, height: 64)
        for y in 0..<64 { for x in 0..<64 { pixels[x, y] = (UInt8(x * 4), UInt8(y * 4), 0, 255) } }
        let asset = imported(pixels)
        let raster = RasterSnapshot.replacing(source: asset,
                                              sourceRect: CGRect(x: 0, y: 0, width: 64, height: 64),
                                              patches: [rgbaPatch(32, 32, 32, 32, r: 255, g: 255, b: 255)],
                                              crop: CGRect(x: 0, y: 0, width: 64, height: 64))
        let full = raster.rendered(width: 64, height: 64)
        let s = RasterSample.rgbaNearest(full, fx: 10, fy: 10)
        XCTAssertEqual(s.r, 40); XCTAssertEqual(s.g, 40)
        let patched = RasterSample.rgbaNearest(full, fx: 40, fy: 40)
        XCTAssertEqual(patched.r, 255)
        // Thumbnail: max side 96 -> 64 stays 64 (factor 1); a larger raster shrinks.
        let thumb = try raster.thumbnail()
        XCTAssertEqual(thumb.width, 64)
        let big = RasterSnapshot(width: 2000, height: 1000, base: RasterImage(PortableImage(pixels)),
                                 baseRect: CGRect(x: 0, y: 0, width: 2000, height: 1000), patches: [])
        let bigThumb = try big.thumbnail()
        XCTAssertEqual(bigThumb.width, 96); XCTAssertEqual(bigThumb.height, 48)
    }

    func testAlignmentCarriesAcrossCommits() {
        // ENG-11: the halving-grid origin is the base's origin, or the painting
        // stroke's grid when painted from nothing — carried across commits so
        // patches never shift between zoom levels.
        let r1 = RasterSnapshot(width: 100, height: 100, base: nil,
                                baseRect: CGRect(x: 7, y: 9, width: 100, height: 100), patches: [])
        XCTAssertEqual(r1.alignment, CGPoint(x: 7, y: 9), "alignment defaults to the base rect origin")
        var pixels = PixelBuffer(width: 8, height: 8)
        var asset = imported(pixels)
        asset.raster = r1
        let r2 = RasterSnapshot.replacing(source: asset,
                                          sourceRect: CGRect(x: 7, y: 9, width: 100, height: 100),
                                          patches: [],
                                          crop: CGRect(x: 3, y: 5, width: 100, height: 100))
        // sourceRect.min + old.alignment - crop.min: (7+7-3, 9+9-5).
        XCTAssertEqual(r2.alignment, CGPoint(x: 11, y: 13), "alignment carries across commits")
    }
}
