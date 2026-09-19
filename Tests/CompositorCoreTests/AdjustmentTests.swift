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
}