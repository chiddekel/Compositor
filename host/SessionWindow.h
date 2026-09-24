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
#include <QElapsedTimer>
#include "interfaces/IPlatformServices.h"
#include "ParityMetrics.h"
#include "ParityPalette.h"

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
#include <QVector>
#include <QRectF>

class ITabletHandler;
class SessionCanvasWidget;

class SessionWindow : public QMainWindow {
    Q_OBJECT

public:
    // Platform services are injected (DIP); omitted members fall back to the Qt implementations.
    explicit SessionWindow(QWidget *parent = nullptr, PlatformServices services = {});
    ~SessionWindow() override;

    // Document management
    void initDemoDocument();
    void createNewDocument(int width, int height);
    bool hasDocument() const { return m_hasDocument; }
    // Exposes the Swift session handle so a debug-only caller (host_run.cpp's COMPOSITOR_GRAB_SWIFTUI_TREE path)
    // can render a SwiftUI-compat panel standalone, against this same session, without a second one.
    uint64_t sessionHandle() const { return m_sessionHandle; }

    // File operations (IO milestone)
    bool exportPNG(const QString &path);
    bool exportJPEG(const QString &path, int quality = 85);
    bool exportTIFF(const QString &path);
    bool exportWebP(const QString &path, int quality = 85);
    bool importImage(const QString &path);
    // Upstream's importer (PSD/PSB with layers and text, RAW, HEIC): replace = open as the document, else add layers.
    bool importWithUpstream(const QStringList &paths, bool replace);
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
        Move = 0,    // V (default)
        Marquee,     // M (Rectangle / Ellipse mode)
        Lasso,       // L (Freehand / Polygonal mode)
        Magic,       // W (Wand / Object mode)
        Crop,        // C
        Brush,       // B (Eraser is a mode: E)
        SpotHealing, // J
        CloneStamp,  // S
        Smear,       // R (Liquify / Blur / Smudge mode)
        Gradient,    // G
        Shape,       // U (Rectangle / Ellipse / Line mode)
        Type,        // T
        Eyedropper,  // I
        Hand,        // H (Space temporary hand)
        Zoom,        // Z
        Idle,
        // Compatibility aliases
        Eraser = Brush,
        RectSelect = Marquee,
        EllipseSelect = Marquee,
        MagicWand = Magic,
        Blur = Smear
    };

    enum class MarqueeMode { Rectangle, Ellipse };
    enum class LassoMode { Freehand, Polygonal };
    enum class MagicMode { Wand, Object };
    enum class BrushToolMode { Paint, Erase };
    enum class SmearMode { Liquify, Blur, Smudge };
    enum class SpotHealingMode { ContentAware, CreateTexture, ProximityMatch };
    enum class ShapeMode { Rectangle, Ellipse, Line };

    void setTool(Tool tool);
    Tool currentTool() const { return m_tool; }

    void setMarqueeMode(MarqueeMode mode);
    MarqueeMode marqueeMode() const { return m_marqueeMode; }
    void cycleMarqueeMode();

    void setLassoMode(LassoMode mode);
    LassoMode lassoMode() const { return m_lassoMode; }
    void cycleLassoMode();

    void setMagicMode(MagicMode mode);
    MagicMode magicMode() const { return m_magicMode; }
    void toggleMagicMode();

    void setBrushToolMode(BrushToolMode mode);
    BrushToolMode brushToolMode() const { return m_brushToolMode; }

    void setSmearMode(SmearMode mode);
    SmearMode smearMode() const { return m_smearMode; }

    void setSpotHealingMode(SpotHealingMode mode);
    SpotHealingMode spotHealingMode() const { return m_spotHealingMode; }

    void setShapeMode(ShapeMode mode);
    ShapeMode shapeMode() const { return m_shapeMode; }
    void cycleShapeMode();

    // Pending Crop controls
    void applyCrop();
    void cancelCrop();
    bool hasPendingCrop() const { return m_hasPendingCrop; }
    QRectF pendingCropRect() const { return m_pendingCropRect; }

    // Space-hand controls
    bool isSpaceHandActive() const { return m_spaceHandActive; }

    bool sendCommand(const QJsonObject &command);
    void updateOptionsBar();
    void updateToolRail();
    void updateLayersPanel();

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
    void keyReleaseEvent(QKeyEvent *event) override;

public:
    // Drags the window when the menu bar's or header bar's empty background is clicked-and-dragged — the native
    // window has no title bar (see setWindowFlag(Qt::FramelessWindowHint) in the constructor), so this is the
    // window's only way to move. Installed on menuBar() (empty area only — menu titles still open), on
    // m_headerToolBar and on its "header.dragArea" spacer; child buttons (traffic lights, New, tabs, zoom) keep
    // working normally.
    bool eventFilter(QObject *watched, QEvent *event) override;

    friend class SessionCanvasWidget;
    void canvasPaintEvent(QPaintEvent *event, QWidget *canvas);
    void canvasMousePressEvent(QMouseEvent *event, QWidget *canvas);
    void canvasMouseMoveEvent(QMouseEvent *event, QWidget *canvas);
    void canvasMouseReleaseEvent(QMouseEvent *event, QWidget *canvas);
    bool canvasMouseDoubleClickEvent(QMouseEvent *event, QWidget *canvas);
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
    // The palette is the session's (upstream ColorPalette.swift): these read it back into the Qt views, push a color
    // into it, and present the color picker upstream's UI asked for (EditorSession.colorPicker).
    void syncPaletteFromSession();
    void sendPaletteColor(const QColor &color, bool background);
    void presentSessionColorPicker();
    bool m_presentingColorPicker = false;
    bool m_railFitChecked = false;
    bool m_layersRefreshQueued = false;
    // Gradient / Shape tools: the pending gradient line (x0,y0,x1,y1), which end is being dragged (1 start, 2 end),
    // and the shape draft being dragged (kind, box, line ends) — all in document pixels, read back from the session.
    QVector<double> m_gradientLine;
    int m_gradientHandle = 0;
    QRectF m_shapeRect;
    QString m_shapeKind;
    QVector<double> m_shapeLine;
    // Type tool: the inline editor over the session's text draft, the draft it shows, and a text box being dragged.
    class QPlainTextEdit *m_textEditor = nullptr;
    QJsonObject m_textDraft;
    bool m_syncingText = false;
    QPointF m_textBoxAnchor;
    QRectF m_textBoxRect;
    int64_t m_shownRenderRevision = -1;   // compositor_session_render_revision of m_image
    uint64_t m_shownRenderHandle = 0;   // refreshImage queues one refreshLayers per event-loop turn   // the opening-size fit to the tool rail runs once
    void showSizeDialog(bool imageSize);
    void showFilterDialog(const QString &kind);
    void showAdjustDialog(const QString &kind);
    QPointF documentPoint(const QPointF &windowPoint) const;
    void refreshImage();
    // Coalesces mid-stroke redraws to one render per frame; see scheduleStrokeRefresh() in SessionWindow.cpp.
    void scheduleStrokeRefresh();
    bool isBrushStrokeActive() const;
    void retireRenderedPanel(QWidget *panel);
    void syncCanvasDrafts();
    void presentSwiftUISheet(const QString &panel);
    bool sendCommandQuiet(const QJsonObject &command);   // no status-bar error (probing, e.g. "text here?")
    void syncTextEditor();
    void layoutTextEditor();
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
    void syncToolFromSession();
    void syncOptionsFromSession();
    void updateStatusTelemetry();
    void fitCanvas();
    void actualPixels();
    void zoomBy(double factor);

    // Document tabs: each open document owns its own Swift session handle. m_sessionHandle always mirrors
    // m_documents[m_activeDocumentIndex].handle — the rest of this class keeps addressing m_sessionHandle
    // unchanged, and tab switching just repoints it and refreshes the UI from the newly active document.
    struct DocumentTab {
        uint64_t handle = 0;
        QString title;
        QString filePath;
        double zoomLevel = 0.0;
        QPointF panOffset{0, 0};
    };
    void addDocumentTab(uint64_t handle, const QString &title, const QString &filePath = QString());
    void switchToDocumentTab(int index);
    void closeDocumentTab(int index);
    // Upstream ProjectController.confirmReplacement: "Save changes to …?" Save / Cancel / Don't Save for the tab at
    // index (made current first, as upstream does). True when closing may proceed.
    bool confirmDocumentClose(int index);
    // Saves the current tab to its known .comp path, or asks for one (always, when forceChoosePath). True on success.
    bool saveCurrentDocument(bool forceChoosePath);
    bool isDocumentModified(uint64_t handle) const;

    QWidget *m_canvasWidget = nullptr;
    QImage m_image;
    uint64_t m_sessionHandle = 0;
    std::vector<DocumentTab> m_documents;
    int m_activeDocumentIndex = -1;
    bool m_painting = false;
    Tool m_tool = Tool::Move;
    MarqueeMode m_marqueeMode = MarqueeMode::Rectangle;
    LassoMode m_lassoMode = LassoMode::Freehand;
    MagicMode m_magicMode = MagicMode::Wand;
    BrushToolMode m_brushToolMode = BrushToolMode::Paint;
    SmearMode m_smearMode = SmearMode::Liquify;
    SpotHealingMode m_spotHealingMode = SpotHealingMode::ContentAware;
    ShapeMode m_shapeMode = ShapeMode::Rectangle;
    QRectF m_pendingCropRect;
    bool m_hasPendingCrop = false;
    QString m_cropRatio = "Free";
    Tool m_preSpaceTool = Tool::Move;
    bool m_spaceHandActive = false;
    QPointF m_panOffset{0, 0};
    bool m_hasDocument = false;

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
    QColor m_brushColor = ParityPalette::defaultForeground();
    QColor m_backgroundColor = ParityPalette::defaultBackground();
    QPushButton *m_bgColorButton = nullptr;
    QPushButton *m_fgPaletteButton = nullptr;   // the Qt fallback rail's foreground swatch (m_brushColorButton is the options bar's)
    int m_brushDiameter = 16;
    int m_brushHardness = 100;
    int m_brushOpacity = 100;
    bool m_syncingLayers = false;
    QMap<Tool, QAction *> m_toolActions;
    std::unique_ptr<ITabletHandler> m_tabletHandler;
    QTimer *m_autosaveTimer = nullptr;
    QTimer *m_mainPumpTimer = nullptr;   // drains Swift's main queue under Qt (see constructor)
    QByteArray m_pumpedState;
    QTimer *m_strokeRefreshTimer = nullptr;
    QElapsedTimer m_strokeFrameClock;            // when the last stroke frame started (frame pacing)
    std::vector<uint8_t> m_strokeRegionBuffer;   // reused between stroke frames: no per-frame allocation
    QToolBar *m_headerToolBar = nullptr;
    QToolBar *m_optionsToolBar = nullptr;
    QToolBar *m_toolsBar = nullptr;
    QAction *m_paletteAction = nullptr;
    QDockWidget *m_layersDock = nullptr;
    QDockWidget *m_adjustmentsDock = nullptr;
    QStackedWidget *m_optionsStack = nullptr;
    QAction *m_optionsStackAction = nullptr;
    QAction *m_swiftUIOptionsAction = nullptr;
    QWidget *m_swiftUIOptionsContainer = nullptr;
    QWidget *m_swiftUICurrentToolHeader = nullptr;
    QWidget *m_swiftUIToolRailContainer = nullptr;
    QWidget *m_swiftUICurrentToolRail = nullptr;
    QWidget *m_legacyLayersPanel = nullptr;
    QStackedWidget *m_layersStack = nullptr;
    QWidget *m_swiftUILayersContainer = nullptr;
    QWidget *m_swiftUICurrentLayersPanel = nullptr;
    QWidget *m_swiftUIStatusBarContainer = nullptr;
    QWidget *m_swiftUICurrentStatusBar = nullptr;
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

    // Tool parameter state
    int m_magicTolerance = 32;
    bool m_magicContiguous = true;
    bool m_magicSampleAll = false;
    bool m_cloneAligned = true;
    bool m_cloneSampleAll = false;
    QString m_gradientType = "Linear";
    int m_gradientOpacity = 100;
    bool m_gradientReverse = false;
    int m_shapeStrokeWidth = 1;
    int m_shapeRadius = 0;
    int m_typeFontSize = 24;
    QString m_typeFontFamily;
    int m_typeAlignment = 0;
    int m_eyedropperSampleSize = 1;
    bool m_eyedropperSampleAll = false;
    int m_cropHandle = -1;
    QPointF m_panStart;

    int hitTestCropHandle(const QPointF &canvasPoint) const;
    void drawCropOverlay(QPainter &painter) const;
};
