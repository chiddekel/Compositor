#include <poppler-qt6.h>
#include <QBuffer>
#include <QByteArray>
#include <QImage>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>

namespace {
struct Document {
    std::unique_ptr<Poppler::Document> pdf;
};
int rotation(const Poppler::Page &page) {
    switch (page.orientation()) {
    case Poppler::Page::Landscape: return 90;
    case Poppler::Page::Seascape: return 270;
    case Poppler::Page::UpsideDown: return 180;
    default: return 0;
    }
}
}

extern "C" void *compositor_pdf_open(const uint8_t *bytes, size_t count) {
    if (!bytes || !count || count > size_t(INT32_MAX)) return nullptr;
    auto pdf = Poppler::Document::loadFromData(QByteArray(reinterpret_cast<const char *>(bytes), qsizetype(count)));
    if (!pdf) return nullptr;
    pdf->setRenderBackend(Poppler::Document::SplashBackend);
    pdf->setPaperColor(Qt::transparent);
    pdf->setRenderHint(Poppler::Document::IgnorePaperColor, true);
    pdf->setRenderHint(Poppler::Document::Antialiasing, true);
    pdf->setRenderHint(Poppler::Document::TextAntialiasing, true);
    return new Document{std::move(pdf)};
}
extern "C" void compositor_pdf_close(void *handle) { delete static_cast<Document *>(handle); }
extern "C" int compositor_pdf_count(void *handle) {
    if (!handle) return 0;
    const auto &pdf = static_cast<Document *>(handle)->pdf;
    return pdf->isLocked() ? 0 : pdf->numPages();
}
extern "C" int compositor_pdf_locked(void *handle) {
    return handle && static_cast<Document *>(handle)->pdf->isLocked();
}
// The crop box before the page's intrinsic rotation. Poppler presents the already-cropped page with origin zero.
extern "C" int compositor_pdf_page(void *handle, int index, double *width, double *height, int *angle) {
    if (!handle || !width || !height || !angle || index < 0) return -1;
    const auto &pdf = static_cast<Document *>(handle)->pdf;
    if (pdf->isLocked()) return -1;
    auto page = pdf->page(index);
    if (!page) return -1;
    const auto size = page->pageSizeF();
    *angle = rotation(*page);
    *width = *angle % 180 ? size.height() : size.width();
    *height = *angle % 180 ? size.width() : size.height();
    return 0;
}
// Unrotated premultiplied pixels: CGContext's page drawing transform applies the intrinsic rotation once.
extern "C" uint8_t *compositor_pdf_render(void *handle, int index, int width, int height) {
    if (!handle || index < 0 || width < 1 || height < 1 || width > 32768 || height > 32768
        || uint64_t(width) * height > 512000000) return nullptr;
    const auto &pdf = static_cast<Document *>(handle)->pdf;
    if (pdf->isLocked()) return nullptr;
    auto page = pdf->page(index);
    if (!page) return nullptr;
    const int angle = rotation(*page);
    const auto size = page->pageSizeF();
    const double w = angle % 180 ? size.height() : size.width(), h = angle % 180 ? size.width() : size.height();
    if (!(w > 0 && h > 0)) return nullptr;
    const auto turn = static_cast<Poppler::Page::Rotation>(((360 - angle) % 360) / 90);
    const QImage image = page->renderToImage(72.0 * width / w, 72.0 * height / h, 0, 0, width, height, turn)
        .convertToFormat(QImage::Format_RGBA8888_Premultiplied);
    if (image.isNull() || image.width() != width || image.height() != height) return nullptr;
    auto *pixels = static_cast<uint8_t *>(std::malloc(size_t(width) * height * 4));
    if (!pixels) return nullptr;
    for (int y = 0; y < height; ++y) std::memcpy(pixels + size_t(y) * width * 4, image.constScanLine(y), size_t(width) * 4);
    return pixels;
}
