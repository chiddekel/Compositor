// AdjustPixels.c under the ENG-17 canonical-buffer contract (generated from AdjustPixels.h; see CompositorKernelChecks.h).
// Upstream's kernel is compiled here unchanged, with its checked entry points renamed; the wrappers below
// abort on a padded stride before calling it.
#include "CompositorKernelChecks.h"
#define adjust_gradient_map adjust_gradient_map__unchecked
#define adjust_grain adjust_grain__unchecked
#define adjust_black_white adjust_black_white__unchecked
#define adjust_color_balance adjust_color_balance__unchecked
#define adjust_camera_raw adjust_camera_raw__unchecked
#define adjust_camera_raw_clip_overlay adjust_camera_raw_clip_overlay__unchecked
#define adjust_camera_raw_curve_color adjust_camera_raw_curve_color__unchecked
#define adjust_camera_raw_effects adjust_camera_raw_effects__unchecked
#define adjust_colored_vignette adjust_colored_vignette__unchecked
#define adjust_camera_raw_detail adjust_camera_raw_detail__unchecked
#define adjust_camera_raw_sharpen_mask_overlay adjust_camera_raw_sharpen_mask_overlay__unchecked
#define adjust_camera_raw_optics adjust_camera_raw_optics__unchecked
#define adjust_camera_raw_calibration adjust_camera_raw_calibration__unchecked
#define adjust_tonal_contrast adjust_tonal_contrast__unchecked
#include "../../Compositor/Rendering/AdjustPixels.c"
#undef adjust_gradient_map
#undef adjust_grain
#undef adjust_black_white
#undef adjust_color_balance
#undef adjust_camera_raw
#undef adjust_camera_raw_clip_overlay
#undef adjust_camera_raw_curve_color
#undef adjust_camera_raw_effects
#undef adjust_colored_vignette
#undef adjust_camera_raw_detail
#undef adjust_camera_raw_sharpen_mask_overlay
#undef adjust_camera_raw_optics
#undef adjust_camera_raw_calibration
#undef adjust_tonal_contrast

void adjust_gradient_map(uint8_t *rgba, size_t width, size_t height, size_t stride, const uint8_t *table) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_gradient_map", stride, width, 4);
    adjust_gradient_map__unchecked(rgba, width, height, stride, table);
}

void adjust_grain(uint8_t *rgba, size_t width, size_t height, size_t stride, double amount, double size, double roughness, uint32_t seed, double originX, double originY, double unitsPerPixel) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_grain", stride, width, 4);
    adjust_grain__unchecked(rgba, width, height, stride, amount, size, roughness, seed, originX, originY, unitsPerPixel);
}

void adjust_black_white(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *weights, int tint, double tintHue, double tintSaturation) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_black_white", stride, width, 4);
    adjust_black_white__unchecked(rgba, width, height, stride, weights, tint, tintHue, tintSaturation);
}

void adjust_color_balance(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *shadows, const float *midtones, const float *highlights, int preserveLuminosity) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_color_balance", stride, width, 4);
    adjust_color_balance__unchecked(rgba, width, height, stride, shadows, midtones, highlights, preserveLuminosity);
}

void adjust_camera_raw(uint8_t *rgba, size_t width, size_t height, size_t stride, double redGain, double greenGain, double blueGain, double exposure, double contrast, double highlights, double shadows, double whites, double blacks, double vibrance, double saturation, int clipping) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_camera_raw", stride, width, 4);
    adjust_camera_raw__unchecked(rgba, width, height, stride, redGain, greenGain, blueGain, exposure, contrast, highlights, shadows, whites, blacks, vibrance, saturation, clipping);
}

void adjust_camera_raw_clip_overlay(uint8_t *rgba, size_t width, size_t height, size_t stride, int shadows, int highlights) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_camera_raw_clip_overlay", stride, width, 4);
    adjust_camera_raw_clip_overlay__unchecked(rgba, width, height, stride, shadows, highlights);
}

void adjust_camera_raw_curve_color(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *lumaLut, const float *redLut, const float *greenLut, const float *blueLut, double refineSaturation, const float *mixer, int pointCount, const float *points, const float *grade, double blending, double balance, int visualize) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_camera_raw_curve_color", stride, width, 4);
    adjust_camera_raw_curve_color__unchecked(rgba, width, height, stride, lumaLut, redLut, greenLut, blueLut, refineSaturation, mixer, pointCount, points, grade, blending, balance, visualize);
}

void adjust_camera_raw_effects(uint8_t *rgba, size_t width, size_t height, size_t stride, double texture, double clarity, double dehaze, double glow, int glowStyle, double glowRange, double glowSpread, double glowWarmth, double vignetteAmount, double vignetteMidpoint, double vignetteRoundness, double vignetteFeather, double vignetteHighlights, int vignetteStyle, double scale) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_camera_raw_effects", stride, width, 4);
    adjust_camera_raw_effects__unchecked(rgba, width, height, stride, texture, clarity, dehaze, glow, glowStyle, glowRange, glowSpread, glowWarmth, vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights, vignetteStyle, scale);
}

void adjust_colored_vignette(uint8_t *rgba, size_t width, size_t height, size_t stride, double frameX, double frameY, double frameWidth, double frameHeight, int fillsClear, double amount, double midpoint, double roundness, double feather, double highlights, double red, double green, double blue) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_colored_vignette", stride, width, 4);
    adjust_colored_vignette__unchecked(rgba, width, height, stride, frameX, frameY, frameWidth, frameHeight, fillsClear, amount, midpoint, roundness, feather, highlights, red, green, blue);
}

void adjust_camera_raw_detail(uint8_t *rgba, size_t width, size_t height, size_t stride, double sharpenAmount, double sharpenRadius, double sharpenDetail, double sharpenMasking, double noiseLuminance, double noiseLuminanceDetail, double noiseLuminanceContrast, double noiseColor, double noiseColorDetail, double noiseColorSmoothness, double scale) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_camera_raw_detail", stride, width, 4);
    adjust_camera_raw_detail__unchecked(rgba, width, height, stride, sharpenAmount, sharpenRadius, sharpenDetail, sharpenMasking, noiseLuminance, noiseLuminanceDetail, noiseLuminanceContrast, noiseColor, noiseColorDetail, noiseColorSmoothness, scale);
}

void adjust_camera_raw_sharpen_mask_overlay(uint8_t *rgba, size_t width, size_t height, size_t stride, double sharpenRadius, double sharpenDetail, double sharpenMasking, double scale) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_camera_raw_sharpen_mask_overlay", stride, width, 4);
    adjust_camera_raw_sharpen_mask_overlay__unchecked(rgba, width, height, stride, sharpenRadius, sharpenDetail, sharpenMasking, scale);
}

void adjust_camera_raw_optics(uint8_t *rgba, size_t width, size_t height, size_t stride, int removeChromatic, int lensProfile, double profileDistortion, double profileVignetting, double distortionK, double purpleAmount, double purpleHueLow, double purpleHueHigh, double greenAmount, double greenHueLow, double greenHueHigh, double vignetteAmount, double vignetteMidpoint, double scale) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_camera_raw_optics", stride, width, 4);
    adjust_camera_raw_optics__unchecked(rgba, width, height, stride, removeChromatic, lensProfile, profileDistortion, profileVignetting, distortionK, purpleAmount, purpleHueLow, purpleHueHigh, greenAmount, greenHueLow, greenHueHigh, vignetteAmount, vignetteMidpoint, scale);
}

void adjust_camera_raw_calibration(uint8_t *rgba, size_t width, size_t height, size_t stride, double shadowTint, double redHue, double redSaturation, double greenHue, double greenSaturation, double blueHue, double blueSaturation, int processVersion) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_camera_raw_calibration", stride, width, 4);
    adjust_camera_raw_calibration__unchecked(rgba, width, height, stride, shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation, processVersion);
}

void adjust_tonal_contrast(uint8_t *rgba, const uint8_t *blurred, size_t width, size_t height, size_t stride, size_t blurredStride, double amount, double shadows, double midtones, double highlights) {
    COMPOSITOR_REQUIRE_CANONICAL("adjust_tonal_contrast", stride, width, 4);
    COMPOSITOR_REQUIRE_CANONICAL("adjust_tonal_contrast", blurredStride, width, 4);
    adjust_tonal_contrast__unchecked(rgba, blurred, width, height, stride, blurredStride, amount, shadows, midtones, highlights);
}
