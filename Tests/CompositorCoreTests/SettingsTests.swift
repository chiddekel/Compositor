// Tests for the portable settings-data layer. Pin the unchanged macOS adjustment
// math (levels, curves, exposure, gradient map, grain, hue/saturation, filters)
// on Linux — validation, lookup-table generation, and band/HSL math.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class SettingsTests: XCTestCase {

    // MARK: Levels

    func testLevelsChannelIndex() {
        XCTAssertEqual(LevelsChannel.rgb.index, 0)
        XCTAssertEqual(LevelsChannel.red.index, 1)
        XCTAssertEqual(LevelsChannel.green.index, 2)
        XCTAssertEqual(LevelsChannel.blue.index, 3)
    }

    func testLevelRangeIdentityApplyIsLinear() {
        let r = LevelRange()
        // Identity: black 0, white 255, gamma 1, output 0..255 → value passes through.
        XCTAssertEqual(r.apply(0), 0, accuracy: 1e-9)
        XCTAssertEqual(r.apply(1), 1, accuracy: 1e-9)
        XCTAssertEqual(r.apply(0.5), 0.5, accuracy: 1e-9)
    }

    func testLevelRangeNormalizedClampsWhiteAboveBlack() {
        var r = LevelRange()
        r.black = 200; r.white = 100  // inverted
        let n = r.normalized
        XCTAssertLessThanOrEqual(n.black, n.white - 1)
    }

    func testLevelsSettingsIsIdentity() {
        XCTAssertTrue(LevelsSettings().isIdentity)
        var s = LevelsSettings()
        s.ranges[1].gamma = 2
        XCTAssertFalse(s.isIdentity)
    }

    func testLevelsHistogramDisplayCapsSpikes() {
        // A single huge spike among small bins is capped to 4× the typical peak.
        let bins: [Double] = [0, 1, 2, 3, 1000, 4, 5, 6, 7, 8]
        let scale = LevelsHistogramDisplay.scale(for: bins)
        XCTAssertLessThan(scale, 1000)
    }

    // MARK: Curves

    func testCurvesValueIdentityCurve() {
        let c = CurvesSettings()
        // Default curve is the identity line y = x (0..255).
        XCTAssertEqual(c.value(0, channel: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(c.value(255, channel: 0), 255, accuracy: 1e-9)
        XCTAssertEqual(c.value(128, channel: 0), 128, accuracy: 1)
    }

    func testCurvesIsValidRequiresMonotonicEndpoints() {
        var c = CurvesSettings()
        c.channels[0] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 100), CurvePoint(x: 100, y: 255)]
        XCTAssertFalse(c.isValid)  // not monotonic in x
    }

    // MARK: Exposure

    func testExposureTableIdentityIsLinear() {
        let t = ExposureSettings().table
        XCTAssertEqual(t.count, 256)
        XCTAssertEqual(Double(t[0]), 0, accuracy: 1e-3)
        XCTAssertEqual(Double(t[255]), 1, accuracy: 1e-3)
        // sRGB identity at mid-gray ~0.2159 linear-light encoded ~187.
        XCTAssertEqual(Double(t[187]), 187.0 / 255.0, accuracy: 1e-2)
    }

    func testExposureNormalizedClamps() {
        var e = ExposureSettings()
        e.exposure = 100
        e.gamma = -1
        let n = e.normalized
        XCTAssertEqual(n.exposure, 20)
        XCTAssertEqual(n.gamma, 0.01)
    }

    // MARK: Gradient Map

    func testGradientMapTableInterpolatesEnds() {
        var g = GradientMapSettings()
        g.shadows = AdjustmentColor(red: 0, green: 0, blue: 0)
        g.highlights = AdjustmentColor(red: 1, green: 1, blue: 1)
        let table = g.table
        XCTAssertEqual(table.count, 256 * 3)
        XCTAssertEqual(table[0], 0)
        XCTAssertEqual(table[255 * 3], 255)
        XCTAssertEqual(table[128 * 3], 128)  // midpoint
    }

    func testGradientMapReversedSwapsEnds() {
        var g = GradientMapSettings()
        g.shadows = AdjustmentColor(red: 0, green: 0, blue: 0)
        g.highlights = AdjustmentColor(red: 1, green: 1, blue: 1)
        g.reversed = true
        XCTAssertEqual(g.ends.dark, g.highlights)
        XCTAssertEqual(g.ends.light, g.shadows)
    }

    // MARK: Grain

    func testGrainNormalizedClamps() {
        var grain = GrainSettings()
        grain.amount = 200
        grain.size = 0.1
        let n = grain.normalized
        XCTAssertEqual(n.amount, 100)
        XCTAssertEqual(n.size, 0.5)
    }

    // MARK: Hue / Saturation

    func testHueBandForwardWraps() {
        XCTAssertEqual(HueBand.forward(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(HueBand.forward(10, 350), 340, accuracy: 1e-9)
    }

    func testHueBandWeightMasterCoversAll() {
        let master = ColorRange.master.defaultBand
        XCTAssertEqual(master.weight(of: 0), 1)
        XCTAssertEqual(master.weight(of: 180), 1)
    }

    func testHueBandWeightRedsInRange() {
        let reds = ColorRange.reds.defaultBand  // plateau 345..15 (wrapping)
        XCTAssertEqual(reds.weight(of: 0), 1, accuracy: 1e-9)    // dead center
        XCTAssertEqual(reds.weight(of: 345), 1, accuracy: 1e-9)
        XCTAssertEqual(reds.weight(of: 180), 0, accuracy: 1e-9)  // opposite hue
    }

    func testHueSaturationIsIdentity() {
        XCTAssertTrue(HueSaturationSettings().isIdentity)
        var s = HueSaturationSettings()
        s.hue = 10
        XCTAssertFalse(s.isIdentity)
    }

    func testHueSaturationColorizeStart() {
        let c = HueSaturationSettings.colorizeStart
        XCTAssertTrue(c.colorize)
        XCTAssertEqual(c.saturation, 25)
    }

    func testHueSaturationAdjustColorizeReplacesHue() {
        var s = HueSaturationSettings(hue: 120, saturation: 50, colorize: true)
        let out = HueSaturationFilter.adjust(red: 0.2, green: 0.3, blue: 0.4, settings: s)
        // Colorize ignores the input hue; output hue should be 120.
        let (h, _, _) = HueSaturationFilter.toHSL(red: out.red, green: out.green, blue: out.blue)
        XCTAssertEqual(h, 120, accuracy: 1e-6)
        s.colorize = false
    }

    func testHSLRoundTrip() {
        for hue in stride(from: 0.0, through: 350.0, by: 35.0) {
            let rgb = HueSaturationFilter.toRGB(hue: hue, saturation: 0.8, lightness: 0.5)
            let (h, s, l) = HueSaturationFilter.toHSL(red: rgb.red, green: rgb.green, blue: rgb.blue)
            XCTAssertEqual(h, hue, accuracy: 1e-6)
            XCTAssertEqual(s, 0.8, accuracy: 1e-6)
            XCTAssertEqual(l, 0.5, accuracy: 1e-6)
        }
    }

    func testHueSaturationCubeDimension() {
        let cube = HueSaturationFilter.cube(HueSaturationSettings())
        XCTAssertEqual(cube.count, 33 * 33 * 33 * 4)
        // Identity settings: every cube corner maps to itself (alpha 1).
        XCTAssertEqual(cube[3], 1)  // alpha of first entry
    }

    func testHueSaturationShiftedHueAppliesWeight() {
        var s = HueSaturationSettings(hue: 30, range: .reds)
        let shifted = HueSaturationFilter.shiftedHue(0, settings: s)  // reds claim hue 0 fully
        XCTAssertEqual(shifted, 30, accuracy: 1e-9)
    }

    // MARK: Filters

    func testFilterKindClassification() {
        XCTAssertTrue(FilterKind.contentAwareFill.isAutomatic)
        XCTAssertTrue(FilterKind.removeBackground.isAutomatic)
        XCTAssertFalse(FilterKind.gaussianBlur.isAutomatic)
        XCTAssertTrue(FilterKind.exposure.isImageAdjustment)
        XCTAssertFalse(FilterKind.gaussianBlur.isImageAdjustment)
    }

    func testFilterSettingsNormalizedClamps() {
        var f = FilterSettings()
        f.radius = 1000
        f.angle = 200
        f.distortion = 500
        let n = f.normalized
        XCTAssertEqual(n.radius, 250)
        XCTAssertEqual(n.angle, 90)
        XCTAssertEqual(n.distortion, 100)
    }

    // MARK: PaletteColor / AdjustmentColor

    func testPaletteColorConstants() {
        XCTAssertEqual(PaletteColor.black, PaletteColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(PaletteColor.white, PaletteColor(red: 1, green: 1, blue: 1))
    }

    func testAdjustmentColorFromPalette() {
        let p = PaletteColor(red: 0.5, green: 0.25, blue: 0.75)
        let a = AdjustmentColor(p)
        XCTAssertEqual(a.red, 0.5)
        XCTAssertEqual(a.green, 0.25)
        XCTAssertEqual(a.blue, 0.75)
    }

    func testAdjustmentColorClamped() {
        var a = AdjustmentColor(red: 1.5, green: -0.5, blue: 0.5)
        let c = a.clamped
        XCTAssertEqual(c.red, 1)
        XCTAssertEqual(c.green, 0)
        XCTAssertEqual(c.blue, 0.5)
        XCTAssertFalse(a.isValid)
        XCTAssertTrue(c.isValid)
    }
}