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
#include <functional>
#include <QImage>
#include <QString>
#include <QStringList>
#include <QPointF>
#include <QJsonObject>
#include "interfaces/IPlatformServices.h"

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
class QSpinBox;
class QPainter;
class QKeyEvent;
#include <vector>
#include <memory>
#include <QMap>

class ITabletHandler;
class SessionCanvasWidget;

class SessionWindow : public QMainWindow {
    Q_OBJECT

public:
    // Platform services are injected (DIP); omitted members fall back to the Qt implementations.
    explicit SessionWindow(QWidget *parent = nullptr, PlatformServices services = {});
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
    // Same commands the CloneStamp/SpotHealing branches of mousePressEvent send; factored out so smoke tests exercise
    // the exact wire protocol without simulating screen-space mouse events.
    void setCloneSource(double x, double y);
    void cloneStroke(double x1, double y1, double x2, double y2);
    void healStroke(double x1, double y1, double x2, double y2);

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
        Crop,
        Blur,
        Gradient,
        Shape,
        Type,
        Eyedropper,
        Hand,
        Zoom
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
    void keyPressEvent(QKeyEvent *event) override;

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
    void createMenus();
    void refreshMenuTitles(const QJsonObject &state);
    void swapPaletteColors();
    void resetPaletteColors();
    void setBackgroundColor(const QColor &color);
    void pickBackgroundColor();
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
    // The source's own point/offset live server-side (EditorSession.cloneSource/cloneOffset); this only tracks
    // whether one has been set, so a stroke before an Option-click is refused with a message instead of a silent no-op.
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
    QColor m_backgroundColor = QColor(255, 255, 255);
    QPushButton *m_bgColorButton = nullptr;
    int m_brushDiameter = 16;
    int m_brushHardness = 100;
    int m_brushOpacity = 100;
    bool m_syncingLayers = false;
    QMap<Tool, QAction *> m_toolActions;
    std::unique_ptr<ITabletHandler> m_tabletHandler;
    QTimer *m_autosaveTimer = nullptr;
    QToolBar *m_headerToolBar = nullptr;
    QToolBar *m_optionsToolBar = nullptr;
    QToolBar *m_toolsBar = nullptr;
    QDockWidget *m_layersDock = nullptr;
    QDockWidget *m_adjustmentsDock = nullptr;
    QStackedWidget *m_optionsStack = nullptr;
    QTabBar *m_documentTabBar = nullptr;
    QLabel *m_statusZoomLabel = nullptr;
    QLabel *m_statusDimsLabel = nullptr;
    QLabel *m_statusProfileLabel = nullptr;
    QLabel *m_statusHintsLabel = nullptr;
    double m_zoomLevel = 0.0;
    PlatformServices m_platform;

    // Dynamic menu action pointers for macOS parity
    QAction *m_actUndo = nullptr;
    QAction *m_actRedo = nullptr;
    QAction *m_actCut = nullptr;
    QAction *m_actCopy = nullptr;
    QAction *m_actCopyMerged = nullptr;
    QAction *m_actPaste = nullptr;
    QAction *m_actFillFG = nullptr;
    QAction *m_actFillBG = nullptr;
    QAction *m_actClearSelection = nullptr;
    QAction *m_actContentAwareFill = nullptr;
    QAction *m_actSelectAll = nullptr;
    QAction *m_actDeselect = nullptr;
    QAction *m_actInverse = nullptr;
    QAction *m_actLayerPixels = nullptr;
    QAction *m_actSelectSubject = nullptr;
    QAction *m_actMaskBlackAreas = nullptr;
    QAction *m_actExpandSelection = nullptr;
    QAction *m_actContractSelection = nullptr;
    QAction *m_actFeatherSelection = nullptr;
    QAction *m_actInvert = nullptr;
    QAction *m_actTransform = nullptr;
    QAction *m_actDuplicate = nullptr;
    QAction *m_actClippingMask = nullptr;
    QAction *m_actGroupLayers = nullptr;
    QAction *m_actMoveOutOfFolder = nullptr;
    QAction *m_actNewBlankLayer = nullptr;
    QAction *m_actRenameLayer = nullptr;
    QAction *m_actShowHideLayer = nullptr;
    QAction *m_actMoveLayerUp = nullptr;
    QAction *m_actMoveLayerDown = nullptr;
    QAction *m_actMerge = nullptr;
    QAction *m_actFlipLayerH = nullptr;
    QAction *m_actFlipLayerV = nullptr;
    QAction *m_actDelete = nullptr;

    // One-shot canvas pixel request (Levels eyedroppers): receives the document point of the next click.
    std::function<void(const QPointF &)> m_pixelSampler;

    // Move / Transform tool state. Geometry is in document pixels; rotation in degrees.
public:
    struct LayerGeometry {
        QString id;
        double x = 0, y = 0, w = 0, h = 0, rotation = 0;
        bool valid = false, isGroup = false, visible = true;
    };
private:
    LayerGeometry m_activeGeometry;
    std::vector<LayerGeometry> m_layerGeometries;  // document order, bottom first
    QSpinBox *m_xSpin = nullptr;
    QSpinBox *m_ySpin = nullptr;
    QSpinBox *m_wSpin = nullptr;
    QSpinBox *m_hSpin = nullptr;
    QSpinBox *m_angleSpin = nullptr;
    QCheckBox *m_linkCheck = nullptr;
    QCheckBox *m_autoSelectCheck = nullptr;
    QCheckBox *m_showControlsCheck = nullptr;
    int m_transformHandle = -1;  // -1 none, 0-7 resize (TL,T,TR,R,BR,B,BL,L), 8 rotate, 9 move body
    LayerGeometry m_transformStart;
    LayerGeometry m_transformDraft;
    // Selection tools: combine mode (New/Add/Subtract) and lasso style.
    QString m_selectionMode = "New";
    bool m_polygonalLasso = false;
    bool m_polyActive = false;
    qint64 m_lastPolyClick = 0;
    void commitLassoSelection();
    void syncTransformFields();
    void applyTransformFields(int changedField);
    int hitTestTransformHandle(const QPointF &canvasPoint) const;
    void drawTransformControls(QPainter &painter) const;
    void previewGeometry(const LayerGeometry &geometry);
    LayerGeometry draggedGeometry(const QPointF &documentPoint, Qt::KeyboardModifiers modifiers) const;
};
