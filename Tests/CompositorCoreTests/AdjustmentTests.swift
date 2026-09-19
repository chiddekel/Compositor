// Tests for the portable LayerAdjustment / AdjustmentKind data layer.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class AdjustmentTests: XCTestCase {

    func testAdjustmentKindFilterKindBridge() {
        XCTAssertEqual(AdjustmentKind.curves.filterKind, .curves)
        XCTAssertEqual(AdjustmentKind.exposure.filterKind, .exposure)
        XCTAssertEqual(AdjustmentKind.gradientMap.filterKind, .gradientMap)
        XCTAssertEqual(AdjustmentKind.grain.filterKind, .grain)
        XCTAssertNil(AdjustmentKind.hsv.filterKind)
        XCTAssertNil(AdjustmentKind.levels.filterKind)
    }

    func testAdjustmentKindSymbolIsOpaqueString() {
        // Symbols are SF Symbol names kept as opaque data; the Qt UI maps them later.
        for kind in AdjustmentKind.allCases {
            XCTAssertFalse(kind.symbol.isEmpty)
        }
    }

    func testLayerAdjustmentResolvedHSVFallsBackToScalars() {
        var a = LayerAdjustment(kind: .hsv)
        a.hue = 12; a.saturation = 30; a.lightness = -10; a.colorize = true
        let resolved = a.resolvedHSV
        XCTAssertEqual(resolved.hue, 12)
        XCTAssertEqual(resolved.saturation, 30)
        XCTAssertEqual(resolved.lightness, -10)
        XCTAssertTrue(resolved.colorize)
    }

    func testLayerAdjustmentResolvedHSVUsesSettingsWhenPresent() {
        var a = LayerAdjustment(kind: .hsv)
        a.hsvSettings = HueSaturationSettings(hue: 99, saturation: 5, lightness: 5)
        XCTAssertEqual(a.resolvedHSV.hue, 99)
        XCTAssertEqual(a.resolvedHSV.saturation, 5)
    }

    func testLayerAdjustmentAccessorsDefaultWhenNil() {
        let a = LayerAdjustment(kind: .exposure)
        XCTAssertEqual(a.exposure, ExposureSettings())
        XCTAssertEqual(a.gradientMap, GradientMapSettings())
        XCTAssertEqual(a.grain, GrainSettings())
    }

    func testLayerAdjustmentAccessorsRoundTrip() {
        var a = LayerAdjustment(kind: .exposure)
        a.exposure.exposure = 2
        XCTAssertEqual(a.exposureSettings?.exposure, 2)
        XCTAssertEqual(a.exposure.exposure, 2)
    }

    func testLayerAdjustmentIsValidDefault() {
        XCTAssertTrue(LayerAdjustment(kind: .levels).isValid)
    }

    func testLayerAdjustmentInvalidWhenHueOutOfRange() {
        var a = LayerAdjustment(kind: .hsv)
        a.hue = 500
        XCTAssertFalse(a.isValid)
    }

    func testLayerAdjustmentInvalidWhenCurvesInvalid() {
        var a = LayerAdjustment(kind: .curves)
        a.curves.channels[0] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 100, y: 255), CurvePoint(x: 255, y: 255), CurvePoint(x: 50, y: 0)]
        XCTAssertFalse(a.isValid)
    }

    // MARK: AdjustmentSurface affected-region semantics
    //
    // macOS `AdjustmentSurface.draw(in:)` renders the live composite into a
    // bounded offscreen surface. On Linux the portable equivalent is
    // `DocumentRenderer.adjust`: an adjustment layer only changes color inside
    // the region its (placed) mask covers; coverage/alpha outside is untouched.

    func testAdjustmentChangesOnlyMaskedRegionAndNeverAlpha() throws {
        var base = PixelBuffer(width: 4, height: 4)
        for y in 0..<4 { for x in 0..<4 { base[x, y] = (200, 100, 50, 255) } }
        let baseImage = ImportedImage(image: RasterImage(PortableImage(base)), thumbnail: RasterImage(PortableImage(base)), name: "Base")

        var maskPixels = MaskBuffer(width: 4, height: 4)
        for y in 0..<4 { for x in 0..<4 { maskPixels[x, y] = x < 2 ? 255 : 0 } }
        let maskAsset = ImportedImage(mask: PortableImage(maskPixels), name: "Mask")
        let mask = LayerMask(asset: maskAsset)

        var adjustment = LayerAdjustment(kind: .levels)
        adjustment.levels.ranges[0].outputWhite = 40
        let layer = ImageLayer(id: UUID(), asset: nil, name: "Levels", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)),
            mask: mask, adjustment: adjustment)

        let doc = CanvasDocument(width: 4, height: 4, layers: [
            ImageLayer(asset: baseImage, origin: .zero),
            layer,
        ])
        let out = try DocumentRenderer(doc).render()
        let covered = RasterSample.rgbaNearest(out, fx: 0, fy: 0)
        let outside = RasterSample.rgbaNearest(out, fx: 3, fy: 0)
        XCTAssertLessThan(covered.r, 200, "masked half is darkened by the levels edit")
        XCTAssertEqual(out.bytes[3], 255, "covered alpha unchanged")
        XCTAssertEqual(out.bytes[4 * 3 + 3], 255, "outside alpha unchanged")
        XCTAssertEqual(out.bytes[4 * 3 + 0], 200, "unmasked half keeps original color")
    }
}