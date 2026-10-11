// Independent fixtures exercise the same ImageIO callbacks that Swift uses. Expected pixels come from
// the source transfer equations, rather than a second call to the conversion under test.
#include <QBuffer>
#include <QColorSpace>
#include <QGuiApplication>
#include <QImage>
#include <QImageReader>
#include <QImageWriter>
#include <QFile>
#include <QTemporaryFile>
#include <tiffio.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <vector>
#ifdef COMPOSITOR_TEST_LIBHEIF
#include <libheif/heif.h>
#endif

using Decode = int32_t (*)(const uint8_t *, size_t, uint8_t **, int32_t *, int32_t *, int32_t *, double *,
                           int32_t *, char *, size_t);
using Encode = int32_t (*)(const uint8_t *, int32_t, int32_t, int32_t, const char *, double, double,
                           int32_t, uint8_t **, size_t *);
extern "C" int compositor_qt_imageio_functions(Decode *, Encode *);

namespace {
Decode decode;
Encode encode;
void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
void near(int actual, int expected, int tolerance, const char *message) {
    if (std::abs(actual - expected) > tolerance) {
        std::fprintf(stderr, "%s: got %d, expected %d +/- %d\n", message, actual, expected, tolerance);
        throw std::runtime_error(message);
    }
}
int srgbByte(double linear) {
    const double value = linear <= 0.0031308 ? 12.92 * linear : 1.055 * std::pow(linear, 1.0 / 2.4) - 0.055;
    return std::clamp(static_cast<int>(std::lround(value * 255)), 0, 255);
}
QByteArray png(const QImage &image) {
    QByteArray bytes;
    QBuffer buffer(&bytes);
    require(buffer.open(QIODevice::WriteOnly), "open fixture buffer");
    QImageWriter writer(&buffer, "png");
    require(writer.write(image), "write independent PNG fixture");
    return bytes;
}
QImage read(const QByteArray &bytes) {
    QBuffer buffer;
    buffer.setData(bytes);
    require(buffer.open(QIODevice::ReadOnly), "open profile read buffer");
    QImageReader reader(&buffer);
    QImage image = reader.read();
    require(!image.isNull(), "read file to inspect actual color profile");
    return image;
}
void bigEndian(QByteArray &bytes, uint32_t value) {
    for (int shift : {24, 16, 8, 0}) bytes.append(char(value >> shift));
}
void chunk(QByteArray &bytes, const char *type, const QByteArray &data) {
    bigEndian(bytes, data.size());
    const QByteArray payload = QByteArray(type, 4) + data;
    bytes.append(payload);
    uint32_t crc = 0xffffffff;
    for (unsigned char byte : payload) {
        crc ^= byte;
        for (int bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    bigEndian(bytes, crc ^ 0xffffffff);
}
QByteArray grayAlphaFixture(int bits) {
    // PNG color type 4 is genuinely grayscale with alpha; Qt's RGB writer cannot construct this case.
    QByteArray bytes("\x89PNG\r\n\x1a\n", 8), header;
    bigEndian(header, 4); bigEndian(header, 2);
    header.append(char(bits)); header.append("\x04\x00\x00\x00", 4);
    chunk(bytes, "IHDR", header);
    const QColorSpace gray(QPointF(0.3127, 0.3290), QColorSpace::TransferFunction::Linear);
    require(gray.isValid() && gray.colorModel() == QColorSpace::ColorModel::Gray, "fixture gray profile valid");
    const QByteArray profile = QByteArray("gray\0\0", 6) + qCompress(gray.iccProfile()).mid(4);
    chunk(bytes, "iCCP", profile);
    QByteArray rows;
    for (int y = 0; y < 2; ++y) {
        rows.append(char(0));
        for (int alpha : {0, 1, 128, 255}) {
            if (bits == 16) { rows.append(char(64)); rows.append(char(0)); rows.append(char(alpha)); rows.append(char(alpha)); }
            else { rows.append(char(64)); rows.append(char(alpha)); }
        }
    }
    chunk(bytes, "IDAT", qCompress(rows).mid(4));
    chunk(bytes, "IEND", {});
    return bytes;
}
std::vector<uint8_t> imported(const QByteArray &bytes, int expectedChannels, int w = 4, int h = 2,
                             int expectedOrientation = 0, int expectedDPI = 0) {
    uint8_t *raw = nullptr;
    int32_t width = 0, height = 0, channels = 0;
    int32_t orientation = 0; double dpi = 0;
    const int rc = decode(reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size(), &raw,
                          &width, &height, &channels, &dpi, &orientation, nullptr, 0);
    std::unique_ptr<uint8_t, decltype(&std::free)> owner(raw, std::free);
    require(rc == 0 && raw, "ImageIO callback decodes fixture");
    require(width == w && height == h && channels == expectedChannels, "import dimensions/channels");
    if (expectedOrientation) require(orientation == expectedOrientation, "import retains raw EXIF orientation");
    if (expectedDPI) near(std::lround(dpi), expectedDPI, 1, "import retains TIFF DPI");
    return {raw, raw + static_cast<size_t>(width) * height * channels};
}
void pngImports() {
    for (int bits : {8, 16}) {
        QImage gray(4, 2, bits == 8 ? QImage::Format_Grayscale8 : QImage::Format_Grayscale16);
        for (int y = 0; y < 2; ++y) for (int x = 0; x < 4; ++x) {
            if (bits == 8) gray.scanLine(y)[x] = 64;
            else reinterpret_cast<uint16_t *>(gray.scanLine(y))[x] = 16384;
        }
        gray.setColorSpace(QColorSpace(QPointF(0.3127, 0.3290), QColorSpace::TransferFunction::Linear));
        const QByteArray grayBytes = png(gray);
        require(read(grayBytes).colorSpace().colorModel() == QColorSpace::ColorModel::Gray, "fixture has gray ICC profile");
        const double value = bits == 8 ? 64.0 / 255 : 16384.0 / 65535;
        for (uint8_t sample : imported(grayBytes, 1)) near(sample, srgbByte(value), 1, "gray linear -> sRGB");
    }

    const int grayAlphas[] = {0, 1, 128, 255};
    for (int bits : {8, 16}) {
        const QByteArray grayAlpha = grayAlphaFixture(bits);
        require(read(grayAlpha).hasAlphaChannel(), "fixture has alpha");
        const auto grayAlphaPixels = imported(grayAlpha, 4);
        const double value = bits == 8 ? 64.0 / 255 : 16384.0 / 65535;
        for (int i = 0; i < 8; ++i) {
            const int alpha = grayAlphas[i % 4];
            near(grayAlphaPixels[i * 4 + 3], alpha, 0, "gray profile preserves alpha");
            for (int c = 0; c < 3; ++c)
                near(grayAlphaPixels[i * 4 + c], (srgbByte(value) * alpha + 127) / 255, 1,
                     "gray profile with alpha converts before premultiplication");
        }
    }

    QImage rgba(4, 2, QImage::Format_RGBA64);
    const uint16_t alphas[] = {0, 257, 32896, 65535};
    for (int y = 0; y < 2; ++y) {
        auto *row = reinterpret_cast<uint16_t *>(rgba.scanLine(y));
        for (int x = 0; x < 4; ++x) {
            row[x * 4] = 16384; row[x * 4 + 1] = 32768; row[x * 4 + 2] = 49152; row[x * 4 + 3] = alphas[x];
        }
    }
    rgba.setColorSpace(QColorSpace(QColorSpace::SRgbLinear));
    const auto pixels = imported(png(rgba), 4);
    for (int i = 0; i < 8; ++i) {
        const int alpha = alphas[i % 4] / 257;
        near(pixels[i * 4 + 3], alpha, 0, "color conversion preserves alpha");
        for (int c = 0; c < 3; ++c)
            near(pixels[i * 4 + c], (srgbByte((c + 1) * 16384.0 / 65535) * alpha + 127) / 255, 1,
                 "linear RGB converts before premultiplication");
    }

    QImage p3(4, 2, QImage::Format_RGBA8888);
    p3.fill(QColor(200, 100, 50, 128));
    p3.setColorSpace(QColorSpace(QColorSpace::DisplayP3));
    const auto p3pixels = imported(png(p3), 4);
    for (int i = 0; i < 8; ++i) {
        near(p3pixels[i * 4], 108, 1, "P3 red converted before premultiplication");
        near(p3pixels[i * 4 + 1], 47, 1, "P3 green converted before premultiplication");
        near(p3pixels[i * 4 + 2], 16, 1, "P3 blue converted before premultiplication");
        near(p3pixels[i * 4 + 3], 128, 0, "P3 alpha preserved");
    }

    p3.setColorSpace({});
    const QByteArray untagged = png(p3);
    require(!read(untagged).colorSpace().isValid(), "untagged fixture genuinely has no profile");
    const auto untaggedPixels = imported(untagged, 4);
    near(untaggedPixels[0], 100, 0, "untagged red assumed sRGB");
    near(untaggedPixels[1], 50, 0, "untagged green assumed sRGB");
    near(untaggedPixels[2], 25, 0, "untagged blue assumed sRGB");
    std::puts("ImageIO PNG color/gray/alpha/untagged imports OK");
}
QByteArray grayAlphaTIFF(int bits, bool big) {
    // Independently assemble an uncompressed grayscale/straight-alpha TIFF and gray linear ICC profile.
    const QByteArray profile = QColorSpace(QPointF(0.3127, 0.3290), QColorSpace::TransferFunction::Linear).iccProfile();
    constexpr uint32_t profileOffset = 8 + 2 + 12 * 12 + 4;
    const uint32_t pixelOffset = profileOffset + profile.size();
    QByteArray bytes;
    const auto word = [&](uint16_t value) {
        bytes.append(char(big ? value >> 8 : value)); bytes.append(char(big ? value : value >> 8));
    };
    const auto longWord = [&](uint32_t value) {
        if (big) { word(value >> 16); word(value); }
        else { word(value); word(value >> 16); }
    };
    bytes.append(big ? "MM" : "II", 2); word(42); longWord(8); word(12);
    const auto tag = [&](uint16_t id, uint16_t type, uint32_t count, uint32_t value) {
        word(id); word(type); longWord(count);
        if (type == 3) { word(value); word(count == 2 ? value : 0); }
        else longWord(value);
    };
    tag(256, 4, 1, 4); tag(257, 4, 1, 2); tag(258, 3, 2, bits);
    tag(259, 3, 1, 1); tag(262, 3, 1, 1); tag(273, 4, 1, pixelOffset);
    tag(277, 3, 1, 2); tag(278, 4, 1, 2); tag(279, 4, 1, 16 * bits / 8);
    tag(284, 3, 1, 1); tag(338, 3, 1, 2); tag(34675, 7, profile.size(), profileOffset);
    longWord(0); bytes.append(profile);
    const int gray[] = {bits == 8 ? 1 : 65, bits == 8 ? 64 : 16384, bits == 8 ? 128 : 32768, 16384};
    const int alpha[] = {bits == 8 ? 255 : 65535, bits == 8 ? 255 : 65535, bits == 8 ? 128 : 32768, 0};
    for (int y = 0; y < 2; ++y) for (int x = 0; x < 4; ++x) {
        if (bits == 8) { bytes.append(char(gray[x])); bytes.append(char(alpha[x])); }
        else { word(gray[x]); word(alpha[x]); }
    }
    return bytes;
}
void tiffImports() {
    for (int bits : {8, 16}) for (bool big : {false, true}) {
        const QByteArray fixture = grayAlphaTIFF(bits, big);
        require(read(fixture).size() == QSize(4, 2), "independent TIFF recognized at its dimensions");
        const auto pixels = imported(fixture, 4);
        const int maximum = bits == 8 ? 255 : 65535;
        const int gray[] = {bits == 8 ? 1 : 65, bits == 8 ? 64 : 16384, bits == 8 ? 128 : 32768, 0};
        const int alpha[] = {255, 255, 128, 0};
        for (int i = 0; i < 8; ++i) {
            near(pixels[i * 4 + 3], alpha[i % 4], 0, "TIFF gray conversion preserves alpha");
            for (int c = 0; c < 3; ++c)
                near(pixels[i * 4 + c], (srgbByte(double(gray[i % 4]) / maximum) * alpha[i % 4] + 127) / 255, 1,
                     "TIFF gray ICC and source precision converted before premultiplication");
        }
        std::printf("ImageIO gray-alpha TIFF %d-bit %s-endian OK\n", bits, big ? "big" : "little");
    }
}
struct TIFFPixel { uint16_t gray, alpha; };
TIFFPixel tiffPixel(int x, int y, int bits, bool associated, bool white) {
    const int maximum = bits == 8 ? 255 : 65535;
    const int values[] = {bits == 8 ? 1 : 65, maximum / 4, maximum / 2, maximum};
    const int alphas[] = {maximum, maximum / 2, 0, maximum};
    int gray = values[x % 4], alpha = alphas[y % 4];
    if (white) gray = maximum - gray;
    if (associated) gray = int((uint64_t(gray) * alpha + maximum / 2) / maximum);
    return {uint16_t(gray), uint16_t(alpha)};
}
QByteArray storedGrayTIFF(int bits, bool separate, bool tiled, bool associated, bool white, bool bigTIFF) {
    QTemporaryFile temporary;
    require(temporary.open(), "open TIFF layout fixture");
    const QByteArray path = temporary.fileName().toUtf8(); temporary.close();
    auto tif = std::unique_ptr<TIFF, decltype(&TIFFClose)>(TIFFOpen(path.constData(), bigTIFF ? "w8b" : "wl"), TIFFClose);
    require(bool(tif), "open independent libtiff writer");
    constexpr int width = 19, height = 17;
    uint16_t extra = associated ? EXTRASAMPLE_ASSOCALPHA : EXTRASAMPLE_UNASSALPHA;
    require(TIFFSetField(tif.get(), TIFFTAG_IMAGEWIDTH, width) && TIFFSetField(tif.get(), TIFFTAG_IMAGELENGTH, height) &&
            TIFFSetField(tif.get(), TIFFTAG_BITSPERSAMPLE, bits) && TIFFSetField(tif.get(), TIFFTAG_SAMPLESPERPIXEL, 2) &&
            TIFFSetField(tif.get(), TIFFTAG_PHOTOMETRIC, white ? PHOTOMETRIC_MINISWHITE : PHOTOMETRIC_MINISBLACK) &&
            TIFFSetField(tif.get(), TIFFTAG_PLANARCONFIG, separate ? PLANARCONFIG_SEPARATE : PLANARCONFIG_CONTIG) &&
            TIFFSetField(tif.get(), TIFFTAG_EXTRASAMPLES, 1, &extra) &&
            TIFFSetField(tif.get(), TIFFTAG_COMPRESSION, COMPRESSION_ADOBE_DEFLATE) &&
            TIFFSetField(tif.get(), TIFFTAG_PREDICTOR, PREDICTOR_HORIZONTAL) &&
            TIFFSetField(tif.get(), TIFFTAG_ORIENTATION, ORIENTATION_RIGHTTOP) &&
            TIFFSetField(tif.get(), TIFFTAG_XRESOLUTION, 144.0) && TIFFSetField(tif.get(), TIFFTAG_YRESOLUTION, 144.0) &&
            TIFFSetField(tif.get(), TIFFTAG_RESOLUTIONUNIT, RESUNIT_INCH), "set TIFF layout fixture tags");
    const QByteArray profile = QColorSpace(QPointF(0.3127, 0.3290), QColorSpace::TransferFunction::Linear).iccProfile();
    require(TIFFSetField(tif.get(), TIFFTAG_ICCPROFILE, profile.size(), profile.constData()), "set independent TIFF profile");
    if (tiled) {
        require(TIFFSetField(tif.get(), TIFFTAG_TILEWIDTH, 16) && TIFFSetField(tif.get(), TIFFTAG_TILELENGTH, 16), "set TIFF tiles");
    } else require(TIFFSetField(tif.get(), TIFFTAG_ROWSPERSTRIP, 3), "set TIFF strips");
    const auto store = [&](uint8_t *row, int index, uint16_t value) {
        if (bits == 8) row[index] = value;
        else memcpy(row + index * 2, &value, 2);
    };
    for (int plane = 0; plane < (separate ? 2 : 1); ++plane) {
        const int bw = tiled ? 16 : width, bh = tiled ? 16 : 1;
        const int rowBytes = bw * (separate ? 1 : 2) * (bits / 8);
        std::vector<uint8_t> block(rowBytes * bh);
        for (int y = 0; y < height; y += bh) for (int x = 0; x < width; x += bw) {
            std::fill(block.begin(), block.end(), 0);
            for (int row = 0; row < bh && y + row < height; ++row) for (int col = 0; col < bw && x + col < width; ++col) {
                const auto p = tiffPixel(x + col, y + row, bits, associated, white);
                auto *destination = block.data() + rowBytes * row;
                if (separate) store(destination, col, plane == 0 ? p.gray : p.alpha);
                else { store(destination, col * 2, p.gray); store(destination, col * 2 + 1, p.alpha); }
            }
            require(tiled ? TIFFWriteTile(tif.get(), block.data(), x, y, 0, plane) >= 0
                          : TIFFWriteScanline(tif.get(), block.data(), y, plane) >= 0, "write compressed TIFF fixture samples");
        }
    }
    tif.reset();
    QFile file(QString::fromUtf8(path)); require(file.open(QIODevice::ReadOnly), "read encoded TIFF layout fixture");
    return file.readAll();
}
void tiffLayouts() {
    for (int bits : {8, 16}) for (bool separate : {false, true}) for (bool tiled : {false, true})
        for (bool associated : {false, true}) for (bool white : {false, true}) {
            const QByteArray fixture = storedGrayTIFF(bits, separate, tiled, associated, white, tiled);
            const auto pixels = imported(fixture, 4, 19, 17, 6, 144);
            const int maximum = bits == 8 ? 255 : 65535;
            for (int y = 0; y < 17; ++y) for (int x = 0; x < 19; ++x) {
                const auto p = tiffPixel(x, y, bits, associated, white);
                double value = associated && p.alpha ? double(p.gray) / p.alpha : double(p.gray) / maximum;
                if (white) value = 1 - value;
                const int alpha = std::lround(double(p.alpha) * 255 / maximum);
                const int expected = (srgbByte(value) * alpha + 127) / 255;
                const int offset = (y * 19 + x) * 4;
                near(pixels[offset + 3], alpha, 0, "TIFF layout alpha");
                for (int c = 0; c < 3; ++c) near(pixels[offset + c], expected, 1, "TIFF layout/profile/source precision");
            }
        }
    std::puts("ImageIO gray-alpha TIFF compressed strips/tiles, planar/contiguous, associated/straight, black/white, BigTIFF, orientation/DPI OK");
    const QByteArray truncated = grayAlphaTIFF(16, false).chopped(5);
    uint8_t *raw = nullptr;
    const int rc = decode(reinterpret_cast<const uint8_t *>(truncated.constData()), truncated.size(), &raw,
                          nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, 0);
    std::unique_ptr<uint8_t, decltype(&std::free)> owner(raw, std::free);
    require(rc != 0 && !raw, "truncated gray-alpha TIFF must fail without an opaque fallback");
}
void exports() {
    const uint8_t pixels[] = {100, 50, 25, 128, 200, 100, 50, 255};
    for (const char *uti : {"public.png", "public.jpeg", "public.tiff", "org.webmproject.webp"}) {
        uint8_t *raw = nullptr;
        size_t length = 0;
        const int rc = encode(pixels, 2, 1, 4, uti, -1, 144, 1, &raw, &length);
        std::unique_ptr<uint8_t, decltype(&std::free)> owner(raw, std::free);
        require(rc == 0 && raw && length, "export file through ImageIO callback");
        const QImage image = read(QByteArray(reinterpret_cast<const char *>(raw), length));
        require(image.colorSpace() == QColorSpace(QColorSpace::SRgb), "exported file decodes with actual sRGB profile");
    }
    std::puts("ImageIO export profiles OK (PNG/JPEG/TIFF/WebP)");
}
#ifdef COMPOSITOR_TEST_LIBHEIF
void heifOK(heif_error error) { require(error.code == heif_error_Ok, error.message); }
QByteArray heifFixture(int bits, uint16_t transfer, int alpha, bool linearICC = false) {
    auto ctx = std::unique_ptr<heif_context, decltype(&heif_context_free)>(heif_context_alloc(), heif_context_free);
    heif_encoder *encoderRaw = nullptr;
    heifOK(heif_context_get_encoder_for_format(ctx.get(), heif_compression_HEVC, &encoderRaw));
    auto encoder = std::unique_ptr<heif_encoder, decltype(&heif_encoder_release)>(encoderRaw, heif_encoder_release);
    heifOK(heif_encoder_set_lossless(encoder.get(), 1));
    heif_image *imageRaw = nullptr;
    heifOK(heif_image_create(32, 32, heif_colorspace_YCbCr, heif_chroma_444, &imageRaw));
    auto image = std::unique_ptr<heif_image, decltype(&heif_image_release)>(imageRaw, heif_image_release);
    const int maximum = (1 << bits) - 1;
    for (const auto channel : {heif_channel_Y, heif_channel_Cb, heif_channel_Cr, heif_channel_Alpha}) {
        heifOK(heif_image_add_plane(image.get(), channel, 32, 32, bits));
        int stride = 0;
        auto *plane = heif_image_get_plane(image.get(), channel, &stride);
        const int value = channel == heif_channel_Y ? (1 << (bits - 2)) :
                          channel == heif_channel_Alpha ? alpha : (1 << (bits - 1));
        require(value <= maximum, "fixture channel value in range");
        for (int y = 0; y < 32; ++y) for (int x = 0; x < 32; ++x) {
            if (bits == 8) plane[y * stride + x] = value;
            else reinterpret_cast<uint16_t *>(plane + y * stride)[x] = value;
        }
    }
    auto nclx = std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>(
        heif_nclx_color_profile_alloc(), heif_nclx_color_profile_free);
    heifOK(heif_nclx_color_profile_set_color_primaries(nclx.get(), 1));
    heifOK(heif_nclx_color_profile_set_transfer_characteristics(nclx.get(), transfer));
    heifOK(heif_nclx_color_profile_set_matrix_coefficients(nclx.get(), 6));
    nclx->full_range_flag = 1;
    heifOK(heif_image_set_nclx_color_profile(image.get(), nclx.get()));
    if (linearICC) {
        const QByteArray profile = QColorSpace(QColorSpace::SRgbLinear).iccProfile();
        heifOK(heif_image_set_raw_color_profile(image.get(), "prof", profile.constData(), profile.size()));
    }
    auto options = std::unique_ptr<heif_encoding_options, decltype(&heif_encoding_options_free)>(
        heif_encoding_options_alloc(), heif_encoding_options_free);
    options->output_nclx_profile = nclx.get();
    options->save_two_colr_boxes_when_ICC_and_nclx_available = 1;
    heifOK(heif_context_encode_image(ctx.get(), image.get(), encoder.get(), options.get(), nullptr));
    QByteArray bytes;
    heif_writer writer{};
    writer.writer_api_version = 1;
    writer.write = [](heif_context *, const void *data, size_t length, void *user) -> heif_error {
        static_cast<QByteArray *>(user)->append(static_cast<const char *>(data), length);
        return {heif_error_Ok, heif_suberror_Unspecified, "ok"};
    };
    heifOK(heif_context_write(ctx.get(), &writer, &bytes));
    return bytes;
}
void heifImports() {
    for (int bits : {8, 10, 12}) for (uint16_t transfer : {1, 8, 13}) {
        const int maximum = (1 << bits) - 1;
        const int alphaCode = 1 << (bits - 1);
        const QByteArray fixture = heifFixture(bits, transfer, alphaCode);
        const auto pixels = imported(fixture, 4, 32, 32);
        const double value = double(1 << (bits - 2)) / maximum;
        const double linear = transfer == 8 ? value : value < 0.081 ? value / 4.5 : std::pow((value + 0.099) / 1.099, 1 / 0.45);
        const int color = transfer == 13 ? std::lround(value * 255) : srgbByte(linear);
        const int alpha = std::lround(double(alphaCode) * 255 / maximum);
        for (size_t i = 0; i < pixels.size(); i += 4) {
            near(pixels[i + 3], alpha, 1, "HEIF alpha retains source range");
            for (int c = 0; c < 3; ++c)
                near(pixels[i + c], (color * alpha + 127) / 255, 2, "HEIF transfer/precision before premultiplication");
        }
        std::printf("ImageIO HEIF %d-bit transfer %u and alpha OK\n", bits, transfer);
    }
    // ICC takes precedence over a coexisting nclx sRGB transfer declaration.
    const auto pixels = imported(heifFixture(10, 13, 512, true), 4, 32, 32);
    const int color = (srgbByte(256.0 / 1023) * 128 + 127) / 255;
    for (size_t i = 0; i < pixels.size(); i += 4) {
        near(pixels[i + 3], 128, 1, "HEIF ICC alpha");
        for (int c = 0; c < 3; ++c) near(pixels[i + c], color, 2, "HEIF ICC overrides nclx");
    }
    std::puts("ImageIO HEIF ICC precedence OK");
}
void heifExport() {
    std::vector<uint8_t> pixels(32 * 32 * 4);
    for (size_t i = 0; i < pixels.size(); i += 4) {
        pixels[i] = 100; pixels[i + 1] = 50; pixels[i + 2] = 25; pixels[i + 3] = 128;
    }
    uint8_t *raw = nullptr;
    size_t length = 0;
    const int rc = encode(pixels.data(), 32, 32, 4, "public.heic", -1, 0, 1, &raw, &length);
    std::unique_ptr<uint8_t, decltype(&std::free)> owner(raw, std::free);
    require(rc == 0 && raw && length, "export HEIF through ImageIO callback");
    auto ctx = std::unique_ptr<heif_context, decltype(&heif_context_free)>(heif_context_alloc(), heif_context_free);
    heifOK(heif_context_read_from_memory_without_copy(ctx.get(), raw, length, nullptr));
    heif_image_handle *handleRaw = nullptr;
    heifOK(heif_context_get_primary_image_handle(ctx.get(), &handleRaw));
    auto handle = std::unique_ptr<heif_image_handle, decltype(&heif_image_handle_release)>(handleRaw, heif_image_handle_release);
    heif_color_profile_nclx *nclxRaw = nullptr;
    heifOK(heif_image_handle_get_nclx_color_profile(handle.get(), &nclxRaw));
    auto nclx = std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>(nclxRaw, heif_nclx_color_profile_free);
    require(nclx && nclx->color_primaries == 1 && nclx->transfer_characteristics == 13, "export HEIF actually declares sRGB");
    require(heif_image_handle_has_alpha_channel(handle.get()), "HEIF export retains alpha channel");
    const auto decoded = imported(QByteArray(reinterpret_cast<const char *>(raw), length), 4, 32, 32);
    for (size_t i = 0; i < decoded.size(); ++i) near(decoded[i], pixels[i], 2, "tagged HEIF export round trip");
    std::puts("ImageIO HEIF sRGB export profile/alpha OK");
}
#endif
}
int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    try {
        require(compositor_qt_imageio_functions(&decode, &encode), "load ImageIO callbacks");
        pngImports();
        tiffImports();
        tiffLayouts();
        exports();
#ifdef COMPOSITOR_TEST_LIBHEIF
        heifImports();
        heifExport();
#else
        require(argc < 2 || std::strcmp(argv[1], "--require-heif"), "contract CI requires libheif color coverage");
        std::puts("HEIF color cases unavailable: built without libheif");
#endif
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "ImageIO color test failed: %s\n", error.what());
        return 1;
    }
}
