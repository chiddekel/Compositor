// Tests for the portable Crop geometry, Magic Wand settings, Brush settings,
// GuidedMatte kernels, and DistortWarp perspective math. Pin the unchanged macOS
// logic on Linux. Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class CropWandDistortTests: XCTestCase {

    // MARK: CropGeometry

    func testCropGeometrySnappedRoundsToIntegers() {
        let r = CropGeometry.snapped(CGRect(x: 10.4, y: 20.6, width: 100.2, height: 50.8))
        XCTAssertEqual(r.minX, 10)
        XCTAssertEqual(r.minY, 21)
        XCTAssertEqual(r.width, 101)   // maxX 110.6 → 111, minus 10
        XCTAssertEqual(r.height, 50)   // maxY 71.4 → 71, minus 21
    }

    func testCropGeometryValidBounds() {
        XCTAssertTrue(CropGeometry.valid(CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertFalse(CropGeometry.valid(CGRect(x: 0, y: 0, width: 0, height: 100)))
        XCTAssertFalse(CropGeometry.valid(CGRect(x: 0, y: 0, width: 30_001, height: 100)))
        XCTAssertFalse(CropGeometry.valid(CGRect(x: 2_000_000, y: 0, width: 100, height: 100)))
    }

    func testCropGeometryCreateAspectRatiostartsFromDominantAxis() {
        // dx=100, dy=30, ratio=2: |dx| > |dy|*2 (100 > 60) → dy grows to 50.
        let r = CropGeometry.create(from: .zero, to: CGPoint(x: 100, y: 30), ratio: 2)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func testCropGeometryCreateSymmetricGrowsFromCenter() {
        let r = CropGeometry.create(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 100, y: 80),
                                    ratio: nil, symmetric: true)
        // dx=50, dy=30 → frame (0,20,100,60) centered on (50,50).
        XCTAssertEqual(r, CGRect(x: 0, y: 20, width: 100, height: 60))
    }

    // MARK: CropDrag

    func testCropDragCreateUsesCropGeometry() {
        let drag = CropDrag(start: .zero, original: .zero, mode: .create)
        XCTAssertEqual(drag.updated(to: CGPoint(x: 100, y: 50), ratio: nil),
                     CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func testCropDragMoveOffsetsByPointerDelta() {
        let drag = CropDrag(start: CGPoint(x: 20, y: 20), original: CGRect(x: 10, y: 10, width: 20, height: 20), mode: .move)
        XCTAssertEqual(drag.updated(to: CGPoint(x: 30, y: 30), ratio: nil),
                     CGRect(x: 20, y: 20, width: 20, height: 20))
    }

    func testCropDragResizeReturnsValidRect() {
        // The resize mode delegates to `TransformDrag.updated` (already tested in
        // LayerTransformTests); here we only confirm CropDrag wires it through and
        // snaps to a valid crop rectangle.
        let drag = CropDrag(start: CGPoint(x: 100, y: 100),
                            original: CGRect(x: 0, y: 0, width: 100, height: 100), mode: .resize(2))
        let next = drag.updated(to: CGPoint(x: 150, y: 150), ratio: nil)
        XCTAssertTrue(CropGeometry.valid(next))
        XCTAssertGreaterThanOrEqual(next.width, 1)
        XCTAssertGreaterThanOrEqual(next.height, 1)
    }

    // MARK: CropSnap

    func testCropSnapMoveSnapsEdgesWithinTolerance() {
        let snap = CropSnap(xs: [50], ys: [50], tolerance: 2)
        let drag = CropDrag(start: .zero, original: CGRect(x: 48, y: 48, width: 10, height: 10), mode: .move)
        let r = snap.apply(CGRect(x: 48, y: 48, width: 10, height: 10), drag: drag,
                          point: .zero, ratio: nil)
        XCTAssertEqual(r.minX, 50)
        XCTAssertEqual(r.minY, 50)
        XCTAssertEqual(r.width, 10)
    }

    func testCropSnapZeroToleranceIsNoOp() {
        let snap = CropSnap(xs: [50], ys: [50], tolerance: 0)
        let drag = CropDrag(start: .zero, original: CGRect(x: 48, y: 48, width: 10, height: 10), mode: .move)
        let r = snap.apply(CGRect(x: 48, y: 48, width: 10, height: 10), drag: drag, point: .zero, ratio: nil)
        XCTAssertEqual(r, CGRect(x: 48, y: 48, width: 10, height: 10))
    }

    // MARK: WandSampleSize / WandSettings

    func testWandSampleSizeRadiusAndTitle() {
        XCTAssertEqual(WandSampleSize.point.radius, 0)
        XCTAssertEqual(WandSampleSize.threeByThree.radius, 1)
        XCTAssertEqual(WandSampleSize.fiveByFive.radius, 2)
        XCTAssertEqual(WandSampleSize.point.title, "Point Sample")
        XCTAssertEqual(WandSampleSize.threeByThree.title, "3 by 3 Average")
        XCTAssertEqual(WandSampleSize.fiveByFive.title, "5 by 5 Average")
    }

    func testWandSettingsDefaults() {
        let s = WandSettings()
        XCTAssertEqual(s.tolerance, 32)
        XCTAssertEqual(s.sampleSize, .point)
        XCTAssertTrue(s.contiguous)
        XCTAssertFalse(s.sampleAllLayers)
    }

    func testMagicWandFailureDescriptions() {
        XCTAssertNotNil(MagicWand.Failure.tooDetailed.errorDescription)
        XCTAssertNotNil(MagicWand.Failure.memory.errorDescription)
    }

    // MARK: SpotHealingMode / BrushSettings

    func testSpotHealingModeCases() {
        XCTAssertEqual(SpotHealingMode.allCases.count, 3)
        XCTAssertEqual(SpotHealingMode.contentAware.rawValue, "Content-Aware")
        XCTAssertEqual(SpotHealingMode.createTexture.rawValue, "Create Texture")
        XCTAssertEqual(SpotHealingMode.proximityMatch.rawValue, "Proximity Match")
    }

    func testBrushSettingsDefaults() {
        let b = BrushSettings()
        XCTAssertEqual(b.diameter, 40)
        XCTAssertEqual(b.hardness, 1)
        XCTAssertEqual(b.opacity, 1)
        XCTAssertFalse(b.erasing)
        XCTAssertFalse(b.healing)
        XCTAssertEqual(b.healingMode, .contentAware)
    }

    // MARK: GuidedMatte

    func testGuidedMatteBoxUniformIsUniform() {
        let n = 5
        let src = [Float](repeating: 0.5, count: n * n)
        let out = GuidedMatte.box(src, width: n, height: n, radius: 1)
        XCTAssertEqual(out.count, n * n)
        XCTAssertTrue(out.allSatisfy { abs($0 - 0.5) < 1e-6 })
    }

    func testGuidedMatteBoxRadiusZeroIsIdentity() {
        let src: [Float] = [0, 0.25, 0.5, 0.75, 1, 0.1, 0.2, 0.3, 0.4]
        let out = GuidedMatte.box(src, width: 3, height: 3, radius: 0)
        XCTAssertEqual(out, src)
    }

    func testGuidedMatteFilterUniformIsUniform() {
        let n = 4
        let mask = [Float](repeating: 0.5, count: n * n)
        let guide = [Float](repeating: 0.5, count: n * n)
        let out = GuidedMatte.filter(mask: mask, guide: guide, width: n, height: n, radius: 1, epsilon: 0.01)
        XCTAssertTrue(out.allSatisfy { abs($0 - 0.5) < 1e-5 })
    }

    func testGuidedMatteFilterClampsToUnitRange() {
        // A step in the guide at the midpoint; result must stay within 0...1.
        var guide = [Float](repeating: 0, count: 9)
        for i in 4..<9 { guide[i] = 1 }
        let mask = [Float](repeating: 0.5, count: 9)
        let out = GuidedMatte.filter(mask: mask, guide: guide, width: 3, height: 3, radius: 1, epsilon: 0.001)
        XCTAssertTrue(out.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    // MARK: DistortWarp

    func testDistortWarpCornersOfAxisAlignedTransform() {
        let t = LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10))
        let c = DistortWarp.corners(of: t)
        XCTAssertEqual(c.count, 4)
        XCTAssertEqual(c[0], CGPoint(x: 0, y: 0))
        XCTAssertEqual(c[1], CGPoint(x: 10, y: 0))
        XCTAssertEqual(c[2], CGPoint(x: 10, y: 10))
        XCTAssertEqual(c[3], CGPoint(x: 0, y: 10))
    }

    func testDistortWarpIsUsableConvexAndBowtie() {
        let convex = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        XCTAssertTrue(DistortWarp.isUsable(convex))
        // Bow-tie (twisted) order is not usable.
        let bowtie = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)]
        XCTAssertFalse(DistortWarp.isUsable(bowtie))
        XCTAssertFalse(DistortWarp.isUsable([CGPoint](repeating: .zero, count: 3)))
    }

    func testDistortWarpHomographyIdentityQuadIsIdentity() {
        let unit = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let map = DistortWarp.homography(unit)
        let p = CGPoint(x: 0.3, y: 0.7)
        let q = map(p)
        XCTAssertEqual(q.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(q.y, p.y, accuracy: 1e-9)
    }

    func testDistortWarpHomographyMapsUnitCornersToQuad() {
        let quad = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        let map = DistortWarp.homography(quad)
        let a = map(CGPoint(x: 0, y: 0))
        let b = map(CGPoint(x: 1, y: 1))
        XCTAssertEqual(a.x, 0, accuracy: 1e-9); XCTAssertEqual(a.y, 0, accuracy: 1e-9)
        XCTAssertEqual(b.x, 100, accuracy: 1e-9); XCTAssertEqual(b.y, 100, accuracy: 1e-9)
    }

    func testDistortWarpImageCornersNoFlip() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        let ic = DistortWarp.imageCorners(corners, flipX: false, flipY: false)
        XCTAssertEqual(ic.topLeft, CGPoint(x: 0, y: 0))
        XCTAssertEqual(ic.topRight, CGPoint(x: 10, y: 0))
        XCTAssertEqual(ic.bottomRight, CGPoint(x: 10, y: 10))
        XCTAssertEqual(ic.bottomLeft, CGPoint(x: 0, y: 10))
    }

    func testDistortWarpImageCornersFlipXSwapsLeftRight() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        let ic = DistortWarp.imageCorners(corners, flipX: true, flipY: false)
        XCTAssertEqual(ic.topLeft, CGPoint(x: 10, y: 0))
        XCTAssertEqual(ic.topRight, CGPoint(x: 0, y: 0))
    }

    func testDistortWarpCarriedReturnsFourFinitePoints() {
        // `carried` is a verbatim port of the macOS mask-placement-carry math. Its
        // concatenation chain order is inherited from CoreGraphics' convention (the
        // same one `pixelToDocument`/`unitToDocument` rely on, which are tested
        // elsewhere); the exact carried output is pinned against real macOS distort
        // behavior at the raster milestone, not here. We assert the structural
        // contract: four finite points for a usable warp.
        let t = LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10))
        let corners = DistortWarp.corners(of: t)
        XCTAssertTrue(DistortWarp.isUsable(corners))
        let carried = DistortWarp.carried(t, by: t, to: corners)
        XCTAssertEqual(carried.count, 4)
        XCTAssertTrue(carried.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    // MARK: DistortWarp raster (port of DistortTests.distorting… / warps into the shape)

    /// Four distinct quadrant colors to make resample landmarks unambiguous.
    private func quadrantImage(_ w: Int, _ h: Int) -> RasterImage {
        var p = PixelBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let top = y * 2 < h, left = x * 2 < w
                p[x, y] = top && left ? (255, 0, 0, 255)      // top-left: red
                    : top ? (0, 255, 0, 255)                  // top-right: green
                    : left ? (0, 0, 255, 255)                 // bottom-left: blue
                    : (255, 255, 0, 255)                      // bottom-right: yellow
            }
        }
        return RasterImage(PortableImage(p))
    }

    func testDistortWarpIdentityLeavesPixelsUntouched() throws {
        let t = LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 20, height: 20))
        let src = quadrantImage(20, 20)
        let warped = try DistortWarp.warp(src, transform: t, corners: DistortWarp.corners(of: t), isMask: false)
        XCTAssertEqual(warped.transform, t)
        XCTAssertEqual(warped.image.pixels.bytes, src.pixels.bytes)
    }

    func testDistortWarpResamplesQuadrantColorsAcrossTheShape() throws {
        // 2 × 2 quadrant image into a slanted quad: intact, sampled at the corners.
        let shape = [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30)]
        let t = LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 20, height: 20))
        let src = quadrantImage(2, 2)
        let warped = try DistortWarp.warp(src, transform: t, corners: shape, isMask: false)
        XCTAssertEqual(warped.transform.origin, CGPoint(x: 10, y: 10))
        XCTAssertEqual(warped.transform.size, CGSize(width: 50, height: 20))
        XCTAssertEqual(warped.image.pixels.width, 50)
        XCTAssertEqual(warped.image.pixels.height, 20)
        let pixels = warped.image.pixels
        func sample(_ u: CGFloat, _ v: CGFloat) -> (Int, Int, Int, Int) {
            // Document point of a unit coordinate under the same homography, then the output
            // pixel containing it. Round-trips forward/inverse; tells us the source color landed.
            let map = DistortWarp.homography(shape)
            let doc = map(CGPoint(x: u, y: v))
            let x = Int(floor(doc.x - 10)), y = Int(floor(doc.y - 10))
            let i = (y * pixels.width + x) * 4
            return (Int(pixels.bytes[i]), Int(pixels.bytes[i + 1]), Int(pixels.bytes[i + 2]), Int(pixels.bytes[i + 3]))
        }
        // Distinct quadrant centers land distinct colors. Bilinear blends each sample with the
        // transparent border at the source edge, so colors carry through premultiplied (173-ish
        // alpha) — the assertion is dominance, not full 255.
        let tl = sample(0.15, 0.15), tr = sample(0.85, 0.15), bl = sample(0.15, 0.85), br = sample(0.85, 0.85)
        XCTAssertTrue(tl.0 > 120 && tl.1 < 40 && tl.2 < 40, "TL \(tl)")
        XCTAssertTrue(tr.1 > 120 && tr.0 < 40 && tr.2 < 40, "TR \(tr)")
        XCTAssertTrue(bl.2 > 120 && bl.0 < 40 && bl.1 < 40, "BL \(bl)")
        XCTAssertTrue(br.0 > 120 && br.1 > 120, "BR \(br)")
    }

    func testDistortWarpMaskWarpKeepsToneAndFillsBackground() throws {
        // Uniform 80% mask into a slanted quad; the area past the shape keeps the
        // requested background tone instead of going black.
        let src = RasterImage(PortableImage(MaskBuffer(width: 2, height: 2, fill: 204)))
        let shape = [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30)]
        let t = LayerTransform(origin: .zero, size: CGSize(width: 20, height: 20))
        let warped = try DistortWarp.warpMask(src, transform: t, corners: shape, background: 0.25)
        XCTAssertEqual(warped.image.pixels.width, 50)
        XCTAssertEqual(warped.image.pixels.height, 20)
        XCTAssertEqual(warped.image.pixels.bytesPerRow, 50)
        let pixels = warped.image.pixels
        func tone(_ x: Int, _ y: Int) -> Int { Int(pixels.bytes[y * 50 + x]) }
        // Local (30, 5) is doc (40, 15), inside the quad (right edge at that height crosses x ≈ 52.5) → 204.
        XCTAssertEqual(tone(30, 5), 204)
        // Local (45, 19) is doc (55, 29), past the right edge at that height (x ≈ 31.5) → the 0.25 background.
        XCTAssertEqual(tone(45, 19), 64)
    }

    func testDistortWarpTrimmedHugsVisiblePixels() throws {
        // A 40 × 20 layer transparent except a 10 × 10 red square; warped, its layer
        // bounds must hug the visible square, not the shape's whole frame.
        var p = PixelBuffer(width: 40, height: 20)
        for y in 5..<15 { for x in 15..<25 { p[x, y] = (255, 0, 0, 255) } }
        let src = RasterImage(PortableImage(p))
        let t = LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 40, height: 20))
        let shape = [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 50, y: 30), CGPoint(x: 10, y: 30)]
        let trimmed = try DistortWarp.warpTrimmed(src, transform: t, corners: shape)
        XCTAssertLessThan(trimmed.transform.size.width, 20, "layer bounds \(trimmed.transform.size)")
        XCTAssertLessThanOrEqual(trimmed.transform.size.height, 12)
        XCTAssertGreaterThanOrEqual(trimmed.transform.origin.x, 20)
        XCTAssertGreaterThanOrEqual(trimmed.transform.origin.y, 14)
        // The square is still somewhere inside the trimmed layer.
        let pixels = trimmed.image.pixels
        let alpha = pixels.bytes.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count
        XCTAssertGreaterThan(alpha / 4, 0)
    }

    func testDistortCommitWarpsLayerAsOneUndoStepAndTrims() throws {
        // Port of DistortTests.distortingWarpsTheLayerIntoTheShapeAsOneUndoStep: the
        // corners draft only commits on window action, as one undo step, with the layer
        // resampled over the shape; undo restores the original pixels.
        let session = EditorSession()
        var doc = CanvasDocument(width: 100, height: 60)
        var p = PixelBuffer(width: 20, height: 20)
        for y in 0..<20 { for x in 0..<20 { p[x, y] = (255, 0, 0, 255) } }
        let red = RasterImage(PortableImage(p))
        let shape = [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30)]
        session.replaceCurrentDocument(doc)
        var layer = ImageLayer(asset: ImportedImage(image: red, thumbnail: red, name: "Red"), origin: .zero)
        layer.transform = LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 20, height: 20))
        doc.layers = [layer]
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(layer.id)
        session.beginTransform()
        session.beginDistort()
        let edit = try XCTUnwrap(session.transformEdit)
        XCTAssertEqual(edit.corners?.count, 4)
        // Twisted corners are refused; the edit keeps the draft's initial corners.
        session.previewCorners([shape[0], shape[2], shape[1], shape[3]])
        XCTAssertEqual(session.transformEdit?.corners?[1], CGPoint(x: 30, y: 10))
        session.previewCorners(shape)
        XCTAssertEqual(session.transformEdit?.corners?[1], CGPoint(x: 60, y: 10))
        let count = session.history.undoCount
        session.commitTransform()
        XCTAssertNil(session.transformEdit)
        XCTAssertEqual(session.history.undoCount, count + 1)
        let transform = try XCTUnwrap(session.activeLayer?.transform)
        XCTAssertEqual(transform.origin, CGPoint(x: 10, y: 10))
        XCTAssertEqual(transform.size, CGSize(width: 50, height: 20))
        XCTAssertEqual(transform.rotation, 0)
        let result = try session.render()
        func alpha(_ x: Int, _ y: Int) -> Int { Int(result.bytes[(y * result.width + x) * 4 + 3]) }
        XCTAssertEqual(alpha(50, 12), 255)  // inside the stretched top-right
        XCTAssertEqual(alpha(15, 25), 255)
        XCTAssertEqual(alpha(50, 28), 0)    // outside the slanted right edge
        XCTAssertEqual(alpha(80, 12), 0)
        try session.undo()
        XCTAssertEqual(session.activeLayer?.transform.size, CGSize(width: 20, height: 20))
    }
}