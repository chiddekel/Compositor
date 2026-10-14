#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ICC color management for the Linux compat layer (Core Graphics colour spaces, ColorSync), over LittleCMS 2.
 * Profiles are passed as their ICC bytes. Intents use Core Graphics' numbering: 0 default, 1 absolute colorimetric,
 * 2 relative colorimetric, 3 perceptual, 4 saturation. */
enum { COMPOSITOR_ICC_UNKNOWN = 0, COMPOSITOR_ICC_RGB = 1, COMPOSITOR_ICC_GRAY = 2, COMPOSITOR_ICC_CMYK = 3 };
/* The profile's data colour space, or COMPOSITOR_ICC_UNKNOWN when the bytes are not a usable ICC profile. */
int compositor_icc_color_model(const uint8_t *profile, size_t length);
/* The profile's description (UTF-8, NUL-terminated, truncated to capacity). Returns the full length in bytes without
 * the NUL, or -1 when the profile has none. */
int64_t compositor_icc_description(const uint8_t *profile, size_t length, char *output, size_t capacity);
/* sRGB pixels (8-bit premultiplied RGBA; colours are unpremultiplied and alpha is ignored) to 8-bit CMYK ink amounts
 * (0 none, 255 full) through `profile`. Returns 0, or -1 for an unusable profile or arguments. */
int compositor_icc_srgb_to_cmyk(const uint8_t *profile, size_t length, int32_t intent, const uint8_t *rgba,
                                size_t rgbaRowBytes, uint8_t *cmyk, size_t cmykRowBytes, uint32_t width, uint32_t height);
/* 8-bit CMYK ink amounts through `profile` to opaque sRGB RGBA. Returns 0, or -1. */
int compositor_icc_cmyk_to_srgb(const uint8_t *profile, size_t length, int32_t intent, const uint8_t *cmyk,
                                size_t cmykRowBytes, uint8_t *rgba, size_t rgbaRowBytes, uint32_t width, uint32_t height);
#ifdef __cplusplus
}
#endif
