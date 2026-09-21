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
class QAction;
class QStackedWidget;
class QTabBar;
class QLabel;
class QToolBar;
#include <vector>
#include <memory>
#include <QMap>

class ITabletHandler;
class SessionCanvasWidget;

class SessionWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit SessionWindow(QWidget *parent = nullptr);
    ~SessionWindow() override;

    // File operations (IO milestone)
    bool exportPNG(const QString &path);
    bool exportJPEG(const QString &path, int quality = 85);
    bool exportTIFF(const QString &path);
    bool exportWebP(const QString &path, int quality = 85);
    bool importImage(const QString &path);
    bool saveProject(const QString &path);
    bool loadProject(const QString &path);

    // Command Palette (Ctrl+Shift+P / F1)
    void showCommandPalette();

    // Layer Multi-Selection (R22)
    void deleteSelectedLayers();

    // Crash-Recovery Autosave (R61)
    bool performAutosave();
    bool hasAutosaveRecovery() const;
    bool recoverAutosave();
    void clearAutosave();
    QString autosaveDirectory() const;

    // Snapshot of the Swift editor core's state JSON (test hook: reads the same
    // bytes the dock renders, through the real C ABI).
    QJsonObject sessionState() const;

    // Paint a stroke from the current palette (diameter/hardness/opacity/color)
    // through brushBegin/brushMove/brushEnd. Public so smokes can drive the
    // same code path the mouse handlers use.
    void paintStroke(double x1, double y1, double x2, double y2);

    enum class Tool {
        Brush,
        Eraser,
        Move,
        RectSelect,
        EllipseSelect,
        Lasso,
        MagicWand,
        CloneStamp,
        SpotHealing,
        Crop
    };

    void setTool(Tool tool);
    Tool currentTool() const { return m_tool; }

protected:
    void paintEvent(QPaintEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void tabletEvent(QTabletEvent *event) override;
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dropEvent(QDropEvent *event) override;
    void closeEvent(QCloseEvent *event) override;

    friend class SessionCanvasWidget;
    void canvasPaintEvent(QPaintEvent *event, QWidget *canvas);
    void canvasMousePressEvent(QMouseEvent *event, QWidget *canvas);
    void canvasMouseMoveEvent(QMouseEvent *event, QWidget *canvas);
    void canvasMouseReleaseEvent(QMouseEvent *event, QWidget *canvas);
    void canvasTabletEvent(QTabletEvent *event, QWidget *canvas);
    void canvasDragEnterEvent(QDragEnterEvent *event, QWidget *canvas);
    void canvasDropEvent(QDropEvent *event, QWidget *canvas);
    QRectF canvasTargetRect() const;
    QPointF documentToCanvasPoint(const QPointF &docPoint) const;

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
    void applyDarkTheme();
    void setupHeaderBar();
    void setupOptionsBar();
    void updateOptionsBar();
    void updateStatusTelemetry();
    void fitCanvas();
    void actualPixels();
    void zoomBy(double factor);

    QWidget *m_canvasWidget = nullptr;
    QImage m_image;
    uint64_t m_sessionHandle = 0;
    bool m_painting = false;
    Tool m_tool = Tool::Brush;
    QPointF m_dragStart;
    QPointF m_currentPoint;
    std::vector<QPointF> m_lassoPoints;
    QPointF m_cloneSource = QPointF(0, 0);
    bool m_hasCloneSource = false;
    QString m_brushMode = "Paint";
    QTreeView *m_layersView = nullptr;
    QStandardItemModel *m_layerModel = nullptr;
    QSlider *m_opacity = nullptr;
    QLabel *m_opacityLabel = nullptr;
    QLabel *m_layerCountLabel = nullptr;
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
    QMap<Tool, QAction *> m_toolActions;
    std::unique_ptr<ITabletHandler> m_tabletHandler;
    QTimer *m_autosaveTimer = nullptr;
    QToolBar *m_headerToolBar = nullptr;
    QToolBar *m_optionsToolBar = nullptr;
    QStackedWidget *m_optionsStack = nullptr;
    QTabBar *m_documentTabBar = nullptr;
    QLabel *m_statusZoomLabel = nullptr;
    QLabel *m_statusDimsLabel = nullptr;
    QLabel *m_statusProfileLabel = nullptr;
    QLabel *m_statusHintsLabel = nullptr;
    double m_zoomLevel = 0.0;
};
