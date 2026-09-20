// Tests for the portable filter execution layer (PixelFilter/FilterJob, the
// settings apply members, BlurTool, PixelInvert, ContentFill glue). Pin the
// macOS FilterTests/ImageAdjustment invariants on Linux with the reused C
// kernels and the portable blur/blend.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

private func solid(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> PortableImage {
    var p = PixelBuffer(width: w, height: h)
    for y in 0..<h { for x in 0..<w { p[x, y] = (r, g, b, 255) } }
    return PortableImage(p)
}

private func gradientRamp() -> PortableImage {
    var p = PixelBuffer(width: 256, height: 1)
    for x in 0..<256 { p[x, 0] = (UInt8(x), UInt8(x), UInt8(x), 255) }
    return PortableImage(p)
}

final class FilterExecutionTests: XCTestCase {

    func testCurvesApplyMapsThroughTheSpline() throws {
        // A simple invert: white where black was (points are 0-255 byte coords).
        let invert = { (x: Double) -> Double in 255 - x }
        var curves = CurvesSettings()
        // Invert the master curve only; inverting each channel too cancels it.
        curves.channels[0] = (0..<4).map {
            CurvePoint(x: Double($0) * 255 / 3, y: invert(Double($0) * 255 / 3))
        }
        let out = try curves.apply(gradientRamp())
        XCTAssertEqual(RasterSample.rgbaNearest(out, fx: 0, fy: 0).r, 255, accuracy: 2)
        XCTAssertEqual(RasterSample.rgbaNearest(out, fx: 255, fy: 0).r, 0, accuracy: 2)
        XCTAssertEqual(RasterSample.rgbaNearest(out, fx: 128, fy: 0).r, 127, accuracy: 3)
    }

    func testExposureApplyStopsToWhiteAndKeepsAlpha() throws {
        var exposure = ExposureSettings()
        exposure.exposure = ExposureSettings.exposureRange.upperBound
        let out = try exposure.apply(solid(4, 4, 128, 128, 128))
        let p = RasterSample.rgbaNearest(out, fx: 1, fy: 1)
        XCTAssertEqual(p.r, 255)
        XCTAssertEqual(p.a, 255, "exposure keeps alpha")
    }

    func testGradientMapEndsApplyInOrder() throws {
        var settings = GradientMapSettings()
        settings.shadows = AdjustmentColor(red: 0, green: 0, blue: 1)
        settings.highlights = AdjustmentColor(red: 1, green: 0, blue: 0)
        let out = try settings.apply(gradientRamp())
        let dark = RasterSample.rgbaNearest(out, fx: 0, fy: 0)
        let light = RasterSample.rgbaNearest(out, fx: 255, fy: 0)
        XCTAssertEqual(dark.b, 255, "the darkest tone takes the shadows color")
        XCTAssertEqual(light.r, 255, "the lightest tone takes the highlights color")
    }

    func testGrainIsDeterministicPerSeedAndKeepsAlpha() throws {
        var settings = GrainSettings()
        settings.amount = 60
        let image = solid(32, 32, 128, 128, 128)
        let a = try settings.apply(image, seed: 7)
        let b = try settings.apply(image, seed: 7)
        let c = try settings.apply(image, seed: 8)
        XCTAssertEqual(a.bytes, b.bytes, "the same seed gives the same grain")
        XCTAssertNotEqual(a.bytes, c.bytes, "a different seed gives a different pattern")
        for i in stride(from: 3, to: a.bytes.count, by: 4) {
            XCTAssertEqual(a.bytes[i], 255, "grain keeps alpha")
        }
    }

    func testGaussianBlurFilterSpreadsTheLayer() throws {
        let job = FilterJob(kind: .gaussianBlur, image: solid(8, 8, 255, 255, 255),
                            settings: FilterSettings(), scale: 1, selection: nil, mapping: .identity)
        let out = try PixelFilter.run(job)
        let edge = RasterSample.rgbaNearest(out, fx: 0, fy: 4)
        let middle = RasterSample.rgbaNearest(out, fx: 4, fy: 4)
        XCTAssertLessThan(edge.a, middle.a, "the blur softens the layer's edges")
    }

    func testMotionBlurSmearsAlongTheAngle() throws {
        var settings = FilterSettings()
        settings.distance = 30
        settings.angle = 0 // horizontal
        var p = PixelBuffer(width: 32, height: 8)
        p[16, 4] = (255, 255, 255, 255)
        let job = FilterJob(kind: .motionBlur, image: PortableImage(p),
                            settings: settings, scale: 1, selection: nil, mapping: .identity)
        let out = try PixelFilter.run(job)
        let spread = RasterSample.rgbaNearest(out, fx: 8, fy: 4)
        XCTAssertGreaterThan(spread.a, 0, "the streak reaches horizontally")
        let offAxis = RasterSample.rgbaNearest(out, fx: 16, fy: 1)
        XCTAssertEqual(offAxis.a, 0, "nothing smears perpendicular to the angle")
    }

    func testAddNoiseIsDeterministicAndKeepsAlpha() throws {
        var settings = FilterSettings()
        settings.amount = 80
        let image = solid(16, 16, 100, 100, 100)
        func run(seed: UInt32) throws -> PortableImage {
            var job = FilterJob(kind: .addNoise, image: image, settings: settings, scale: 1, selection: nil, mapping: .identity)
            job.seed = seed
            return try PixelFilter.run(job)
        }
        let a = try run(seed: 42)
        let b = try run(seed: 42)
        XCTAssertEqual(a.bytes, b.bytes, "the same seed gives the same noise")
        for i in stride(from: 3, to: a.bytes.count, by: 4) {
            XCTAssertEqual(a.bytes[i], 255, "noise keeps alpha")
        }
    }

    func testLensCorrectionAtZeroIsIdentity() throws {
        var settings = FilterSettings()
        settings.distortion = 0
        let image = gradientRamp()
        let job = FilterJob(kind: .lensCorrection, image: image, settings: settings,
                            scale: 1, selection: nil, mapping: .identity)
        let out = try PixelFilter.run(job)
        XCTAssertEqual(out.bytes, image.bytes, "k=0 lens correction is the identity")
    }

    func testRemoveBackgroundThrowsModelMissingUntilTheModelLands() {
        let job = FilterJob(kind: .removeBackground, image: solid(4, 4, 0, 0, 0),
                            settings: FilterSettings(), scale: 1, selection: nil, mapping: .identity)
        XCTAssertThrowsError(try PixelFilter.run(job)) { error in
            guard case FilterError.modelMissing = error else { return XCTFail("expected FilterError.modelMissing") }
        }
    }

    func testContentFillNeedsASelection() {
        let job = FilterJob(kind: .contentAwareFill, image: solid(8, 8, 255, 0, 0),
                            settings: FilterSettings(), scale: 1, selection: nil, mapping: .identity)
        XCTAssertThrowsError(try PixelFilter.run(job)) { error in
            guard case ContentFill.Failure.noSource = error else { return XCTFail("expected noSource") }
        }
    }

    func testFilterRunBlendsThroughSelection() throws {
        var settings = FilterSettings()
        settings.amount = 200
        let image = solid(8, 8, 0, 0, 0)
        // Half-selection: the left half takes the filter, the right half stays.
        let clip = SelectionClip(rect: CGRect(x: 0, y: 0, width: 4, height: 8),
                                 coverage: MaskBuffer(width: 4, height: 8, fill: 255))
        var job = FilterJob(kind: .addNoise, image: image, settings: settings, scale: 1,
                            selection: clip, mapping: .identity)
        job.seed = 1
        let out = try PixelFilter.run(job)
        let left = RasterSample.rgbaNearest(out, fx: 1, fy: 4)
        let right = RasterSample.rgbaNearest(out, fx: 6, fy: 4)
        XCTAssertNotEqual(left.r, 0, "the selected half is filtered")
        XCTAssertEqual(right.r, 0, "the unselected half stays original")
    }

    // MARK: PixelInvert

    func testInvertKeepsTransparencyInPremultipliedSpace() throws {
        var p = PixelBuffer(width: 2, height: 1)
        p[0, 0] = (100, 50, 25, 128) // premultiplied
        p[1, 0] = (0, 0, 0, 0)
        let inverted = try PixelInvert.run(PixelInvert.Job(image: PortableImage(p), isMask: false,
                                                pixelToDocument: CGAffineTransform.identity, selection: nil))
        let q = RasterSample.rgbaNearest(inverted, fx: 0, fy: 0)
        XCTAssertEqual(q.a, 128)
        XCTAssertEqual(q.r, 28, accuracy: 1) // 128 - 100
        XCTAssertEqual(q.g, 78, accuracy: 1)
        XCTAssertEqual(q.b, 103, accuracy: 1)
        let transparent = RasterSample.rgbaNearest(inverted, fx: 1, fy: 0)
        XCTAssertEqual(transparent.a, 0, "transparent pixels stay transparent")
    }

    func testInvertMaskFlipsTone() throws {
        let mask = PortableImage(MaskBuffer(width: 2, height: 1, bytes: [0, 200]))
        let inverted = try PixelInvert.run(PixelInvert.Job(image: mask, isMask: true,
                                                pixelToDocument: CGAffineTransform.identity, selection: nil))
        XCTAssertEqual(inverted.bytes[0], 255)
        XCTAssertEqual(inverted.bytes[1], 55)
    }

    // MARK: trimmed

    func testTrimmedCropsEmptyPaddingAndKeepsPlacement() throws {
        var p = PixelBuffer(width: 16, height: 16)
        for y in 4..<10 { for x in 6..<12 { p[x, y] = (255, 0, 0, 255) } }
        let placed = LayerTransform(origin: CGPoint(x: 32, y: 32), size: CGSize(width: 16, height: 16))
        let (trimmed, transform) = try PixelFilter.trimmed(PortableImage(p), placed: placed)
        XCTAssertEqual(trimmed.width, 6)
        XCTAssertEqual(trimmed.height, 6)
        XCTAssertEqual(transform.size, CGSize(width: 6, height: 6))
        // The content's middle stays put in document space.
        let toDocument = BrushRaster.pixelToDocument(placed, width: 16, height: 16)
        let oldMiddle = CGPoint(x: 9, y: 7).applying(toDocument)
        let newMiddle = CGPoint(x: transform.origin.x + 3, y: transform.origin.y + 3)
        XCTAssertEqual(newMiddle.x, oldMiddle.x, accuracy: 0.001)
        XCTAssertEqual(newMiddle.y, oldMiddle.y, accuracy: 0.001)
    }

    func testRGBAFiltersRejectMaskStorageAndInvalidScale() {
        let mask = PortableImage(MaskBuffer(width: 8, height: 8, fill: 255))
        for kind in FilterKind.allCases {
            XCTAssertThrowsError(try PixelFilter.run(FilterJob(kind: kind, image: mask,
                settings: FilterSettings(), scale: 1, selection: nil, mapping: .identity)))
        }
        for scale: CGFloat in [0, -1, .infinity, .nan, 2] {
            XCTAssertThrowsError(try PixelFilter.run(FilterJob(kind: .motionBlur, image: solid(8, 8, 0, 0, 0),
                settings: FilterSettings(), scale: scale, selection: nil, mapping: .identity)))
        }
        XCTAssertThrowsError(try PixelInvert.run(.init(image: mask, isMask: false,
            pixelToDocument: .identity, selection: nil)))
    }

    func testRotatedRevealMaskBlurDoesNotDarkenBoundingBoxCorners() throws {
        var layer = ImageLayer(name: "Masked", blankSize: CGSize(width: 20, height: 20))
        layer.transform.origin = CGPoint(x: 20, y: 20)
        layer.transform.rotation = 45
        layer.mask = LayerMask.solid(revealing: true)
        let document = CanvasDocument(width: 60, height: 60, layers: [layer])
        for sampling in [LayerSampling.nearest, .high] {
            layer.transform.sampling = sampling
            let sample = try XCTUnwrap(BlurTool.blurSample(layer: layer, document: document, mask: true,
                diameter: 15, displayedTransform: layer.transform, displayedMaskPlacement: nil))
            XCTAssertTrue(sample.bytes.allSatisfy { $0 == 255 }, "A reveal-all mask must remain white after rotation and blur")
        }
    }

    func testSmoothLayerDrawAtOneToOneKeepsPixelCentersAndAlpha() {
        var pixels = PixelBuffer(width: 2, height: 2)
        pixels[0, 0] = (255, 0, 0, 255)
        pixels[1, 0] = (0, 128, 0, 128)
        pixels[0, 1] = (0, 0, 255, 255)
        pixels[1, 1] = (0, 0, 0, 0)
        let placed = LayerTransform(origin: .zero, size: CGSize(width: 2, height: 2))
        var rendered = PixelBuffer(width: 2, height: 2)
        LayerRenderer.draw(RasterImage(PortableImage(pixels)), transform: placed, center: placed.center, into: &rendered)
        XCTAssertEqual(rendered.bytes, pixels.bytes)
    }

    func testLayerDrawUsesRequestedCenterWhenScaling() {
        let pixels = RasterImage(solid(2, 2, 255, 0, 0))
        let placed = LayerTransform(origin: .zero, size: CGSize(width: 2, height: 2))
        var rendered = PixelBuffer(width: 10, height: 10)
        LayerRenderer.draw(pixels, transform: placed, center: CGPoint(x: 5, y: 5), scale: 2, into: &rendered)
        XCTAssertEqual(rendered[0, 0].a, 0)
        XCTAssertEqual(rendered[3, 3].a, 255)
        XCTAssertEqual(rendered[6, 6].a, 255)
        XCTAssertEqual(rendered[7, 7].a, 0)
    }
}
