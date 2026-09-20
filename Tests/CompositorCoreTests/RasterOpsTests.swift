// Tests for the portable raster core: LayerRenderer placement draw + blend
// kernels, GaussianBlur box approximation, WarpStroke smudge/liquify, and
// PixelAdjust coverage/blend. Pin the macOS invariants these replace:
// premultiplied source-over placement, opacity exactly once, blend-mode
// formulas (incl. the two CG got wrong), mask-edge clamp vs transparent-pad
// blur, and the smudge carry / forward-warp behavior.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

private func solid(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> PortableImage {
    var p = PixelBuffer(width: w, height: h)
    for y in 0..<h { for x in 0..<w { p[x, y] = (r, g, b, 255) } }
    return PortableImage(p)
}

private func halfRedBlue() -> PortableImage {
    // 4x2: solid red left half, solid blue right half (interior samples stay
    // clear of pixel boundaries and edge fade).
    var p = PixelBuffer(width: 4, height: 2)
    for y in 0..<2 { for x in 0..<4 { p[x, y] = x < 2 ? (255, 0, 0, 255) : (0, 0, 255, 255) } }
    return PortableImage(p)
}

final class RasterOpsTests: XCTestCase {

    // MARK: Blend kernels

    func testBlendKernelFormulasMatchTheSpec() {
        // Separable modes at Cb=0.4, Cs=0.8 (rounded to byte steps where sensible).
        let cb: Float = 0.4, cs: Float = 0.8
        // Over an opaque backdrop: the blend result shows through directly.
        func pixel(_ mode: LayerBlendMode) -> Float {
            LayerRenderer.blendPixel(mode, (cs, cs, cs), 1, (cb, cb, cb), 1).0
        }
        XCTAssertEqual(pixel(.normal), cs, accuracy: 1e-6)
        XCTAssertEqual(pixel(.multiply), cb * cs, accuracy: 1e-6)
        XCTAssertEqual(pixel(.screen), cb + cs - cb * cs, accuracy: 1e-6)
        XCTAssertEqual(pixel(.darken), cb, accuracy: 1e-6)
        XCTAssertEqual(pixel(.lighten), cs, accuracy: 1e-6)
        XCTAssertEqual(pixel(.difference), 0.4, accuracy: 1e-6)
        XCTAssertEqual(pixel(.colorDodge), 1, accuracy: 1e-6) // min(1, 0.8/0.6)
        XCTAssertEqual(pixel(.colorBurn), 1 - min(1, 0.2 / 0.4), accuracy: 1e-6)
        XCTAssertEqual(pixel(.overlay), 2 * 0.4 * 0.8, accuracy: 1e-6) // cb <= 0.5 branch
    }

    func testColorDodgeAndBurnRespectSourceTransparency() {
        // The two modes Core Graphics got wrong on macOS: a half-transparent
        // source must blend half-way, not stamp a hard edge. αs = 0.5 over an
        // opaque backdrop: Co = αs·αb·B + (1-αs)·αb·Cb.
        let out = LayerRenderer.blendPixel(.colorDodge, (1, 1, 1), 0.5, (0.5, 0.5, 0.5), 1)
        // αo = 1; C = 0.5·1·1 + 0.5·0.5 = 0.75.
        XCTAssertEqual(out.0, 0.75, accuracy: 1e-5)
        XCTAssertEqual(out.3, 1, accuracy: 1e-6)
        let burn = LayerRenderer.blendPixel(.colorBurn, (0, 0, 0), 0.5, (0.5, 0.5, 0.5), 1)
        XCTAssertEqual(burn.0, 0.25, accuracy: 1e-5)
    }

    func testNonSeparableModesPreserveBackdropLuminanceOrHue() {
        // Luminosity over a saturated backdrop: the backdrop's chroma, the
        // source's lightness (G and B stay equal-near-zero, R carries the luma).
        let out = LayerRenderer.blendPixel(.luminosity, (0.1, 0.1, 0.9), 1, (0.8, 0.2, 0.2), 1)
        XCTAssertEqual(out.1, out.2, accuracy: 1e-4)
        XCTAssertGreaterThan(out.0, out.1)
        let hue = LayerRenderer.blendPixel(.hue, (0.9, 0.1, 0.1), 1, (0.1, 0.1, 0.9), 1)
        // Backdrop hue (blue) replaced by source hue (red): R > B.
        XCTAssertGreaterThan(hue.0, hue.2)
    }

    // MARK: Placement draw

    func testDrawPlacesImageAtItsTransformIdentity() {
        var canvas = PixelBuffer(width: 16, height: 16)
        let image = RasterImage(solid(4, 4, 255, 0, 0))
        let transform = LayerTransform(origin: CGPoint(x: 6, y: 6), size: CGSize(width: 4, height: 4))
        LayerRenderer.draw(image, transform: transform, center: transform.center, into: &canvas)
        XCTAssertEqual(RasterSample.rgbaNearest(PortableImage(canvas), fx: 7, fy: 7).r, 255, "placed pixel is red")
        XCTAssertEqual(RasterSample.rgbaNearest(PortableImage(canvas), fx: 3, fy: 3).a, 0, "outside stays transparent")
    }

    func testDrawRotatesQuarterTurn() {
        // `rotation` is degrees. A red|blue image rotated 90° (scaled 2x1 to
        // 2x4) becomes a horizontal split: red on top, blue below.
        var canvas = PixelBuffer(width: 8, height: 8)
        let image = RasterImage(halfRedBlue())
        var transform = LayerTransform(origin: CGPoint(x: 2, y: 2), size: CGSize(width: 2, height: 4))
        transform.rotation = 90
        LayerRenderer.draw(image, transform: transform, center: transform.center, into: &canvas)
        let px = PortableImage(canvas)
        let top = RasterSample.rgbaNearest(px, fx: 4, fy: 3.5)
        let bottom = RasterSample.rgbaNearest(px, fx: 4, fy: 4.5)
        XCTAssertEqual(top.r, 255, "red half lands on top after a quarter turn")
        XCTAssertEqual(bottom.b, 255, "blue half lands at the bottom")
    }

    func testDrawFlipXMirrorsLeftRight() {
        var canvas = PixelBuffer(width: 6, height: 2)
        let image = RasterImage(halfRedBlue())
        var transform = LayerTransform(origin: CGPoint(x: 1, y: 0), size: CGSize(width: 4, height: 2))
        transform.flipX = true
        LayerRenderer.draw(image, transform: transform, center: transform.center, into: &canvas)
        let px = PortableImage(canvas)
        XCTAssertEqual(RasterSample.rgbaNearest(px, fx: 4, fy: 0.5).r, 255, "flipX moves red to the right")
        XCTAssertEqual(RasterSample.rgbaNearest(px, fx: 2, fy: 0.5).b, 255, "…and blue to the left")
    }

    func testOpacityAppliesExactlyOnceAtHalf() {
        var canvas = PixelBuffer(width: 8, height: 8)
        let image = RasterImage(solid(8, 8, 0, 255, 0))
        let transform = LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8))
        LayerRenderer.draw(image, transform: transform, center: transform.center, opacity: 0.5, blendMode: .normal, mask: nil, into: &canvas)
        let p = RasterSample.rgbaNearest(PortableImage(canvas), fx: 3.5, fy: 3.5)
        XCTAssertEqual(p.a, 128, "opacity halves the alpha exactly")
        XCTAssertEqual(p.g, 128)
    }

    func testDrawCoverageCompositesWhiteThroughMask() {
        var coverage = MaskBuffer(width: 4, height: 4, fill: 0)
        for y in 0..<4 { for x in 0..<4 { coverage[x, y] = x < 2 ? 255 : 0 } }
        var canvas = MaskBuffer(width: 8, height: 8, fill: 0)
        let transform = LayerTransform(origin: CGPoint(x: 2, y: 2), size: CGSize(width: 4, height: 4))
        LayerRenderer.drawCoverage(RasterImage(PortableImage(coverage)), transform: transform, into: &canvas)
        XCTAssertEqual(canvas[2, 2], 255, "white through the mask's left half")
        XCTAssertEqual(canvas[4, 2], 0, "black where the mask is black")
        XCTAssertEqual(canvas[0, 0], 0, "outside the placement untouched")
    }

    // MARK: Gaussian blur

    func testBlurSpreadsAOnePixelPulseAndKeepsEnergy() {
        var pixels = PixelBuffer(width: 9, height: 9)
        pixels[4, 4] = (255, 255, 255, 255)
        GaussianBlur.apply(&pixels, sigma: 1.5, edges: .clamp)
        let image = PortableImage(pixels)
        let center = RasterSample.rgbaNearest(image, fx: 4, fy: 4)
        // CI's exact Gaussian at sigma 1.5 peaks near 255/(2*pi*sigma^2) ~ 18;
        // the box approximation lands in the same class.
        XCTAssertGreaterThan(center.a, 8, "the pulse spreads")
        XCTAssertLessThan(center.a, 60, "…but the center is no longer full")
        let neighbor = RasterSample.rgbaNearest(image, fx: 5, fy: 4)
        XCTAssertGreaterThan(neighbor.a, 0, "neighbors pick up mass")
        var total = 0
        for y in 0..<9 { for x in 0..<9 { total += Int(RasterSample.rgbaNearest(image, fx: CGFloat(x), fy: CGFloat(y)).a) } }
        XCTAssertEqual(total, 255, accuracy: 10, "clamp edges preserve total mass")
    }

    func testTransparentEdgesFadeInsteadOfClamping() {
        // A solid block blurred with transparent padding must fade at its edge,
        // not extend the edge tone (the layer-blur CI path).
        var pixels = PixelBuffer(width: 8, height: 8)
        for y in 0..<8 { for x in 0..<8 { pixels[x, y] = (255, 255, 255, 255) } }
        GaussianBlur.apply(&pixels, sigma: 3, edges: .transparent)
        let image = PortableImage(pixels)
        let edge = RasterSample.rgbaNearest(image, fx: 0, fy: 4)
        let middle = RasterSample.rgbaNearest(image, fx: 4, fy: 4)
        XCTAssertLessThan(edge.a, middle.a, "transparent padding dims the edge")
        XCTAssertGreaterThan(middle.a, 120, "the middle keeps most of its mass")
    }

    func testMaskBlurClampsEdgeTone() {
        // The mask path (CI clampedToExtent): an all-white mask stays white.
        var mask = MaskBuffer(width: 8, height: 8, fill: 255)
        GaussianBlur.apply(&mask, sigma: 3, edges: .clamp)
        XCTAssertEqual(mask[0, 0], 255, "clamped edges keep the edge tone")
        XCTAssertEqual(mask[7, 7], 255)
    }

    // MARK: WarpStroke

    private func warpLayer() -> ImageLayer {
        let pixels = solid(16, 16, 0, 128, 255)
        let asset = ImportedImage(image: RasterImage(pixels),
                                  thumbnail: RasterImage(RasterSample.thumbnail(pixels)),
                                  name: "Warp")
        return ImageLayer(asset: asset, origin: .zero)
    }

    func testLiquifyPushesPixelsTowardTheMovement() throws {
        var settings = BrushSettings()
        settings.diameter = 6; settings.hardness = 1; settings.opacity = 1
        // Left half solid: pushing right carries solid pixels into empty space.
        var pixels = PixelBuffer(width: 16, height: 16)
        for y in 0..<16 { for x in 0..<8 { pixels[x, y] = (0, 0, 255, 255) } }
        let layer = ImageLayer(asset: ImportedImage(image: RasterImage(PortableImage(pixels)),
                                                    thumbnail: RasterImage(RasterSample.thumbnail(PortableImage(pixels))),
                                                    name: "Warp"), origin: .zero)
        let stroke = try WarpStroke(layer: layer, image: layer.asset!.image,
                                    transform: layer.transform, canvas: CGSize(width: 16, height: 16),
                                    mode: .liquify, settings: settings)
        stroke.append(CGPoint(x: 5, y: 8))
        stroke.append(CGPoint(x: 9, y: 8))
        let image = stroke.image
        // The dab that landed at (9,8) sampled from behind: solid moved right.
        let movedTo = RasterSample.rgbaNearest(image, fx: 10, fy: 8)
        XCTAssertGreaterThan(movedTo.b, 0, "solid pixels were pushed into empty space")
        XCTAssertFalse(stroke.points.isEmpty, "dab centers are recorded for the commit")
    }

    func testSmudgeCarriesColorAlongTheStroke() throws {
        var settings = BrushSettings()
        settings.diameter = 6; settings.hardness = 1; settings.opacity = 0.9
        // Left half solid, right half empty: smudging right carries color into the empty half.
        var pixels = PixelBuffer(width: 16, height: 16)
        for y in 0..<16 { for x in 0..<8 { pixels[x, y] = (0, 0, 255, 255) } }
        let layer = ImageLayer(asset: ImportedImage(image: RasterImage(PortableImage(pixels)),
                                                    thumbnail: RasterImage(RasterSample.thumbnail(PortableImage(pixels))),
                                                    name: "Warp"), origin: .zero)
        let stroke = try WarpStroke(layer: layer, image: layer.asset!.image,
                                    transform: layer.transform, canvas: CGSize(width: 16, height: 16),
                                    mode: .smudge, settings: settings)
        stroke.append(CGPoint(x: 6, y: 8))
        stroke.append(CGPoint(x: 12, y: 8))
        let image = stroke.image
        let carried = RasterSample.rgbaNearest(image, fx: 11, fy: 8)
        XCTAssertGreaterThan(carried.b, 0, "the brush carried blue into the empty half")
    }

    // MARK: PixelAdjust

    func testCoverageRasterizesTheClipRectOnTheImageGrid() {
        let clip = SelectionClip(rect: CGRect(x: 4, y: 4, width: 8, height: 8), coverage: nil)
        let cov = PixelAdjust.coverage(clip, width: 16, height: 16, pixelToDocument: .identity)
        XCTAssertEqual(cov[2, 2], 0)
        XCTAssertEqual(cov[5, 5], 255)
        XCTAssertEqual(cov[12, 5], 0)
    }

    func testBlendThroughCoverageMixesInFloat() {
        let adjusted = solid(4, 4, 255, 255, 255)
        let original = solid(4, 4, 0, 0, 0)
        var cov = MaskBuffer(width: 4, height: 4, fill: 128)
        _ = cov
        let cov2 = MaskBuffer(width: 4, height: 4, fill: 128)
        let blended = PixelAdjust.blend(adjusted, over: original, through: cov2)
        let p = RasterSample.rgbaNearest(blended, fx: 1, fy: 1)
        XCTAssertEqual(p.r, 128, "half coverage mixes half-way")
    }
}
