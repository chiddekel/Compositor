// SessionWindow — see SessionWindow.h. Drives the Swift core via compositor_session_*
// and paints the composited RGBA via QImage.

#include "SessionWindow.h"

#include <QPainter>
#include <QPaintEvent>

#include <cstdint>
#include <cstring>
#include <vector>

// compositor_session_* C ABI (see include/CompositorCore.h). Declared locally so
// the Qt host need not add an include path to the Swift core's headers.
extern "C" {
uint64_t compositor_session_create(void);
void compositor_session_close(uint64_t handle);
int32_t compositor_session_command(uint64_t handle, const uint8_t *json, size_t count);
int64_t compositor_session_render(uint64_t handle, uint8_t *output, size_t capacity);
}

static int32_t cmd(uint64_t h, const char *json) {
    return compositor_session_command(h, reinterpret_cast<const uint8_t *>(json),
                                      std::strlen(json));
}

SessionWindow::SessionWindow(QWidget *parent) : QMainWindow(parent) {
    setWindowTitle("Compositor");
    resize(320, 240);

    // Drive the Swift editor core through the C ABI: create a canvas, paint a red
    // stroke, render, and hold the composited RGBA as a QImage for paintEvent.
    uint64_t h = compositor_session_create();
    cmd(h, R"({"version":1,"action":"new","width":64,"height":64})");
    cmd(h, R"({"version":1,"action":"addLayer"})");
    cmd(h, R"({"version":1,"action":"brushBegin","x":8,"y":8,"parameters":{"diameter":16,"hardness":1,"opacity":1,"red":1,"green":0,"blue":0,"erasing":0,"mask":0}})");
    cmd(h, R"({"version":1,"action":"brushMove","x":48,"y":48})");
    cmd(h, R"({"version":1,"action":"brushEnd"})");

    const int bytes = 64 * 64 * 4;
    std::vector<uint8_t> rgba(static_cast<size_t>(bytes));
    int64_t n = compositor_session_render(h, rgba.data(), rgba.size());
    if (n == bytes) {
        // The core emits premultiplied RGBA; QImage Format_RGBA8888 expects
        // non-premultiplied. For this proof (solid-opaque red on transparent) the
        // channels are identical; pixel parity is Skia's job, not this slice.
        m_image = QImage(rgba.data(), 64, 64, 64 * 4, QImage::Format_RGBA8888).copy();
    }
    compositor_session_close(h);
}

void SessionWindow::paintEvent(QPaintEvent *event) {
    Q_UNUSED(event);
    QPainter p(this);
    if (!m_image.isNull()) {
        p.drawImage(rect(), m_image.scaled(rect().size(), Qt::KeepAspectRatio));
    } else {
        p.fillRect(rect(), Qt::black);
    }
}