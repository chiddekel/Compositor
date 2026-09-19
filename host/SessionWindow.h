#pragma once

// SessionWindow — a moc'd Qt window that drives the Swift editor core through the
// compositor_session_* C ABI, built by SwiftPM (with a committed moc output) and
// linked into the Swift `@main` composition root.
//
// This is distinct from MainWindow (the C++-main, C-kernels Qt shell): MainWindow
// is the "Rewrite Linux UI" workspace shell exercising the portable C kernels
// directly (no Swift), built via CMake for the C++-only build path. SessionWindow
// proves the architecture the Flatpak build ships — a moc'd Q_OBJECT Qt window
// created from compositor_host_run (the Swift-@main Qt entry) that calls back into
// the Swift core and paints the composited RGBA via QImage. As the Qt UI tier
// grows, MainWindow's shell will be rewired to drive compositor_session_* through
// this same link.
//
// Private C++ header in host/ (NOT host/include/, the Swift-importable C module),
// found via same-directory include.

#include <QMainWindow>
#include <QImage>
#include <QString>
#include <QPointF>
#include <QJsonObject>

class QListWidget;
class QListWidgetItem;
class QSlider;
#include <vector>

class SessionWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit SessionWindow(QWidget *parent = nullptr);
    ~SessionWindow() override;

    // File operations (IO milestone)
    bool exportPNG(const QString &path);
    bool exportJPEG(const QString &path, int quality = 85);
    bool importImage(const QString &path);
    bool saveProject(const QString &path);
    bool loadProject(const QString &path);

protected:
    void paintEvent(QPaintEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dropEvent(QDropEvent *event) override;

private:
    void showSizeDialog(bool imageSize);
    void showFilterDialog(const QString &kind);
    QJsonObject sessionState() const;
    bool sendCommand(QJsonObject command);
    QPointF documentPoint(const QPointF &windowPoint) const;
    void refreshImage();
    void refreshLayers();
    void selectLayerRow(int row);
    void setOpacityFromSlider(int value);
    QImage m_image;
    uint64_t m_sessionHandle = 0;
    bool m_painting = false;
    QString m_brushMode = "Paint";
    QListWidget *m_layers = nullptr;
    QSlider *m_opacity = nullptr;
    bool m_syncingLayers = false;
};
