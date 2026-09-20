// Tests for the portable color-picker math (PickerHSB, PaletteColor quantized/hex,
// ColorPickerState, ColorPickerTarget), the brush/blur tool-mode enums, the
// Hue/Saturation sample modes, and the Levels automatic/sample math. Pin the
// unchanged macOS logic on Linux. Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class ColorPickerAndAutoTests: XCTestCase {

    // MARK: PickerHSB

    func testPickerHSBRedRoundTrip() {
        let red = PaletteColor(red: 1, green: 0, blue: 0)
        let hsb = PickerHSB(red)
        XCTAssertEqual(hsb.hue, 0, accuracy: 1e-9)
        XCTAssertEqual(hsb.saturation, 1, accuracy: 1e-9)
        XCTAssertEqual(hsb.brightness, 1, accuracy: 1e-9)
        let back = hsb.rgb
        XCTAssertEqual(back.red, 1, accuracy: 1e-9)
        XCTAssertEqual(back.green, 0, accuracy: 1e-9)
        XCTAssertEqual(back.blue, 0, accuracy: 1e-9)
    }

    func testPickerHSBGreenHueIs120() {
        let hsb = PickerHSB(PaletteColor(red: 0, green: 1, blue: 0))
        XCTAssertEqual(hsb.hue, 120, accuracy: 1e-9)
        XCTAssertEqual(hsb.saturation, 1, accuracy: 1e-9)
        XCTAssertEqual(hsb.brightness, 1, accuracy: 1e-9)
    }

    func testPickerHSBBlueHueIs240() {
        let hsb = PickerHSB(PaletteColor(red: 0, green: 0, blue: 1))
        XCTAssertEqual(hsb.hue, 240, accuracy: 1e-9)
    }

    func testPickerHSBYellowFromHue60() {
        let hsb = PickerHSB(hue: 60, saturation: 1, brightness: 1)
        let rgb = hsb.rgb
        XCTAssertEqual(rgb.red, 1, accuracy: 1e-9)
        XCTAssertEqual(rgb.green, 1, accuracy: 1e-9)
        XCTAssertEqual(rgb.blue, 0, accuracy: 1e-9)
    }

    func testPickerHSBGrayKeepsPreviousHue() {
        var hsb = PickerHSB(PaletteColor(red: 1, green: 0, blue: 0))  // hue 0
        XCTAssertEqual(hsb.hue, 0, accuracy: 1e-9)
        hsb.setRGB(PaletteColor(red: 0.5, green: 0.5, blue: 0.5))
        // Gray carries no chroma, so hue is preserved from the prior color.
        XCTAssertEqual(hsb.hue, 0, accuracy: 1e-9)
        XCTAssertEqual(hsb.saturation, 0, accuracy: 1e-9)
        XCTAssertEqual(hsb.brightness, 0.5, accuracy: 1e-9)
        let back = hsb.rgb
        XCTAssertEqual(back.red, 0.5, accuracy: 1e-9)
        XCTAssertEqual(back.green, 0.5, accuracy: 1e-9)
        XCTAssertEqual(back.blue, 0.5, accuracy: 1e-9)
    }

    func testPickerHSBBlackKeepsPreviousSaturation() {
        var hsb = PickerHSB(hue: 60, saturation: 0.8, brightness: 0.5)
        hsb.setRGB(PaletteColor.black)
        // Black has zero brightness; saturation is preserved (Photoshop field behavior).
        XCTAssertEqual(hsb.brightness, 0, accuracy: 1e-9)
        XCTAssertEqual(hsb.saturation, 0.8, accuracy: 1e-9)
        XCTAssertEqual(hsb.hue, 60, accuracy: 1e-9)
        let back = hsb.rgb
        XCTAssertEqual(back.red, 0, accuracy: 1e-9)
        XCTAssertEqual(back.green, 0, accuracy: 1e-9)
        XCTAssertEqual(back.blue, 0, accuracy: 1e-9)
    }

    // MARK: PaletteColor extensions

    func testPaletteColorHex() {
        XCTAssertEqual(PaletteColor.white.hex, "FFFFFF")
        XCTAssertEqual(PaletteColor.black.hex, "000000")
        XCTAssertEqual(PaletteColor(red: 1, green: 0, blue: 0).hex, "FF0000")
    }

    func testPaletteColorInitHex() {
        XCTAssertEqual(PaletteColor(hex: "FF0000"), PaletteColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(PaletteColor(hex: "#FF0000"), PaletteColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(PaletteColor(hex: "F00"), PaletteColor(red: 1, green: 0, blue: 0))
        XCTAssertNil(PaletteColor(hex: "GGGGGG"))
        XCTAssertNil(PaletteColor(hex: "12"))
    }

    func testPaletteColorQuantized() {
        let q = PaletteColor(red: 0.5, green: 0.5, blue: 0.5).quantized
        // 0.5 * 255 = 127.5 → rounds to 128 → 128/255.
        XCTAssertEqual(q.red, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(q.green, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(q.blue, 128.0 / 255, accuracy: 1e-9)
    }

    // MARK: ColorPickerState / ColorPickerTarget

    func testColorPickerStateColorMatchesOriginal() {
        let red = PaletteColor(red: 1, green: 0, blue: 0)
        let state = ColorPickerState(background: false, original: red)
        XCTAssertFalse(state.background)
        XCTAssertEqual(state.color, red.quantized)
        XCTAssertEqual(state.original, red)
    }

    func testColorPickerTargetTitles() {
        XCTAssertEqual(ColorPickerTarget.palette(background: false).title, "Color Picker (Foreground Color)")
        XCTAssertEqual(ColorPickerTarget.palette(background: true).title, "Color Picker (Background Color)")
        XCTAssertEqual(ColorPickerTarget.gradientMap(highlights: true).title, "Color Picker (Gradient Map Highlights)")
        XCTAssertEqual(ColorPickerTarget.gradientMap(highlights: false).title, "Color Picker (Gradient Map Shadows)")
    }

    func testColorPickerStateBackgroundDerivedFromTarget() {
        XCTAssertTrue(ColorPickerState(background: true, original: .black).background)
    }

    // MARK: Brush / Blur tool modes

    func testBrushToolModeCases() {
        XCTAssertEqual(BrushToolMode.allCases.count, 2)
        XCTAssertEqual(BrushToolMode.paint.rawValue, "Paint")
        XCTAssertEqual(BrushToolMode.erase.rawValue, "Erase")
    }

    func testBlurToolModeCases() {
        XCTAssertEqual(BlurToolMode.allCases.count, 3)
        XCTAssertEqual(BlurToolMode.liquify.rawValue, "Liquify")
        XCTAssertEqual(BlurToolMode.blur.rawValue, "Blur")
        XCTAssertEqual(BlurToolMode.smudge.rawValue, "Smudge")
    }

    // MARK: HueSampleMode / HueTargetDrag

    func testHueSampleModeSymbolAndBadge() {
        XCTAssertEqual(HueSampleMode.replace.symbol, "eyedropper")
        XCTAssertEqual(HueSampleMode.add.symbol, "eyedropper")
        XCTAssertNil(HueSampleMode.replace.badge)
        XCTAssertEqual(HueSampleMode.add.badge, "plus.circle.fill")
        XCTAssertEqual(HueSampleMode.remove.badge, "minus.circle.fill")
    }

    func testHueSampleModeHelp() {
        XCTAssertTrue(HueSampleMode.replace.help.contains("center"))
        XCTAssertTrue(HueSampleMode.add.help.contains("widen"))
        XCTAssertTrue(HueSampleMode.remove.help.contains("narrow"))
    }

    func testHueTargetDrag() {
        let drag = HueTargetDrag(range: .reds, hue: 10, saturation: 0.5)
        XCTAssertEqual(drag.range, .reds)
        XCTAssertEqual(drag.hue, 10, accuracy: 1e-9)
        XCTAssertEqual(drag.saturation, 0.5, accuracy: 1e-9)
    }

    // MARK: LevelsAuto

    /// Histogram helper: 4 channels of 256 bins; channels 1–3 carry mass at 50 and 200.
    private func twoPeakHistogram() -> [[Double]] {
        var channels = [[Double]]()
        channels.append([Double](repeating: 0, count: 256))  // master/luminance (unused by auto)
        for _ in 1...3 {
            var bins = [Double](repeating: 0, count: 256)
            bins[50] = 1
            bins[200] = 1
            channels.append(bins)
        }
        return channels
    }

    func testLevelsAutoContrastSetsSharedRange() {
        let s = LevelsAuto.contrast.settings(histogram: twoPeakHistogram())
        // 0.1% cumulative thresholds land at 50 and 200; shared interval preserves relationships.
        XCTAssertEqual(s.ranges[0].black, 50, accuracy: 1e-9)
        XCTAssertEqual(s.ranges[0].white, 200, accuracy: 1e-9)
    }

    func testLevelsAutoColorSetsPerChannelRanges() {
        let s = LevelsAuto.color.settings(histogram: twoPeakHistogram())
        for c in 1...3 {
            XCTAssertEqual(s.ranges[c].black, 50, accuracy: 1e-9)
            XCTAssertEqual(s.ranges[c].white, 200, accuracy: 1e-9)
        }
        // Color mode does not touch the composite RGB range.
        XCTAssertEqual(s.ranges[0], LevelRange())
    }

    func testLevelsAutoNeutralAppliesGamma() {
        // Asymmetric mass skews the post-black/white mean away from 0.5, so the
        // neutral midtone gamma departs from 1.0 (here mean=0.75 → gamma<1).
        var channels = [[Double]]()
        channels.append([Double](repeating: 0, count: 256))
        for _ in 1...3 {
            var bins = [Double](repeating: 0, count: 256)
            bins[50] = 1
            bins[200] = 3
            channels.append(bins)
        }
        let s = LevelsAuto.neutral.settings(histogram: channels)
        for c in 1...3 {
            XCTAssertEqual(s.ranges[c].black, 50, accuracy: 1e-9)
            XCTAssertEqual(s.ranges[c].white, 200, accuracy: 1e-9)
            XCTAssertLessThan(s.ranges[c].gamma, 1)
        }
    }

    func testLevelsAutoContrastEmptyHistogramIsIdentity() {
        let empty = [[Double]](repeating: [Double](repeating: 0, count: 256), count: 4)
        let s = LevelsAuto.contrast.settings(histogram: empty)
        XCTAssertTrue(s.isIdentity)
    }

    // MARK: LevelsSettings.sampling

    func testLevelsSamplingBlackPinpointsBlackPoint() {
        var s = LevelsSettings()
        s = s.sampling([0, 0, 0], mode: .black)
        for c in 1...3 {
            XCTAssertEqual(s.ranges[c].black, 0, accuracy: 1e-9)
        }
    }

    func testLevelsSamplingWhitePinpointsWhitePoint() {
        var s = LevelsSettings()
        s = s.sampling([1, 1, 1], mode: .white)
        for c in 1...3 {
            XCTAssertEqual(s.ranges[c].white, 255, accuracy: 1e-9)
        }
    }

    func testLevelsSamplingGraySetsGammaToOne() {
        var s = LevelsSettings()
        s = s.sampling([0.5, 0.5, 0.5], mode: .gray)
        // v=127.5, fraction=(127.5-0)/(255-0)=0.5, gamma=log(0.5)/log(0.5)=1.
        for c in 1...3 {
            XCTAssertEqual(s.ranges[c].gamma, 1, accuracy: 1e-9)
        }
    }

    func testLevelsSamplingResetsCompositeRGBRange() {
        var s = LevelsSettings()
        s.ranges[0] = LevelRange(black: 30, white: 220)
        s = s.sampling([0.5, 0.5, 0.5], mode: .gray)
        // Sampling calibrates channels only; the composite RGB range is reset to identity.
        XCTAssertEqual(s.ranges[0], LevelRange())
    }
}