// Tests for the portable BrushStroke engine (Compositor/Document/BrushStroke.swift
// port). Pin the kept macOS invariants on Linux: tile-scoped allocation, the
// stroke-wide opacity cap, coverage-then-recompose publishing, tail
// erase/redraw, selection clipping, clone/erase semantics, lift/move, the
// canvas passes (fill/gradient/clear), and BrushCommit's flatten + crop.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

private func blankLayer(_ size: CGSize) -> ImageLayer {
    ImageLayer(name: "Blank", blankSize: size)
}

private func imageLayer(_ pixels: PixelBuffer, name: String = "Image") -> ImageLayer {
    let portable = PortableImage(pixels)
    let asset = ImportedImage(image: RasterImage(portable),
                              thumbnail: RasterImage(RasterSample.thumbnail(portable)),
                              name: name)
    return ImageLayer(asset: asset, origin: .zero)
}

private func opaquePixels(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> PixelBuffer {
    var p = PixelBuffer(width: w, height: h)
    for y in 0..<h { for x in 0..<w { p[x, y] = (r, g, b, 255) } }
    return p
}

/// Sample the committed image at DOCUMENT coordinates (the commit crops to the
/// alpha bounds, so the buffer is crop-local).
private func rgbaAt(_ px: PortableImage, _ crop: CGRect, _ docX: CGFloat, _ docY: CGFloat)
    -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    RasterSample.rgbaNearest(px, fx: docX - crop.minX, fy: docY - crop.minY)
}

private func grayAt(_ px: PortableImage, _ crop: CGRect, _ docX: CGFloat, _ docY: CGFloat) -> UInt8 {
    RasterSample.grayNearest(px, fx: docX - crop.minX, fy: docY - crop.minY)
}

final class BrushStrokeTests: XCTestCase {

    // MARK: Stroke painting

    func testSingleDabPaintsCenterOfBlankLayerAndCommits() throws {
        let layer = blankLayer(CGSize(width: 64, height: 64))
        var settings = BrushSettings()
        settings.diameter = 20; settings.hardness = 1; settings.opacity = 1
        settings.red = 1; settings.green = 1; settings.blue = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        try stroke.append(CGPoint(x: 32, y: 32))
        try stroke.flush()
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        let crop = output.pixelBounds
        XCTAssertEqual(px.width, Int(crop.width)); XCTAssertEqual(px.height, Int(crop.height))
        let center = rgbaAt(px, crop, 31.5, 31.5)
        XCTAssertEqual(center.a, 255, "full-opacity hard dab must be opaque at its center")
        XCTAssertEqual(center.r, 255); XCTAssertEqual(center.g, 255); XCTAssertEqual(center.b, 255)
        let rim = rgbaAt(px, crop, 1, 1)
        XCTAssertEqual(rim.a, 0, "dab must not touch pixels outside its radius")
    }

    func testOpacityCapsTheWholeStrokeWhereItOverlapsItself() throws {
        let layer = blankLayer(CGSize(width: 64, height: 64))
        var settings = BrushSettings()
        settings.diameter = 24; settings.hardness = 1; settings.opacity = 0.5
        settings.red = 0; settings.green = 1; settings.blue = 0
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        // Cross the same center repeatedly from four directions.
        try stroke.append(CGPoint(x: 32, y: 20))
        try stroke.append(CGPoint(x: 32, y: 44))
        try stroke.append(CGPoint(x: 20, y: 32))
        try stroke.append(CGPoint(x: 44, y: 32))
        try stroke.flush()
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        for y in 0..<px.height {
            for x in 0..<px.width {
                let p = RasterSample.rgbaNearest(px, fx: CGFloat(x), fy: CGFloat(y))
                XCTAssertLessThanOrEqual(Float(p.a), 128, "overlapping dabs must never exceed the stroke opacity cap")
            }
        }
    }

    func testSoftBrushProducesPartialAlpha() throws {
        let layer = blankLayer(CGSize(width: 64, height: 64))
        var settings = BrushSettings()
        settings.diameter = 40; settings.hardness = 0; settings.opacity = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        try stroke.append(CGPoint(x: 32, y: 32))
        try stroke.flush()
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        let crop = output.pixelBounds
        let center = rgbaAt(px, crop, 31.5, 31.5)
        XCTAssertGreaterThanOrEqual(center.a, 250, "soft tip is (near) full strength at its center")
        // Half-way to the rim the falloff must be partial but present.
        let mid = rgbaAt(px, crop, 39.5, 31.5)
        XCTAssertGreaterThan(mid.a, 0, "soft rim must reach past the center")
        XCTAssertLessThan(mid.a, 255, "soft rim must be partial alpha")
        // The Gaussian falloff fades to ~zero approaching the rim (pixel-center
        // sampling, exactly like the CG radial gradient it replaces).
        let rim = rgbaAt(px, crop, 51, 31.5)
        XCTAssertLessThan(rim.a, 6, "falloff fades to zero at the rim")
    }

    func testSparseSamplesFollowACurveAndTailIsReplacedExactly() throws {
        // The provisional straight tail must be erased and replaced by the curve
        // piece; repeating flush() must be safe (no further change). The Catmull–Rom
        // piece between the two middle samples bulges BELOW the straight chord
        // (its neighbors pull it), so spline-only and chord-only pixels exist.
        let layer = blankLayer(CGSize(width: 120, height: 96))
        var settings = BrushSettings()
        settings.diameter = 8; settings.hardness = 1; settings.opacity = 1
        func runStroke() throws -> (PortableImage, CGRect) {
            let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 120, height: 96))
            try stroke.append(CGPoint(x: 10, y: 48))
            try stroke.append(CGPoint(x: 40, y: 20))
            try stroke.append(CGPoint(x: 70, y: 48))
            try stroke.append(CGPoint(x: 100, y: 20))
            try stroke.flush()
            try stroke.flush()
            let output = try BrushCommit.output(input: stroke.commitInput())
            return (output.asset.image.pixels, output.pixelBounds)
        }
        let (a, _) = try runStroke()
        let (b, _) = try runStroke()
        XCTAssertEqual(a.bytes, b.bytes, "flush() is idempotent and the engine is deterministic")
        let (px, crop) = try runStroke()
        // The final spline between (70,48) and (100,20) bulges below the straight
        // chord (measured: spline covers y 31..43 at x=85, the chord only 30..38).
        let splineOnly = rgbaAt(px, crop, 85, 41)
        XCTAssertGreaterThan(splineOnly.a, 0, "the spline bulges below the straight chord")
        // Chord-only region (on the provisional straight tail's line, above the
        // spline): never painted, proving the tail was replaced by the curve.
        let chordOnly = rgbaAt(px, crop, 85, 30)
        XCTAssertEqual(chordOnly.a, 0, "the provisional straight tail is replaced by the curve")
    }

    func testEraseTakesCoverageOutOfAlpha() throws {
        let layer = imageLayer(opaquePixels(64, 64, 200, 100, 50))
        var settings = BrushSettings()
        settings.diameter = 20; settings.hardness = 1; settings.opacity = 1
        settings.erasing = true
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        try stroke.append(CGPoint(x: 32, y: 32))
        try stroke.flush()
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        let crop = output.pixelBounds
        let center = rgbaAt(px, crop, 31.5, 31.5)
        XCTAssertEqual(center.a, 0, "full-opacity erase clears the layer's alpha")
        let far = rgbaAt(px, crop, 1, 1)
        XCTAssertEqual(far.a, 255, "erase must not touch pixels outside the tip")
    }

    func testCloneStampSamplesThroughTheOffset() throws {
        let layer = imageLayer(opaquePixels(64, 64, 0, 0, 0))
        var settings = BrushSettings()
        settings.diameter = 10; settings.hardness = 1; settings.opacity = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        // A clone source with a white square at (20..28, 20..28); painted at +20 offset.
        var clonePixels = PixelBuffer(width: 64, height: 64)
        for y in 20..<28 { for x in 20..<28 { clonePixels[x, y] = (255, 255, 255, 255) } }
        stroke.clone = (PortableImage(clonePixels), CGSize(width: 20, height: 20))
        try stroke.append(CGPoint(x: 42, y: 42))
        try stroke.flush()
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        let crop = output.pixelBounds
        let sampled = rgbaAt(px, crop, 41.5, 41.5)
        XCTAssertEqual(sampled.r, 255, "clone must copy the source pixel at the offset position")
        let outside = rgbaAt(px, crop, 60, 60)
        XCTAssertEqual(outside.r, 0, "clone only paints through the tip coverage")
    }

    // MARK: Tiles and bounds

    func testLargeBlankCanvasOnlyAllocatesTouchedTiles() throws {
        let layer = blankLayer(CGSize(width: 4000, height: 4000))
        var settings = BrushSettings()
        settings.diameter = 12; settings.hardness = 1; settings.opacity = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 4000, height: 4000))
        try stroke.append(CGPoint(x: 1000, y: 1000))
        try stroke.flush()
        let bounds = stroke.committedBounds
        XCTAssertLessThanOrEqual(bounds.width, 512, "commit must stay tile-local, not canvas-wide")
        XCTAssertLessThanOrEqual(bounds.height, 512)
        XCTAssertTrue(bounds.contains(CGPoint(x: 1000, y: 1000)))
    }

    func testPaintedBoundsTrimPaddingButKeepSoftEdges() throws {
        let layer = blankLayer(CGSize(width: 200, height: 200))
        var settings = BrushSettings()
        settings.diameter = 50; settings.hardness = 0; settings.opacity = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 200, height: 200))
        try stroke.append(CGPoint(x: 100, y: 100))
        try stroke.flush()
        let output = try BrushCommit.output(input: stroke.commitInput())
        let crop = output.pixelBounds
        // The crop must cover the soft rim (a faint outer ring stays) while the
        // empty padding around it is trimmed.
        XCTAssertGreaterThan(crop.width, 40, "soft rim pixels must be kept, not trimmed away")
        XCTAssertLessThan(crop.width, 200, "empty padding must be trimmed")
        // Every nonzero-alpha pixel in the buffer lies inside the reported crop.
        let px = output.asset.image.pixels
        for y in 0..<px.height {
            for x in 0..<px.width {
                let p = RasterSample.rgbaNearest(px, fx: CGFloat(x), fy: CGFloat(y))
                if p.a > 0 {
                    let docX = CGFloat(x) + crop.minX, docY = CGFloat(y) + crop.minY
                    XCTAssertTrue(docX >= crop.minX && docX < crop.maxX && docY >= crop.minY && docY < crop.maxY)
                }
            }
        }
    }

    func testPixelLimitRejectsOversizedEditBeforeAllocation() throws {
        let layer = blankLayer(CGSize(width: 4000, height: 4000))
        var settings = BrushSettings()
        settings.diameter = 500; settings.hardness = 1; settings.opacity = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 4000, height: 4000))
        stroke.pixelLimit = 10
        XCTAssertThrowsError(try stroke.append(CGPoint(x: 2000, y: 2000))) { error in
            guard case ProjectError.tooLarge = error else { return XCTFail("expected ProjectError.tooLarge") }
        }
    }

    // MARK: Masks

    func testMaskPaintingUsesTheGrayValue() throws {
        var maskPixels = MaskBuffer(width: 32, height: 32, fill: 128)
        _ = maskPixels
        let maskAsset = ImportedImage(mask: PortableImage(MaskBuffer(width: 32, height: 32, fill: 128)), name: "Mask")
        var layer = blankLayer(CGSize(width: 64, height: 64))
        layer.mask = LayerMask(asset: maskAsset)
        var settings = BrushSettings()
        settings.diameter = 10; settings.hardness = 1; settings.opacity = 1
        settings.red = 0.75 // gray value 191
        let stroke = try BrushStroke(layer: layer, mask: true, settings: settings, canvas: CGSize(width: 64, height: 64))
        try stroke.append(CGPoint(x: 10, y: 10))
        try stroke.flush()
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        XCTAssertEqual(px.kind, .mask)
        let painted = grayAt(px, output.pixelBounds, 9.5, 9.5)
        XCTAssertEqual(painted, 191, "mask painting fills the brush gray value")
    }

    func testExpandMaskFillsNewCanvasAreaWhite() {
        // A 32x32 mask expanded into a 64x64 crop: existing coverage stays aligned,
        // new canvas area has no pre-existing mask restriction.
        let asset = ImportedImage(mask: PortableImage(MaskBuffer(width: 32, height: 32, fill: 128)), name: "Mask")
        let input = BrushCommit.Input(width: 64, height: 64, source: nil, patches: [], mask: true, name: "Mask",
                                      sourceRect: CGRect(x: 0, y: 0, width: 32, height: 32))
        let expanded = BrushCommit.expandMask(asset, for: input, croppedTo: CGRect(x: 0, y: 0, width: 64, height: 64))
        let px = expanded.image.pixels
        XCTAssertEqual(px.width, 64)
        XCTAssertEqual(RasterSample.grayNearest(px, fx: 16, fy: 16), 128, "existing coverage stays aligned")
        XCTAssertEqual(RasterSample.grayNearest(px, fx: 60, fy: 60), 255, "new canvas area has no pre-existing mask restriction")
    }

    // MARK: Selection clipping

    func testClearPixelsOnlyErasesInsideTheSelection() throws {
        let layer = imageLayer(opaquePixels(64, 64, 90, 90, 200))
        var settings = BrushSettings()
        settings.diameter = 10; settings.hardness = 1; settings.opacity = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        // Rectangular selection covering the left half (coverage nil = full clip).
        stroke.selectionClip = SelectionClip(rect: CGRect(x: 0, y: 0, width: 32, height: 64), coverage: nil)
        try stroke.clearPixels()
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        let crop = output.pixelBounds
        let inside = rgbaAt(px, crop, 16, 32)
        XCTAssertEqual(inside.a, 0, "selected pixels are erased")
        let outside = rgbaAt(px, crop, 48, 32)
        XCTAssertEqual(outside.a, 255, "unselected pixels stay intact")
    }

    func testFillRespectsTheSelectionCoverage() throws {
        let layer = imageLayer(opaquePixels(64, 64, 0, 0, 0))
        var settings = BrushSettings()
        settings.diameter = 10; settings.hardness = 1; settings.opacity = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        // Selection covering the left half.
        let cov = MaskBuffer(width: 32, height: 64, fill: 255)
        stroke.selectionClip = SelectionClip(rect: CGRect(x: 0, y: 0, width: 32, height: 64), coverage: cov)
        try stroke.fill(PaletteColor(red: 0, green: 1, blue: 0))
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        let crop = output.pixelBounds
        let inside = rgbaAt(px, crop, 16, 32)
        XCTAssertEqual(inside.g, 255, "fill covers the selected region")
        let outside = rgbaAt(px, crop, 48, 32)
        XCTAssertEqual(outside.g, 0, "fill leaves the unselected region alone")
    }

    func testGradientFillRunsLinearRampOverTheCanvas() throws {
        let layer = imageLayer(opaquePixels(64, 64, 0, 0, 0))
        var settings = BrushSettings()
        settings.diameter = 10; settings.hardness = 1; settings.opacity = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        try stroke.fillGradient(.linear, from: CGPoint(x: 0, y: 32), to: CGPoint(x: 63, y: 32),
                                colors: [PaletteColor(red: 0, green: 0, blue: 0), PaletteColor(red: 1, green: 1, blue: 1)],
                                opacity: 1)
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        let crop = output.pixelBounds
        let left = rgbaAt(px, crop, 0.5, 32)
        XCTAssertLessThan(left.r, 8, "ramp starts black at the start point")
        let right = rgbaAt(px, crop, 62.5, 32)
        XCTAssertGreaterThan(right.r, 240, "ramp must reach near-white at the end point")
        let mid = rgbaAt(px, crop, 31.5, 32)
        XCTAssertEqual(mid.r, 128, accuracy: 6, "ramp midpoint is half strength")
    }

    // MARK: Lift and move

    func testLiftAndMoveCutsAHoleAndPlacesPixels() throws {
        let layer = imageLayer(opaquePixels(64, 64, 0, 128, 0))
        var settings = BrushSettings()
        settings.diameter = 10; settings.hardness = 1; settings.opacity = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        stroke.selectionClip = SelectionClip(rect: CGRect(x: 20, y: 20, width: 24, height: 24),
                                             coverage: MaskBuffer(width: 24, height: 24, fill: 255))
        XCTAssertTrue(try stroke.liftSelection(), "selection over pixels must lift")
        try stroke.moveLifted(by: CGSize(width: 10, height: 0))
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        let crop = output.pixelBounds
        // Left of the moved content: the hole the selection left behind.
        let hole = rgbaAt(px, crop, 24, 32)
        XCTAssertEqual(hole.a, 0, "the selection becomes a transparent hole")
        // Inside the moved content.
        let moved = rgbaAt(px, crop, 40, 32)
        XCTAssertEqual(moved.a, 255, "lifted pixels are placed at the offset")
        XCTAssertEqual(moved.g, 128)
    }

    // MARK: Commit flattening

    func testCommitFlattensSourcePlusPatchesInOrder() throws {
        let layer = imageLayer(opaquePixels(64, 64, 255, 0, 0))
        var settings = BrushSettings()
        settings.diameter = 20; settings.hardness = 1; settings.opacity = 1
        settings.red = 0; settings.green = 0; settings.blue = 1
        let stroke = try BrushStroke(layer: layer, mask: false, settings: settings, canvas: CGSize(width: 64, height: 64))
        try stroke.append(CGPoint(x: 32, y: 32))
        try stroke.flush()
        let output = try BrushCommit.output(input: stroke.commitInput())
        let px = output.asset.image.pixels
        let crop = output.pixelBounds
        let painted = rgbaAt(px, crop, 31.5, 31.5)
        XCTAssertEqual(painted.b, 255, "the stroke's color wins over the source where painted")
        let untouched = rgbaAt(px, crop, 2, 2)
        XCTAssertEqual(untouched.r, 255, "the source shows through where not painted")
    }

    func testSpacingFractionMatchesMacOS() {
        XCTAssertEqual(BrushStroke.spacingFraction(1), 0.015)
        XCTAssertEqual(BrushStroke.spacingFraction(0), 0.025)
    }
}
