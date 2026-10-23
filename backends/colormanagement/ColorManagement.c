#include "include/CompositorColorManagement.h"
#include <lcms2.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* Built transforms, by profile bytes, direction and intent: proofing asks for the same one for every lookup. */
typedef struct { uint64_t hash; size_t length; int toCMYK; int intent; cmsHTRANSFORM transform; } Entry;
enum { CACHE = 8 };
static Entry cache[CACHE];
static int nextSlot;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t hashBytes(const uint8_t *bytes, size_t length) {
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < length; ++i) { h ^= bytes[i]; h *= 1099511628211ull; }
    return h;
}

static int lcmsIntent(int32_t intent) {
    switch (intent) {
    case 1: return INTENT_ABSOLUTE_COLORIMETRIC;
    case 2: return INTENT_RELATIVE_COLORIMETRIC;
    case 4: return INTENT_SATURATION;
    default: return INTENT_PERCEPTUAL;   /* default and perceptual: the profile's own default intent */
    }
}

static cmsHPROFILE open(const uint8_t *profile, size_t length) {
    if (!profile || length < 128 || length > (size_t)INT32_MAX) return NULL;
    return cmsOpenProfileFromMem(profile, (cmsUInt32Number)length);
}

int compositor_icc_color_model(const uint8_t *profile, size_t length) {
    cmsHPROFILE handle = open(profile, length);
    if (!handle) return COMPOSITOR_ICC_UNKNOWN;
    cmsColorSpaceSignature space = cmsGetColorSpace(handle);
    cmsCloseProfile(handle);
    return space == cmsSigRgbData ? COMPOSITOR_ICC_RGB : space == cmsSigGrayData ? COMPOSITOR_ICC_GRAY
        : space == cmsSigCmykData ? COMPOSITOR_ICC_CMYK : COMPOSITOR_ICC_UNKNOWN;
}

int64_t compositor_icc_description(const uint8_t *profile, size_t length, char *output, size_t capacity) {
    cmsHPROFILE handle = open(profile, length);
    if (!handle) return -1;
    cmsUInt32Number needed = cmsGetProfileInfoUTF8(handle, cmsInfoDescription, "en", "US", NULL, 0);
    int64_t result = -1;
    if (needed > 1) {
        char *text = malloc(needed);
        if (text && cmsGetProfileInfoUTF8(handle, cmsInfoDescription, "en", "US", text, needed)) {
            result = (int64_t)strlen(text);
            if (output && capacity) {
                size_t copied = (size_t)result < capacity - 1 ? (size_t)result : capacity - 1;
                memcpy(output, text, copied);
                output[copied] = 0;
            }
        }
        free(text);
    }
    cmsCloseProfile(handle);
    return result;
}

/* The transform for this profile, direction and intent; NULL when the profile is not a usable CMYK one. */
static cmsHTRANSFORM transformFor(const uint8_t *profile, size_t length, int toCMYK, int32_t intent) {
    const uint64_t hash = hashBytes(profile, length);
    const int mapped = lcmsIntent(intent);
    pthread_mutex_lock(&lock);
    for (int i = 0; i < CACHE; ++i)
        if (cache[i].transform && cache[i].hash == hash && cache[i].length == length && cache[i].toCMYK == toCMYK
            && cache[i].intent == mapped) {
            cmsHTRANSFORM found = cache[i].transform;
            pthread_mutex_unlock(&lock);
            return found;
        }
    pthread_mutex_unlock(&lock);
    cmsHPROFILE cmyk = open(profile, length);
    if (!cmyk) return NULL;
    if (cmsGetColorSpace(cmyk) != cmsSigCmykData) { cmsCloseProfile(cmyk); return NULL; }
    cmsHPROFILE srgb = cmsCreate_sRGBProfile();
    /* Pixels in: RGBA with the alpha byte skipped; out: CMYK. And back: CMYK to RGBA with the extra byte left alone. */
    cmsHTRANSFORM transform = toCMYK
        ? cmsCreateTransform(srgb, TYPE_RGBA_8, cmyk, TYPE_CMYK_8, mapped, 0)
        : cmsCreateTransform(cmyk, TYPE_CMYK_8, srgb, TYPE_RGBA_8, mapped, 0);
    cmsCloseProfile(srgb);
    cmsCloseProfile(cmyk);
    if (!transform) return NULL;
    pthread_mutex_lock(&lock);
    Entry *slot = &cache[nextSlot];
    nextSlot = (nextSlot + 1) % CACHE;
    cmsHTRANSFORM evicted = slot->transform;
    *slot = (Entry){hash, length, toCMYK, mapped, transform};
    pthread_mutex_unlock(&lock);
    /* An evicted transform may still be running on another thread: kept rather than deleted (at most a few exist). */
    (void)evicted;
    return transform;
}

int compositor_icc_srgb_to_cmyk(const uint8_t *profile, size_t length, int32_t intent, const uint8_t *rgba,
                                size_t rgbaRowBytes, uint8_t *cmyk, size_t cmykRowBytes, uint32_t width, uint32_t height) {
    if (!rgba || !cmyk || !width || !height || rgbaRowBytes < (size_t)width * 4 || cmykRowBytes < (size_t)width * 4) return -1;
    cmsHTRANSFORM transform = transformFor(profile, length, 1, intent);
    if (!transform) return -1;
    uint8_t *row = malloc((size_t)width * 4);
    if (!row) return -1;
    for (uint32_t y = 0; y < height; ++y) {
        const uint8_t *source = rgba + (size_t)y * rgbaRowBytes;
        for (uint32_t x = 0; x < width; ++x) {
            const uint8_t a = source[x * 4 + 3];
            for (int c = 0; c < 3; ++c) {
                const uint8_t v = source[x * 4 + c];
                /* Premultiplied colours back to straight ones (opaque pixels unchanged). */
                const unsigned straight = a == 255 || a == 0 ? v : ((unsigned)v * 255 + a / 2) / a;
                row[x * 4 + c] = (uint8_t)(straight > 255 ? 255 : straight);
            }
            row[x * 4 + 3] = 255;
        }
        cmsDoTransform(transform, row, cmyk + (size_t)y * cmykRowBytes, width);
    }
    free(row);
    return 0;
}

int compositor_icc_cmyk_to_srgb(const uint8_t *profile, size_t length, int32_t intent, const uint8_t *cmyk,
                                size_t cmykRowBytes, uint8_t *rgba, size_t rgbaRowBytes, uint32_t width, uint32_t height) {
    if (!rgba || !cmyk || !width || !height || rgbaRowBytes < (size_t)width * 4 || cmykRowBytes < (size_t)width * 4) return -1;
    cmsHTRANSFORM transform = transformFor(profile, length, 0, intent);
    if (!transform) return -1;
    for (uint32_t y = 0; y < height; ++y) {
        uint8_t *target = rgba + (size_t)y * rgbaRowBytes;
        cmsDoTransform(transform, cmyk + (size_t)y * cmykRowBytes, target, width);
        for (uint32_t x = 0; x < width; ++x) target[x * 4 + 3] = 255;
    }
    return 0;
}
