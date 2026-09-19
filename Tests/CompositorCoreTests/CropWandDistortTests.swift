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
}