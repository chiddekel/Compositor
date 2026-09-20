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
#include <QStringList>
#include <QPointF>
#include <QJsonObject>

class QTreeView;
class QStandardItemModel;
class QStandardItem;
class QSlider;
class QComboBox;
class QPushButton;
class QCheckBox;
class QMenu;
class QColor;
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

    // Snapshot of the Swift editor core's state JSON (test hook: reads the same
    // bytes the dock renders, through the real C ABI).
    QJsonObject sessionState() const;

    // Paint a stroke from the current palette (diameter/hardness/opacity/color)
    // through brushBegin/brushMove/brushEnd. Public so smokes can drive the
    // same code path the mouse handlers use.
    void paintStroke(double x1, double y1, double x2, double y2);

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
    void showAdjustDialog(const QString &kind);
    bool sendCommand(const QJsonObject &command);
    QPointF documentPoint(const QPointF &windowPoint) const;
    void refreshImage();
    void refreshLayers();
    void selectLayerRow(int row);
    void setOpacityFromSlider(int value);
    void setBrushDiameter(int value);
    void setBrushHardness(int value);
    void setBrushOpacity(int value);
    void setBrushColor(const QColor &color);
    void setBlendModeFromCombo(int index);
    void pickBrushColor();
    QStringList blendModes() const;
    bool setLayerFlag(const char *action, bool on);
    void selectRegion(bool rectangle);
    QImage m_image;
    uint64_t m_sessionHandle = 0;
    bool m_painting = false;
    QString m_brushMode = "Paint";
    QTreeView *m_layersView = nullptr;
    QStandardItemModel *m_layerModel = nullptr;
    QSlider *m_opacity = nullptr;
    QComboBox *m_blend = nullptr;
    QPushButton *m_brushColorButton = nullptr;
    QSlider *m_brushDiameterSlider = nullptr;
    QSlider *m_brushHardnessSlider = nullptr;
    QSlider *m_brushOpacitySlider = nullptr;
    QCheckBox *m_visibleCheck = nullptr;
    QCheckBox *m_maskCheck = nullptr;
    QColor m_brushColor = QColor(255, 0, 0);
    int m_brushDiameter = 16;
    int m_brushHardness = 100;
    int m_brushOpacity = 100;
    bool m_syncingLayers = false;
};
