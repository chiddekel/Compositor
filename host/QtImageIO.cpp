#include "QtTextFont.h"
#include <QFontDatabase>
// Qt image plugins as the ImageIO compat backend. Registered into the Swift core at startup so
// CGImageSource / CGImageDestination (used by upstream's importer, exporter and project store) decode and encode
// every format Qt supports (PNG, JPEG, TIFF, WebP, BMP, GIF, ...), not just the portable PNG codec.

#include <QBuffer>
#include <QByteArray>
#include <QImage>
#include <QImageReader>
#include <QImageWriter>
#include <QPainter>
#include <QFont>
#include <QFontMetricsF>
#include <QColorSpace>
#include <QColorTransform>
#include <QtGui/qrgbafloat.h>
#include <QtCore/qfloat16.h>
#include <QRawFont>
#include <QGuiApplication>
#include <QString>
#include <QStringList>
#include <QTextLayout>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QTextOption>
#include <cmath>
#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <memory>
#include <zlib.h>
#include <tiffio.h>
#include <lcms2.h>
#include <limits>

// HEIF/HEIC/AVIF go through libheif directly: the Qt plugin for them is not dependable (it swaps the dimensions of a
// 64x32 image on a round trip). libheif is optional; without it those formats are simply not handled here.
#if defined(__has_include)
#if __has_include(<libheif/heif.h>)
#define COMPOSITOR_HAS_LIBHEIF 1
#include <libheif/heif.h>
#endif
#endif

// OpenEXR (static; scripts/build-openexr.sh or the Flatpak module) for EXR, as Apple's ImageIO reads and writes it.
#if defined(COMPOSITOR_HAS_OPENEXR)
#include <ImfRgbaFile.h>
#include <ImfIO.h>
#include <ImfHeader.h>
#include <ImfCompression.h>
#include <ImathBox.h>
#include <half.h>
#endif

// Pixel layouts on the codec C ABI (`channels`): 1 gray 8-bit, 4 RGBA 8-bit, 8 RGBA 16-bit unsigned, 16 RGBA 32-bit
// float. All color layouts are premultiplied; 16-bit is native-endian; float is linear light (EXR, Radiance HDR).
constexpr int32_t kLayoutGray8 = 1, kLayoutRGBA8 = 4, kLayoutRGBA16 = 8, kLayoutRGBAFloat = 16;

extern "C" {
typedef int32_t (*CompositorImageDecodeFn)(const uint8_t *, size_t, uint8_t **, int32_t *, int32_t *, int32_t *, double *,
                                           int32_t *, char *, size_t);
typedef int32_t (*CompositorImageEncodeFn)(const uint8_t *, int32_t, int32_t, int32_t, const char *, double, double,
                                           int32_t, uint8_t **, size_t *);
// Provided by the Swift core; weak so C++-only builds (no Swift) still link.
void compositor_imageio_register(CompositorImageDecodeFn, CompositorImageEncodeFn) __attribute__((weak));
typedef void *(*CompositorAnimationOpenFn)(const uint8_t *, size_t);
typedef int32_t (*CompositorAnimationReadFn)(void *, int32_t, uint8_t **, int32_t *, int32_t *);
typedef void (*CompositorAnimationCloseFn)(void *);
void compositor_imageio_register_animation(CompositorAnimationOpenFn, CompositorAnimationReadFn,
                                          CompositorAnimationCloseFn) __attribute__((weak));
// The deep decode (16-bit and float layouts), registered beside the 8-bit one.
void compositor_imageio_register_deep(CompositorImageDecodeFn) __attribute__((weak));
void compositor_imageio_register_straight(CompositorImageDecodeFn, CompositorImageEncodeFn) __attribute__((weak));
// CMYK JPEG and TIFF, as Apple's ImageIO keeps them: ink amounts (0 none, 255 full, four a pixel) and the embedded profile.
typedef int32_t (*CompositorCMYKDecodeFn)(const uint8_t *, size_t, uint8_t **, int32_t *, int32_t *, uint8_t **, size_t *,
                                          double *, char *, size_t);
typedef int32_t (*CompositorCMYKEncodeFn)(const uint8_t *, int32_t, int32_t, const uint8_t *, size_t, const char *, double,
                                          double, uint8_t **, size_t *);
void compositor_imageio_register_cmyk(CompositorCMYKDecodeFn, CompositorCMYKEncodeFn) __attribute__((weak));
}

namespace {

bool isHeifContainer(const uint8_t *d, size_t n) {
    if (n < 12 || memcmp(d + 4, "ftyp", 4) != 0) return false;
    static const char *brands[] = {"heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"};
    for (const char *b : brands) if (memcmp(d + 8, b, 4) == 0) return true;
    return false;
}

// Color management follows upstream's Core Image import into 8-bit sRGB. Convert in a 16-bit intermediate before
// reducing to document pixels; untagged images use the existing sRGB assumption. Exports carry an sRGB profile.
QImage toSRGB(QImage image) {
    const QColorSpace space = image.colorSpace();
    if (!space.isValid() || space == QColorSpace(QColorSpace::SRgb)) return image;
    const bool gray = image.format() == QImage::Format_Grayscale8 || image.format() == QImage::Format_Grayscale16;
    // Convert color model and pixel format together. Converting gray-profile pixels to RGB first would leave the
    // source profile describing the wrong format and prevent Qt from applying the gray transfer curve.
    QImage wide = image.convertedToColorSpace(QColorSpace(QColorSpace::SRgb),
        image.hasAlphaChannel() ? QImage::Format_RGBA64 : QImage::Format_RGBX64);
    if (!wide.isNull() && gray) wide = wide.convertToFormat(QImage::Format_Grayscale16);
    return wide;
}

QImage grayAlphaToSRGB(const QImage &image, const QColorSpace &space) {
    const QImage source = image.convertToFormat(QImage::Format_RGBA64);
    QImage gray(image.size(), QImage::Format_Grayscale16);
    if (source.isNull() || gray.isNull()) return {};
    for (int y = 0; y < image.height(); ++y) {
        const auto *rgba = reinterpret_cast<const QRgba64 *>(source.constScanLine(y));
        auto *row = reinterpret_cast<uint16_t *>(gray.scanLine(y));
        for (int x = 0; x < image.width(); ++x) row[x] = rgba[x].red();
    }
    gray.setColorSpace(space);
    QImage converted = gray.convertedToColorSpace(QColorSpace(QColorSpace::SRgb), QImage::Format_RGBA64);
    if (converted.isNull()) return {};
    for (int y = 0; y < image.height(); ++y) {
        const auto *original = reinterpret_cast<const QRgba64 *>(source.constScanLine(y));
        auto *row = reinterpret_cast<QRgba64 *>(converted.scanLine(y));
        for (int x = 0; x < image.width(); ++x) row[x].setAlpha(original[x].alpha());
    }
    converted.setDotsPerMeterX(image.dotsPerMeterX());
    converted.setDotsPerMeterY(image.dotsPerMeterY());
    return converted;
}

// Qt's grayscale TIFF path loses alpha and the gray profile; float TIFFs also need an unclipped linear path.
// libtiff handles byte order, compression, planar storage and tiles without an intermediate RGBA8 reduction.
QImage decodeNativeTIFF(const uint8_t *data, size_t length, bool &handled, int &orientation) {
    struct Reader { const uint8_t *data; size_t size, offset; } reader{data, length, 0};
    auto options = std::unique_ptr<TIFFOpenOptions, decltype(&TIFFOpenOptionsFree)>(TIFFOpenOptionsAlloc(), TIFFOpenOptionsFree);
    if (!options) return {};
    constexpr tmsize_t bufferLimit = 256 * 1024 * 1024;
    TIFFOpenOptionsSetMaxSingleMemAlloc(options.get(), bufferLimit);
#if TIFFLIB_VERSION >= 20240911
    TIFFOpenOptionsSetMaxCumulatedMemAlloc(options.get(), bufferLimit);
#endif
    const auto quiet = [](TIFF *, void *, const char *, const char *, va_list) -> int { return 1; };
    TIFFOpenOptionsSetErrorHandlerExtR(options.get(), quiet, nullptr);
    TIFFOpenOptionsSetWarningHandlerExtR(options.get(), quiet, nullptr);
    TIFF *raw = TIFFClientOpenExt("Compositor image", "r", &reader,
        [](thandle_t handle, void *out, tmsize_t count) -> tmsize_t {
            auto &r = *static_cast<Reader *>(handle);
            if (count < 0) return 0;
            const size_t n = std::min(static_cast<size_t>(count), r.size - r.offset);
            memcpy(out, r.data + r.offset, n); r.offset += n;
            return static_cast<tmsize_t>(n);
        },
        [](thandle_t, void *, tmsize_t) -> tmsize_t { return 0; },
        [](thandle_t handle, toff_t value, int origin) -> toff_t {
            auto &r = *static_cast<Reader *>(handle);
            uint64_t target = value;
            if (origin != SEEK_SET) {
                const uint64_t base = origin == SEEK_CUR ? r.offset : origin == SEEK_END ? r.size : UINT64_MAX;
                if (base == UINT64_MAX) return toff_t(-1);
                if (value > INT64_MAX) {
                    const uint64_t magnitude = uint64_t(0) - value;
                    if (magnitude > base) return toff_t(-1);
                    target = base - magnitude;
                } else {
                    if (value > UINT64_MAX - base) return toff_t(-1);
                    target = base + value;
                }
            }
            if (target > r.size) return toff_t(-1);
            r.offset = static_cast<size_t>(target);
            return target;
        },
        [](thandle_t) -> int { return 0; },
        [](thandle_t handle) -> toff_t { return static_cast<Reader *>(handle)->size; },
        [](thandle_t, void **, toff_t *) -> int { return 0; },
        [](thandle_t, void *, toff_t) {}, options.get());
    auto tif = std::unique_ptr<TIFF, decltype(&TIFFClose)>(raw, TIFFClose);
    if (!tif) return {};
    uint16_t samples = 0, photo = 0, extras = 0, *extraTypes = nullptr, sampleFormat = 0;
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_SAMPLESPERPIXEL, &samples);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_PHOTOMETRIC, &photo);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_SAMPLEFORMAT, &sampleFormat);
    const bool floating = sampleFormat == SAMPLEFORMAT_IEEEFP;
    const bool grayscale = photo == PHOTOMETRIC_MINISBLACK || photo == PHOTOMETRIC_MINISWHITE;
    const int colors = grayscale ? 1 : 3;
    TIFFGetField(tif.get(), TIFFTAG_EXTRASAMPLES, &extras, &extraTypes);
    if (!floating && (!grayscale || samples != 2)) return {};
    if (floating && !grayscale && photo != PHOTOMETRIC_RGB) return {};
    handled = true;
    const bool hasAlpha = samples == colors + 1;
    if ((samples != colors && !hasAlpha) || (hasAlpha && (extras != 1 || !extraTypes ||
        (extraTypes[0] != EXTRASAMPLE_UNASSALPHA && extraTypes[0] != EXTRASAMPLE_ASSOCALPHA))) ||
        (!hasAlpha && extras != 0)) return {};
    uint32_t width = 0, height = 0;
    uint16_t bits = 0, planar = 0, orient = 1;
    TIFFGetField(tif.get(), TIFFTAG_IMAGEWIDTH, &width); TIFFGetField(tif.get(), TIFFTAG_IMAGELENGTH, &height);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_BITSPERSAMPLE, &bits);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_PLANARCONFIG, &planar);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_SAMPLEFORMAT, &sampleFormat);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_ORIENTATION, &orient);
    if (!width || !height || width > uint32_t(INT_MAX) || height > uint32_t(INT_MAX) ||
        (floating ? bits != 16 && bits != 32 && bits != 64 : (bits != 8 && bits != 16) || sampleFormat != SAMPLEFORMAT_UINT) ||
        (planar != PLANARCONFIG_CONTIG && planar != PLANARCONFIG_SEPARATE)) return {};
    // Account for the actual output allocation, including floating-point samples.
    const int limit = QImageReader::allocationLimit();
    if (limit > 0 && uint64_t(width) * height > uint64_t(limit) * 1024 * 1024 / (floating ? 16 : 8)) return {};
    QImage image(int(width), int(height), floating ? QImage::Format_RGBA32FPx4 : QImage::Format_RGBA64);
    if (image.isNull()) return {};
    const bool separate = planar == PLANARCONFIG_SEPARATE, associated = hasAlpha && extraTypes[0] == EXTRASAMPLE_ASSOCALPHA;
    const double maximum = floating ? 1 : bits == 8 ? 255 : 65535;
    const auto unpack = [&](const std::vector<std::vector<uint8_t>> &planes, uint32_t x, uint32_t y,
                            uint32_t count, size_t rowOffset) -> bool {
        const auto sample = [&](uint32_t i, int c) -> double {
            const auto *p = planes[separate ? c : 0].data() + rowOffset + size_t(i * (separate ? 1 : samples) + c * !separate) * (bits / 8);
            if (floating) {
                if (bits == 16) { qfloat16 value; memcpy(&value, p, 2); return float(value); }
                if (bits == 32) { float value; memcpy(&value, p, 4); return value; }
                double value; memcpy(&value, p, 8); return value;
            }
            if (bits == 8) return *p / maximum;
            uint16_t value; memcpy(&value, p, 2); return value / maximum;
        };
        for (uint32_t i = 0; i < count; ++i) {
            const double originalAlpha = hasAlpha ? sample(i, colors) : 1;
            if (!std::isfinite(originalAlpha)) return false;
            const float a = float(std::clamp(originalAlpha, 0.0, 1.0));
            float rgba[4] = {0, 0, 0, a};
            for (int c = 0; c < 3; ++c) {
                double v = sample(i, grayscale ? 0 : c);
                if (!std::isfinite(v)) return false;
                if (associated) v = a > 0 ? v / a : 0;
                if (!floating) v = std::clamp(v, 0.0, 1.0);
                if (photo == PHOTOMETRIC_MINISWHITE) v = 1 - v;
                if (std::abs(v) > std::numeric_limits<float>::max()) return false;
                rgba[c] = float(v);
            }
            if (floating) memcpy(image.scanLine(int(y)) + size_t(x + i) * 16, rgba, 16);
            else reinterpret_cast<QRgba64 *>(image.scanLine(int(y)))[x + i] = QRgba64::fromRgba64(
                uint16_t(std::lround(rgba[0] * 65535)), uint16_t(std::lround(rgba[1] * 65535)),
                uint16_t(std::lround(rgba[2] * 65535)), uint16_t(std::lround(a * 65535)));
        }
        return true;
    };
    const bool tiled = TIFFIsTiled(tif.get());
    uint32_t blockWidth = width, blockHeight = 0;
    if (tiled) {
        TIFFGetField(tif.get(), TIFFTAG_TILEWIDTH, &blockWidth); TIFFGetField(tif.get(), TIFFTAG_TILELENGTH, &blockHeight);
    } else TIFFGetFieldDefaulted(tif.get(), TIFFTAG_ROWSPERSTRIP, &blockHeight);
    const uint64_t rowBytes = tiled ? TIFFTileRowSize64(tif.get()) : TIFFScanlineSize64(tif.get());
    const uint64_t blockBytes = tiled ? TIFFTileSize64(tif.get()) : TIFFStripSize64(tif.get());
    if (!blockWidth || !blockHeight || !blockBytes || blockBytes > uint64_t(bufferLimit) ||
        rowBytes < uint64_t(blockWidth) * (separate ? 1 : samples) * (bits / 8)) return {};
    std::vector<std::vector<uint8_t>> planes;
    try {
        planes.resize(separate ? samples : 1);
        for (auto &plane : planes) plane.resize(blockBytes);
    } catch (const std::bad_alloc &) { return {}; }
    for (uint32_t y = 0; y < height;) {
        const uint32_t rows = std::min(blockHeight, height - y);
        for (uint32_t x = 0; x < width;) {
            const uint32_t columns = std::min(blockWidth, width - x);
            const auto read = [&](std::vector<uint8_t> &buffer, uint16_t plane) -> tmsize_t {
                return tiled ? TIFFReadEncodedTile(tif.get(), TIFFComputeTile(tif.get(), x, y, 0, plane), buffer.data(), tmsize_t(blockBytes))
                             : TIFFReadEncodedStrip(tif.get(), TIFFComputeStrip(tif.get(), y, plane), buffer.data(), tmsize_t(blockBytes));
            };
            if (!rowBytes || rows > blockBytes / rowBytes) return {};
            const uint64_t needed = rowBytes * rows;
            for (size_t plane = 0; plane < planes.size(); ++plane)
                if (read(planes[plane], uint16_t(plane)) < tmsize_t(needed)) return {};
            for (uint32_t row = 0; row < rows; ++row)
                if (!unpack(planes, x, y + row, columns, rowBytes * row)) return {};
            x += columns;
        }
        y += rows;
    }
    uint32_t profileSize = 0; void *profile = nullptr;
    if (TIFFGetField(tif.get(), TIFFTAG_ICCPROFILE, &profileSize, &profile)) {
        if (!profile || !profileSize || profileSize > 4 * 1024 * 1024) return {};
        const QColorSpace space = QColorSpace::fromIccProfile(QByteArray(static_cast<const char *>(profile), profileSize));
        if (!space.isValid()) return {};
        if (floating && space.colorModel() == QColorSpace::ColorModel::Gray) {
            // Qt's scalar float transform treats gray as RGB and introduces a color cast.
            // Keep gray as one channel through ICC conversion, with alpha outside the transform.
            const auto closeProfile = [](cmsHPROFILE p) { if (p) cmsCloseProfile(p); };
            std::unique_ptr<void, decltype(closeProfile)> source(cmsOpenProfileFromMem(profile, profileSize), closeProfile);
            const cmsCIExyY white = {0.3127, 0.3290, 1};
            const cmsCIExyYTRIPLE primaries = {{0.64, 0.33, 1}, {0.30, 0.60, 1}, {0.15, 0.06, 1}};
            std::unique_ptr<cmsToneCurve, decltype(&cmsFreeToneCurve)> gamma(cmsBuildGamma(nullptr, 1), cmsFreeToneCurve);
            if (!source || !gamma) return {};
            cmsToneCurve *curves[] = {gamma.get(), gamma.get(), gamma.get()};
            std::unique_ptr<void, decltype(closeProfile)> destination(cmsCreateRGBProfile(&white, &primaries, curves), closeProfile);
            if (!destination) return {};
            std::unique_ptr<void, decltype(&cmsDeleteTransform)> transform(
                cmsCreateTransform(source.get(), TYPE_GRAY_FLT, destination.get(), TYPE_RGB_FLT,
                                   INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE), cmsDeleteTransform);
            if (!transform) return {};
            for (int y = 0; y < image.height(); ++y) {
                auto *row = reinterpret_cast<QRgbaFloat32 *>(image.scanLine(y));
                for (int x = 0; x < image.width(); ++x) {
                    const float gray = row[x].red(); float rgb[3];
                    cmsDoTransform(transform.get(), &gray, rgb, 1);
                    if (!std::isfinite(rgb[0]) || !std::isfinite(rgb[1]) || !std::isfinite(rgb[2])) return {};
                    row[x] = QRgbaFloat32{rgb[0], rgb[1], rgb[2], row[x].alpha()};
                }
            }
            image.setColorSpace(QColorSpace(QColorSpace::SRgbLinear));
        }
        else if (floating && space.colorModel() == QColorSpace::ColorModel::Rgb) {
            const QColorTransform transform = space.transformationToColorSpace(QColorSpace(QColorSpace::SRgbLinear));
            for (int y = 0; y < image.height(); ++y) {
                auto *row = reinterpret_cast<QRgbaFloat32 *>(image.scanLine(y));
                for (int x = 0; x < image.width(); ++x) row[x] = transform.map(row[x]);
            }
            image.setColorSpace(QColorSpace(QColorSpace::SRgbLinear));
        }
        else if (space.colorModel() == QColorSpace::ColorModel::Gray) image = grayAlphaToSRGB(image, space);
        else if (space.colorModel() == QColorSpace::ColorModel::Rgb) { image.setColorSpace(space); image = toSRGB(image); }
        else return {};
    } else image.setColorSpace(QColorSpace(floating ? QColorSpace::SRgbLinear : QColorSpace::SRgb));
    if (image.isNull()) return {};
    float xResolution = 0, yResolution = 0; uint16_t unit = RESUNIT_NONE;
    TIFFGetField(tif.get(), TIFFTAG_XRESOLUTION, &xResolution); TIFFGetField(tif.get(), TIFFTAG_YRESOLUTION, &yResolution);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_RESOLUTIONUNIT, &unit);
    const double factor = unit == RESUNIT_INCH ? 1 / 0.0254 : unit == RESUNIT_CENTIMETER ? 100 : 0;
    if (factor && xResolution > 0 && xResolution * factor < INT_MAX) image.setDotsPerMeterX(int(std::lround(xResolution * factor)));
    if (factor && yResolution > 0 && yResolution * factor < INT_MAX) image.setDotsPerMeterY(int(std::lround(yResolution * factor)));
    orientation = orient >= 1 && orient <= 8 ? orient : 1;
    return image;
}

// Qt expands grayscale PNGs with alpha to RGB, then rejects their gray ICC profile as incompatible with
// that pixel format. Recover only that profile; keep the original alpha outside the gray conversion.
QImage grayPNGToSRGB(QImage image, const uint8_t *data, size_t length) {
    if (image.colorSpace().isValid() || !image.hasAlphaChannel() || length < 33 ||
        memcmp(data, "\x89PNG\r\n\x1a\n", 8) || memcmp(data + 12, "IHDR", 4) ||
        (data[25] != 0 && data[25] != 4)) return image;
    const auto read32 = [](const uint8_t *p) -> uint32_t {
        return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
    };
    constexpr size_t profileLimit = 4 * 1024 * 1024;
    for (size_t offset = 8; length - offset >= 12;) {
        const uint32_t size = read32(data + offset);
        if (size > length - offset - 12) return image;
        const uint8_t *type = data + offset + 4, *payload = type + 4;
        if (!memcmp(type, "iCCP", 4)) {
            if (size > profileLimit || crc32(0, type, size + 4) != read32(payload + size)) return image;
            const auto *separator = static_cast<const uint8_t *>(memchr(payload, 0, size));
            if (!separator || separator == payload || separator - payload > 79 ||
                size - size_t(separator - payload) < 3 || separator[1] != 0)
                return image;
            QByteArray profile(static_cast<qsizetype>(profileLimit), Qt::Uninitialized);
            uLongf outputSize = profileLimit;
            if (uncompress(reinterpret_cast<Bytef *>(profile.data()), &outputSize, separator + 2,
                           static_cast<uLong>(payload + size - separator - 2)) != Z_OK) return image;
            profile.resize(static_cast<qsizetype>(outputSize));
            const QColorSpace space = QColorSpace::fromIccProfile(profile);
            if (!space.isValid() || space.colorModel() != QColorSpace::ColorModel::Gray) return image;
            return grayAlphaToSRGB(image, space);
        }
        if (!memcmp(type, "IDAT", 4) || !memcmp(type, "IEND", 4)) break;
        offset += size_t(size) + 12;
    }
    return image;
}

#if defined(COMPOSITOR_HAS_LIBHEIF)
// The color space a HEIF image declares: an embedded ICC profile, else its CICP (nclx) primaries and transfer; none
// declared is sRGB.
QColorSpace heifColorSpace(const heif_image_handle *handle) {
    const heif_color_profile_type type = heif_image_handle_get_color_profile_type(handle);
    if (type == heif_color_profile_type_prof || type == heif_color_profile_type_rICC) {
        const size_t size = heif_image_handle_get_raw_color_profile_size(handle);
        if (size > 4 * 1024 * 1024) return {};   // do not allocate an unbounded embedded profile
        QByteArray icc(static_cast<qsizetype>(size), Qt::Uninitialized);
        if (!icc.isEmpty() && heif_image_handle_get_raw_color_profile(handle, icc.data()).code == heif_error_Ok) {
            const QColorSpace space = QColorSpace::fromIccProfile(icc);
            if (space.isValid()) return space;
        }
    }
    heif_color_profile_nclx *nclx = nullptr;
    QColorSpace space(QColorSpace::SRgb);
    if (heif_image_handle_get_nclx_color_profile(handle, &nclx).code == heif_error_Ok && nclx) {
        auto transfer = QColorSpace::TransferFunction::Custom;
        float gamma = 0;
        bool bt709 = false;
        switch (nclx->transfer_characteristics) {
            case heif_transfer_characteristic_unspecified:
            case heif_transfer_characteristic_IEC_61966_2_1: transfer = QColorSpace::TransferFunction::SRgb; break;
            case heif_transfer_characteristic_linear: transfer = QColorSpace::TransferFunction::Linear; break;
            case heif_transfer_characteristic_ITU_R_BT_470_6_System_M: transfer = QColorSpace::TransferFunction::Gamma; gamma = 2.2f; break;
            case heif_transfer_characteristic_ITU_R_BT_470_6_System_B_G: transfer = QColorSpace::TransferFunction::Gamma; gamma = 2.8f; break;
            case heif_transfer_characteristic_ITU_R_BT_709_5:
            case heif_transfer_characteristic_ITU_R_BT_601_6: bt709 = true; break;
            case heif_transfer_characteristic_ITU_R_BT_2020_2_10bit:
            case heif_transfer_characteristic_ITU_R_BT_2020_2_12bit: transfer = QColorSpace::TransferFunction::Bt2020; break;
            case heif_transfer_characteristic_ITU_R_BT_2100_0_PQ: transfer = QColorSpace::TransferFunction::St2084; break;
            case heif_transfer_characteristic_ITU_R_BT_2100_0_HLG: transfer = QColorSpace::TransferFunction::Hlg; break;
            default: break;   // an unsupported declared curve must not be silently treated as sRGB
        }
        if (transfer != QColorSpace::TransferFunction::Custom || bt709) {
            const auto initialTransfer = bt709 ? QColorSpace::TransferFunction::Linear : transfer;
            if (nclx->color_primaries == heif_color_primaries_unspecified) {
                space = QColorSpace(QColorSpace::Primaries::SRgb, initialTransfer, gamma);
            } else {
                space = QColorSpace(QPointF(nclx->color_primary_white_x, nclx->color_primary_white_y),
                    QPointF(nclx->color_primary_red_x, nclx->color_primary_red_y),
                    QPointF(nclx->color_primary_green_x, nclx->color_primary_green_y),
                    QPointF(nclx->color_primary_blue_x, nclx->color_primary_blue_y), initialTransfer, gamma);
            }
            if (bt709) {
                QList<uint16_t> curve;
                curve.reserve(65536);
                uint16_t previous = 0;
                for (int i = 0; i <= 65535; ++i) {
                    const double v = i / 65535.0;
                    const double linear = v < 0.081 ? v / 4.5 : std::pow((v + 0.099) / 1.099, 1.0 / 0.45);
                    // The rounded BT.709 constants produce a tiny downward step at 0.081. Qt rejects a
                    // nonmonotonic table, leaving the initial linear curve in place. Flatten that step
                    // (less than one 8-bit level) so the declared transfer is actually applied.
                    previous = std::max(previous, static_cast<uint16_t>(std::clamp(std::lround(linear * 65535), 0L, 65535L)));
                    curve.append(previous);
                }
                space.setTransferFunction(curve);
            }
        } else {
            space = {};
        }
        heif_nclx_color_profile_free(nclx);
    }
    return space;
}

int32_t decodeHeif(const uint8_t *data, size_t length, uint8_t **out, int32_t *width, int32_t *height, int32_t *channels,
                   int32_t *orientation, char *uti, size_t utiCapacity, bool deepAllowed) {
    heif_context *ctx = heif_context_alloc();
    heif_image_handle *handle = nullptr;
    heif_image *img = nullptr;
    int32_t rc = -3;
    if (heif_context_read_from_memory_without_copy(ctx, data, length, nullptr).code == heif_error_Ok &&
        heif_context_get_primary_image_handle(ctx, &handle).code == heif_error_Ok) {
        heif_decoding_options *opts = heif_decoding_options_alloc();
        // libheif applies the file's rotation/mirroring itself, so the pixels come back upright.
        const auto chroma = Q_BYTE_ORDER == Q_LITTLE_ENDIAN ? heif_chroma_interleaved_RRGGBBAA_LE : heif_chroma_interleaved_RRGGBBAA_BE;
        if (heif_decode_image(handle, &img, heif_colorspace_RGB, chroma, opts).code == heif_error_Ok) {
            int stride = 0;
            const uint8_t *raw = heif_image_get_plane_readonly(img, heif_channel_interleaved, &stride);
            const int w = heif_image_get_width(img, heif_channel_interleaved), h = heif_image_get_height(img, heif_channel_interleaved);
            const int bits = heif_image_get_bits_per_pixel_range(img, heif_channel_interleaved);
            // libheif stores 10/12-bit channels in 16-bit words without scaling them to 0...65535. Keep their source
            // precision through color conversion rather than reducing to RGBA8 before applying the profile.
            QImage decoded = raw && w > 0 && h > 0 && bits > 0 && bits <= 16
                ? QImage(w, h, QImage::Format_RGBA64) : QImage();
            if (!decoded.isNull()) {
                const uint32_t maximum = (uint32_t(1) << bits) - 1;
                for (int y = 0; y < h; ++y) {
                    const auto *source = reinterpret_cast<const uint16_t *>(raw + static_cast<size_t>(y) * stride);
                    auto *target = reinterpret_cast<uint16_t *>(decoded.scanLine(y));
                    for (int x = 0; x < w; ++x) for (int c = 0; c < 4; ++c)
                        target[x * 4 + c] = static_cast<uint16_t>((uint32_t(source[x * 4 + c]) * 65535 + maximum / 2) / maximum);
                }
            }
            int layout = kLayoutRGBA8;
            if (!decoded.isNull()) {
                const QColorSpace space = heifColorSpace(handle);
                if (!space.isValid()) decoded = {};
                else {
                    decoded.setColorSpace(space);
                    const bool hdr = deepAllowed && (space.transferFunction() == QColorSpace::TransferFunction::St2084 ||
                                                     space.transferFunction() == QColorSpace::TransferFunction::Hlg);
                    if (hdr) {
                        // Convert encoded PQ/HLG and wide primaries directly into linear float pixels. An integer
                        // sRGB intermediate would clip light above white before the upstream HDR importer sees it.
                        decoded = decoded.convertedToColorSpace(QColorSpace(QColorSpace::SRgbLinear),
                                                                 QImage::Format_RGBA32FPx4);
                        decoded = decoded.convertToFormat(QImage::Format_RGBA32FPx4_Premultiplied);
                        layout = kLayoutRGBAFloat;
                    } else {
                        layout = deepAllowed && bits > 8 ? kLayoutRGBA16 : kLayoutRGBA8;
                        decoded = toSRGB(decoded).convertToFormat(layout == kLayoutRGBA16 ? QImage::Format_RGBA64_Premultiplied
                                                                                        : QImage::Format_RGBA8888_Premultiplied);
                    }
                }
            }
            const uint8_t *src = decoded.isNull() ? nullptr : decoded.constBits();
            stride = decoded.isNull() ? 0 : static_cast<int>(decoded.bytesPerLine());
            const size_t rowBytes = static_cast<size_t>(w) * layout;
            auto *pixels = src ? static_cast<uint8_t *>(malloc(rowBytes * h)) : nullptr;
            if (src && pixels && w > 0 && h > 0) {
                for (int y = 0; y < h; ++y) memcpy(pixels + size_t(y) * rowBytes, src + size_t(y) * stride, rowBytes);
                *out = pixels;
                if (width) *width = w;
                if (height) *height = h;
                if (channels) *channels = layout;
                if (orientation) *orientation = 1;
                // Typed by major brand as CGImageSourceGetType does: AV1 is AVIF, the generic MIAF brands (cameras'
                // .hif/.heif) are public.heif, HEVC brands are public.heic.
                const bool avif = length >= 12 && (memcmp(data + 8, "avif", 4) == 0 || memcmp(data + 8, "avis", 4) == 0);
                const bool heif = length >= 12 && (memcmp(data + 8, "mif1", 4) == 0 || memcmp(data + 8, "msf1", 4) == 0);
                const char *type = avif ? "public.avif" : heif ? "public.heif" : "public.heic";
                if (uti && utiCapacity) { strncpy(uti, type, utiCapacity - 1); uti[utiCapacity - 1] = 0; }
                rc = 0;
            } else {
                free(pixels);
            }
        }
        heif_decoding_options_free(opts);
    }
    if (img) heif_image_release(img);
    if (handle) heif_image_handle_release(handle);
    heif_context_free(ctx);
    return rc;
}

int32_t encodeHeif(const uint8_t *pixels, int32_t width, int32_t height, int32_t channels, double quality,
                   uint8_t **out, size_t *outLength) {
    if (channels != 4) return -1;
    heif_context *ctx = heif_context_alloc();
    heif_encoder *encoder = nullptr;
    // HEVC is what a .heic normally holds; where only an AV1 encoder is installed the same HEIF container carries AV1.
    if (heif_context_get_encoder_for_format(ctx, heif_compression_HEVC, &encoder).code != heif_error_Ok)
        heif_context_get_encoder_for_format(ctx, heif_compression_AV1, &encoder);
    int32_t rc = -2;
    heif_image *img = nullptr;
    if (encoder && heif_image_create(width, height, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, &img).code == heif_error_Ok &&
        heif_image_add_plane(img, heif_channel_interleaved, width, height, 8).code == heif_error_Ok) {
        int stride = 0;
        uint8_t *dst = heif_image_get_plane(img, heif_channel_interleaved, &stride);
        for (int y = 0; y < height; ++y)
            for (int x = 0; x < width; ++x) {  // premultiplied -> straight
                const uint8_t *p = pixels + (static_cast<size_t>(y) * width + x) * 4;
                uint8_t *q = dst + static_cast<size_t>(y) * stride + x * 4;
                const int a = p[3];
                for (int c = 0; c < 3; ++c) q[c] = a == 0 ? 0 : static_cast<uint8_t>(std::min(255, (p[c] * 255 + a / 2) / a));
                q[3] = static_cast<uint8_t>(a);
            }
        // Tagged sRGB (CICP 1/13: BT.709 primaries, the sRGB curve), what the document's pixels are.
        if (heif_color_profile_nclx *nclx = heif_nclx_color_profile_alloc()) {
            nclx->color_primaries = heif_color_primaries_ITU_R_BT_709_5;
            nclx->transfer_characteristics = heif_transfer_characteristic_IEC_61966_2_1;
            nclx->matrix_coefficients = heif_matrix_coefficients_ITU_R_BT_601_6;
            nclx->full_range_flag = 1;
            heif_image_set_nclx_color_profile(img, nclx);
            heif_nclx_color_profile_free(nclx);
        }
        if (quality >= 0) heif_encoder_set_lossy_quality(encoder, static_cast<int>(quality * 100 + 0.5));
        else heif_encoder_set_lossless(encoder, 1);
        heif_encoding_options *opts = heif_encoding_options_alloc();
        heif_image_handle *handle = nullptr;
        if (heif_context_encode_image(ctx, img, encoder, opts, &handle).code == heif_error_Ok) {
            struct Writer { std::vector<uint8_t> bytes; } writer;
            heif_writer w{};
            w.writer_api_version = 1;
            w.write = [](heif_context *, const void *d, size_t n, void *ud) -> heif_error {
                auto *wr = static_cast<Writer *>(ud);
                wr->bytes.insert(wr->bytes.end(), static_cast<const uint8_t *>(d), static_cast<const uint8_t *>(d) + n);
                return {heif_error_Ok, heif_suberror_Unspecified, "ok"};
            };
            if (heif_context_write(ctx, &w, &writer).code == heif_error_Ok && !writer.bytes.empty()) {
                auto *copy = static_cast<uint8_t *>(malloc(writer.bytes.size()));
                if (copy) {
                    memcpy(copy, writer.bytes.data(), writer.bytes.size());
                    *out = copy;
                    *outLength = writer.bytes.size();
                    rc = 0;
                }
            }
            heif_image_handle_release(handle);
        }
        heif_encoding_options_free(opts);
    }
    if (img) heif_image_release(img);
    if (encoder) heif_encoder_release(encoder);
    heif_context_free(ctx);
    return rc;
}
#endif

const char *utiForFormat(const QByteArray &format) {
    const QByteArray f = format.toLower();
    if (f == "png") return "public.png";
    if (f == "jpg" || f == "jpeg") return "public.jpeg";
    if (f == "tif" || f == "tiff") return "public.tiff";
    if (f == "webp") return "org.webmproject.webp";
    if (f == "bmp") return "com.microsoft.bmp";
    if (f == "gif") return "com.compuserve.gif";
    if (f == "heic" || f == "heif") return "public.heic";
    if (f == "hdr") return "public.radiance";
    return nullptr;
}

const char *formatForUti(const char *uti) {
    if (!uti) return nullptr;
    if (!strcmp(uti, "public.png")) return "png";
    if (!strcmp(uti, "public.jpeg")) return "jpeg";
    if (!strcmp(uti, "public.tiff")) return "tiff";
    if (!strcmp(uti, "org.webmproject.webp")) return "webp";
    if (!strcmp(uti, "com.microsoft.bmp")) return "bmp";
    if (!strcmp(uti, "com.compuserve.gif")) return "gif";
    if (!strcmp(uti, "public.heic") || !strcmp(uti, "public.heif")) return "heic";
    return nullptr;
}

// Qt's transformation flags -> EXIF orientation 1...8.
int exifOrientation(QImageIOHandler::Transformations t) {
    const bool mirror = t.testFlag(QImageIOHandler::TransformationMirror);
    const bool flip = t.testFlag(QImageIOHandler::TransformationFlip);
    const bool rotate = t.testFlag(QImageIOHandler::TransformationRotate90);
    if (!rotate) return mirror && flip ? 3 : mirror ? 2 : flip ? 4 : 1;
    return mirror && flip ? 7 : mirror ? 5 : flip ? 7 : 6;
}

// EXIF orientation 1...8 -> Qt's transformation flags (inverse of exifOrientation).
QImageIOHandler::Transformations transformationForExif(int o) {
    using T = QImageIOHandler;
    switch (o) {
        case 2: return T::TransformationMirror;
        case 3: return T::TransformationRotate180;
        case 4: return T::TransformationFlip;
        case 5: return T::TransformationFlipAndRotate90;
        case 6: return T::TransformationRotate90;
        case 7: return T::TransformationMirrorAndRotate90;
        case 8: return T::TransformationRotate270;
        default: return T::TransformationNone;
    }
}

void writeUti(char *uti, size_t capacity, const char *type) {
    if (uti && capacity) { strncpy(uti, type, capacity - 1); uti[capacity - 1] = 0; }
}

#if defined(COMPOSITOR_HAS_OPENEXR)
bool isEXR(const uint8_t *d, size_t n) { return n >= 4 && d[0] == 0x76 && d[1] == 0x2f && d[2] == 0x31 && d[3] == 0x01; }

// An EXR read from memory.
class MemoryIStream : public Imf::IStream {
public:
    MemoryIStream(const uint8_t *data, size_t length) : Imf::IStream("memory"), data_(data), length_(length) {}
    bool read(char c[], int n) override {
        if (n < 0 || position_ + uint64_t(n) > length_) throw std::runtime_error("EXR read past the end");
        memcpy(c, data_ + position_, size_t(n));
        position_ += uint64_t(n);
        return position_ < length_;
    }
    uint64_t tellg() override { return position_; }
    void seekg(uint64_t pos) override { position_ = pos; }
private:
    const uint8_t *data_;
    size_t length_;
    uint64_t position_ = 0;
};

// An EXR written to memory.
class MemoryOStream : public Imf::OStream {
public:
    MemoryOStream() : Imf::OStream("memory") {}
    void write(const char c[], int n) override {
        if (position_ + uint64_t(n) > bytes.size()) bytes.resize(size_t(position_ + uint64_t(n)));
        memcpy(bytes.data() + position_, c, size_t(n));
        position_ += uint64_t(n);
    }
    uint64_t tellp() override { return position_; }
    void seekp(uint64_t pos) override { position_ = pos; }
    std::vector<uint8_t> bytes;
private:
    uint64_t position_ = 0;
};

// EXR -> RGBA 32-bit float, premultiplied linear light (EXR's own convention), the data window's pixels.
int32_t decodeEXR(const uint8_t *data, size_t length, uint8_t **out, int32_t *width, int32_t *height, int32_t *channels,
                  double *dpi, int32_t *orientation, char *uti, size_t utiCapacity) {
    try {
        MemoryIStream stream(data, length);
        Imf::RgbaInputFile file(stream);
        const Imath::Box2i window = file.dataWindow();
        const int w = window.max.x - window.min.x + 1, h = window.max.y - window.min.y + 1;
        if (w <= 0 || h <= 0 || int64_t(w) * h > 1'000'000'000) return -3;
        std::vector<Imf::Rgba> rgba(size_t(w) * h);
        file.setFrameBuffer(rgba.data() - window.min.x - size_t(window.min.y) * w, 1, size_t(w));
        file.readPixels(window.min.y, window.max.y);
        const bool alpha = file.channels() & Imf::WRITE_A;
        auto *pixels = static_cast<float *>(malloc(size_t(w) * h * 16));
        if (!pixels) return -4;
        for (size_t i = 0; i < rgba.size(); ++i) {
            const float a = alpha ? float(rgba[i].a) : 1.0f;
            const float values[4] = {float(rgba[i].r), float(rgba[i].g), float(rgba[i].b), a};
            for (int c = 0; c < 4; ++c) pixels[i * 4 + c] = std::isfinite(values[c]) ? values[c] : 0.0f;
        }
        *out = reinterpret_cast<uint8_t *>(pixels);
        if (width) *width = w;
        if (height) *height = h;
        if (channels) *channels = kLayoutRGBAFloat;
        if (dpi) *dpi = 0;
        if (orientation) *orientation = 1;
        writeUti(uti, utiCapacity, "com.ilm.openexr-image");
        return 0;
    } catch (const std::exception &) {
        return -3;
    }
}

// RGBA 32-bit float, premultiplied linear light -> a half-float RGBA EXR, ZIP compressed (as Apple's ImageIO writes).
int32_t encodeEXR(const float *pixels, int32_t width, int32_t height, double dpi, uint8_t **out, size_t *outLength) {
    try {
        Imf::Header header(width, height);
        header.compression() = Imf::ZIP_COMPRESSION;
        (void)dpi;
        std::vector<Imf::Rgba> rgba(size_t(width) * height);
        for (size_t i = 0; i < rgba.size(); ++i)
            rgba[i] = Imf::Rgba(half(pixels[i * 4]), half(pixels[i * 4 + 1]), half(pixels[i * 4 + 2]), half(pixels[i * 4 + 3]));
        MemoryOStream stream;
        {
            Imf::RgbaOutputFile file(stream, header, Imf::WRITE_RGBA);
            file.setFrameBuffer(rgba.data(), 1, size_t(width));
            file.writePixels(height);
        }
        auto *copy = static_cast<uint8_t *>(malloc(stream.bytes.size()));
        if (!copy) return -3;
        memcpy(copy, stream.bytes.data(), stream.bytes.size());
        *out = copy;
        *outLength = stream.bytes.size();
        return 0;
    } catch (const std::exception &) {
        return -2;
    }
}
#endif

// Qt's float formats (Radiance HDR, a float TIFF): kept as linear-light floats, premultiplied, nothing clipped.
bool isFloatFormat(QImage::Format f) {
    return f == QImage::Format_RGBA32FPx4 || f == QImage::Format_RGBA32FPx4_Premultiplied || f == QImage::Format_RGBX32FPx4
        || f == QImage::Format_RGBA16FPx4 || f == QImage::Format_RGBA16FPx4_Premultiplied || f == QImage::Format_RGBX16FPx4;
}
// 16 bits a color channel in the file.
bool isDeepFormat(QImage::Format f) {
    return f == QImage::Format_RGBA64 || f == QImage::Format_RGBA64_Premultiplied || f == QImage::Format_RGBX64;
}

// Linear-light float RGBA (premultiplied) -> 8-bit sRGB premultiplied, clipped at white: an EXR for an 8-bit caller.
uint8_t *eightBitFromLinear(const float *pixels, size_t count) {
    auto *out = static_cast<uint8_t *>(malloc(count * 4));
    if (!out) return nullptr;
    for (size_t i = 0; i < count; ++i) {
        const float a = std::clamp(pixels[i * 4 + 3], 0.0f, 1.0f);
        for (int c = 0; c < 3; ++c) {
            const float v = a > 0 ? std::clamp(pixels[i * 4 + c] / pixels[i * 4 + 3], 0.0f, 1.0f) : 0.0f;
            const float encoded = v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1 / 2.4f) - 0.055f;
            out[i * 4 + c] = uint8_t(std::lround(encoded * a * 255));
        }
        out[i * 4 + 3] = uint8_t(std::lround(a * 255));
    }
    return out;
}

// `deep`: hand back 16-bit color files at 16 bits and float files as linear floats (the deep entry point, which
// compat ImageIO uses as Apple's ImageIO keeps a file's depth); otherwise everything at 8 bits, as the codec ABI's
// original decode callback always has.
int32_t decodeAny(const uint8_t *data, size_t length, uint8_t **out, int32_t *width, int32_t *height,
                  int32_t *channels, double *dpi, int32_t *orientation, char *uti, size_t utiCapacity, bool deepAllowed,
                  bool straight = false) {
    if (!data || !length || !out) return -1;
#if defined(COMPOSITOR_HAS_OPENEXR)
    if (isEXR(data, length)) {
        int32_t w = 0, h = 0, layout = 0;
        uint8_t *floats = nullptr;
        const int32_t rc = decodeEXR(data, length, &floats, &w, &h, &layout, dpi, orientation, uti, utiCapacity);
        if (rc != 0) return rc;
        if (!deepAllowed) {
            uint8_t *eight = eightBitFromLinear(reinterpret_cast<const float *>(floats), size_t(w) * h);
            free(floats);
            if (!eight) return -4;
            floats = eight;
            layout = kLayoutRGBA8;
        }
        *out = floats;
        if (width) *width = w;
        if (height) *height = h;
        if (channels) *channels = layout;
        return 0;
    }
#endif
#if defined(COMPOSITOR_HAS_LIBHEIF)
    if (isHeifContainer(data, length)) return decodeHeif(data, length, out, width, height, channels, orientation, uti, utiCapacity, deepAllowed);
#endif
    QByteArray bytes = QByteArray::fromRawData(reinterpret_cast<const char *>(data), static_cast<qsizetype>(length));
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);
    reader.setAutoTransform(false);
    const char *type = utiForFormat(reader.format());
    if (!type) return -2;
    const auto transform = reader.transformation();
    bool nativeTIFF = false;
    int nativeOrientation = 1;
    QImage image;
    if (!strcmp(type, "public.tiff")) image = decodeNativeTIFF(data, length, nativeTIFF, nativeOrientation);
    if (!nativeTIFF) image = reader.read();
    if (image.isNull()) return -3;
    // As Apple's ImageIO: float files (Radiance HDR) come as linear-light floats, 16-bit color files at 16 bits.
    const bool floating = deepAllowed && isFloatFormat(image.format());
    const bool deep = deepAllowed && !floating && isDeepFormat(image.format());
    if (!floating) {
        image = grayPNGToSRGB(image, data, length);
        image = toSRGB(image);
        if (image.isNull()) return -3;
    }

    // Gray only when the file itself is gray; an RGB file whose pixels happen to be neutral stays colour.
    const bool gray = image.format() == QImage::Format_Grayscale8 || image.format() == QImage::Format_Grayscale16;
    QImage converted = gray ? image.convertToFormat(QImage::Format_Grayscale8)
                     : floating ? image.convertToFormat(QImage::Format_RGBA32FPx4_Premultiplied)
                     : deep ? image.convertToFormat(QImage::Format_RGBA64_Premultiplied)
                            : image.convertToFormat(straight ? QImage::Format_RGBA8888 : QImage::Format_RGBA8888_Premultiplied);
    const int ch = gray ? kLayoutGray8 : floating ? kLayoutRGBAFloat : deep ? kLayoutRGBA16 : kLayoutRGBA8;
    const size_t bytesPerLine = static_cast<size_t>(converted.width()) * ch;
    auto *pixels = static_cast<uint8_t *>(malloc(bytesPerLine * converted.height()));
    if (!pixels) return -4;
    for (int y = 0; y < converted.height(); ++y) memcpy(pixels + y * bytesPerLine, converted.constScanLine(y), bytesPerLine);
    *out = pixels;
    if (width) *width = converted.width();
    if (height) *height = converted.height();
    if (channels) *channels = ch;
    if (dpi) *dpi = image.dotsPerMeterX() > 0 ? image.dotsPerMeterX() * 0.0254 : 0.0;
    if (orientation) *orientation = nativeTIFF ? nativeOrientation : exifOrientation(transform);
    if (uti && utiCapacity) { strncpy(uti, type, utiCapacity - 1); uti[utiCapacity - 1] = 0; }
    return 0;
}

int32_t decodeImage(const uint8_t *data, size_t length, uint8_t **out, int32_t *width, int32_t *height,
                    int32_t *channels, double *dpi, int32_t *orientation, char *uti, size_t utiCapacity) {
    return decodeAny(data, length, out, width, height, channels, dpi, orientation, uti, utiCapacity, false);
}
int32_t decodeImageDeep(const uint8_t *data, size_t length, uint8_t **out, int32_t *width, int32_t *height,
                        int32_t *channels, double *dpi, int32_t *orientation, char *uti, size_t utiCapacity) {
    return decodeAny(data, length, out, width, height, channels, dpi, orientation, uti, utiCapacity, true);
}

// Optional source-sample access. Keep the legacy canonical decoder unchanged for rendering clients.
int32_t decodeStraightImage(const uint8_t *data, size_t length, uint8_t **out, int32_t *width, int32_t *height,
                           int32_t *channels, double *dpi, int32_t *orientation, char *uti, size_t utiCapacity) {
    static const uint8_t png[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (!data || length < 33 || memcmp(data, png, sizeof(png)) || data[24] != 8) return -2;
    return decodeAny(data, length, out, width, height, channels, dpi, orientation, uti, utiCapacity, false, true);
}

// A CMYK JPEG or TIFF as its inks and embedded profile (nullptr when it names none). Anything else: -2.
int32_t decodeCMYK(const uint8_t *data, size_t length, uint8_t **inks, int32_t *width, int32_t *height, uint8_t **profile,
                   size_t *profileLength, double *dpi, char *uti, size_t utiCapacity) {
    if (!data || !length || !inks || !profile || !profileLength) return -1;
    QByteArray bytes = QByteArray::fromRawData(reinterpret_cast<const char *>(data), static_cast<qsizetype>(length));
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);
    reader.setAutoTransform(false);
    const char *type = utiForFormat(reader.format());
    if (!type || (strcmp(type, "public.jpeg") && strcmp(type, "public.tiff"))) return -2;
    if (reader.imageFormat() != QImage::Format_CMYK8888) return -2;
    const QImage image = reader.read();
    if (image.isNull() || image.format() != QImage::Format_CMYK8888) return -3;
    const size_t row = static_cast<size_t>(image.width()) * 4;
    auto *pixels = static_cast<uint8_t *>(malloc(row * image.height()));
    if (!pixels) return -4;
    for (int y = 0; y < image.height(); ++y) memcpy(pixels + y * row, image.constScanLine(y), row);
    const QByteArray icc = image.colorSpace().colorModel() == QColorSpace::ColorModel::Cmyk ? image.colorSpace().iccProfile()
                                                                                              : QByteArray();
    *profile = nullptr;
    *profileLength = 0;
    if (!icc.isEmpty()) {
        *profile = static_cast<uint8_t *>(malloc(static_cast<size_t>(icc.size())));
        if (!*profile) { free(pixels); return -4; }
        memcpy(*profile, icc.constData(), static_cast<size_t>(icc.size()));
        *profileLength = static_cast<size_t>(icc.size());
    }
    *inks = pixels;
    if (width) *width = image.width();
    if (height) *height = image.height();
    if (dpi) *dpi = image.dotsPerMeterX() > 0 ? image.dotsPerMeterX() * 0.0254 : 0.0;
    if (uti && utiCapacity) { strncpy(uti, type, utiCapacity - 1); uti[utiCapacity - 1] = 0; }
    return 0;
}

// Inks (four a pixel) as a CMYK JPEG or LZW TIFF with `profile` embedded, as print shops take it.
int32_t encodeCMYK(const uint8_t *inks, int32_t width, int32_t height, const uint8_t *profile, size_t profileLength,
                   const char *uti, double quality, double dpi, uint8_t **out, size_t *outLength) {
    if (!inks || width <= 0 || height <= 0 || !uti || !out || !outLength) return -1;
    const bool tiff = !strcmp(uti, "public.tiff");
    if (!tiff && strcmp(uti, "public.jpeg")) return -1;
    QImage image = QImage(inks, width, height, width * 4, QImage::Format_CMYK8888).copy();
    if (profile && profileLength) {
        const QColorSpace space = QColorSpace::fromIccProfile(QByteArray(reinterpret_cast<const char *>(profile),
                                                                         static_cast<qsizetype>(profileLength)));
        if (!space.isValid() || space.colorModel() != QColorSpace::ColorModel::Cmyk) return -1;
        image.setColorSpace(space);
    }
    if (dpi > 0) {
        const int dpm = static_cast<int>(dpi / 0.0254 + 0.5);
        image.setDotsPerMeterX(dpm);
        image.setDotsPerMeterY(dpm);
    }
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    QImageWriter writer(&buffer, tiff ? "tiff" : "jpeg");
    if (tiff) writer.setCompression(1);   // LZW
    else if (quality >= 0) writer.setQuality(static_cast<int>(quality * 100 + 0.5));
    if (!writer.write(image)) return -3;
    *out = static_cast<uint8_t *>(malloc(static_cast<size_t>(bytes.size())));
    if (!*out) return -4;
    memcpy(*out, bytes.constData(), static_cast<size_t>(bytes.size()));
    *outLength = static_cast<size_t>(bytes.size());
    return 0;
}

int32_t encodeAny(const uint8_t *pixels, int32_t width, int32_t height, int32_t channels, const char *uti,
                    double quality, double dpi, int32_t orientation, uint8_t **out, size_t *outLength, bool straight) {
#if defined(COMPOSITOR_HAS_LIBHEIF)
    if (uti && pixels && width > 0 && height > 0 && out && outLength &&
        (!strcmp(uti, "public.heic") || !strcmp(uti, "public.heif") || !strcmp(uti, "public.avif")))
        return encodeHeif(pixels, width, height, channels, quality, out, outLength);
#endif
    const char *format = formatForUti(uti);
#if defined(COMPOSITOR_HAS_OPENEXR)
    if (uti && !strcmp(uti, "com.ilm.openexr-image")) {
        if (!pixels || width <= 0 || height <= 0 || channels != kLayoutRGBAFloat || !out || !outLength) return -1;
        return encodeEXR(reinterpret_cast<const float *>(pixels), width, height, dpi, out, outLength);
    }
#endif
    if (!pixels || width <= 0 || height <= 0 || !format || !out || !outLength) return -1;
    QImage image;
    if (channels == kLayoutGray8) {
        image = QImage(pixels, width, height, width, QImage::Format_Grayscale8).copy();
    } else if (channels == kLayoutRGBA8) {
        image = QImage(pixels, width, height, width * 4,
                       straight ? QImage::Format_RGBA8888 : QImage::Format_RGBA8888_Premultiplied).copy();
    } else if (channels == kLayoutRGBA16) {
        // A 16-bit PNG / TIFF, as Apple's ImageIO writes a 16-bit image.
        image = QImage(pixels, width, height, width * 8, QImage::Format_RGBA64_Premultiplied).copy();
    } else {
        return -1;
    }
    if (channels != kLayoutGray8) image.setColorSpace(QColorSpace(QColorSpace::SRgb));   // the document is sRGB: say so in the file
    if (dpi > 0) {
        const int dpm = static_cast<int>(dpi / 0.0254 + 0.5);
        image.setDotsPerMeterX(dpm);
        image.setDotsPerMeterY(dpm);
    }
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    QImageWriter writer(&buffer, format);
    if (quality >= 0) writer.setQuality(static_cast<int>(quality * 100 + 0.5));
    if (orientation > 1 && orientation <= 8) writer.setTransformation(transformationForExif(orientation));
    // JPEG has no alpha: flatten onto white like ImageIO does for opaque destinations.
    if (!strcmp(format, "jpeg") && image.hasAlphaChannel()) {
        QImage flat(image.size(), QImage::Format_RGB32);
        flat.fill(Qt::white);
        QPainter p(&flat);
        p.drawImage(0, 0, image);
        p.end();
        image = flat;
        image.setColorSpace(QColorSpace(QColorSpace::SRgb));
    }
    if (!writer.write(image)) return -2;
    auto *copy = static_cast<uint8_t *>(malloc(static_cast<size_t>(bytes.size())));
    if (!copy) return -3;
    memcpy(copy, bytes.constData(), static_cast<size_t>(bytes.size()));
    *out = copy;
    *outLength = static_cast<size_t>(bytes.size());
    return 0;
}

int32_t encodeImage(const uint8_t *pixels, int32_t width, int32_t height, int32_t channels, const char *uti,
                    double quality, double dpi, int32_t orientation, uint8_t **out, size_t *outLength) {
    return encodeAny(pixels, width, height, channels, uti, quality, dpi, orientation, out, outLength, false);
}

int32_t encodeStraightImage(const uint8_t *pixels, int32_t width, int32_t height, int32_t channels, const char *uti,
                            double quality, double dpi, int32_t orientation, uint8_t **out, size_t *outLength) {
    if (!uti || strcmp(uti, "public.png") || channels != kLayoutRGBA8) return -2;
    return encodeAny(pixels, width, height, channels, uti, quality, dpi, orientation, out, outLength, true);
}

// ---- Text: real fonts for the compat text system (AppKit's NSLayoutManager / NSString measuring and drawing) ----


struct TextLines {
    std::vector<std::unique_ptr<QTextLayout>> paragraphs;
    double width = 0, height = 0, lineHeight = 0, baseline = 0;
    double coordinateScale = 1;
};

// Lays the text out as AppKit does with a fixed line height (min = max): each line `lineHeight` tall, its baseline
// `lineHeight - descent` down, wrapping at `maxWidth` when positive; tracking is extra space after every character.
// A color over part of the text: UTF-16 offsets into the whole string, premultiplied-free RGBA 0...1.
struct ColorRun { int start, length; QColor color; };
struct AttributeRun { int start, length; QTextCharFormat format; double pixelSize; };

// Canonical, nonoverlapping attributed ranges from NSAttributedString. Both
// measuring and drawing use these exact formats, including font and color.
bool attributeRuns(const char *json, int count, double tracking, std::vector<AttributeRun> &runs) {
    const auto document = QJsonDocument::fromJson(json ? QByteArray(json) : QByteArray("[]"));
    if (!document.isArray()) return false;
    int previousEnd = 0;
    for (const auto &value : document.array()) {
        if (!value.isObject()) return false;
        const auto object = value.toObject();
        const double start = object.value("location").toDouble(-1), length = object.value("length").toDouble(-1);
        const double size = object.value("size").toDouble();
        const QString name = object.value("font").toString();
        if (!std::isfinite(start) || !std::isfinite(length) || start != std::floor(start) || length != std::floor(length)
            || start < previousEnd || length <= 0 || start > count || length > count - start
            || !std::isfinite(size) || size <= 0 || size > 2000 || name.isEmpty()) return false;
        QTextCharFormat format;
        QFont font = fontFor(name.toUtf8().constData(), size);
        font.setLetterSpacing(QFont::AbsoluteSpacing, tracking);
        format.setFont(font);
        const auto color = object.value("color").toArray();
        if (!color.isEmpty()) {
            if (color.size() != 4) return false;
            for (const auto &component : color) if (!component.isDouble() || !std::isfinite(component.toDouble()) ||
                                                  component.toDouble() < 0 || component.toDouble() > 1) return false;
            format.setForeground(QColor::fromRgbF(color[0].toDouble(), color[1].toDouble(), color[2].toDouble(), color[3].toDouble()));
        }
        runs.push_back({int(start), int(length), format, size});
        previousEnd = int(start + length);
    }
    return true;
}

TextLines layOut(const char *utf8, const char *fontName, double pixelSize, double tracking, double lineHeight, double maxWidth,
                 const std::vector<ColorRun> &runs = {}, const std::vector<AttributeRun> &attributes = {}) {
    TextLines out;
    // QFontDatabase rounds even floating-point point sizes to whole pixels.
    // Lay out fractional sizes in a larger coordinate space, then draw through
    // its inverse transform. Qt still owns shaping, fallback and mixed-font runs.
    bool fractional = pixelSize != std::round(pixelSize);
    double largestSize = pixelSize;
    for (const auto &run : attributes) {
        fractional = fractional || run.pixelSize != std::round(run.pixelSize);
        largestSize = std::max(largestSize, run.pixelSize);
    }
    const double scale = out.coordinateScale = fractional ? std::max(1.0, std::min(64.0, std::floor(32768 / largestSize))) : 1;
    const QFont font = [&] {
        QFont f = fontFor(fontName, pixelSize * scale);
        f.setLetterSpacing(QFont::AbsoluteSpacing, tracking * scale);
        return f;
    }();
    const QFontMetricsF metrics(font);
    out.lineHeight = lineHeight > 0 ? lineHeight * scale : std::round(metrics.lineSpacing() / scale) * scale;
    out.baseline = out.lineHeight - metrics.descent();
    const QStringList paragraphs = QString::fromUtf8(utf8 ? utf8 : "").split('\n');
    int lines = 0, paragraphStart = 0;
    for (const QString &text : paragraphs) {
        auto layout = std::make_unique<QTextLayout>(text, font);
        // Letters colored on their own (upstream's selected-letter colors): each run's part within this paragraph.
        QList<QTextLayout::FormatRange> formats;
        for (const ColorRun &run : runs) {
            const int from = std::max(run.start, paragraphStart), to = std::min(run.start + run.length, paragraphStart + int(text.size()));
            if (to <= from) continue;
            QTextLayout::FormatRange range;
            range.start = from - paragraphStart;
            range.length = to - from;
            range.format.setForeground(run.color);
            formats << range;
        }
        for (const auto &run : attributes) {
            const int from = std::max(run.start, paragraphStart), to = std::min(run.start + run.length, paragraphStart + int(text.size()));
            if (to <= from) continue;
            QTextLayout::FormatRange range;
            range.start = from - paragraphStart; range.length = to - from; range.format = run.format;
            if (scale != 1) {
                QFont scaled = range.format.font();
                scaled.setPixelSize(std::max(1, int(std::lround(run.pixelSize * scale))));
                scaled.setLetterSpacing(QFont::AbsoluteSpacing, tracking * scale);
                range.format.setFont(scaled);
            }
            formats << range;
        }
        if (!formats.isEmpty()) layout->setFormats(formats);
        paragraphStart += int(text.size()) + 1;
        QTextOption option;
        option.setWrapMode(maxWidth > 0 ? QTextOption::WrapAtWordBoundaryOrAnywhere : QTextOption::NoWrap);
        layout->setTextOption(option);
        layout->beginLayout();
        for (;;) {
            QTextLine line = layout->createLine();
            if (!line.isValid()) break;
            line.setLineWidth(maxWidth > 0 ? maxWidth * scale : 1e7);
            const double baseline = attributes.empty() ? out.baseline : out.lineHeight - line.descent();
            if (lines == 0) out.baseline = baseline;
            line.setPosition(QPointF(0, lines * out.lineHeight + baseline - line.ascent()));
            out.width = std::max(out.width, double(line.naturalTextWidth()));
            ++lines;
        }
        layout->endLayout();
        out.paragraphs.push_back(std::move(layout));
    }
    out.height = std::max(1, lines) * out.lineHeight;
    out.width /= scale;
    out.height /= scale;
    out.lineHeight /= scale;
    out.baseline /= scale;
    return out;
}

int32_t textLayout(const char *text, const char *fontName, double pixelSize, double tracking, double lineHeight,
                   double maxWidth, double *width, double *height, double *baseline) {
    if (!qGuiApp) return -2;   // fonts need a QGuiApplication (the shell has one; bare test processes may not)
    const TextLines lines = layOut(text, fontName, pixelSize, tracking, lineHeight, maxWidth);
    if (width) *width = lines.width;
    if (height) *height = lines.height;
    if (baseline) *baseline = lines.baseline;
    return 0;
}

// Draws the laid-out text, premultiplied RGBA8, `boxWidth` wide (alignment within it) — malloc'd, the caller frees.
int32_t textRenderRuns(const char *text, const char *fontName, double pixelSize, double tracking, double lineHeight,
                       double maxWidth, int32_t alignment, double boxWidth, double r, double g, double b, double a,
                       const std::vector<ColorRun> &runs, uint8_t **pixels, int32_t *outWidth, int32_t *outHeight,
                       const std::vector<AttributeRun> &attributes = {});

int32_t textRender(const char *text, const char *fontName, double pixelSize, double tracking, double lineHeight,
                   double maxWidth, int32_t alignment, double boxWidth, double r, double g, double b, double a,
                   uint8_t **pixels, int32_t *outWidth, int32_t *outHeight) {
    return textRenderRuns(text, fontName, pixelSize, tracking, lineHeight, maxWidth, alignment, boxWidth, r, g, b, a, {},
                          pixels, outWidth, outHeight);
}

int32_t textRenderRuns(const char *text, const char *fontName, double pixelSize, double tracking, double lineHeight,
                       double maxWidth, int32_t alignment, double boxWidth, double r, double g, double b, double a,
                       const std::vector<ColorRun> &runs, uint8_t **pixels, int32_t *outWidth, int32_t *outHeight,
                       const std::vector<AttributeRun> &attributes) {
    if (!qGuiApp || !pixels || !outWidth || !outHeight) return -2;
    const TextLines lines = layOut(text, fontName, pixelSize, tracking, lineHeight, maxWidth, runs, attributes);
    const double width = std::max(boxWidth, lines.width);
    const int w = std::max(1, int(std::ceil(width))), h = std::max(1, int(std::ceil(lines.height)));
    if (qint64(w) * h > 200000000) return -1;
    QImage image(w, h, QImage::Format_RGBA8888_Premultiplied);
    image.fill(Qt::transparent);
    {
        QPainter painter(&image);
        painter.setRenderHint(QPainter::TextAntialiasing, true);
        painter.scale(1 / lines.coordinateScale, 1 / lines.coordinateScale);
        painter.setPen(QColor::fromRgbF(float(r), float(g), float(b), float(a)));
        for (const auto &layout : lines.paragraphs) {
            for (int i = 0; i < layout->lineCount(); ++i) {
                const QTextLine line = layout->lineAt(i);
                const double slack = width - line.naturalTextWidth() / lines.coordinateScale;
                const double x = alignment == 1 ? slack / 2 : alignment == 2 ? slack : 0;
                line.draw(&painter, QPointF(x * lines.coordinateScale, 0));
            }
        }
    }
    const size_t bytes = size_t(w) * h * 4;
    auto *copy = static_cast<uint8_t *>(std::malloc(bytes));
    if (!copy) return -3;
    for (int y = 0; y < h; ++y) std::memcpy(copy + size_t(y) * w * 4, image.constScanLine(y), size_t(w) * 4);
    *pixels = copy; *outWidth = w; *outHeight = h;
    return 0;
}

}  // namespace

typedef int32_t (*CompositorTextLayoutFn)(const char *, const char *, double, double, double, double, double *, double *, double *);
typedef int32_t (*CompositorTextRenderFn)(const char *, const char *, double, double, double, double, int32_t, double,
                                          double, double, double, double, uint8_t **, int32_t *, int32_t *);
extern "C" __attribute__((weak)) void compositor_text_register(CompositorTextLayoutFn layout, CompositorTextRenderFn render);

// Every installed face, named the way fontFor reads names back ("Family" for the regular face, "Family-Style"
// otherwise), newline-separated: what the compat NSFontManager.availableFonts lists (upstream's font menu). Returns
// the byte count (copied when `out` has room), -1 without a Qt GUI application.
extern "C" int64_t compositor_qt_font_names(char *out, size_t capacity) {
    if (!QGuiApplication::instance()) return -1;
    QStringList names;
    for (const QString &family : QFontDatabase::families()) {
        if (QFontDatabase::isPrivateFamily(family)) continue;
        for (const QString &style : QFontDatabase::styles(family)) {
            const bool regular = style.compare(QLatin1String("Regular"), Qt::CaseInsensitive) == 0
                || style.compare(QLatin1String("Normal"), Qt::CaseInsensitive) == 0
                || style.compare(QLatin1String("Book"), Qt::CaseInsensitive) == 0
                || style.compare(QLatin1String("Roman"), Qt::CaseInsensitive) == 0;
            QString compact = style;
            compact.remove(QLatin1Char(' '));
            names << (regular ? family : family + QLatin1Char('-') + compact);
        }
    }
    names.removeDuplicates();
    names.sort(Qt::CaseInsensitive);
    const QByteArray bytes = names.join(QLatin1Char('\n')).toUtf8();
    if (out && capacity >= size_t(bytes.size())) memcpy(out, bytes.constData(), size_t(bytes.size()));
    return bytes.size();
}

// Resolve a document's PostScript/full font name through the same installed-face aliases used when drawing it.
extern "C" int64_t compositor_qt_font_family(const char *name, char *out, size_t capacity) {
    if (!qGuiApp || !name) return -1;
    const auto &aliases = installedFontAliases();
    const auto found = aliases.constFind(fontNameKey(QString::fromUtf8(name)));
    if (found == aliases.constEnd()) return -1;
    const QByteArray family = QRawFont::fromFont(found.value()).familyName().toUtf8();
    if (out && capacity >= size_t(family.size())) memcpy(out, family.constData(), size_t(family.size()));
    return family.size();
}

// An SVG drawn by Qt's SVG image plugin: its declared size in `declaredWidth/Height`, and — when `width` and `height`
// are positive — the drawing at exactly that size in `out` (premultiplied RGBA8, malloc'd, the caller frees). 0 on success.
extern "C" int32_t compositor_qt_svg_render(const uint8_t *data, size_t length, int32_t width, int32_t height, uint8_t **out,
                                           int32_t *declaredWidth, int32_t *declaredHeight) {
    if (!data || !length) return -1;
    if (!qGuiApp) return -5;   // SVG text needs fonts, and fonts a QGuiApplication
    QByteArray bytes = QByteArray::fromRawData(reinterpret_cast<const char *>(data), static_cast<qsizetype>(length));
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer, "svg");
    const QSize declared = reader.size();
    if (!declared.isValid() || declared.isEmpty()) return -2;
    if (declaredWidth) *declaredWidth = declared.width();
    if (declaredHeight) *declaredHeight = declared.height();
    if (width <= 0 || height <= 0 || !out) return 0;
    reader.setScaledSize(QSize(width, height));
    const QImage image = reader.read().convertToFormat(QImage::Format_RGBA8888_Premultiplied);
    if (image.isNull() || image.width() != width || image.height() != height) return -3;
    const size_t bytesPerLine = size_t(width) * 4;
    auto *pixels = static_cast<uint8_t *>(malloc(bytesPerLine * size_t(height)));
    if (!pixels) return -4;
    for (int y = 0; y < height; ++y) memcpy(pixels + y * bytesPerLine, image.constScanLine(y), bytesPerLine);
    *out = pixels;
    return 0;
}

// The font's vertical metrics in points (NSFont's ascender, descender — negative, below the baseline — and leading).
extern "C" int compositor_qt_font_metrics(const char *name, double pointSize, double *ascent, double *descent, double *leading) {
    if (!qGuiApp) return 0;   // fonts need a QGuiApplication (bare test processes have none): the caller's estimate stands
    QRawFont metrics = QRawFont::fromFont(fontFor(name, pointSize));
    if (pointSize != std::round(pointSize)) metrics.setPixelSize(pointSize);
    if (!metrics.isValid()) return 0;
    if (ascent) *ascent = metrics.ascent();
    if (descent) *descent = -metrics.descent();
    if (leading) *leading = metrics.leading();
    return 1;
}

// Which of `count` code points the face `name` draws itself (NSFont.coveredCharacterSet): out[i] is 1 or 0.
extern "C" int32_t compositor_qt_font_covers(const char *name, const uint32_t *codes, int32_t count, uint8_t *out) {
    if (!qGuiApp || !codes || !out || count < 0) return 0;
    const QRawFont raw = QRawFont::fromFont(fontFor(name, 13));
    if (!raw.isValid()) return 0;
    for (int32_t i = 0; i < count; ++i) out[i] = raw.supportsCharacter(codes[i]) ? 1 : 0;
    return 1;
}

// textRender with letters colored on their own: `runs` holds `runCount` groups of (start, length, r, g, b, a), UTF-16
// offsets into the whole text; letters outside every run take (r, g, b, a).
extern "C" int32_t compositor_qt_text_render_runs(const char *text, const char *fontName, double pixelSize, double tracking,
                                                 double lineHeight, double maxWidth, int32_t alignment, double boxWidth,
                                                 double r, double g, double b, double a, const double *runs, int32_t runCount,
                                                 uint8_t **pixels, int32_t *outWidth, int32_t *outHeight) {
    std::vector<ColorRun> list;
    for (int32_t i = 0; runs && i < runCount; ++i) {
        const double *run = runs + i * 6;
        list.push_back({int(run[0]), int(run[1]), QColor::fromRgbF(float(run[2]), float(run[3]), float(run[4]), float(run[5]))});
    }
    return textRenderRuns(text, fontName, pixelSize, tracking, lineHeight, maxWidth, alignment, boxWidth, r, g, b, a, list,
                          pixels, outWidth, outHeight);
}

extern "C" int32_t compositor_qt_text_layout_attributes(const char *text, const char *fontName, double size, double tracking,
                                                         double leading, double maxWidth, const char *json,
                                                         double *width, double *height, double *baseline) {
    if (!qGuiApp) return -2;
    std::vector<AttributeRun> runs;
    if (!attributeRuns(json, QString::fromUtf8(text ? text : "").size(), tracking, runs)) return -1;
    const auto lines = layOut(text, fontName, size, tracking, leading, maxWidth, {}, runs);
    if (width) *width = lines.width;
    if (height) *height = lines.height;
    if (baseline) *baseline = lines.baseline;
    return 0;
}

extern "C" int32_t compositor_qt_text_render_attributes(const char *text, const char *fontName, double size, double tracking,
                                                         double leading, double maxWidth, int32_t alignment, double boxWidth,
                                                         double r, double g, double b, double a, const char *json,
                                                         uint8_t **pixels, int32_t *width, int32_t *height) {
    if (!qGuiApp) return -2;
    std::vector<AttributeRun> runs;
    if (!attributeRuns(json, QString::fromUtf8(text ? text : "").size(), tracking, runs)) return -1;
    return textRenderRuns(text, fontName, size, tracking, leading, maxWidth, alignment, boxWidth, r, g, b, a, {}, pixels, width, height, runs);
}

extern "C" int compositor_qt_text_functions(CompositorTextLayoutFn *layout, CompositorTextRenderFn *render) {
    if (!layout || !render) return 0;
    *layout = textLayout;
    *render = textRender;
    return 1;
}

// One source owns a sequential reader and its current composed canvas, never all decoded frames.
// Rewinding rebuilds the reader so Qt reapplies disposal and frame offsets correctly.
namespace {
std::atomic<uint64_t> animationReads{0};
struct AnimationSource {
    QByteArray bytes;
    QBuffer buffer;
    std::unique_ptr<QImageReader> reader;
    QImage image;
    int32_t cursor = -1;
    uint64_t reads = 0;
    AnimationSource(const uint8_t *data, size_t length)
        : bytes(reinterpret_cast<const char *>(data), qsizetype(length)), buffer(&bytes) {
        buffer.open(QIODevice::ReadOnly);
        reset();
    }
    void reset() {
        reader.reset();
        buffer.seek(0);
        reader = std::make_unique<QImageReader>(&buffer, "gif");
        image = QImage();
        cursor = -1;
    }
};
}
extern "C" void *compositor_qt_imageio_animation_open(const uint8_t *data, size_t length) {
    if (!data || !length || length > size_t(std::numeric_limits<int>::max())) return nullptr;
    auto source = std::make_unique<AnimationSource>(data, length);
    const QSize size = source->reader->size();
    if (size.width() <= 0 || size.height() <= 0 || size.width() > 30000 || size.height() > 30000
        || int64_t(size.width()) * size.height() > 200000000) return nullptr;
    return source.release();
}
extern "C" void compositor_qt_imageio_animation_close(void *handle) {
    delete static_cast<AnimationSource *>(handle);
}
// Instrumentation counts actual reader work, including rewinds, for scaling regressions.
extern "C" uint64_t compositor_qt_imageio_animation_reads(void *handle) {
    return handle ? static_cast<AnimationSource *>(handle)->reads : animationReads.load(std::memory_order_relaxed);
}
extern "C" int32_t compositor_qt_imageio_animation_read(void *handle, int32_t index,
                                                       uint8_t **out, int32_t *width, int32_t *height) {
    if (out) *out = nullptr;
    if (!handle || !out || !width || !height || index < 0) return -1;
    auto &source = *static_cast<AnimationSource *>(handle);
    if (index < source.cursor) source.reset();
    while (source.cursor < index) {
        source.image = source.reader->read();
        ++source.reads;
        animationReads.fetch_add(1, std::memory_order_relaxed);
        if (source.image.isNull()) { source.reset(); return -4; }
        ++source.cursor;
    }
    const QImage image = source.image.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
    const size_t stride = size_t(image.width()) * 4;
    auto *pixels = static_cast<uint8_t *>(malloc(stride * image.height()));
    if (!pixels) return -5;
    for (int y = 0; y < image.height(); ++y) memcpy(pixels + y * stride, image.constScanLine(y), stride);
    *out = pixels; *width = image.width(); *height = image.height();
    return 0;
}
// Stateless entry point retained for independent callers; ImageIO uses source sessions.
extern "C" int32_t compositor_qt_imageio_decode_frame(const uint8_t *data, size_t length, int32_t index,
                                                       uint8_t **out, int32_t *width, int32_t *height) {
    void *source = compositor_qt_imageio_animation_open(data, length);
    const int32_t result = compositor_qt_imageio_animation_read(source, index, out, width, height);
    compositor_qt_imageio_animation_close(source);
    return result;
}

extern "C" int compositor_qt_imageio_install(void) {
    if (compositor_text_register) compositor_text_register(textLayout, textRender);
    if (!compositor_imageio_register) return 0;
    compositor_imageio_register(decodeImage, encodeImage);
    if (compositor_imageio_register_animation) compositor_imageio_register_animation(
        compositor_qt_imageio_animation_open, compositor_qt_imageio_animation_read, compositor_qt_imageio_animation_close);
    if (compositor_imageio_register_deep) compositor_imageio_register_deep(decodeImageDeep);
    if (compositor_imageio_register_straight) compositor_imageio_register_straight(decodeStraightImage, encodeStraightImage);
    if (compositor_imageio_register_cmyk) compositor_imageio_register_cmyk(decodeCMYK, encodeCMYK);
    return 1;
}

// CMYK JPEG/TIFF for loaders that dlopen this library.
extern "C" int compositor_qt_imageio_cmyk_functions(CompositorCMYKDecodeFn *decode, CompositorCMYKEncodeFn *encode) {
    if (!decode || !encode) return 0;
    *decode = decodeCMYK;
    *encode = encodeCMYK;
    return 1;
}

extern "C" int compositor_qt_imageio_straight_functions(CompositorImageDecodeFn *decode, CompositorImageEncodeFn *encode) {
    if (!decode || !encode) return 0;
    *decode = decodeStraightImage;
    *encode = encodeStraightImage;
    return 1;
}

// The deep decode for loaders that dlopen this library (16-bit layout 8, linear float layout 16 besides 1 and 4).
extern "C" int compositor_qt_imageio_deep_decode(CompositorImageDecodeFn *decode) {
    if (!decode) return 0;
    *decode = decodeImageDeep;
    return 1;
}

// For loaders that cannot be called back into (a test process that dlopens this library): hand out the callbacks.
extern "C" int compositor_qt_imageio_functions(CompositorImageDecodeFn *decode, CompositorImageEncodeFn *encode) {
    if (!decode || !encode) return 0;
    *decode = decodeImage;
    *encode = encodeImage;
    return 1;
}

// Round-trips through the same callbacks the Swift core uses. Returns 0 when every supported format behaves.
extern "C" int compositor_qt_imageio_selftest(void) {
    const int w = 16, h = 12;
    std::vector<uint8_t> rgba(static_cast<size_t>(w) * h * 4);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            const uint8_t a = 255;
            uint8_t *p = &rgba[(static_cast<size_t>(y) * w + x) * 4];
            p[0] = static_cast<uint8_t>(x * 15); p[1] = static_cast<uint8_t>(y * 20); p[2] = 90; p[3] = a;
        }
    struct Case { const char *uti; bool lossless; };
    for (const Case &c : {Case{"public.png", true}, Case{"public.tiff", true}, Case{"public.jpeg", false}}) {
        uint8_t *encoded = nullptr; size_t length = 0;
        if (encodeImage(rgba.data(), w, h, 4, c.uti, c.lossless ? -1 : 0.95, 144.0, 1, &encoded, &length) != 0) return 1;
        uint8_t *decoded = nullptr; int32_t dw = 0, dh = 0, ch = 0, orient = 0; double dpi = 0; char uti[96] = {0};
        const int32_t rc = decodeImage(encoded, length, &decoded, &dw, &dh, &ch, &dpi, &orient, uti, sizeof(uti));
        free(encoded);
        if (rc != 0 || dw != w || dh != h || ch != 4 || strcmp(uti, c.uti) != 0) { free(decoded); return 2; }
        if (c.lossless) {
            if (memcmp(decoded, rgba.data(), rgba.size()) != 0) { free(decoded); return 3; }
            if (dpi < 143.0 || dpi > 145.0) { free(decoded); return 4; }
        } else {
            long diff = 0;
            for (size_t i = 0; i < rgba.size(); ++i) diff += std::abs(int(decoded[i]) - int(rgba[i]));
            if (diff / static_cast<long>(rgba.size()) > 12) { free(decoded); return 5; }
        }
        free(decoded);
    }
    // A gray plane stays a one-channel mask through PNG.
    std::vector<uint8_t> plane(static_cast<size_t>(w) * h);
    for (size_t i = 0; i < plane.size(); ++i) plane[i] = static_cast<uint8_t>(i);
    uint8_t *encoded = nullptr; size_t length = 0;
    if (encodeImage(plane.data(), w, h, 1, "public.png", -1, 0, 1, &encoded, &length) != 0) return 6;
    uint8_t *decoded = nullptr; int32_t dw = 0, dh = 0, ch = 0, orient = 0; double dpi = 0; char uti[96] = {0};
    const int32_t rc = decodeImage(encoded, length, &decoded, &dw, &dh, &ch, &dpi, &orient, uti, sizeof(uti));
    free(encoded);
    const bool ok = rc == 0 && ch == 1 && dw == w && memcmp(decoded, plane.data(), plane.size()) == 0;
    free(decoded);
    return ok ? 0 : 7;
}
