// Qt image plugins as the ImageIO compat backend. Registered into the Swift core at startup so
// CGImageSource / CGImageDestination (used by upstream's importer, exporter and project store) decode and encode
// every format Qt supports (PNG, JPEG, TIFF, WebP, BMP, GIF, ...), not just the portable PNG codec.

#include <QBuffer>
#include <QByteArray>
#include <QImage>
#include <QImageReader>
#include <QImageWriter>
#include <QPainter>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>

extern "C" {
typedef int32_t (*CompositorImageDecodeFn)(const uint8_t *, size_t, uint8_t **, int32_t *, int32_t *, int32_t *, double *,
                                           int32_t *, char *, size_t);
typedef int32_t (*CompositorImageEncodeFn)(const uint8_t *, int32_t, int32_t, int32_t, const char *, double, double,
                                           uint8_t **, size_t *);
// Provided by the Swift core; weak so C++-only builds (no Swift) still link.
void compositor_imageio_register(CompositorImageDecodeFn, CompositorImageEncodeFn) __attribute__((weak));
}

namespace {

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

int32_t decodeImage(const uint8_t *data, size_t length, uint8_t **out, int32_t *width, int32_t *height,
                    int32_t *channels, double *dpi, int32_t *orientation, char *uti, size_t utiCapacity) {
    if (!data || !length || !out) return -1;
    QByteArray bytes = QByteArray::fromRawData(reinterpret_cast<const char *>(data), static_cast<qsizetype>(length));
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);
    reader.setAutoTransform(false);
    const char *type = utiForFormat(reader.format());
    if (!type) return -2;
    const auto transform = reader.transformation();
    QImage image = reader.read();
    if (image.isNull()) return -3;

    const bool gray = image.format() == QImage::Format_Grayscale8 || (image.isGrayscale() && !image.hasAlphaChannel() &&
                                                                       image.colorCount() == 0 && image.format() != QImage::Format_Indexed8);
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
    if (orientation) *orientation = exifOrientation(transform);
    if (uti && utiCapacity) { strncpy(uti, type, utiCapacity - 1); uti[utiCapacity - 1] = 0; }
    return 0;
}

int32_t encodeImage(const uint8_t *pixels, int32_t width, int32_t height, int32_t channels, const char *uti,
                    double quality, double dpi, uint8_t **out, size_t *outLength) {
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
    // JPEG has no alpha: flatten onto white like ImageIO does for opaque destinations.
    if (!strcmp(format, "jpeg") && image.hasAlphaChannel()) {
        QImage flat(image.size(), QImage::Format_RGB32);
        flat.fill(Qt::white);
        QPainter p(&flat);
        p.drawImage(0, 0, image);
        p.end();
        image = flat;
    }
    if (!writer.write(image)) return -2;
    auto *copy = static_cast<uint8_t *>(malloc(static_cast<size_t>(bytes.size())));
    if (!copy) return -3;
    memcpy(copy, bytes.constData(), static_cast<size_t>(bytes.size()));
    *out = copy;
    *outLength = static_cast<size_t>(bytes.size());
    return 0;
}

}  // namespace

extern "C" int compositor_qt_imageio_install(void) {
    if (!compositor_imageio_register) return 0;
    compositor_imageio_register(decodeImage, encodeImage);
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
        if (encodeImage(rgba.data(), w, h, 4, c.uti, c.lossless ? -1 : 0.95, 144.0, &encoded, &length) != 0) return 1;
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
    if (encodeImage(plane.data(), w, h, 1, "public.png", -1, 0, &encoded, &length) != 0) return 6;
    uint8_t *decoded = nullptr; int32_t dw = 0, dh = 0, ch = 0, orient = 0; double dpi = 0; char uti[96] = {0};
    const int32_t rc = decodeImage(encoded, length, &decoded, &dw, &dh, &ch, &dpi, &orient, uti, sizeof(uti));
    free(encoded);
    const bool ok = rc == 0 && ch == 1 && dw == w && memcmp(decoded, plane.data(), plane.size()) == 0;
    free(decoded);
    return ok ? 0 : 7;
}
