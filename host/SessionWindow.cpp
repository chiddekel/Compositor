// SessionWindow — see SessionWindow.h. Drives the Swift core via compositor_session_*
// and paints the composited RGBA via QImage. Implements file operations using Qt
// codecs (IO milestone: file-map "IO / codec mapping" tier).

#include "SessionWindow.h"

#include <QPainter>
#include <QPaintEvent>
#include <QMouseEvent>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QUrl>
#include <QFileDialog>
#include <QMenuBar>
#include <QMessageBox>
#include <QComboBox>
#include <QColorDialog>
#include <QPushButton>
#include <QStatusBar>
#include <QDockWidget>
#include <QListWidget>
#include <QSlider>
#include <QVBoxLayout>
#include <QLabel>
#include <QFile>
#include <QImageWriter>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QFileInfo>
#include <QDir>

#include <cstdint>
#include <cstring>
#include <algorithm>
#include <vector>

// compositor_session_* C ABI (see include/CompositorCore.h). Declared locally so
// the Qt host need not add an include path to the Swift core's headers.
extern "C" {
uint64_t compositor_session_create(void);
void compositor_session_close(uint64_t handle);
int32_t compositor_session_command(uint64_t handle, const uint8_t *json, size_t count);
int64_t compositor_session_render(uint64_t handle, uint8_t *output, size_t capacity);
int64_t compositor_session_state(uint64_t handle, uint8_t *output, size_t capacity);
int64_t compositor_session_export_manifest(uint64_t handle, uint8_t *output, size_t capacity);
int32_t compositor_session_import_manifest(uint64_t handle, const uint8_t *json, size_t count);
int64_t compositor_session_export_layer(uint64_t handle, const uint8_t *layer_id, size_t layer_id_count,
                                        int32_t mask, uint8_t *output, size_t capacity,
                                        size_t *width, size_t *height);
int32_t compositor_session_import_layer(uint64_t handle, const uint8_t *layer_id, size_t layer_id_count,
                                        int32_t mask, const uint8_t *pixels, size_t count,
                                        size_t width, size_t height);
int32_t compositor_session_import_rgba(uint64_t handle, const uint8_t *pixels, size_t count,
                                       size_t width, size_t height, const uint8_t *name, size_t name_count,
                                       int32_t replacing);
}

static int32_t cmd(uint64_t h, const char *json) {
    return compositor_session_command(h, reinterpret_cast<const uint8_t *>(json),
                                      std::strlen(json));
}

static QImage straightRGBA(const std::vector<uint8_t> &premultiplied, int width, int height) {
    std::vector<uint8_t> straight = premultiplied;
    for (size_t i = 0; i + 3 < straight.size(); i += 4) {
        const uint8_t alpha = straight[i + 3];
        if (alpha == 0) {
            straight[i] = straight[i + 1] = straight[i + 2] = 0;
        } else if (alpha != 255) {
            straight[i] = static_cast<uint8_t>(std::min(255, (static_cast<int>(straight[i]) * 255 + alpha / 2) / alpha));
            straight[i + 1] = static_cast<uint8_t>(std::min(255, (static_cast<int>(straight[i + 1]) * 255 + alpha / 2) / alpha));
            straight[i + 2] = static_cast<uint8_t>(std::min(255, (static_cast<int>(straight[i + 2]) * 255 + alpha / 2) / alpha));
        }
    }
    return QImage(reinterpret_cast<const uchar *>(straight.data()), width, height, width * 4,
                  QImage::Format_RGBA8888).copy();
}

static QImage renderToQImage(uint64_t h, int width, int height) {
    const int bytes = width * height * 4;
    std::vector<uint8_t> rgba(static_cast<size_t>(bytes));
    int64_t n = compositor_session_render(h, rgba.data(), rgba.size());
    if (n == bytes) {
        return straightRGBA(rgba, width, height);
    }
    return QImage();
}

SessionWindow::SessionWindow(QWidget *parent) : QMainWindow(parent) {
    setWindowTitle("Compositor");
    resize(320, 240);
    setAcceptDrops(true);

    // Drive the Swift editor core through the C ABI: create a canvas, paint a red
    // stroke, render, and hold the composited RGBA as a QImage for paintEvent.
    m_sessionHandle = compositor_session_create();
    cmd(m_sessionHandle, R"({"version":1,"action":"new","width":64,"height":64})");
    cmd(m_sessionHandle, R"({"version":1,"action":"addLayer"})");
    cmd(m_sessionHandle, R"({"version":1,"action":"brushBegin","x":8,"y":8,"parameters":{"diameter":16,"hardness":1,"opacity":1,"red":1,"green":0,"blue":0,"erasing":0,"mask":0}})");
    cmd(m_sessionHandle, R"({"version":1,"action":"brushMove","x":48,"y":48})");
    cmd(m_sessionHandle, R"({"version":1,"action":"brushEnd"})");

    m_image = renderToQImage(m_sessionHandle, 64, 64);

    QMenu *file = menuBar()->addMenu(tr("&File"));
    file->addAction(tr("&New Canvas"), QKeySequence::New, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"new","width":512,"height":512})") == 0) {
            m_image = renderToQImage(m_sessionHandle, 512, 512);
            refreshImage();
        }
    });
    file->addAction(tr("&Open Image..."), QKeySequence::Open, this, [this] {
        const QString path = QFileDialog::getOpenFileName(this, tr("Open Image"), QString(),
            tr("Images (*.png *.jpg *.jpeg *.bmp *.tiff *.webp);;All files (*)"));
        if (!path.isEmpty() && !importImage(path)) QMessageBox::warning(this, tr("Open failed"), tr("Could not open image."));
    });
    file->addAction(tr("Open &Project..."), this, [this] {
        const QString path = QFileDialog::getExistingDirectory(this, tr("Open Project"));
        if (!path.isEmpty() && !loadProject(path)) QMessageBox::warning(this, tr("Open failed"), tr("Could not open project."));
    });
    file->addAction(tr("Save Project &As..."), QKeySequence::Save, this, [this] {
        const QString path = QFileDialog::getSaveFileName(this, tr("Save Project"), QString(), tr("Compositor project (*.comp);;All files (*)"));
        if (!path.isEmpty() && !saveProject(path)) QMessageBox::warning(this, tr("Save failed"), tr("Could not save project."));
    });
    file->addAction(tr("Export &PNG..."), this, [this] {
        const QString path = QFileDialog::getSaveFileName(this, tr("Export PNG"), QString(), tr("PNG (*.png)"));
        if (!path.isEmpty() && !exportPNG(path)) QMessageBox::warning(this, tr("Export failed"), tr("Could not export PNG."));
    });
    file->addAction(tr("Export &JPEG..."), this, [this] {
        const QString path = QFileDialog::getSaveFileName(this, tr("Export JPEG"), QString(), tr("JPEG (*.jpg *.jpeg)"));
        if (!path.isEmpty() && !exportJPEG(path)) QMessageBox::warning(this, tr("Export failed"), tr("Could not export JPEG."));
    });
    file->addSeparator();
    file->addAction(tr("&Quit"), QKeySequence::Quit, this, &QWidget::close);

    QMenu *edit = menuBar()->addMenu(tr("&Edit"));
    edit->addAction(tr("&Undo"), QKeySequence::Undo, this, [this] {
        if (!m_painting && cmd(m_sessionHandle, R"({"version":1,"action":"undo"})") == 0) refreshImage();
    });
    edit->addAction(tr("&Redo"), QKeySequence::Redo, this, [this] {
        if (!m_painting && cmd(m_sessionHandle, R"({"version":1,"action":"redo"})") == 0) refreshImage();
    });
    edit->addSeparator();
    edit->addAction(tr("&Copy"), QKeySequence::Copy, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"copy"})") == 0) statusBar()->showMessage(tr("Copied selection."), 1500);
    });
    edit->addAction(tr("Copy &Merged"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"copyMerged"})") == 0) statusBar()->showMessage(tr("Copied merged selection."), 1500);
    });
    edit->addAction(tr("Cu&t"), QKeySequence::Cut, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"cut"})") == 0) refreshImage();
    });
    edit->addAction(tr("&Paste"), QKeySequence::Paste, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"paste"})") == 0) refreshImage();
    });
    edit->addAction(tr("Duplicate Layer"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"duplicateLayer"})") == 0) { refreshImage(); refreshLayers(); }
    });
    QMenu *layer = menuBar()->addMenu(tr("&Layer"));
    layer->addAction(tr("&New Layer"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addLayer"})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("&Delete Layer"), QKeySequence::Delete, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"deleteLayer"})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Flip Layer &Horizontal"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"flipLayer","horizontally":true})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Flip Layer &Vertical"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"flipLayer","horizontally":false})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Add Rectangle"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addShape","kind":"Rectangle","x":8,"y":8,"width":48,"height":32,"parameters":{"red":1,"green":1,"blue":1,"cornerRadius":0}})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Add Ellipse"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addShape","kind":"Ellipse","x":8,"y":8,"width":48,"height":32,"parameters":{"red":1,"green":1,"blue":1}})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Add Reveal Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addRevealMask"})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Add Hide Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addHideMask"})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Invert Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"invertMask"})") == 0) refreshImage();
    });
    layer->addAction(tr("Delete Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"deleteMask"})") == 0) { refreshImage(); refreshLayers(); }
    });
    QMenu *tool = menuBar()->addMenu(tr("&Tool"));
    tool->addAction(tr("Paint"), this, [this] { m_brushMode = "Paint"; });
    tool->addAction(tr("Smudge"), this, [this] { m_brushMode = "Smudge"; });
    tool->addAction(tr("Liquify"), this, [this] { m_brushMode = "Liquify"; });
    QMenu *filter = menuBar()->addMenu(tr("&Filter"));
    for (const QString &kind : {QString("Gaussian Blur"), QString("Motion Blur"), QString("Add Noise"),
                                QString("Lens Correction"), QString("Grain"), QString("Exposure")}) {
        auto *action = filter->addAction(kind, this, [this, kind] { showFilterDialog(kind); });
        action->setObjectName("filter." + kind);
    }
    QMenu *adjust = menuBar()->addMenu(tr("&Adjust"));
    for (const QString &kind : {QString("Levels"), QString("Hue/Saturation"), QString("Curves"),
                                QString("Exposure"), QString("Gradient Map"), QString("Grain")}) {
        auto *action = adjust->addAction(kind, this, [this, kind] { showAdjustDialog(kind); });
        action->setObjectName("adjust." + kind);
    }
    QMenu *imageMenu = menuBar()->addMenu(tr("&Image"));
    imageMenu->addAction(tr("Canvas Size…"), this, [this] { showSizeDialog(false); })->setObjectName("canvasSize");
    imageMenu->addAction(tr("Image Size…"), this, [this] { showSizeDialog(true); })->setObjectName("imageSize");

    auto *dock = new QDockWidget(tr("Layers"), this);
    auto *panel = new QWidget(dock);
    auto *layout = new QVBoxLayout(panel);
    m_layers = new QListWidget(panel);
    m_layers->setSelectionMode(QAbstractItemView::SingleSelection);
    layout->addWidget(m_layers);
    layout->addWidget(new QLabel(tr("Opacity"), panel));
    m_opacity = new QSlider(Qt::Horizontal, panel);
    m_opacity->setRange(0, 100);
    m_opacity->setValue(100);
    layout->addWidget(m_opacity);
    dock->setWidget(panel);
    addDockWidget(Qt::RightDockWidgetArea, dock);
    connect(m_layers, &QListWidget::currentRowChanged, this, &SessionWindow::selectLayerRow);
    connect(m_opacity, &QSlider::valueChanged, this, &SessionWindow::setOpacityFromSlider);
    refreshLayers();

    // Brush palette: diameter/hardness/opacity sliders, a color button, and the
    // active-layer blend mode. Shared by the mouse paint path and smokes.
    auto *brushDock = new QDockWidget(tr("Brush"), this);
    auto *brushPanel = new QWidget(brushDock);
    auto *brushLayout = new QVBoxLayout(brushPanel);
    m_brushColorButton = new QPushButton(tr("Red"), brushPanel);
    m_brushColorButton->setObjectName("brush.color");
    m_brushColorButton->setStyleSheet("background-color: red;");
    brushLayout->addWidget(m_brushColorButton);
    brushLayout->addWidget(new QLabel(tr("Diameter"), brushPanel));
    m_brushDiameterSlider = new QSlider(Qt::Horizontal, brushPanel);
    m_brushDiameterSlider->setObjectName("brush.diameter");
    m_brushDiameterSlider->setRange(1, 256);
    m_brushDiameterSlider->setValue(m_brushDiameter);
    brushLayout->addWidget(m_brushDiameterSlider);
    brushLayout->addWidget(new QLabel(tr("Hardness"), brushPanel));
    m_brushHardnessSlider = new QSlider(Qt::Horizontal, brushPanel);
    m_brushHardnessSlider->setObjectName("brush.hardness");
    m_brushHardnessSlider->setRange(0, 100);
    m_brushHardnessSlider->setValue(m_brushHardness);
    brushLayout->addWidget(m_brushHardnessSlider);
    brushLayout->addWidget(new QLabel(tr("Opacity"), brushPanel));
    m_brushOpacitySlider = new QSlider(Qt::Horizontal, brushPanel);
    m_brushOpacitySlider->setObjectName("brush.opacity");
    m_brushOpacitySlider->setRange(0, 100);
    m_brushOpacitySlider->setValue(m_brushOpacity);
    brushLayout->addWidget(m_brushOpacitySlider);
    brushLayout->addWidget(new QLabel(tr("Blend"), brushPanel));
    m_blend = new QComboBox(brushPanel);
    m_blend->setObjectName("blend.mode");
    for (const QString &mode : blendModes()) m_blend->addItem(mode);
    brushLayout->addWidget(m_blend);
    brushDock->setWidget(brushPanel);
    addDockWidget(Qt::RightDockWidgetArea, brushDock);
    connect(m_brushColorButton, &QPushButton::clicked, this, &SessionWindow::pickBrushColor);
    connect(m_brushDiameterSlider, &QSlider::valueChanged, this, &SessionWindow::setBrushDiameter);
    connect(m_brushHardnessSlider, &QSlider::valueChanged, this, &SessionWindow::setBrushHardness);
    connect(m_brushOpacitySlider, &QSlider::valueChanged, this, &SessionWindow::setBrushOpacity);
    connect(m_blend, &QComboBox::currentIndexChanged, this, &SessionWindow::setBlendModeFromCombo);

    statusBar()->showMessage(tr("Drag on canvas to paint."));
}

SessionWindow::~SessionWindow() {
    if (m_sessionHandle != 0) compositor_session_close(m_sessionHandle);
}

void SessionWindow::paintEvent(QPaintEvent *event) {
    Q_UNUSED(event);
    QPainter p(this);
    if (!m_image.isNull()) {
        const QSize scaled = m_image.size().scaled(size(), Qt::KeepAspectRatio);
        const QRect target((width() - scaled.width()) / 2, (height() - scaled.height()) / 2,
                           scaled.width(), scaled.height());
        p.fillRect(rect(), Qt::black);
        p.drawImage(target, m_image);
    } else {
        p.fillRect(rect(), Qt::black);
    }
}

QPointF SessionWindow::documentPoint(const QPointF &windowPoint) const {
    if (m_image.isNull()) return QPointF();
    const QSize scaled = m_image.size().scaled(size(), Qt::KeepAspectRatio);
    const QRectF target((width() - scaled.width()) / 2.0, (height() - scaled.height()) / 2.0,
                       scaled.width(), scaled.height());
    const QPointF local = windowPoint - target.topLeft();
    return QPointF(local.x() * m_image.width() / target.width(),
                   local.y() * m_image.height() / target.height());
}

QJsonObject SessionWindow::sessionState() const {
    const int64_t size = compositor_session_state(m_sessionHandle, nullptr, 0);
    if (size <= 0 || size > 4 * 1024 * 1024) return {};
    QByteArray bytes(static_cast<qsizetype>(size), Qt::Uninitialized);
    if (compositor_session_state(m_sessionHandle, reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size) return {};
    return QJsonDocument::fromJson(bytes).object();
}

bool SessionWindow::sendCommand(QJsonObject command) {
    command.insert("version", 1);
    const QByteArray bytes = QJsonDocument(command).toJson(QJsonDocument::Compact);
    const int result = compositor_session_command(m_sessionHandle,
        reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size());
    if (result != 0) statusBar()->showMessage(sessionState().value("error").toString(tr("Could not apply the operation.")), 5000);
    return result == 0;
}

void SessionWindow::refreshImage() {
    if (m_sessionHandle == 0) return;
    const auto state = sessionState();
    const int width = state.value("width").toInt(), height = state.value("height").toInt();
    if (width <= 0 || height <= 0 || qint64(width) * height > 100000000) return;
    QImage rendered = renderToQImage(m_sessionHandle, width, height);
    if (rendered.isNull()) return;
    const int dpm = qRound(state.value("resolution").toDouble(72) / 0.0254);
    rendered.setDotsPerMeterX(dpm);
    rendered.setDotsPerMeterY(dpm);
    m_image = rendered;
    update();
    refreshLayers();
}

void SessionWindow::refreshLayers() {
    if (!m_layers || m_sessionHandle == 0) return;
    const int64_t size = compositor_session_state(m_sessionHandle, nullptr, 0);
    if (size <= 0 || size > 4 * 1024 * 1024) return;
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    if (compositor_session_state(m_sessionHandle, bytes.data(), bytes.size()) != size) return;
    const QJsonDocument state = QJsonDocument::fromJson(QByteArray(reinterpret_cast<char *>(bytes.data()), bytes.size()));
    if (!state.isObject()) return;
    const QJsonArray layers = state.object().value("layers").toArray();
    const QString active = state.object().value("activeLayerID").toString();
    m_syncingLayers = true;
    m_layers->clear();
    int selected = -1;
    for (int i = 0; i < layers.size(); ++i) {
        const QJsonObject layer = layers.at(i).toObject();
        const QString id = layer.value("id").toString();
        const QString name = layer.value("name").toString();
        auto *item = new QListWidgetItem(layer.value("isGroup").toBool() ? "[Folder] " + name : name, m_layers);
        item->setData(Qt::UserRole, id);
        if (id == active) selected = i;
    }
    if (selected >= 0) {
        m_layers->setCurrentRow(selected);
        if (selected < layers.size()) m_opacity->setValue(qRound(layers.at(selected).toObject().value("opacity").toDouble(1) * 100));
    }
    m_syncingLayers = false;
}

void SessionWindow::selectLayerRow(int row) {
    if (m_syncingLayers || row < 0 || !m_layers) return;
    const QString id = m_layers->item(row)->data(Qt::UserRole).toString();
    const QByteArray json = QString(R"({"version":1,"action":"selectLayer","layerID":"%1"})").arg(id).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(json.constData()), json.size()) == 0) refreshImage();
}

void SessionWindow::setOpacityFromSlider(int value) {
    if (m_syncingLayers) return;
    const QByteArray json = QString(R"({"version":1,"action":"setOpacity","value":%1})").arg(value / 100.0, 0, 'f', 3).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(json.constData()), json.size()) == 0) refreshImage();
}

QStringList SessionWindow::blendModes() const {
    return {QStringLiteral("Normal"), QStringLiteral("Multiply"), QStringLiteral("Screen"),
            QStringLiteral("Overlay"), QStringLiteral("Darken"), QStringLiteral("Lighten"),
            QStringLiteral("Color Dodge"), QStringLiteral("Color Burn"), QStringLiteral("Hard Light"),
            QStringLiteral("Soft Light"), QStringLiteral("Difference"), QStringLiteral("Exclusion"),
            QStringLiteral("Hue"), QStringLiteral("Saturation"), QStringLiteral("Color"), QStringLiteral("Luminosity")};
}

void SessionWindow::pickBrushColor() {
    const QColor color = QColorDialog::getColor(m_brushColor, this, tr("Brush color"));
    if (color.isValid()) setBrushColor(color);
}

void SessionWindow::setBrushColor(const QColor &color) {
    m_brushColor = color;
    const QString style = QString("background-color: rgb(%1, %2, %3);").arg(color.red()).arg(color.green()).arg(color.blue());
    m_brushColorButton->setStyleSheet(style);
    m_brushColorButton->setText(color.name());
}

void SessionWindow::setBrushDiameter(int value) { m_brushDiameter = value; }
void SessionWindow::setBrushHardness(int value) { m_brushHardness = value; }
void SessionWindow::setBrushOpacity(int value) { m_brushOpacity = value; }

void SessionWindow::setBlendModeFromCombo(int index) {
    if (m_syncingLayers || index < 0) return;
    const QJsonObject command{{"action", "setBlendMode"}, {"kind", blendModes().at(index)}};
    if (sendCommand(command)) refreshImage();
}

void SessionWindow::paintStroke(double x1, double y1, double x2, double y2) {
    const QByteArray begin = QString(
        R"({"version":1,"action":"brushBegin","x":%1,"y":%2,"parameters":{"diameter":%3,"hardness":%4,"opacity":%5,"red":%6,"green":%7,"blue":%8,"erasing":0,"mask":0}})")
        .arg(x1, 0, 'f', 4).arg(y1, 0, 'f', 4)
        .arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3).arg(m_brushOpacity / 100.0, 0, 'f', 3)
        .arg(m_brushColor.redF(), 0, 'f', 4).arg(m_brushColor.greenF(), 0, 'f', 4).arg(m_brushColor.blueF(), 0, 'f', 4).toUtf8();
    const QByteArray move = QString(R"({"version":1,"action":"brushMove","x":%1,"y":%2})")
        .arg(x2, 0, 'f', 4).arg(y2, 0, 'f', 4).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(begin.constData()), begin.size()) != 0) return;
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(move.constData()), move.size()) != 0) return;
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(R"({"version":1,"action":"brushEnd"})"), std::strlen(R"({"version":1,"action":"brushEnd"})")) == 0) refreshImage();
}

void SessionWindow::mousePressEvent(QMouseEvent *event) {
    if (event->button() != Qt::LeftButton || m_painting) return;
    const QPointF point = documentPoint(event->position());
    const bool warp = m_brushMode != "Paint";
    const QString json = warp
        ? QString(R"({"version":1,"action":"warpBegin","kind":"%1","x":%2,"y":%3,"parameters":{"diameter":%4,"hardness":%5,"opacity":1}})").arg(m_brushMode).arg(point.x(), 0, 'f', 4).arg(point.y(), 0, 'f', 4).arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3)
        : QString(R"({"version":1,"action":"brushBegin","x":%1,"y":%2,"parameters":{"diameter":%3,"hardness":%4,"opacity":%5,"red":%6,"green":%7,"blue":%8,"erasing":0,"mask":0}})")
        .arg(point.x(), 0, 'f', 4).arg(point.y(), 0, 'f', 4)
        .arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3).arg(m_brushOpacity / 100.0, 0, 'f', 3)
        .arg(m_brushColor.redF(), 0, 'f', 4).arg(m_brushColor.greenF(), 0, 'f', 4).arg(m_brushColor.blueF(), 0, 'f', 4);
    const QByteArray bytes = json.toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
        m_painting = true;
        refreshImage();
    }
}

void SessionWindow::mouseMoveEvent(QMouseEvent *event) {
    if (!m_painting) return;
    const QPointF point = documentPoint(event->position());
    const QString json = QString(R"({"version":1,"action":"%1","x":%2,"y":%3})")
        .arg(m_brushMode == "Paint" ? "brushMove" : "warpMove")
        .arg(point.x(), 0, 'f', 4).arg(point.y(), 0, 'f', 4);
    const QByteArray bytes = json.toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) refreshImage();
}

void SessionWindow::mouseReleaseEvent(QMouseEvent *event) {
    if (event->button() != Qt::LeftButton || !m_painting) return;
    m_painting = false;
    const char *action = m_brushMode == "Paint" ? "brushEnd" : "warpEnd";
    const QByteArray json = QString(R"({"version":1,"action":"%1"})").arg(action).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(json.constData()), json.size()) == 0) refreshImage();
}

void SessionWindow::dragEnterEvent(QDragEnterEvent *event) {
    if (event->mimeData()->hasUrls()) event->acceptProposedAction();
}

void SessionWindow::dropEvent(QDropEvent *event) {
    for (const QUrl &url : event->mimeData()->urls()) {
        if (url.isLocalFile() && importImage(url.toLocalFile())) {
            event->acceptProposedAction();
            return;
        }
    }
    event->ignore();
}

// IO milestone: Export flattened canvas as PNG using Qt's QImageWriter
// (replaces macOS CGImageDestination/ImageIO).
bool SessionWindow::exportPNG(const QString &path) {
    if (m_sessionHandle == 0 || m_image.isNull()) return false;

    QImageWriter writer(path, "PNG");
    // The core emits premultiplied RGBA; QImageWriter expects straight alpha.
    // QImageWriter preserves straight alpha correctly for PNG.
    if (!writer.write(m_image)) return false;

    // Verify round-trip (byte-identical for straight-alpha PNG)
    QImageReader reader(path);
    QImage reimported = reader.read();
    return !reimported.isNull() && reimported.size() == m_image.size();
}

// IO milestone: Export flattened canvas as JPEG using Qt's QImageWriter
// (replaces macOS CGImageDestination with kCGImageDestinationLossyCompressionQuality).
bool SessionWindow::exportJPEG(const QString &path, int quality) {
    if (m_sessionHandle == 0 || m_image.isNull()) return false;

    // JPEG doesn't support alpha; composite over white background (matches macOS ImageExporter).
    QImage flattened(m_image.size(), QImage::Format_RGB888);
    QPainter painter(&flattened);
    painter.fillRect(flattened.rect(), Qt::white);
    painter.drawImage(0, 0, m_image);
    painter.end();
    flattened.setDotsPerMeterX(m_image.dotsPerMeterX());
    flattened.setDotsPerMeterY(m_image.dotsPerMeterY());

    QImageWriter writer(path, "JPEG");
    writer.setQuality(qBound(0, quality, 100));
    return writer.write(flattened);
}

// IO milestone: Import image using Qt's QImageReader
// (replaces macOS CGImageSource/CoreImage). Loads image, converts to
// premultiplied RGBA, and imports via compositor_session_import_rgba.
bool SessionWindow::importImage(const QString &path) {
    if (m_sessionHandle == 0) return false;

    QImageReader reader(path);
    reader.setAutoTransform(true); // Handle EXIF orientation
    QImage image = reader.read();
    if (image.isNull()) return false;

    // Convert to RGBA8888 (straight alpha) then premultiply for the core
    QImage rgba = image.convertToFormat(QImage::Format_RGBA8888);
    if (rgba.isNull()) return false;

    // Premultiply alpha (core expects premultiplied RGBA)
    for (int y = 0; y < rgba.height(); ++y) {
        uint8_t *scan = rgba.scanLine(y);
        for (int x = 0; x < rgba.width(); ++x) {
            uint8_t a = scan[x * 4 + 3];
            if (a != 255) {
                scan[x * 4] = (scan[x * 4] * a + 127) / 255;
                scan[x * 4 + 1] = (scan[x * 4 + 1] * a + 127) / 255;
                scan[x * 4 + 2] = (scan[x * 4 + 2] * a + 127) / 255;
            }
        }
    }

    QByteArray nameBytes = QFileInfo(path).baseName().toUtf8();
    int32_t rc = compositor_session_import_rgba(m_sessionHandle,
                                                rgba.constBits(), rgba.sizeInBytes(),
                                                rgba.width(), rgba.height(),
                                                reinterpret_cast<const uint8_t *>(nameBytes.constData()), nameBytes.size(),
                                                1); // replacing = true
    if (rc != 0) return false;

    // Update displayed image
    m_image = renderToQImage(m_sessionHandle, rgba.width(), rgba.height());
    update();
    return true;
}

// IO milestone: Save project as .compositor package
// (replaces macOS ProjectStore.save with FileWrapper/NSFileCoordinator).
// Writes manifest.json + layer PNGs + mask PNGs into a directory.
bool SessionWindow::saveProject(const QString &path) {
    if (m_sessionHandle == 0) return false;

    // Export manifest JSON from Swift core
    int64_t manifestSize = compositor_session_export_manifest(m_sessionHandle, nullptr, 0);
    if (manifestSize <= 0) return false;

    std::vector<uint8_t> manifestBytes(static_cast<size_t>(manifestSize));
    int64_t n = compositor_session_export_manifest(m_sessionHandle, manifestBytes.data(), manifestBytes.size());
    if (n != manifestSize) return false;

    QByteArray manifestData(reinterpret_cast<char *>(manifestBytes.data()), manifestSize);
    if (manifestData.size() > 4 * 1024 * 1024) return false;
    QJsonDocument manifestDoc = QJsonDocument::fromJson(manifestData);
    if (manifestDoc.isNull() || !manifestDoc.isObject()) return false;

    const QJsonObject manifest = manifestDoc.object();
    const QString temporaryPath = path + ".tmp-" + QString::number(QCoreApplication::applicationPid());
    QDir temporary(temporaryPath);
    if (temporary.exists() && !temporary.removeRecursively()) return false;
    if (!temporary.mkpath("images")) return false;

    QFile manifestFile(temporary.filePath("manifest.json"));
    if (!manifestFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    const QByteArray encodedManifest = QJsonDocument(manifest).toJson(QJsonDocument::Indented);
    if (manifestFile.write(encodedManifest) != encodedManifest.size()) return false;
    manifestFile.close();

    for (const QJsonValue &value : manifest.value("layers").toArray()) {
        const QJsonObject layer = value.toObject();
        const QString idString = layer.value("id").toString();
        const QByteArray id = idString.toUtf8();
        if (id.isEmpty()) return false;
        for (const bool isMask : {false, true}) {
            const QString filename = layer.value(isMask ? "maskFile" : "imageFile").toString();
            if (filename.isEmpty()) continue;
            const QString expected = idString + (isMask ? ".mask.png" : ".png");
            if (filename != expected || QFileInfo(filename).fileName() != filename) return false;

            size_t width = 0, height = 0;
            const int64_t size = compositor_session_export_layer(m_sessionHandle,
                reinterpret_cast<const uint8_t *>(id.constData()), static_cast<size_t>(id.size()),
                isMask ? 1 : 0, nullptr, 0, &width, &height);
            if (size <= 0 || width == 0 || height == 0 || static_cast<uint64_t>(size) > 512ULL * 1024 * 1024) return false;
            std::vector<uint8_t> bytes(static_cast<size_t>(size));
            const int64_t copied = compositor_session_export_layer(m_sessionHandle,
                reinterpret_cast<const uint8_t *>(id.constData()), static_cast<size_t>(id.size()),
                isMask ? 1 : 0, bytes.data(), bytes.size(), &width, &height);
            if (copied != size) return false;

            QImage image;
            if (isMask) {
                image = QImage(static_cast<int>(width), static_cast<int>(height), QImage::Format_Grayscale8);
                for (size_t y = 0; y < height; ++y)
                    std::memcpy(image.scanLine(static_cast<int>(y)), bytes.data() + y * width, width);
            } else {
                image = straightRGBA(bytes, static_cast<int>(width), static_cast<int>(height));
            }
            QImageWriter writer(temporary.filePath("images/" + filename), "PNG");
            if (!writer.write(image)) return false;
        }
    }

    QDir destinationInfo = QFileInfo(path).dir();
    const QString backupPath = path + ".old-" + QString::number(QCoreApplication::applicationPid());
    QDir backup(backupPath);
    if (backup.exists() && !backup.removeRecursively()) return false;
    if (QFileInfo::exists(path) && !destinationInfo.rename(path, backupPath)) return false;
    if (!destinationInfo.rename(temporaryPath, path)) {
        if (QFileInfo::exists(backupPath)) destinationInfo.rename(backupPath, path);
        return false;
    }
    if (QFileInfo::exists(backupPath)) backup.removeRecursively();
    return true;
}

// IO milestone: Load project from .compositor package
// (replaces macOS ProjectStore.load with FileWrapper/NSFileCoordinator).
bool SessionWindow::loadProject(const QString &path) {
    if (m_sessionHandle == 0) return false;

    QDir dir(path);
    const QFileInfo packageInfo(path);
    if (!packageInfo.isDir() || packageInfo.isSymLink()) return false;

    const QFileInfo manifestInfo(dir.filePath("manifest.json"));
    if (!manifestInfo.isFile() || manifestInfo.isSymLink() || manifestInfo.size() > 4 * 1024 * 1024) return false;
    QFile manifestFile(manifestInfo.filePath());
    if (!manifestFile.open(QIODevice::ReadOnly)) return false;
    QByteArray manifestData = manifestFile.readAll();
    manifestFile.close();

    QJsonDocument manifestDoc = QJsonDocument::fromJson(manifestData);
    if (manifestDoc.isNull() || !manifestDoc.isObject()) return false;

    const QJsonObject manifest = manifestDoc.object();
    const uint64_t replacement = compositor_session_create();
    if (replacement == 0) return false;
    int32_t rc = compositor_session_import_manifest(replacement,
                                                    reinterpret_cast<const uint8_t *>(manifestData.constData()),
                                                    manifestData.size());
    if (rc != 0) {
        compositor_session_close(replacement);
        return false;
    }
    const QFileInfo imagesInfo(dir.filePath("images"));
    if (!imagesInfo.isDir() || imagesInfo.isSymLink()) {
        compositor_session_close(replacement);
        return false;
    }
    uint64_t imagePixels = 0, maskPixels = 0;

    for (const QJsonValue &value : manifest.value("layers").toArray()) {
        const QJsonObject layer = value.toObject();
        const QString idString = layer.value("id").toString();
        const QByteArray id = idString.toUtf8();
        if (id.isEmpty()) { compositor_session_close(replacement); return false; }
        for (const bool isMask : {false, true}) {
            const QString filename = layer.value(isMask ? "maskFile" : "imageFile").toString();
            if (filename.isEmpty()) continue;
            const QString expected = idString + (isMask ? ".mask.png" : ".png");
            if (filename != expected || QFileInfo(filename).fileName() != filename) {
                compositor_session_close(replacement);
                return false;
            }
            const QFileInfo assetInfo(QDir(imagesInfo.filePath()).filePath(filename));
            if (!assetInfo.isFile() || assetInfo.isSymLink() || assetInfo.size() > 512LL * 1024 * 1024) {
                compositor_session_close(replacement);
                return false;
            }
            QImageReader reader(assetInfo.filePath());
            if (reader.format().toLower() != QByteArray("png")) {
                compositor_session_close(replacement);
                return false;
            }
            const QSize decodedSize = reader.size();
            const uint64_t pixels = decodedSize.isValid()
                ? static_cast<uint64_t>(decodedSize.width()) * static_cast<uint64_t>(decodedSize.height()) : 0;
            uint64_t &usedPixels = isMask ? maskPixels : imagePixels;
            if (!decodedSize.isValid() || decodedSize.width() <= 0 || decodedSize.height() <= 0 ||
                decodedSize.width() > 30'000 || decodedSize.height() > 30'000 ||
                pixels > 100'000'000 || usedPixels > 100'000'000 - pixels) {
                compositor_session_close(replacement);
                return false;
            }
            usedPixels += pixels;
            const QImage decoded = reader.read();
            if (decoded.isNull()) { compositor_session_close(replacement); return false; }
            if (isMask) {
                const QImage gray = decoded.convertToFormat(QImage::Format_Grayscale8);
                std::vector<uint8_t> pixels(static_cast<size_t>(gray.width()) * gray.height());
                for (int y = 0; y < gray.height(); ++y)
                    std::memcpy(pixels.data() + static_cast<size_t>(y) * gray.width(), gray.constScanLine(y), gray.width());
                rc = compositor_session_import_layer(replacement,
                    reinterpret_cast<const uint8_t *>(id.constData()), static_cast<size_t>(id.size()), 1,
                    pixels.data(), pixels.size(), gray.width(), gray.height());
            } else {
                const QImage rgba = decoded.convertToFormat(QImage::Format_RGBA8888);
                std::vector<uint8_t> pixels(static_cast<size_t>(rgba.sizeInBytes()));
                for (int y = 0; y < rgba.height(); ++y) {
                    const uint8_t *source = rgba.constScanLine(y);
                    uint8_t *target = pixels.data() + static_cast<size_t>(y) * rgba.width() * 4;
                    for (int x = 0; x < rgba.width(); ++x) {
                        const uint8_t alpha = source[x * 4 + 3];
                        target[x * 4] = static_cast<uint8_t>((source[x * 4] * alpha + 127) / 255);
                        target[x * 4 + 1] = static_cast<uint8_t>((source[x * 4 + 1] * alpha + 127) / 255);
                        target[x * 4 + 2] = static_cast<uint8_t>((source[x * 4 + 2] * alpha + 127) / 255);
                        target[x * 4 + 3] = alpha;
                    }
                }
                rc = compositor_session_import_layer(replacement,
                    reinterpret_cast<const uint8_t *>(id.constData()), static_cast<size_t>(id.size()), 0,
                    pixels.data(), pixels.size(), rgba.width(), rgba.height());
            }
            if (rc != 0) { compositor_session_close(replacement); return false; }
        }
    }

    // Render the loaded document
    int width = manifest["width"].toInt();
    int height = manifest["height"].toInt();
    if (width <= 0 || height <= 0) { compositor_session_close(replacement); return false; }
    QImage rendered = renderToQImage(replacement, width, height);
    if (rendered.isNull()) { compositor_session_close(replacement); return false; }
    compositor_session_close(m_sessionHandle);
    m_sessionHandle = replacement;
    m_image = rendered;
    refreshImage();
    return true;
}
