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
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <memory>
#include <zlib.h>
#include <tiffio.h>
#include <limits>

// HEIF/HEIC/AVIF go through libheif directly: the Qt plugin for them is not dependable (it swaps the dimensions of a
// 64x32 image on a round trip). libheif is optional; without it those formats are simply not handled here.
#if defined(__has_include)
#if __has_include(<libheif/heif.h>)
#define COMPOSITOR_HAS_LIBHEIF 1
#include <libheif/heif.h>
#endif
#endif

extern "C" {
typedef int32_t (*CompositorImageDecodeFn)(const uint8_t *, size_t, uint8_t **, int32_t *, int32_t *, int32_t *, double *,
                                           int32_t *, char *, size_t);
typedef int32_t (*CompositorImageEncodeFn)(const uint8_t *, int32_t, int32_t, int32_t, const char *, double, double,
                                           int32_t, uint8_t **, size_t *);
// Provided by the Swift core; weak so C++-only builds (no Swift) still link.
void compositor_imageio_register(CompositorImageDecodeFn, CompositorImageEncodeFn) __attribute__((weak));
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

// Qt's grayscale TIFF path loses alpha and the gray profile. Decode those samples before color conversion;
// libtiff handles byte order, compression, planar storage and tiles without an intermediate RGBA8 reduction.
QImage decodeGrayAlphaTIFF(const uint8_t *data, size_t length, bool &handled, int &orientation) {
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
    uint16_t samples = 0, photo = 0, extras = 0, *extraTypes = nullptr;
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_SAMPLESPERPIXEL, &samples);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_PHOTOMETRIC, &photo);
    if (samples != 2 || (photo != PHOTOMETRIC_MINISBLACK && photo != PHOTOMETRIC_MINISWHITE) ||
        !TIFFGetField(tif.get(), TIFFTAG_EXTRASAMPLES, &extras, &extraTypes) || extras != 1 ||
        !extraTypes || (extraTypes[0] != EXTRASAMPLE_UNASSALPHA && extraTypes[0] != EXTRASAMPLE_ASSOCALPHA)) return {};
    handled = true;
    uint32_t width = 0, height = 0;
    uint16_t bits = 0, planar = 0, sampleFormat = 0, orient = 1;
    TIFFGetField(tif.get(), TIFFTAG_IMAGEWIDTH, &width); TIFFGetField(tif.get(), TIFFTAG_IMAGELENGTH, &height);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_BITSPERSAMPLE, &bits);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_PLANARCONFIG, &planar);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_SAMPLEFORMAT, &sampleFormat);
    TIFFGetFieldDefaulted(tif.get(), TIFFTAG_ORIENTATION, &orient);
    if (!width || !height || width > uint32_t(INT_MAX) || height > uint32_t(INT_MAX) ||
        (bits != 8 && bits != 16) || sampleFormat != SAMPLEFORMAT_UINT ||
        (planar != PLANARCONFIG_CONTIG && planar != PLANARCONFIG_SEPARATE)) return {};
    // Keep the Qt reader's configured admission limit (its old TIFF path used four bytes per pixel).
    const int limit = QImageReader::allocationLimit();
    if (limit > 0 && uint64_t(width) * height > uint64_t(limit) * 1024 * 1024 / 4) return {};
    QImage image(int(width), int(height), QImage::Format_RGBA64);
    if (image.isNull()) return {};
    const bool separate = planar == PLANARCONFIG_SEPARATE, associated = extraTypes[0] == EXTRASAMPLE_ASSOCALPHA;
    const uint32_t maximum = bits == 8 ? 255 : 65535;
    const auto unpack = [&](const uint8_t *grayData, const uint8_t *alphaData, uint32_t x, uint32_t y,
                            uint32_t count, size_t first) {
        auto *out = reinterpret_cast<QRgba64 *>(image.scanLine(int(y)));
        const auto sample = [&](const uint8_t *p, size_t i) -> uint32_t {
            if (bits == 8) return p[i];
            uint16_t value; memcpy(&value, p + i * 2, 2); return value;
        };
        for (uint32_t i = 0; i < count; ++i) {
            const size_t index = first + i;
            uint32_t g = sample(grayData, index * (separate ? 1 : 2));
            const uint32_t a = sample(alphaData, separate ? index : index * 2 + 1);
            if (associated) g = a ? std::min(maximum, (g * maximum + a / 2) / a) : 0;
            if (photo == PHOTOMETRIC_MINISWHITE) g = maximum - g;
            const auto gray = uint16_t((g * 65535 + maximum / 2) / maximum);
            const auto alpha = uint16_t((a * 65535 + maximum / 2) / maximum);
            out[x + i] = QRgba64::fromRgba64(gray, gray, gray, alpha);
        }
    };
    const bool tiled = TIFFIsTiled(tif.get());
    uint32_t blockWidth = width, blockHeight = 0;
    if (tiled) {
        TIFFGetField(tif.get(), TIFFTAG_TILEWIDTH, &blockWidth); TIFFGetField(tif.get(), TIFFTAG_TILELENGTH, &blockHeight);
    } else TIFFGetFieldDefaulted(tif.get(), TIFFTAG_ROWSPERSTRIP, &blockHeight);
    const uint64_t rowBytes = tiled ? TIFFTileRowSize64(tif.get()) : TIFFScanlineSize64(tif.get());
    const uint64_t blockBytes = tiled ? TIFFTileSize64(tif.get()) : TIFFStripSize64(tif.get());
    if (!blockWidth || !blockHeight || !blockBytes || blockBytes > uint64_t(bufferLimit) ||
        rowBytes < uint64_t(blockWidth) * (separate ? 1 : 2) * (bits / 8)) return {};
    std::vector<uint8_t> gray, alpha;
    try {
        gray.resize(blockBytes);
        if (separate) alpha.resize(blockBytes);
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
            if (read(gray, 0) < tmsize_t(needed) || (separate && read(alpha, 1) < tmsize_t(needed))) return {};
            for (uint32_t row = 0; row < rows; ++row) {
                const auto *g = gray.data() + rowBytes * row;
                const auto *a = separate ? alpha.data() + rowBytes * row : g;
                unpack(g, a, x, y + row, columns, 0);
            }
            x += columns;
        }
        y += rows;
    }
    uint32_t profileSize = 0; void *profile = nullptr;
    if (TIFFGetField(tif.get(), TIFFTAG_ICCPROFILE, &profileSize, &profile)) {
        if (!profile || !profileSize || profileSize > 4 * 1024 * 1024) return {};
        const QColorSpace space = QColorSpace::fromIccProfile(QByteArray(static_cast<const char *>(profile), profileSize));
        if (!space.isValid()) return {};
        if (space.colorModel() == QColorSpace::ColorModel::Gray) image = grayAlphaToSRGB(image, space);
        else if (space.colorModel() == QColorSpace::ColorModel::Rgb) { image.setColorSpace(space); image = toSRGB(image); }
        else return {};
    } else image.setColorSpace(QColorSpace(QColorSpace::SRgb));
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
                   int32_t *orientation, char *uti, size_t utiCapacity) {
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
            if (!decoded.isNull()) {
                const QColorSpace space = heifColorSpace(handle);
                if (!space.isValid()) decoded = {};
                else {
                    decoded.setColorSpace(space);
                    decoded = toSRGB(decoded).convertToFormat(QImage::Format_RGBA8888);
                }
            }
            const uint8_t *src = decoded.isNull() ? nullptr : decoded.constBits();
            stride = decoded.isNull() ? 0 : static_cast<int>(decoded.bytesPerLine());
            auto *pixels = static_cast<uint8_t *>(malloc(static_cast<size_t>(w) * h * 4));
            if (src && pixels && w > 0 && h > 0) {
                for (int y = 0; y < h; ++y) {
                    const uint8_t *row = src + static_cast<size_t>(y) * stride;
                    uint8_t *dst = pixels + static_cast<size_t>(y) * w * 4;
                    for (int x = 0; x < w; ++x) {  // straight -> premultiplied
                        const int a = row[x * 4 + 3];
                        dst[x * 4] = static_cast<uint8_t>((row[x * 4] * a + 127) / 255);
                        dst[x * 4 + 1] = static_cast<uint8_t>((row[x * 4 + 1] * a + 127) / 255);
                        dst[x * 4 + 2] = static_cast<uint8_t>((row[x * 4 + 2] * a + 127) / 255);
                        dst[x * 4 + 3] = static_cast<uint8_t>(a);
                    }
                }
                *out = pixels;
                if (width) *width = w;
                if (height) *height = h;
                if (channels) *channels = 4;
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

int32_t decodeImage(const uint8_t *data, size_t length, uint8_t **out, int32_t *width, int32_t *height,
                    int32_t *channels, double *dpi, int32_t *orientation, char *uti, size_t utiCapacity) {
    if (!data || !length || !out) return -1;
#if defined(COMPOSITOR_HAS_LIBHEIF)
    if (isHeifContainer(data, length)) return decodeHeif(data, length, out, width, height, channels, orientation, uti, utiCapacity);
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
    if (!strcmp(type, "public.tiff")) image = decodeGrayAlphaTIFF(data, length, nativeTIFF, nativeOrientation);
    if (!nativeTIFF) image = reader.read();
    if (image.isNull()) return -3;
    image = grayPNGToSRGB(image, data, length);
    image = toSRGB(image);
    if (image.isNull()) return -3;

    // Gray only when the file itself is gray; an RGB file whose pixels happen to be neutral stays colour.
    const bool gray = image.format() == QImage::Format_Grayscale8 || image.format() == QImage::Format_Grayscale16;
    QImage converted = gray ? image.convertToFormat(QImage::Format_Grayscale8)
                            : image.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
    const int ch = gray ? 1 : 4;
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

int32_t encodeImage(const uint8_t *pixels, int32_t width, int32_t height, int32_t channels, const char *uti,
                    double quality, double dpi, int32_t orientation, uint8_t **out, size_t *outLength) {
#if defined(COMPOSITOR_HAS_LIBHEIF)
    if (uti && pixels && width > 0 && height > 0 && out && outLength &&
        (!strcmp(uti, "public.heic") || !strcmp(uti, "public.heif") || !strcmp(uti, "public.avif")))
        return encodeHeif(pixels, width, height, channels, quality, out, outLength);
#endif
    const char *format = formatForUti(uti);
    if (!pixels || width <= 0 || height <= 0 || !format || !out || !outLength) return -1;
    QImage image;
    if (channels == 1) {
        image = QImage(pixels, width, height, width, QImage::Format_Grayscale8).copy();
    } else if (channels == 4) {
        image = QImage(pixels, width, height, width * 4, QImage::Format_RGBA8888_Premultiplied).copy();
    } else {
        return -1;
    }
    if (channels == 4) image.setColorSpace(QColorSpace(QColorSpace::SRgb));   // the document is sRGB: say so in the file
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

// ---- Text: real fonts for the compat text system (AppKit's NSLayoutManager / NSString measuring and drawing) ----


struct TextLines {
    std::vector<std::unique_ptr<QTextLayout>> paragraphs;
    double width = 0, height = 0, lineHeight = 0, baseline = 0;
};

// Lays the text out as AppKit does with a fixed line height (min = max): each line `lineHeight` tall, its baseline
// `lineHeight - descent` down, wrapping at `maxWidth` when positive; tracking is extra space after every character.
// A color over part of the text: UTF-16 offsets into the whole string, premultiplied-free RGBA 0...1.
struct ColorRun { int start, length; QColor color; };
struct AttributeRun { int start, length; QTextCharFormat format; };

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
        runs.push_back({int(start), int(length), format});
        previousEnd = int(start + length);
    }
    return true;
}

TextLines layOut(const char *utf8, const char *fontName, double pixelSize, double tracking, double lineHeight, double maxWidth,
                 const std::vector<ColorRun> &runs = {}, const std::vector<AttributeRun> &attributes = {}) {
    TextLines out;
    const QFont font = [&] { QFont f = fontFor(fontName, pixelSize); f.setLetterSpacing(QFont::AbsoluteSpacing, tracking); return f; }();
    const QFontMetricsF metrics(font);
    out.lineHeight = lineHeight > 0 ? lineHeight : pixelSize * 1.2;
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
            line.setLineWidth(maxWidth > 0 ? maxWidth : 1e7);
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
        painter.setPen(QColor::fromRgbF(float(r), float(g), float(b), float(a)));
        for (const auto &layout : lines.paragraphs) {
            for (int i = 0; i < layout->lineCount(); ++i) {
                const QTextLine line = layout->lineAt(i);
                const double slack = width - line.naturalTextWidth();
                const double x = alignment == 1 ? slack / 2 : alignment == 2 ? slack : 0;
                line.draw(&painter, QPointF(x, 0));
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
    const QFontMetricsF metrics(fontFor(name, pointSize));
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

extern "C" int compositor_qt_imageio_install(void) {
    if (compositor_text_register) compositor_text_register(textLayout, textRender);
    if (!compositor_imageio_register) return 0;
    compositor_imageio_register(decodeImage, encodeImage);
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
