// UpstreamEditor.swift — the Linux shell's command adapter over upstream's UNMODIFIED `EditorSession`.
//
// Replaces the forked `Sources/CompositorCore/EditorBridge.swift`, which drove a hand-edited copy of the session. This
// file lives inside the `Compositor` module (via Sources/UpstreamCore/LinuxBridge) only to reach upstream's internal
// types without editing them; it holds no editing logic, every command calls an upstream method.
//
// Threading: the Qt shell calls from the process's main thread while the C++ event loop runs. Synchronous commands run
// with `MainActor.assumeIsolated`; upstream's async operations (fill, invert, commit, render) are awaited by pumping the
// run loop from that same plain callback (`awaitOnMain`), which lets the main-actor task progress. Verified by
// Tests/LinuxOverrideTests (differential tests against the fork's bridge, the behavioural spec being replaced).

import Foundation
import CoreGraphics
import CoreImage
import AppKit

/// Runs `operation` (main-actor, async) to completion from a synchronous call on the main thread.
func awaitOnMain<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async -> Value,
                                   whileWaiting: (@MainActor () -> Void)? = nil) -> Value {
    nonisolated(unsafe) var result: Value?
    Task { @MainActor in result = await operation() }
    while result == nil {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        if result == nil, let whileWaiting { MainActor.assumeIsolated { whileWaiting() } }
    }
    return result!
}

private struct Command: Decodable {
    let version: Int
    let action: String
    var width: Int?
    var height: Int?
    var layerID: UUID?
    var name: String?
    var kind: String?
    var value: Double?
    var enabled: Bool?
    var forward: Bool?
    var horizontally: Bool?
    var x: Double?
    var y: Double?
    var parameters: [String: Double]?
    var points: [[Double]]?
    var adjustment: LayerAdjustment?
    /// "new" only: start with a blank "Layer 1", as upstream's New Canvas sheet asks (`emptyLayer: true`).
    var emptyLayer: Bool?
    /// "importFiles": absolute paths of the files to bring in.
    var paths: [String]?
    var location: Int?
    var length: Int?
    var draftID: UUID?
    var textStyle: LayerTextStyle?

    var newCanvasSize: (width: Int, height: Int)? {
        guard let width, let height, (1...30_000).contains(width), (1...30_000).contains(height) else { return nil }
        return (width, height)
    }

    /// JSON doubles must be representable before dispatch converts them to integer controls.
    var integerArgumentRefusal: String? {
        let argument: (name: String, value: Double?)
        switch action {
        case "featherSelection", "expandSelection", "contractSelection", "setSelectionExpandAmount":
            argument = ("amount", parameters?["amount"])
        case "moveActiveLayer": argument = ("layer offset", value)
        case "magicWand": argument = ("tolerance", parameters?["tolerance"])
        case "distortDragBegin": argument = ("handle", value)
        case "brushBegin":
            guard (parameters?["healing"] ?? 0) != 0 else { return nil }
            argument = ("healing mode", parameters?["healingMode"])
        default: return nil
        }
        guard let value = argument.value else { return nil }
        guard value.isFinite, Int(exactly: value.rounded(.towardZero)) != nil else {
            return "\(argument.name) is outside the supported integer range"
        }
        return nil
    }
}

private struct State: Encodable {
    struct Layer: Encodable {
        let id: UUID
        let name: String
        let visible: Bool
        let opacity: Double
        let blendMode: String
        let parentID: UUID?
        let isGroup: Bool
        let hasMask: Bool
        let maskEnabled: Bool?
        let maskLinked: Bool?
        let maskPlacement: LayerTransform?
        let transform: LayerTransform
    }
    let version = 1
    let width: Int
    let height: Int
    let resolution: Double
    let activeLayerID: UUID?
    let modified: Bool
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String
    let redoName: String
    let busy: Bool
    /// The filter worker or its queued settings are still rendering; distinct from an open filter edit.
    let filterPreviewRendering: Bool
    /// Upstream ProjectWorkspace.canSwitch for this session: dropped or opened files wait while it is false.
    let canSwitch: Bool
    let layers: [Layer]
    let error: String?
    let hasSelection: Bool
    let canTransformSelection: Bool
    let showsTransformControls: Bool
    let transformAutoSelect: Bool
    /// Free Transform / Move handle edit in progress (Ctrl+T persistent or drag-resize).
    let transforming: Bool
    /// Only persistent edits wait for Apply / Cancel; ordinary drags apply on release.
    let transformPending: Bool
    let isMaskSelected: Bool
    /// Option-click mask thumbnail: canvas shows that mask alone (Photoshop).
    let viewsMaskAlone: Bool
    let activeLayerIsVisible: Bool
    let activeLayerIsGroup: Bool
    let activeLayerHasMask: Bool
    let activeLayerHasParent: Bool
    let activeLayerIsClipped: Bool
    let canToggleClippingMask: Bool
    let canUngroupLayers: Bool
    let canMergeLayers: Bool
    let mergeTitle: String
    let brushError: String?
    let canMoveActiveLayerUp: Bool
    let canMoveActiveLayerDown: Bool
    let tool: String
    let selectionMode: String
    let lassoKind: String
    let marqueeKind: String
    /// The palette swatches as shown (a mask selection shows black/white), sRGB 0...1.
    let foregroundColor: [Double]
    let backgroundColor: [Double]
    /// Upstream's brush options (the options bar edits `EditorSession.brushSettings`): diameter in pixels, hardness and
    /// opacity 0...1, smoothing 0...100. The shell's cursor and legacy sliders follow these.
    let brushDiameter: Double
    let brushHardness: Double
    let brushOpacity: Double
    let brushSmoothing: Double
    /// Tip 1.4.2+: Blur mode's own radius (px), apart from Strength (opacity).
    let blurRadius: Double
    /// Smear sub-mode: Liquify / Blur / Smudge (`BlurToolMode.rawValue`).
    let blurMode: String
    /// The upstream color picker the UI asked for (`EditorSession.colorPicker`), for the shell to present.
    let colorPickerTitle: String?
    let colorPickerColor: [Double]?
    /// A pending gradient's line (start x, y, end x, y) in document pixels, adjustable until Enter/Esc.
    let gradientLine: [Double]?
    /// The shape being dragged: its kind, box (x, y, width, height) and, for a line, its two ends.
    let shapeKind: String?
    let shapeRect: [Double]?
    let shapeLine: [Double]?
    /// A pending crop's rect (x, y, width, height) in document pixels, as upstream `cropRect`.
    let cropRect: [Double]?
    /// The text being typed (upstream `textDraft`): where it sits and how it looks, for the shell's inline editor.
    let colorRange: ColorRangeState?
    struct ColorRangeState: Encodable {
        let working: Bool
        let generation: Int
        let hasColors: Bool
        let sampleMode: String
        let error: String?
    }
    let textDraft: TextDraftState?
    /// Upstream's RAW Develop sheet is up (the shell's dialog closes when this turns false).
    let rawDevelopOpen: Bool
    /// Upstream's Photoshop conversion sheet is up (reading the file, or waiting for Import / Cancel).
    let conversionSheetOpen: Bool
    /// Upstream's floating panels that should be showing (FloatingPanels.swift), in the order ContentView opens them.
    let floatingPanels: [FloatingPanels.Open]
    /// Upstream's `.fileImporter` is up (`session.showsImporter`, e.g. the welcome's Import image): the shell shows its file
    /// chooser, imports what was picked with upstream's importer, and answers with dismissImporter.
    let showsImporter: Bool
    /// The welcome's Open project was pressed (upstream calls `projects.open()`): the shell shows its project chooser.
    let openProjectRequested: Bool
    /// Canvas chrome as EditorCanvas / TransformOverlay draw it: rulers, the layout grid, guides (with a drag in
    /// progress), the lines a snapped move lines up with.
    let showsRulers: Bool
    let showsGrid: Bool
    /// View > Pixel Grid (800% and above): EditorCanvas.drawPixelGrid.
    let showsPixelGrid: Bool
    /// View › CMYK › Proof Colors / Gamut Warning: what the canvas display is proofed through (proofForDisplay).
    let proofsColors: Bool
    let showsGamutWarning: Bool
    /// The proofing profile's name, which the canvas pills show (upstream ProofBadge: `proofProfile?.name ?? ""`).
    let proofProfileName: String
    let showsGuides: Bool
    let guides: [GuideState]
    let guideDragging: Bool
    let canEditGuides: Bool
    let snapLines: [[Double]]
    struct GuideState: Encodable { let vertical: Bool; let position: Double }
    /// Upstream's modal sheets that are open (RawDevelopSheet, PSDConversionSheet, TrimSheet): the shell shows each.
    let sheets: [String]
    /// After Export As accepts: format name (PNG/JPEG/PDF) while `writeExport` still has bytes to write.
    let exportFormat: String?
    /// View › Toggle Fullscreen / Canvas Only (F).
    let canvasOnly: Bool
    let canToggleCanvasOnly: Bool
    let escapeHasNothingToCancel: Bool
    /// Canvas zoom (1 = 100%), for Navigator ≥300% and shell chrome.
    let zoom: Double
    /// An alert upstream's ContentView would be showing ("Couldn’t paint" / "Couldn’t crop"): `kind` for dismissAlert.
    let alert: AlertState?
    /// A pending distortion's corners (document px: top-left, top-right, bottom-right, bottom-left), for the shell's handles.
    let distortCorners: [[Double]]?
    /// Every keyboard shortcut upstream defines (ShortcutDefinition.all) with the chord it is set to now (ShortcutSettings:
    /// the editor's saved choices) and its original: the shell applies them to its menus and canvas keys.
    let shortcuts: [ShortcutState]
    struct ShortcutState: Encodable, Equatable { let title: String; let group: String; let key: String; let modifiers: Int; let originalKey: String; let originalModifiers: Int }
    struct AlertState: Encodable { let kind: String; let title: String; let message: String }
    struct TextDraftState: Encodable {
        let id: UUID
        let selectionLocation: Int
        let selectionLength: Int
        let colorRuns: [LayerTextColorRun]?
        let fontRuns: [LayerTextFontRun]?
        let tracking: Double
        let leading: Double
        let origin: [Double]
        let size: [Double]?
        let rotation: Double
        let content: String
        let fontName: String
        let fontSize: Double
        let color: [Double]
        let alignment: String
        let boxSize: [Double]?
        let padding: Double
        let editingLayer: Bool
    }
}

private func rgb(_ color: PaletteColor) -> [Double] { [Double(color.red), Double(color.green), Double(color.blue)] }

/// Result codes shared with the C ABI: 0 ok, -1 invalid argument, -2 no document, -3 busy, -4 unsupported version,
/// -5 operation failed, -6 unknown handle, -7 command not supported by this bridge yet.
final class UpstreamEditor {
    let session: EditorSession
    private lazy var standaloneProjects = ProjectController(session: session)
    var nativeProjects: ProjectController {
        Workspace.shared.tabs.first(where: { $0.session === session })?.controller ?? standaloneProjects
    }
    /// Replacement imports keep the current document/history intact until every file succeeds.
    private(set) var replacementImportSession: EditorSession?
    var importSession: EditorSession { replacementImportSession ?? session }
    /// Distinguishes reloading the same document ID from editing that document.
    var persistenceGeneration = UUID()
    private(set) var error: String?

    /// `session` defaults to a fresh one; SessionABI's workspace-backed handles inject the `EditorSession` that
    /// belongs to a `ProjectTab`, so a Linux document tab and an upstream `ProjectWorkspace` tab share one session
    /// instead of the C ABI keeping a second, independent copy of "which documents are open".
    init(session: EditorSession = EditorSession()) {
        self.session = session
    }

    /// Commands this adapter can run today; the rest report -7 so callers (and the parity tests) see the gap explicitly.
    static let supportedActions: Set<String> = [
        "markSaved", "markUnsaved", "new", "addLayer", "addGroup", "groupSelectedLayers", "ungroupLayers", "selectLayer", "deleteLayer", "renameLayer", "setVisible",
        "setOpacity", "setBlendMode", "setSelectedOpacity", "cycleBlendMode", "flipLayer", "flipCanvas", "undo", "redo",
        "addRevealMask", "addHideMask", "toggleMaskAlone", "clearMaskAlone", "stopProofing", "hideGamutWarning", "deleteMask", "setMaskEnabled", "setMaskLinked", "moveLayer",
        "selectAll", "deselect", "invertSelection", "loadLayerSelection", "loadMaskSelection", "selectSubject", "featherSelection",
        "setSelectionExpandAmount", "setSelectionMode",
        "colorRangeBegin", "colorRangeSample", "colorRangeUpdate", "colorRangeCommit", "colorRangeCancel",
        "selectRectangle", "selectEllipse", "selectLasso", "expandSelection", "contractSelection",
        "fillForeground", "fillBackground", "clearSelection", "invert", "copy", "copyMerged", "cut", "paste",
        "duplicateLayer", "layerViaCopy", "toggleClippingMask", "moveActiveLayer", "moveActiveLayerOutOfGroup", "mergeLayers",
        "brushBegin", "setBrushSettings", "setGradientSettings", "brushMove", "brushEnd", "brushCancel", "cloneSetSource", "magicWand",
        "filterBegin", "filterPreview", "filterCommit", "filterCancel", "filterSetPreview",
        "setMaskSelected", "invertMask", "transform", "transformCommand", "transformBegin", "transformPreview", "transformCommit", "transformCommitFinal", "transformCancel",
        "setShowsTransformControls", "setTransformAutoSelect", "setCanvasOnly",
        "distortBegin", "distortCommit", "addShape", "warpBegin", "warpMove", "warpEnd", "warpCancel",
        "resizeCanvas", "cropCanvas", "resizeImage", "addAdjustment", "adjustmentBegin", "adjustmentPreview",
        "adjustmentCommit", "adjustmentCancel", "contentFill", "removeBackground", "smartMatte", "selectTool",
        "swapPaletteColors", "resetPaletteColors", "setPaletteColor", "openColorPicker", "setColorPickerColor",
        "closeColorPicker", "closeFloatingPanel", "addLayerEffect", "openFilter", "beginLevels", "beginHueSaturation",
        "beginAdjustmentEditing", "trim", "canvasSizeSheet", "imageSizeSheet", "gridSettingsSheet", "exportPNG", "exportPDF", "exportAsSheet", "writeExport", "sampleColorPicker", "dismissAlert", "dismissImporter", "guideCreate", "guideHit", "guideMove", "guideFinish", "guideCancel", "showKeyboardShortcuts", "distortDragBegin", "distortDragMove", "distortDragEnd", "importFiles",
        "gradientBegin", "gradientMove", "gradientEndDrag", "gradientCommit", "gradientCancel",
        "shapeBegin", "shapeDrag", "shapeFinish", "shapeCancel",
        "textEditAt", "textBegin", "textBeginBox", "textSetContent", "textReplace", "textRestore", "textSelect", "textFinish", "textCancel",
    ]

    /// The adjustment as it was when editing began, for cancel.
    private var adjustmentOriginal: (id: UUID, value: LayerAdjustment)?
    /// The adjustment layer the shell's dialog is editing.
    private var adjustmentEditing: UUID?
    /// Upstream's Trim sheet while Image > Trim… waits for its answer (resolved as panel "TrimSheet"; its @State lives here).
    private(set) var trimSheet: TrimSheet?
    /// Upstream's Canvas Size / Image Size sheets while Image > Canvas Size… / Image Size… waits for their answer.
    private(set) var canvasSizeSheet: CanvasSizeSheet?
    private(set) var imageSizeSheet: ImageSizeSheet?
    /// Tip File › Export As… sheet while the shell waits for PNG/JPEG/PDF bytes.
    private(set) var exportAsSheet: ExportAsSheet?
    /// View > Grid Settings…: values as they were when the sheet opened (Cancel puts them back).
    private(set) var gridSettingsBackup: (grid: LayoutGrid, appearance: GridAppearance, shown: Bool)?
    /// Resumes `gridSettingsSheet` when the shell's modal closes (OK or Cancel).
    private var gridSettingsAnswer: (() -> Void)?
    private var sizeAnswer: ((Any?) -> Void)?
    private var pendingExport: (data: Data, format: ExportFormat)?
    /// Format Export As last used (same idea as tip ProjectController.lastExportFormat).
    private var lastExportFormat: ExportFormat = .png
    private var trimAnswer: ((TrimOptions?) -> Void)?
    /// The filter in progress was opened the upstream way ("openFilter"), so its FilterSheet floats beside the canvas;
    /// the shell's own filter dialogs ("filterBegin") drive filterEdit without it.
    var filterInShellDialog = false
    /// The documentless welcome (NewCanvasSheet) asked to open a project; the shell answers with dismissImporter.
    var openProjectRequested = false
    /// A Move-tool handle drag that distorts (Ctrl held, or the layer already distorted): upstream's own TransformDrag.
    private var distortDrag: TransformDrag?

    /// ProjectController.begin(): a project operation starts only when the session can take one; it then cancels a
    /// crop, commits a transform and holds the project busy until the caller's sheet or write ends (`isProjectBusy`
    /// disables Undo/Redo, layer edits and other project commands meanwhile, as upstream's menus show).
    private func beginProjectOperation() -> Bool {
        let s = session
        guard s.canStartProjectOperation else { return false }
        s.cancelCrop()
        s.commitTransform()
        s.isProjectBusy = true
        return true
    }
    /// Export As holds the project from its sheet until the shell's save panel answers with `writeExport`.
    private var exportHoldsProject = false

    /// Answers the open Canvas Size / Image Size sheet (nil = Cancel).
    func finishSizeSheet(_ options: Any?) {
        let answer = sizeAnswer
        sizeAnswer = nil
        canvasSizeSheet = nil
        imageSizeSheet = nil
        answer?(options)
    }


    /// Answers the open Export As sheet (nil = Cancel).
    func finishExportAsSheet(_ chosen: (data: Data, format: ExportFormat)?) {
        let answer = sizeAnswer
        sizeAnswer = nil
        exportAsSheet = nil
        answer?(chosen)
    }

    /// Answers the open Trim sheet (nil = Cancel), e.g. when the shell's dialog is closed.
    func finishTrim(_ options: TrimOptions?) {
        let answer = trimAnswer
        trimAnswer = nil
        trimSheet = nil
        answer?(options)
    }

    /// Ends View > Grid Settings…: `settings` nil restores the backup (Cancel); otherwise keeps the previewed values.
    func finishGridSettings(_ settings: (LayoutGrid, GridAppearance)?) {
        guard let backup = gridSettingsBackup else { return }
        session.showsGrid = backup.shown
        if let settings {
            session.layoutGrid = settings.0
            session.gridAppearance = settings.1
        } else {
            session.layoutGrid = backup.grid
            session.gridAppearance = backup.appearance
        }
        gridSettingsBackup = nil
        let answer = gridSettingsAnswer
        gridSettingsAnswer = nil
        answer?()
    }

    /// Modal upstream sheets open now, by panel name (the shell shows each while it is listed).
    var openSheets: [String] {
        var sheets: [String] = []
        if importSession.showsRawDevelop { sheets.append("RawDevelopSheet") }
        if importSession.showsConversionSheet { sheets.append("PSDConversionSheet") }
        if trimSheet != nil { sheets.append("TrimSheet") }
        if canvasSizeSheet != nil { sheets.append("CanvasSizeSheet") }
        if imageSizeSheet != nil { sheets.append("ImageSizeSheet") }
        if exportAsSheet != nil { sheets.append("ExportAsSheet") }
        if gridSettingsBackup != nil { sheets.append("GridSettingsSheet") }
        return sheets
    }
    /// The manifest of a project being loaded; its layers' images and masks arrive through `installLayerAsset`.
    private var loadingManifest: ProjectManifest?
    private var pendingLayerImages: Set<UUID> = []
    private var pendingLayerMasks: Set<UUID> = []
    private var loadingRevision: UUID?

    /// Synchronous entry for the C ABI (called from the Qt main thread): runs `commandAsync`, pumping the run loop while
    /// upstream's async operations finish. Must not be called from inside a main-actor job (tests use `commandAsync`).
    func command(_ json: Data) -> Int32 {
        // While upstream waits on a sheet (RAW Develop), the shell presents it.
        // A command still waiting after a moment is doing real work off the main thread (a full RAW develop is seconds):
        // the shell gets to repaint every frame meanwhile.
        let started = Date()
        var pumped = Date.distantPast
        return awaitOnMain({ [self] in await commandAsync(json) }, whileWaiting: { [self] in
            ImportPrompts.presentPendingSheet(for: self)
            let now = Date()
            guard ImportPrompts.sessionWaitPump != nil || ImportPrompts.waitPump != nil,
                  now.timeIntervalSince(started) > 0.15, now.timeIntervalSince(pumped) > 0.016 else { return }
            pumped = now
            ImportPrompts.pump(for: self)
        })
    }

    /// Brush options present in `parameters` (diameter px, hardness / opacity 0...1, smoothing 0...100,
    /// blurRadius 0.5...50), clamped to the options bar's ranges; absent ones keep their value.
    private static func apply(_ parameters: [String: Double], to settings: inout BrushSettings) {
        if let d = parameters["diameter"], d.isFinite { settings.diameter = CGFloat(min(2000, max(1, d))) }
        if let h = parameters["hardness"], h.isFinite { settings.hardness = CGFloat(min(1, max(0, h))) }
        if let o = parameters["opacity"], o.isFinite { settings.opacity = CGFloat(min(1, max(0.01, o))) }
        if let m = parameters["smoothing"], m.isFinite { settings.smoothing = CGFloat(min(100, max(0, m))) }
        if let r = parameters["blurRadius"], r.isFinite { settings.blurRadius = CGFloat(min(50, max(0.5, r))) }
    }

    func commandAsync(_ json: Data) async -> Int32 {
        guard let command = try? JSONDecoder().decode(Command.self, from: json) else { error = "Invalid command JSON"; return -1 }
        guard command.version == 1 else { error = "Unsupported command version"; return -4 }
        guard Self.supportedActions.contains(command.action) else {
            return fail(-7, "Unsupported by the upstream bridge yet: \(command.action)")
        }
        if let refusal = command.integerArgumentRefusal { return fail(-1, refusal) }
        if replacementImportSession != nil { return fail(-3, "The editor is busy; a replacement import is in progress") }
        let s = session
        // Project commands can arrive through the native event pump while an operation or modal is active.
        // Refuse before resolving a gradient or replacing the document and unsaved history.
        if (command.action == "importFiles" || command.action == "new"), !s.canStartProjectOperation {
            return fail(-3, command.action == "new" ? "The editor is busy; no canvas was created" : "The editor is busy; no files were imported")
        }
        if command.action == "new", command.newCanvasSize == nil { return fail(-1, "invalid size") }
        if command.action == "importFiles", command.enabled == true {
            guard let paths = command.paths, !paths.isEmpty else { return fail(-1, "paths required") }
            return await importReplacement(paths)
        }
        // Upstream applies a pending gradient when the tool, layer or target changes (selectTool / selectLayer →
        // resolveGradient), in a Task that the Mac's run loop finishes before the next click reaches the canvas. The
        // shell's commands arrive back to back (brushBegin switches tool and starts the stroke in one call), so the
        // bridge applies it first, in order, as the Mac's next event would find it.
        // Re-choosing the current tool is no switch (upstream selectTool resolves only when the tool changes).
        let reselectsTool = command.action == "selectTool" && (command.kind ?? command.name) == s.tool.rawValue
        if s.gradientEdit != nil, !reselectsTool, !Self.keepsPendingGradient.contains(command.action) {
            if let refusal = refusalBeforeGradient(command) { return fail(refusal.code, refusal.message) }
            let result = await commitPendingGradient()
            guard result == 0 else { return result }
        }
        switch command.action {
        case "new":
            guard let size = command.newCanvasSize else { return fail(-1, "invalid size") }
            s.createDocument(width: size.width, height: size.height, emptyLayer: command.emptyLayer ?? false)
        case "addLayer":
            guard s.document != nil else { return fail(-2, "no document") }
            s.addBlankLayer()
        case "addGroup": s.addGroup()
        case "groupSelectedLayers": s.groupSelectedLayers()
        case "ungroupLayers": s.ungroupLayers()
        case "selectLayer":
            guard let id = command.layerID else { return fail(-1, "layerID required") }
            guard s.document?.layers.contains(where: { $0.id == id }) == true else { return fail(-5, "no such layer") }
            // enabled=true: additive panel selection (Ctrl-click), so Cut-with-multi can be exercised.
            if command.enabled == true {
                s.selectLayers(s.selectedLayerIDs.union([id]), primary: id)
            } else {
                s.selectLayer(id)
            }
        case "deleteLayer":
            guard s.activeLayerID != nil else { return fail(-5, "no layer") }
            s.deleteActiveLayer()
        case "renameLayer":
            guard let name = command.name, let id = s.activeLayerID else { return fail(-1, "name required") }
            s.renameLayer(id, to: name)
        case "setVisible":
            guard let enabled = command.enabled, let layer = s.activeLayer else { return fail(-1, "enabled required") }
            if layer.isVisible != enabled { s.toggleLayerVisibility(layer.id) }
        case "setOpacity":
            guard let value = command.value, value.isFinite, s.activeLayer != nil else { return fail(-1, "value required") }
            s.setLayerOpacity(min(1, max(0, value)))
        case "setBlendMode":
            guard let name = command.kind, let mode = LayerBlendMode(rawValue: name) else { return fail(-1, "unknown blend mode") }
            s.setLayerBlendMode(mode)
        case "setSelectedOpacity":
            guard let value = command.value else { return fail(-1, "value required") }
            s.setSelectedLayersOpacity(value)
        case "cycleBlendMode": s.cycleBlendMode(forward: command.forward ?? true)
        case "flipLayer": s.flipLayers(horizontally: command.horizontally ?? true)
        case "flipCanvas": s.flipCanvas(horizontally: command.horizontally ?? true)
        // Opening establishes a saved revision; recovery must still require a user save.
        // Background save completion uses ProjectSaveSnapshot's captured revision instead.
        case "markSaved": s.history.markSaved()
        case "markUnsaved": s.history.markSaved(UUID())
        case "undo": s.undo()
        case "redo": s.redo()
        case "addRevealMask", "addHideMask":
            guard s.activeLayer != nil else { return fail(-5, "no layer") }
            s.addMask(revealing: command.action == "addRevealMask")
        case "toggleMaskAlone":
            guard let id = command.layerID ?? s.activeLayerID else { return fail(-5, "no layer") }
            s.toggleMaskAlone(id)
        case "clearMaskAlone":
            s.viewsMaskAlone = false
        // The × on the canvas's CMYK pills (upstream ProofBadge's close actions).
        case "stopProofing":
            s.proofsColors = false
        case "hideGamutWarning":
            s.showsGamutWarning = false
        case "deleteMask": s.deleteLayerMask()
        case "setMaskEnabled":
            guard let enabled = command.enabled, let mask = s.activeLayer?.mask else { return fail(-1, "no mask") }
            if mask.isEnabled != enabled { s.toggleLayerMask() }
        case "setMaskLinked":
            guard let linked = command.enabled, let layer = s.activeLayer, let mask = layer.mask else { return fail(-1, "no mask") }
            if mask.isLinked != linked { s.toggleMaskLink(layer.id) }
        case "moveLayer":
            guard let dx = command.x, let dy = command.y, dx.isFinite, dy.isFinite, s.activeLayer != nil else { return fail(-1, "delta required") }
            s.nudgeLayer(dx: CGFloat(dx), dy: CGFloat(dy))
        case "selectRectangle", "selectEllipse":
            guard s.document != nil else { return fail(-2, "no document") }
            guard let x = command.x, let y = command.y, let width = command.width, let height = command.height,
                  [x, y].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), (0...30_000).contains(width), (0...30_000).contains(height)
            else { return fail(-1, "invalid rectangle") }
            let rect = CGRect(x: x, y: y, width: CGFloat(width), height: CGFloat(height))
            let resolvedMode = (command.kind.flatMap { k in
                SelectionMode(rawValue: k) ?? SelectionMode.allCases.first(where: { "\($0)".caseInsensitiveCompare(k) == .orderedSame })
            }) ?? s.displayedSelectionMode
            select(command.action == "selectEllipse" ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil),
                   mode: resolvedMode)
        case "selectLasso":
            guard s.document != nil else { return fail(-2, "no document") }
            guard let list = command.points, list.count >= 3 else { return fail(-1, "lasso needs 3+ points") }
            let points = list.compactMap { $0.count == 2 && $0[0].isFinite && $0[1].isFinite ? CGPoint(x: $0[0], y: $0[1]) : nil }
            guard points.count == list.count else { return fail(-1, "invalid point") }
            let path = CGMutablePath()
            path.addLines(between: points); path.closeSubpath()
            let resolvedMode = (command.kind.flatMap { k in
                SelectionMode(rawValue: k) ?? SelectionMode.allCases.first(where: { "\($0)".caseInsensitiveCompare(k) == .orderedSame })
            }) ?? s.displayedSelectionMode
            select(path, mode: resolvedMode)
        case "colorRangeBegin":
            guard s.canSelectColorRange else { return fail(-5, "selection cannot be edited") }
            s.beginColorRange()
            guard s.colorRange != nil else { return fail(-5, "could not sample document") }
        case "colorRangeSample":
            guard s.colorRange != nil, let x = command.x, let y = command.y, x.isFinite, y.isFinite
            else { return fail(-1, "invalid color sample") }
            s.sampleColorRange(at: CGPoint(x: x, y: y), shift: (command.parameters?["shift"] ?? 0) != 0,
                              option: (command.parameters?["option"] ?? 0) != 0)
        case "colorRangeUpdate":
            guard let edit = s.colorRange else { return fail(-5, "no color range being edited") }
            if let value = command.value {
                guard value.isFinite, ColorRangeEdit.fuzzinessRange.contains(value) else { return fail(-1, "invalid fuzziness") }
            }
            if let kind = command.kind, HueSampleMode(rawValue: kind) == nil { return fail(-1, "invalid sample mode") }
            if let value = command.value { edit.fuzziness = value }
            if let enabled = command.enabled { edit.invert = enabled }
            if let kind = command.kind { edit.sampleMode = HueSampleMode(rawValue: kind)! }
            s.updateColorRange()
        case "colorRangeCommit":
            guard let edit = s.colorRange, !edit.isWorking else { return fail(-5, "color range is still updating") }
            s.commitColorRange()
        case "colorRangeCancel": s.cancelColorRange()
        case "selectAll": s.selectAll()
        case "deselect": s.deselect()
        case "invertSelection":
            // Linux shell: inverting a selection that already covers the whole canvas keeps it (marching ants stay,
            // painting still works everywhere) instead of upstream's deselect. Only the shell command differs;
            // EditorSession.invertSelection keeps upstream behavior.
            if let document = s.document, let current = s.selection {
                let canvas = CGPath(rect: CGRect(origin: .zero, size: document.size), transform: nil)
                let inverse = DocumentSelection(path: canvas.subtracting(current.path, using: .winding),
                                                antialiased: current.antialiased, feather: current.feather)
                if inverse.isEmpty { break }
            }
            s.invertSelection()
        case "loadLayerSelection":
            guard let id = s.activeLayerID else { return fail(-5, "no layer") }
            s.loadLayerSelection(layerID: id)
        case "loadMaskSelection":
            guard let id = s.activeLayerID else { return fail(-5, "no layer") }
            s.loadMaskSelection(layerID: id)
        case "selectSubject":
            await s.selectSubject()
        case "featherSelection":
            s.featherSelection(by: Int(command.parameters?["amount"] ?? 1))
        case "expandSelection":
            let amt = Int(command.parameters?["amount"] ?? 1)
            s.selectionExpandAmount = amt
            s.expandSelection(by: amt)
        case "setSelectionExpandAmount":
            if let amt = command.parameters?["amount"] {
                s.selectionExpandAmount = Int(amt)
            }
        case "setSelectionMode":
            if let k = command.kind, let mode = SelectionMode(rawValue: k) ?? SelectionMode.allCases.first(where: { "\($0)".caseInsensitiveCompare(k) == .orderedSame }) {
                s.selectionModeChoice = mode
            }
        case "contractSelection": s.contractSelection(by: Int(command.parameters?["amount"] ?? 1))
        // The palette is the session's (upstream's ColorPalette.swift): swatches, swap/reset and the picker all go
        // through it, so the SwiftUI tool rail, the options bar and the next brush stroke agree on one color.
        case "swapPaletteColors": s.swapPaletteColors()
        case "resetPaletteColors": s.resetPaletteColors()
        case "setPaletteColor", "openColorPicker", "setColorPickerColor":
            let p = command.parameters ?? [:]
            let color = PaletteColor(red: p["red"] ?? 0, green: p["green"] ?? 0, blue: p["blue"] ?? 0)
            switch command.action {
            case "setPaletteColor": s.setPaletteColor(color, background: command.kind == "background")
            case "openColorPicker": s.openColorPicker(background: command.kind == "background")
            default:
                guard let picker = s.colorPicker else { return fail(-5, "no color picker open") }
                picker.hsb = PickerHSB(color)
                // Upstream's views observe the picker's working color (`.onChange(of: session.colorPicker?.color)`)
                // and preview it live — text being edited, a layer effect, a gradient map end, the vignette. The Qt
                // shell has no such observers, so the bridge runs the same previews (each checks its own target).
                s.previewTextColor(); s.previewEffectColor(); s.previewGradientMapColor(); s.previewVignetteColor()
            }
        case "closeColorPicker": s.closeColorPicker(commit: command.enabled ?? false)
        // Edit > Keyboard Shortcuts… (ShortcutSettings.show): upstream's editor, shown as a floating panel.
        case "showKeyboardShortcuts": ShortcutSettings.shared.show()
        // The alert's OK button (ContentView: session.brushError / cropError = nil).
        case "dismissAlert":
            if command.kind == "crop" { s.cropError = nil } else { s.brushError = nil }
        // Guides, as CanvasRulerNSView and EditorCanvas drag them: from a ruler (`kind` = horizontal | vertical, `value` =
        // document position), or grabbing one on the canvas (x, y in view points, the viewport's space).
        case "guideCreate":
            guard let axis = command.kind.flatMap(CanvasGuide.Axis.init(rawValue:)), let value = command.value, value.isFinite else { return fail(-1, "invalid guide") }
            s.beginGuideCreation(axis: axis, at: value)
            guard s.guideDrag != nil else { return fail(-5, "guides can't be edited now") }
        case "guideHit":
            guard let p = point(command), let guide = s.hitGuide(at: p), s.canEditGuides else { return fail(-5, "no guide there") }
            s.beginGuideMove(guide)
        case "guideMove":
            guard let value = command.value, value.isFinite else { return fail(-1, "invalid position") }
            s.moveGuideDrag(to: value)
        case "guideFinish": s.finishGuideDrag(delete: command.enabled == true)
        case "guideCancel": s.cancelGuideDrag()
        // The shell's file chooser for upstream's .fileImporter / the welcome's Open project has closed.
        case "dismissImporter":
            s.showsImporter = false
            openProjectRequested = false
        // The Layers panel's fx menu (LayersPanel: session.addEffect): `kind` = LayerEffectKind raw value.
        case "addLayerEffect":
            guard let name = command.kind, let kind = LayerEffectKind(rawValue: name) else { return fail(-1, "invalid effect") }
            guard s.activeLayer != nil else { return fail(-2, "no layer") }
            s.addEffect(kind)
        // The close button of a floating panel the shell shows for upstream (FloatingPanels.swift): `kind` = panel name.
        case "closeFloatingPanel":
            guard let panel = command.kind else { return fail(-1, "panel name required") }
            FloatingPanels.close(panel, in: self)
        // Upstream's own importer (EditorSession.importImages): PNG/JPEG/TIFF/HEIC through ImageIO, Photoshop PSD and PSB
        // with their layers, masks and editable text, camera RAW. `enabled` = replace the document (the shell's Open
        // Image); otherwise the files come in as layers, as a drop onto the canvas does.
        case "importFiles":
            guard let paths = command.paths, !paths.isEmpty else { return fail(-1, "paths required") }
            ImportPrompts.install(on: s)
            await s.importImages(paths.map { URL(fileURLWithPath: $0) })
            if let message = s.importError {
                s.importError = nil   // reported to the shell; left set, it would block editing
                return fail(-5, message)
            }
            guard s.document != nil else { return fail(-5, "nothing could be imported") }
        // The Gradient and Shape tools, as upstream's EditorCanvas drives them with the mouse.
        case "gradientBegin":
            guard let point = point(command) else { return fail(-1, "invalid point") }
            if s.tool != .gradient {
                s.selectTool(.gradient)
                guard s.tool == .gradient else {
                    return fail(-5, s.brushError ?? "could not leave text editing to use Gradient")
                }
            }
            let before = s.brushError
            s.beginGradient(at: point)
            guard s.gradientEdit != nil else {
                return fail(-5, refusal(s, before: before, cause: "gradient could not start: no layer to paint on"))
            }
        case "gradientMove":
            guard let point = point(command) else { return fail(-1, "invalid point") }
            s.moveGradient(start: command.kind == "start" ? point : nil, end: command.kind == "start" ? nil : point)
        case "gradientEndDrag": s.endGradientDrag()
        case "gradientCommit":
            let result = await commitPendingGradient()
            guard result == 0 else { return result }
        case "gradientCancel": s.cancelGradient()
        case "shapeBegin":
            guard let point = point(command) else { return fail(-1, "invalid point") }
            if s.tool != .shape {
                s.selectTool(.shape)
                guard s.tool == .shape else {
                    return fail(-5, s.brushError ?? "could not leave text editing to use Shape")
                }
            }
            let before = s.brushError
            s.beginShape(at: point)
            guard s.shapeDraft != nil else {
                return fail(-5, refusal(s, before: before, cause: "shape could not start: the editor is busy"))
            }
        case "shapeDrag":
            guard let point = point(command) else { return fail(-1, "invalid point") }
            let p = command.parameters ?? [:]
            s.dragShape(to: point, square: (p["square"] ?? 0) != 0, fromCenter: (p["fromCenter"] ?? 0) != 0)
        case "shapeFinish": s.finishShape()
        case "shapeCancel": s.cancelShape()
        // The Type tool, as upstream's EditorCanvas / InlineTextEditor drive it.
        case "textEditAt":   // live text under the point (Type click, or Move double-click): open it for editing
            guard let point = point(command), let document = s.document, s.canEditLayers else { return fail(-1, "invalid point") }
            guard s.finishText() else { return fail(-5, s.brushError ?? "text could not be applied") }
            let visible = document.effectiveVisibleIDs
            guard let layer = document.layers.reversed().first(where: { visible.contains($0.id) && $0.liveText != nil && $0.transform.contains(point) })
            else { return fail(-5, "no text here") }
            s.commitTransform()
            s.selectLayer(layer.id)
            s.editActiveText()
            guard s.textDraft != nil else { return fail(-5, "text could not be opened") }
        case "textBegin":
            guard let point = point(command) else { return fail(-1, "invalid point") }
            guard s.finishText() else { return fail(-5, s.brushError ?? "text could not be applied") }
            s.beginText(at: point, newLayer: command.enabled ?? true)
            guard s.textDraft != nil else { return fail(-5, "text could not start") }
        case "textBeginBox":
            guard let point = point(command), let w = command.width, let h = command.height else { return fail(-1, "invalid box") }
            guard s.finishText() else { return fail(-5, s.brushError ?? "text could not be applied") }
            s.beginText(in: CGRect(x: point.x, y: point.y, width: Double(w), height: Double(h)))
            guard s.textDraft != nil else { return fail(-5, s.brushError ?? "text box could not start") }
        case "textSetContent":   // InlineTextEditor.textDidChange
            guard var draft = s.textDraft else { return fail(-5, "no text being edited") }
            guard LinuxTextEditing.setContent(command.name ?? "", in: &draft) else { return fail(-1, "invalid text edit") }
            s.textDraft = draft
        case "textReplace":
            guard var draft = s.textDraft else { return fail(-5, "no text being edited") }
            guard let location = command.location, let length = command.length,
                  LinuxTextEditing.replace(in: &draft, location: location, length: length, with: command.name ?? "")
            else { return fail(-1, "invalid text edit") }
            s.textDraft = draft
        case "textRestore":
            guard var draft = s.textDraft, draft.id == command.draftID,
                  let style = command.textStyle, style.isValid,
                  let location = command.location, let length = command.length,
                  LinuxTextEditing.validRange(location: location, length: length, in: style.content)
            else { return fail(-1, "invalid text history state") }
            draft.style = style
            draft.selection = NSRange(location: location, length: length)
            s.textDraft = draft
        case "textSelect":
            guard var draft = s.textDraft else { return fail(-5, "no text being edited") }
            guard let location = command.location, let length = command.length,
                  LinuxTextEditing.validRange(location: location, length: length, in: draft.style.content)
            else { return fail(-1, "invalid text selection") }
            draft.selection = NSRange(location: location, length: length)
            s.textDraft = draft
        case "textFinish":
            guard s.finishText() else { return fail(-5, s.brushError ?? "text could not be applied") }
        case "textCancel": s.cancelText()
        case "fillForeground", "fillBackground":
            let background = command.action == "fillBackground"
            let p = command.parameters ?? [:]
            if p["red"] != nil || p["green"] != nil || p["blue"] != nil {
                s.setPaletteColor(PaletteColor(red: p["red"] ?? 0, green: p["green"] ?? 0, blue: p["blue"] ?? 0), background: background)
            }
            await s.fillSelection(with: background ? .background : .foreground)
        case "clearSelection":
            // Tip canEditPixels == canPaint refuses when several layers are selected. Clear every
            // selected pixel layer inside the marquee (Photoshop-style), then restore the multi-selection.
            await Self.clearThroughSelectedLayers(s)
        case "invert": await s.invertPixels()
        case "copy": s.copySelection()
        case "copyMerged": s.copyMergedSelection()
        case "cut":
            await Self.cutThroughSelectedLayers(s)
        case "paste":
            // As upstream's Edit › Paste: on the New canvas screen an image on the clipboard (or image files copied in
            // the file manager) makes the canvas; otherwise the copied pixels go in.
            if s.canPasteImageAsNewCanvas { await s.pasteImageAsNewCanvas() } else { s.paste() }
        case "duplicateLayer": s.duplicateActiveLayer()
        case "layerViaCopy": s.layerViaCopy()
        case "toggleClippingMask":
            guard let id = s.activeLayerID else { return fail(-5, "no layer") }
            s.toggleClippingMask(id)
        case "moveActiveLayer":
            s.moveActiveLayer(by: Int(command.value ?? 1))
        case "moveActiveLayerOutOfGroup":
            s.moveActiveLayerOutOfGroup()
        case "mergeLayers":
            s.mergeLayers()
        case "cloneSetSource":
            guard let point = point(command) else { return fail(-1, "invalid point") }
            s.setCloneSource(point)
        case "brushBegin":
            let p = command.parameters ?? [:]
            guard s.document != nil, let point = point(command) else { return fail(-1, "invalid brush start") }
            let healing = (p["healing"] ?? 0) != 0
            let cloning = command.kind == "Clone"
            if cloning, s.cloneSource == nil { return fail(-5, "no clone source set (send cloneSetSource first)") }
            s.selectTool(healing ? .spotHealing : cloning ? .cloneStamp : .brush)
            if healing, let modeIndex = p["healingMode"], (0..<SpotHealingMode.allCases.count).contains(Int(modeIndex)) {
                s.spotHealingMode = SpotHealingMode.allCases[Int(modeIndex)]
            }
            if cloning { s.cloneSettings.aligned = (p["aligned"] ?? 1) != 0; s.cloneSettings.sampleAllLayers = (p["sampleAllLayers"] ?? 0) != 0 }
            // The session's own settings (what upstream's options bar edits: hardness, opacity, smoothing, ...), with
            // whatever the shell sends on top — a fresh BrushSettings() here threw the options bar's choices away.
            var settings = s.brushSettings
            Self.apply(p, to: &settings)
            if let red = p["red"] { settings.red = red }
            if let green = p["green"] { settings.green = green }
            if let blue = p["blue"] { settings.blue = blue }
            s.brushSettings = settings
            s.brushMode = (p["erasing"] ?? 0) != 0 ? .erase : .paint
            s.isMaskSelected = (p["mask"] ?? 0) != 0
            // A mask stroke paints white (reveal) or black (hide): upstream keeps that choice as the mask palette.
            if s.isMaskSelected { s.maskPaintWhite = (0.2126 * settings.red + 0.7152 * settings.green + 0.0722 * settings.blue) > 0.5 }
            let before = s.brushError
            s.beginBrush(at: point)
            guard s.brushStroke != nil else {
                return fail(-5, refusal(s, before: before, cause: cloning ? "clone stamp could not start: the source is out of range"
                                                                       : "brush could not start: the editor is busy"))
            }
        // The shell's brush controls (legacy sliders, [ and ] keys) change the session's settings, as the options bar does.
        case "setBrushSettings":
            var settings = s.brushSettings
            Self.apply(command.parameters ?? [:], to: &settings)
            s.brushSettings = settings
        case "setGradientSettings":
            // Qt options fallback (SwiftUI GradientControls binds session.gradientSettings directly).
            let p = command.parameters ?? [:]
            if let shape = command.kind.flatMap(GradientShape.init(rawValue:)) {
                s.gradientSettings.shape = shape
            }
            if let style = command.name.flatMap(GradientStyle.init(rawValue:)) {
                s.gradientSettings.style = style
            }
            if let reversed = p["reversed"] { s.gradientSettings.reversed = reversed != 0 }
            if let opacity = p["opacity"], opacity.isFinite {
                s.gradientSettings.opacity = CGFloat(min(1, max(0.01, opacity)))
            }
            s.refreshGradient()
        case "brushMove":
            guard let point = point(command) else { return fail(-1, "invalid point") }
            s.continueBrush(at: point)
        case "brushEnd": await s.finishBrush()
        case "brushCancel": s.cancelBrush()
        case "magicWand":
            guard s.document != nil, let point = point(command) else { return fail(-1, "invalid point") }
            let p = command.parameters ?? [:]
            var settings = WandSettings()
            settings.tolerance = Int(p["tolerance"] ?? Double(settings.tolerance))
            settings.contiguous = (p["contiguous"] ?? (settings.contiguous ? 1 : 0)) != 0
            settings.sampleAllLayers = (p["sampleAllLayers"] ?? (settings.sampleAllLayers ? 1 : 0)) != 0
            s.wandSettings = settings
            await s.magicWand(at: point, mode: SelectionMode(rawValue: command.kind ?? "New") ?? .replace)
        // Filter menu, the upstream way (CompositorApp's Filter menu: session.beginFilter): its FilterSheet floats.
        case "openFilter":
            guard let name = command.kind, let kind = FilterKind(rawValue: name) else { return fail(-1, "unknown filter") }
            s.beginFilter(kind)
            guard s.filterEdit != nil else { return fail(-5, "filter could not start") }
            filterInShellDialog = false
        // Image > Levels… / Hue/Saturation… (CompositorApp): floating LevelsSheet / HueSaturationSheet.
        case "beginLevels":
            s.beginLevels()
            guard s.levels != nil else { return fail(-5, "levels could not start") }
        case "beginHueSaturation":
            s.beginHueSaturation()
            guard s.hueSaturation != nil else { return fail(-5, "hue/saturation could not start") }
        // Layer > Edit Adjustment… / double-click: open the upstream editor for that adjustment layer.
        case "beginAdjustmentEditing":
            let id = command.layerID ?? s.activeLayerID
            guard let id, let adjustment = s.document?.layers.first(where: { $0.id == id })?.adjustment else {
                return fail(-1, "not an adjustment layer")
            }
            guard adjustment.kind.isEditable else { return fail(-1, "adjustment has no editable settings") }
            s.adjustmentEditingID = id
            await s.beginAdjustmentEditing(id)
            guard s.adjustmentOriginal != nil || s.levels != nil || s.hueSaturation != nil || s.filterEdit != nil else {
                return fail(-5, "adjustment editor could not start")
            }
        // Image > Trim… (ProjectController.trim): upstream's sheet, then its trim, as one undo step.
        case "trim":
            guard s.document != nil else { return fail(-2, "no document") }
            guard beginProjectOperation() else { return fail(-3, "The editor is busy; the image was not trimmed") }
            defer { s.isProjectBusy = false }
            let options: TrimOptions? = await withCheckedContinuation { continuation in
                trimAnswer = { continuation.resume(returning: $0) }
                trimSheet = TrimSheet { [weak self] options in self?.finishTrim(options) }
            }
            guard let options, let snapshot = s.projectSnapshot() else { break }
            do {
                guard let trimmed = try await ImageTrim.trim(snapshot, options: options) else { break }
                s.applyDocumentSize(trimmed, actionName: "Trim")
            } catch { return fail(-5, "Couldn’t trim image: \(error.localizedDescription)") }
        // ProjectController.canvasSize() / imageSize(): upstream's sheet, then its resizer, one undo step.
        case "canvasSizeSheet":
            guard let document = s.document else { return fail(-2, "no document") }
            guard beginProjectOperation() else { return fail(-3, "The editor is busy; the canvas size was not changed") }
            defer { s.isProjectBusy = false }
            let options: CanvasSizeOptions? = await withCheckedContinuation { continuation in
                sizeAnswer = { continuation.resume(returning: $0 as? CanvasSizeOptions) }
                canvasSizeSheet = CanvasSizeSheet(document: document, session: s) { [weak self] in
                    self?.finishSizeSheet($0)
                }
            }
            guard let options, let snapshot = s.projectSnapshot() else { break }
            do {
                let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
                s.applyDocumentSize(resized, actionName: "Canvas Size")
            } catch { return fail(-5, "Couldn’t change canvas size: \(error.localizedDescription)") }
        case "imageSizeSheet":
            guard let document = s.document else { return fail(-2, "no document") }
            guard beginProjectOperation() else { return fail(-3, "The editor is busy; the image size was not changed") }
            defer { s.isProjectBusy = false }
            let options: ImageSizeOptions? = await withCheckedContinuation { continuation in
                sizeAnswer = { continuation.resume(returning: $0 as? ImageSizeOptions) }
                imageSizeSheet = ImageSizeSheet(document: document) { [weak self] in self?.finishSizeSheet($0) }
            }
            guard let options, let snapshot = s.projectSnapshot() else { break }
            do {
                let resized = try await ImageResizer.shared.resize(snapshot, to: options)
                s.applyImageSize(resized)
            } catch { return fail(-5, "Couldn’t resize the image: \(error.localizedDescription)") }
        // ProjectController.exportPNG(), the save panel being the shell's: `paths` = [destination]. Export JPEG… is
        // Export As starting on JPEG, as in upstream 1.4.8 ("exportAsSheet" with kind "jpeg").
        case "exportPNG":
            guard let path = command.paths?.first, let snapshot = s.projectSnapshot() else { return fail(-1, "nothing to export") }
            guard beginProjectOperation() else { return fail(-3, "The editor is busy; nothing was exported") }
            defer { s.isProjectBusy = false }
            do { try await ImageExporter.shared.exportPNG(snapshot, to: URL(fileURLWithPath: path)) }
            catch { return fail(-5, "Couldn’t export PNG: \(error.localizedDescription)") }
        case "exportPDF":
            guard let path = command.paths?.first, let snapshot = s.projectSnapshot() else { return fail(-1, "nothing to export") }
            guard beginProjectOperation() else { return fail(-3, "The editor is busy; nothing was exported") }
            defer { s.isProjectBusy = false }
            do { try await ImageExporter.shared.exportPDF(snapshot, to: URL(fileURLWithPath: path)) }
            catch { return fail(-5, "Couldn’t export PDF: \(error.localizedDescription)") }
        case "exportAsSheet":
            guard let snapshot = s.projectSnapshot() else { return fail(-2, "no document") }
            guard beginProjectOperation() else { return fail(-3, "The editor is busy; nothing was exported") }
            exportHoldsProject = true
            var chosenExport = false
            defer { if !chosenExport { exportHoldsProject = false; s.isProjectBusy = false } }
            do {
                let raster = try await ImageExporter.shared.render(snapshot)
                // As upstream ProjectController.exportAs: a 16-bit PNG with a 16-bit layer, an EXR with an HDR layer.
                let deepRaster = snapshot.images.values.contains { $0.deep != nil }
                    ? try await ImageExporter.shared.render(snapshot, sixteenBit: true) : nil
                let hdrRaster = snapshot.images.values.contains { $0.isHDR }
                    ? try await ImageExporter.shared.render(snapshot, sixteenBit: true, hdr: true) : nil
                let start: ExportFormat = {
                    switch command.kind?.lowercased() {
                    case "jpeg": return .jpeg
                    case "pdf": return .pdf
                    case "png": return .png
                    case "exr": return .exr
                    case "tiff": return .tiff
                    default: return lastExportFormat
                    }
                }()
                let chosen: (data: Data, format: ExportFormat)? = await withCheckedContinuation { continuation in
                    sizeAnswer = { continuation.resume(returning: $0 as? (data: Data, format: ExportFormat)) }
                    exportAsSheet = ExportAsSheet(raster: raster, deepRaster: deepRaster, hdrRaster: hdrRaster, session: s,
                                                  format: start) { [weak self] in
                        self?.finishExportAsSheet($0)
                    }
                }
                guard let chosen else { return fail(-7, "cancelled") }
                pendingExport = chosen
                lastExportFormat = chosen.format
                chosenExport = true
            } catch { return fail(-5, "Couldn’t export: \(error.localizedDescription)") }
        case "gridSettingsSheet":
            // ProjectController.gridSettings(): live preview while open; Cancel restores the backup.
            // Await until the shell modal finishes so ImportPrompts.presentPendingSheet can show GridSettingsSheet.
            guard gridSettingsBackup == nil else { return fail(-5, "grid settings already open") }
            let original = (grid: s.layoutGrid, appearance: s.gridAppearance, shown: s.showsGrid)
            gridSettingsBackup = original
            s.showsGrid = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gridSettingsAnswer = { continuation.resume() }
            }
        case "writeExport":
            // The save panel has answered: Export As's hold on the project ends whatever happens next.
            if exportHoldsProject { exportHoldsProject = false; s.isProjectBusy = false }
            // No path: Cancel on the save panel — drop pending bytes (nothing is written).
            guard let pending = pendingExport else { return fail(-1, "nothing to write") }
            pendingExport = nil
            guard let path = command.paths?.first else { return fail(-7, "cancelled") }
            do { try await ImageExporter.shared.write(pending.data, to: URL(fileURLWithPath: path)) }
            catch { return fail(-5, "Couldn’t export: \(error.localizedDescription)") }
        // EditorCanvas.sampleColor while the color picker is open: the canvas under the pointer into the picker.
        case "sampleColorPicker":
            guard let p = point(command), s.colorPicker != nil else { return fail(-2, "no picker") }
            s.sampleIntoColorPicker(at: p)
        case "filterBegin":
            guard let name = command.kind, let kind = FilterKind(rawValue: name) else { return fail(-1, "unknown filter") }
            filterInShellDialog = true
            s.beginFilter(kind)
            guard s.filterEdit != nil else { return fail(-5, "filter could not start") }
            s.updateFilter(filterSettings(command, s.filterSettings), preview: true)
        case "filterPreview":
            guard s.filterEdit != nil else { return fail(-1, "no filter in progress") }
            s.updateFilter(filterSettings(command, s.filterEdit?.settings ?? s.filterSettings), preview: s.filterEdit?.preview ?? true)
        case "filterCommit":
            guard s.filterEdit != nil else { return fail(-1, "no filter in progress") }
            await s.commitFilter()
        case "filterCancel": s.cancelFilter()
        case "filterSetPreview":
            guard let enabled = command.enabled, let edit = s.filterEdit else { return fail(-1, "no filter in progress") }
            edit.preview = enabled
        case "setMaskSelected":
            s.isMaskSelected = command.enabled ?? false
            if s.isMaskSelected, s.activeLayer?.mask?.isLinked == false { s.beginTransform() }
        case "invertMask":
            guard let layer = s.activeLayer, layer.mask != nil else { return fail(-5, "no mask") }
            let was = s.isMaskSelected
            s.isMaskSelected = true
            await s.invertPixels()
            s.isMaskSelected = was
        case "transformBegin": s.beginTransform()
        case "transformCommand":
            // Tip Cmd-T: selection float when possible, else persistent Free Transform on the layer.
            if s.canTransformSelection { await s.beginSelectionTransform() }
            else { s.beginTransform() }
        case "setCanvasOnly":
            guard let enabled = command.enabled else { return fail(-1, "enabled required") }
            s.canvasOnly = enabled
        case "setShowsTransformControls":
            guard let enabled = command.enabled else { return fail(-1, "enabled required") }
            s.showsTransformControls = enabled
            // TransformOverlay.draw reads this flag; mark every hosted canvas's overlay dirty so a partial
            // blit (and the shell's invalidateOverlay) both pick up the switch.
            for canvas in UpstreamCanvases.canvases.values {
                guard canvas.view.session === s else { continue }
                canvas.view.subviews.compactMap { $0 as? TransformOverlay }.forEach { $0.needsDisplay = true }
            }
        case "setTransformAutoSelect":
            guard let enabled = command.enabled else { return fail(-1, "enabled required") }
            s.transformAutoSelect = enabled
        case "transform":
            // Options-bar fields: update the live draft. While Free Transform (Ctrl+T) is open, leave it
            // pending until Enter/Esc — tip TransformInspector does the same for typed values.
            if s.transformEdit == nil { s.beginTransform(persistent: false) }
            guard var transform = s.transformEdit?.draft else { return fail(-5, "no layer") }
            apply(command.parameters ?? [:], to: &transform)
            s.previewTransform(transform)
            if s.transformEdit?.persistent != true { s.commitTransform() }
        case "transformPreview":
            guard var draft = s.transformEdit?.draft ?? s.activeLayer?.transform else { return fail(-5, "no layer") }
            apply(command.parameters ?? [:], to: &draft)
            s.previewTransform(draft)
        case "transformCommit":
            s.commitTransform()
        case "transformCommitFinal":
            // Save / export / tab switch: fold the draft into the document and leave transform idle.
            s.commitTransform()
        case "transformCancel":
            s.cancelTransform()
        // Move tool, as EditorCanvas drags: Ctrl-dragging a handle distorts (and once distorted, handles keep distorting);
        // `value` = handle (0...7 around from top-left, 9 = the body). The edit stays pending until Enter / Apply.
        case "distortDragBegin":
            guard let point = point(command), let handle = command.value.map({ Int($0) }), (0...9).contains(handle), handle != 8 else { return fail(-1, "invalid handle") }
            if s.transformEdit == nil { s.beginTransform(persistent: false) }
            if handle != 9 { s.beginDistort() }
            guard let edit = s.transformEdit, let corners = edit.corners else { return fail(-5, "nothing to distort") }
            distortDrag = TransformDrag(original: edit.draft, start: point, mode: handle == 9 ? .move : .distort(handle), originalCorners: corners)
        case "distortDragMove":
            guard let point = point(command), let drag = distortDrag else { return fail(-1, "no distort drag") }
            if let corners = drag.corners(to: point, shift: command.enabled ?? false) { s.previewCorners(corners) }
        case "distortDragEnd": distortDrag = nil
        case "distortBegin":
            s.beginTransform()
            s.beginDistort()
        case "distortCommit":
            guard let edit = s.transformEdit, let list = command.points, list.count == 4 else { return fail(-1, "four corners required") }
            let corners = list.compactMap { $0.count == 2 && $0[0].isFinite && $0[1].isFinite ? CGPoint(x: $0[0], y: $0[1]) : nil }
            guard corners.count == 4 else { return fail(-1, "invalid corner") }
            s.commitDistort(edit, corners: corners)
        case "addShape":
            guard s.document != nil, let name = command.kind, let kind = ShapeKind(rawValue: name),
                  let width = command.width, let height = command.height, let x = command.x, let y = command.y else { return fail(-1, "invalid shape") }
            let p = command.parameters ?? [:]
            s.setPaletteColor(PaletteColor(red: p["red"] ?? 0, green: p["green"] ?? 0, blue: p["blue"] ?? 0), background: false)
            s.selectTool(.shape)
            s.shapeKind = kind
            s.shapeCornerRadius = p["cornerRadius"] ?? 0
            s.beginShape(at: CGPoint(x: x, y: y))
            s.dragShape(to: CGPoint(x: x + Double(width), y: y + Double(height)), square: false, fromCenter: false)
            s.finishShape()
        case "warpBegin":
            guard let name = command.kind, let mode = BlurToolMode(rawValue: name), let point = point(command) else { return fail(-1, "invalid warp") }
            let p = command.parameters ?? [:]
            var settings = s.brushSettings
            Self.apply(p, to: &settings)
            s.selectTool(.blur)
            s.blurMode = mode
            s.brushSettings = settings
            s.beginWarp(at: point)
            guard s.warpStroke != nil else { return fail(-5, "warp could not start") }
        case "warpMove":
            guard let point = point(command) else { return fail(-1, "invalid point") }
            s.continueBrush(at: point)
        case "warpEnd": s.finishWarp()
        case "warpCancel": s.cancelBrush()
        case "resizeCanvas":
            guard let width = command.width, let height = command.height, let snapshot = s.projectSnapshot() else { return fail(-1, "invalid size") }
            let p = command.parameters ?? [:]
            let anchor = p["anchor"] ?? 4
            guard (0...8).contains(anchor), anchor.rounded() == anchor else { return fail(-1, "invalid anchor") }
            var options = CanvasSizeOptions(width: width, height: height, anchor: Int(anchor))
            if command.enabled == true { options.fill = CanvasExtensionColor(red: p["red"] ?? 0, green: p["green"] ?? 0, blue: p["blue"] ?? 0) }
            guard let resized = try? await CanvasResizer.shared.resize(snapshot, to: options) else { return fail(-5, "canvas resize failed") }
            s.applyDocumentSize(resized, actionName: "Canvas Size")
        case "cropCanvas":
            guard let width = command.width, let height = command.height, let snapshot = s.projectSnapshot() else { return fail(-1, "invalid crop") }
            let options = CanvasSizeOptions(width: width, height: height, contentOffset: CGPoint(x: -(command.x ?? 0), y: -(command.y ?? 0)))
            guard let cropped = try? await CanvasResizer.shared.resize(snapshot, to: options) else { return fail(-5, "crop failed") }
            s.applyDocumentSize(cropped, actionName: "Crop")
        case "resizeImage":
            guard let width = command.width, let height = command.height, let snapshot = s.projectSnapshot() else { return fail(-1, "invalid size") }
            var sampling = LayerSampling.high
            if let kind = command.kind { guard let chosen = LayerSampling(rawValue: kind) else { return fail(-1, "unknown sampling") }; sampling = chosen }
            let options = ImageSizeOptions(width: width, height: height, resolution: command.value ?? s.document?.resolution ?? 72, sampling: sampling)
            guard let resized = try? await ImageResizer.shared.resize(snapshot, to: options) else { return fail(-5, "image resize failed") }
            s.applyImageSize(resized)
        // The shell's Qt AdjustDialog path used to clear adjustmentEditingID and drive preview via
        // adjustmentPreview commands. Prefer upstream's own editors (LevelsSheet / HueSaturationSheet /
        // FilterSheet) the way LayersPanel's .task does on the Mac.
        case "addAdjustment":
            guard let name = command.kind, let kind = AdjustmentKind(rawValue: name) else { return fail(-1, "unknown adjustment") }
            s.addAdjustment(kind)
            if let id = s.adjustmentEditingID {
                await s.beginAdjustmentEditing(id)
            }
        case "adjustmentBegin":
            guard let id = command.layerID, let value = s.document?.layers.first(where: { $0.id == id })?.adjustment else { return fail(-1, "not an adjustment layer") }
            s.selectLayer(id)
            adjustmentEditing = id
            adjustmentOriginal = (id, value)
        case "adjustmentPreview":
            guard let value = command.adjustment, let id = adjustmentEditing else { return fail(-1, "no adjustment being edited") }
            s.updateAdjustment(id, value: value)
        case "adjustmentCommit":
            guard let value = command.adjustment, let id = adjustmentEditing ?? adjustmentOriginal?.id else { return fail(-1, "no adjustment being edited") }
            s.beginEdit("Edit \(value.kind.rawValue) Adjustment")
            s.updateAdjustment(id, value: value)
            s.endEdit()
            adjustmentEditing = nil; adjustmentOriginal = nil
        case "adjustmentCancel":
            if let original = adjustmentOriginal { s.updateAdjustment(original.id, value: original.value) }
            adjustmentEditing = nil; adjustmentOriginal = nil
            // Also cancel an upstream floating adjustment edit started via addAdjustment / beginAdjustmentEditing.
            if s.adjustmentEditingID != nil { _ = s.finishAdjustmentEditing(commit: false) }
        case "contentFill":
            s.beginFilter(.contentAwareFill)
            guard s.filterEdit != nil else { return fail(-5, "content-aware fill needs a selection") }
            await s.commitFilter()
        case "removeBackground", "smartMatte":
            s.beginFilter(.removeBackground)
            guard s.filterEdit != nil else { return fail(-5, "remove background could not start") }
            var settings = s.filterEdit?.settings ?? s.filterSettings
            let p = command.parameters ?? [:]
            settings.refineEdges = p["refineEdges"] ?? settings.refineEdges
            settings.matteContrast = p["matteContrast"] ?? settings.matteContrast
            settings.shiftEdge = p["shiftEdge"] ?? settings.shiftEdge
            s.updateFilter(settings, preview: true)
            await s.commitFilter()
        case "selectTool":
            guard let toolName = command.kind ?? command.name,
                  let tool = NavigationTool(rawValue: toolName)
            else { return fail(-1, "unknown tool") }
            let before = s.brushError
            s.selectTool(tool)
            // Upstream keeps the current tool when the switch can't happen (text that can't be finished, a stroke or
            // Levels in progress); say why instead of letting the rail and the session disagree silently.
            guard s.tool == tool else {
                if let message = s.brushError, message != before { return fail(-5, message) }
                return fail(-5, "\(tool.rawValue.capitalized) can't be chosen while \(s.tool.rawValue) work is in progress")
            }
            if let mode = command.name {
                if let k = LassoKind(rawValue: mode) {
                    if tool == .marquee { s.marqueeKind = k }
                    if tool == .lasso { s.lassoKind = k }
                }
                if let w = WandMode(rawValue: mode) { s.wandMode = w }
                if let b = BrushToolMode(rawValue: mode) { s.brushMode = b }
                if let k = ShapeKind(rawValue: mode) { s.shapeKind = k }
                if let blur = BlurToolMode(rawValue: mode) { s.blurMode = blur }
            }
        default:
            return fail(-7, "Unsupported by the upstream bridge yet: \(command.action)")
        }
        error = nil
        return 0
    }

    private func fail(_ code: Int32, _ message: String) -> Int32 { error = message; return code }

    private func importReplacement(_ paths: [String]) async -> Int32 {
        let originalDocument = session.document, originalRevision = session.history.currentRevision
        let originalModified = session.history.isModified, originalGeneration = persistenceGeneration
        let originalURL = session.projectURL
        let staged = EditorSession()
        staged.confirmConversions = session.confirmConversions
        staged.confirmRawDevelop = session.confirmRawDevelop
        replacementImportSession = staged
        session.isProjectBusy = true
        var folders: [URL] = []
        defer {
            for folder in folders { folder.stopAccessingSecurityScopedResource() }
            // A cached RAW sheet can retain the staged session after the modal closes.
            staged.clearProject()
            replacementImportSession = nil
            session.isProjectBusy = false
        }
        ImportPrompts.install(on: staged)
        var files: [URL] = []
        var cameraRawLayer: UUID?
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if ImageFolder.matches(url) {
                if url.startAccessingSecurityScopedResource() { folders.append(url) }
                let images = ImageFolder.images(in: url)
                guard !images.isEmpty else { return fail(-5, "“\(url.lastPathComponent)” has no images to import.") }
                files.append(contentsOf: images)
            } else { files.append(url) }
        }
        for file in files {
            let before = staged.history.currentRevision
            await staged.importImages([file])
            if let message = staged.importError { return fail(-5, message) }
            // Upstream skips a cancelled RAW/Photoshop input. A replacement must abort the entire staged batch.
            guard staged.history.currentRevision != before else { return fail(-7, "cancelled") }
            if staged.filterEdit?.kind == .cameraRaw {
                cameraRawLayer = staged.activeLayerID
                staged.cancelFilter()   // The batch continues; reopen on the installed document after success.
            }
        }
        guard let document = staged.document else { return fail(-7, "cancelled") }
        guard session.document == originalDocument, session.history.currentRevision == originalRevision,
              session.history.isModified == originalModified, persistenceGeneration == originalGeneration,
              session.projectURL == originalURL else {
            return fail(-5, "The project changed during replacement import")
        }
        // Match the original successful replacement's new-document Undo entry, without a partial clear on failure.
        session.cancelGradient()
        nativeProjects.stopWatchingProject()
        session.clearProject()
        session.beginEdit(files.allSatisfy { PSDReader.matches($0) } ? "Import Photoshop File" : "Import Images")
        session.document = document
        session.activeLayerID = staged.activeLayerID
        session.selectedLayerIDs = staged.selectedLayerIDs
        session.collapsedGroupIDs = staged.collapsedGroupIDs
        session.viewport = staged.viewport
        session.endEdit()
        persistenceGeneration = UUID()
        replacementImportSession = nil
        session.isProjectBusy = false
        if let cameraRawLayer, session.document?.layers.contains(where: { $0.id == cameraRawLayer }) == true {
            session.selectLayer(cameraRawLayer)
            session.beginFilter(.cameraRaw)
        }
        error = nil
        return 0
    }

    /// Check immutable arguments and current target preconditions before applying an unrelated pending draft.
    /// Dispatch checks remain necessary because resolving the gradient can suspend and change session state.
    private func refusalBeforeGradient(_ command: Command) -> (code: Int32, message: String)? {
        let s = session
        switch command.action {
        case "selectLayer":
            guard let id = command.layerID else { return (-1, "layerID required") }
            if s.document?.layers.contains(where: { $0.id == id }) != true { return (-5, "no such layer") }
        case "renameLayer":
            if command.name == nil || s.activeLayerID == nil { return (-1, "name required") }
        case "setVisible":
            if command.enabled == nil || s.activeLayer == nil { return (-1, "enabled required") }
        case "setOpacity":
            if command.value?.isFinite != true || s.activeLayer == nil { return (-1, "value required") }
        case "setSelectedOpacity":
            if command.value == nil { return (-1, "value required") }
        case "setBlendMode":
            if command.kind.flatMap(LayerBlendMode.init(rawValue:)) == nil { return (-1, "unknown blend mode") }
        case "setMaskEnabled", "setMaskLinked":
            if command.enabled == nil || s.activeLayer?.mask == nil { return (-1, "no mask") }
        case "moveLayer":
            if command.x?.isFinite != true || command.y?.isFinite != true || s.activeLayer == nil { return (-1, "delta required") }
        case "selectRectangle", "selectEllipse":
            guard s.document != nil else { return (-2, "no document") }
            guard point(command) != nil, let width = command.width, let height = command.height,
                  (0...30_000).contains(width), (0...30_000).contains(height) else { return (-1, "invalid rectangle") }
        case "selectLasso":
            guard s.document != nil else { return (-2, "no document") }
            guard let points = command.points, points.count >= 3 else { return (-1, "lasso needs 3+ points") }
            if !points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) { return (-1, "invalid point") }
        case "shapeBegin", "shapeDrag", "textBegin", "textEditAt", "brushMove", "cloneSetSource", "magicWand", "warpMove":
            if point(command) == nil { return (-1, "invalid point") }
        case "textBeginBox":
            if point(command) == nil || command.width == nil || command.height == nil { return (-1, "invalid box") }
        case "brushBegin":
            if s.document == nil || point(command) == nil { return (-1, "invalid brush start") }
            if command.kind == "Clone", s.cloneSource == nil { return (-5, "no clone source set (send cloneSetSource first)") }
        case "openFilter", "filterBegin":
            if command.kind.flatMap(FilterKind.init(rawValue:)) == nil { return (-1, "unknown filter") }
        case "addAdjustment":
            if command.kind.flatMap(AdjustmentKind.init(rawValue:)) == nil { return (-1, "unknown adjustment") }
        case "beginAdjustmentEditing":
            let id = command.layerID ?? s.activeLayerID
            guard let id, let adjustment = s.document?.layers.first(where: { $0.id == id })?.adjustment else {
                return (-1, "not an adjustment layer")
            }
            if !adjustment.kind.isEditable { return (-1, "adjustment has no editable settings") }
        case "addLayerEffect":
            if command.kind.flatMap(LayerEffectKind.init(rawValue:)) == nil { return (-1, "invalid effect") }
            if s.activeLayer == nil { return (-2, "no layer") }
        case "selectTool":
            if (command.kind ?? command.name).flatMap(NavigationTool.init(rawValue:)) == nil { return (-1, "unknown tool") }
        case "addShape":
            if s.document == nil || command.kind.flatMap(ShapeKind.init(rawValue:)) == nil
                || command.width == nil || command.height == nil || command.x == nil || command.y == nil {
                return (-1, "invalid shape")
            }
        case "warpBegin":
            if command.kind.flatMap(BlurToolMode.init(rawValue:)) == nil || point(command) == nil { return (-1, "invalid warp") }
        case "importFiles":
            if command.paths?.isEmpty != false { return (-1, "paths required") }
        case "exportPNG", "exportPDF":
            if command.paths?.first == nil || s.document == nil { return (-1, "nothing to export") }
            if !s.canStartProjectOperation { return (-3, "The editor is busy; nothing was exported") }
        case "trim", "canvasSizeSheet", "imageSizeSheet", "exportAsSheet":
            if s.document == nil { return (-2, "no document") }
            if !s.canStartProjectOperation { return (-3, "The editor is busy; the project operation did not start") }
        case "resizeCanvas", "cropCanvas", "resizeImage":
            let crop = command.action == "cropCanvas", image = command.action == "resizeImage"
            guard let width = command.width, let height = command.height, s.document != nil else {
                return (-1, crop ? "invalid crop" : "invalid size")
            }
            if image, let kind = command.kind, LayerSampling(rawValue: kind) == nil { return (-1, "unknown sampling") }
            if !crop && !image {
                let anchor = command.parameters?["anchor"] ?? 4
                if !(0...8).contains(anchor) || anchor.rounded() != anchor { return (-1, "invalid anchor") }
            }
            let failure = crop ? "crop failed" : image ? "image resize failed" : "canvas resize failed"
            if !(1...DocumentLimits.maxSide).contains(width) || !(1...DocumentLimits.maxSide).contains(height) {
                return (-5, failure)
            }
            if image {
                let resolution = command.value ?? s.document?.resolution ?? 72
                if !resolution.isFinite || !(1...9600).contains(resolution) { return (-5, failure) }
            }
            if crop {
                let x = command.x ?? 0, y = command.y ?? 0
                if !x.isFinite || !y.isFinite || abs(x) > 1_000_000 || abs(y) > 1_000_000 { return (-5, failure) }
            }
        default: break
        }
        return nil
    }

    private func commitPendingGradient() async -> Int32 {
        let s = session
        guard let pending = s.gradientEdit else { return 0 }
        guard !s.isProjectBusy else { return fail(-5, "The project is busy; the pending gradient has not been applied") }
        if pending.hasLine {
            guard let current = s.document?.layers.first(where: { $0.id == pending.raster.layer.id }),
                  current.asset?.image === pending.raster.layer.asset?.image,
                  current.transform == pending.raster.layer.transform,
                  current.mask?.asset.image === pending.raster.layer.mask?.asset.image else {
                return fail(-5, "The gradient target changed while it was being applied")
            }
        }
        // Upstream reports thrown errors through brushError, and silently discards a commit whose target changed.
        // Await the operation to completion: a timeout would leave a late write running after reporting failure.
        let previousError = s.brushError
        let revision = s.history.currentRevision
        s.brushError = nil
        await s.commitGradient()
        if let message = s.brushError { return fail(-5, message) }
        s.brushError = previousError
        guard s.gradientEdit == nil else {
            return fail(-5, s.gradientEdit === pending ? "The pending gradient has not been applied" : "The gradient changed while it was being applied")
        }
        if pending.hasLine {
            let layer = s.document?.layers.first { $0.id == pending.raster.layer.id }
            let before = pending.raster.isMask ? pending.raster.layer.mask?.asset.image : pending.raster.layer.asset?.image
            let after = pending.raster.isMask ? layer?.mask?.asset.image : layer?.asset?.image
            guard let after, after !== before, s.history.currentRevision != revision else {
                return fail(-5, "The gradient target changed while it was being applied")
            }
        }
        return 0
    }

    /// Commands that leave a pending gradient pending, as their Mac counterparts do: the gradient's own drag and
    /// options, the palette and color picker it previews live, and shell chrome that does not touch the document.
    private static let keepsPendingGradient: Set<String> = [
        "gradientBegin", "gradientMove", "gradientEndDrag", "gradientCommit", "gradientCancel", "setGradientSettings",
        "swapPaletteColors", "resetPaletteColors", "setPaletteColor", "openColorPicker", "setColorPickerColor",
        "closeColorPicker", "sampleColorPicker", "dismissAlert", "closeFloatingPanel", "showKeyboardShortcuts",
        "dismissImporter", "setCanvasOnly", "setShowsTransformControls", "setTransformAutoSelect", "markSaved",
        "markUnsaved", "guideCreate", "guideHit", "guideMove", "guideFinish", "guideCancel", "undo", "redo",
    ]

    /// Why a tool could not start, for the command's error: upstream's own alert text when it raised one, else its
    /// `paintRefusal` (a folder, hidden layer, adjustment layer … , which some tools, like the gradient, decline
    /// silently on the Mac), else the concrete cause the call site knows.
    private func refusal(_ s: EditorSession, before: String?, cause: String) -> String {
        if let message = s.brushError, message != before { return message }
        return s.paintRefusal ?? cause
    }

    private func apply(_ p: [String: Double], to transform: inout LayerTransform) {
        transform.origin.x = p["x"] ?? transform.origin.x
        transform.origin.y = p["y"] ?? transform.origin.y
        transform.size.width = p["width"] ?? transform.size.width
        transform.size.height = p["height"] ?? transform.size.height
        transform.rotation = p["rotation"] ?? transform.rotation
    }

    // MARK: Project persistence (the shell writes the files; the session hands over and takes back layer pixels)

    func importProjectSnapshot(_ snapshot: ProjectSnapshot) -> Int32 {
        do { try LinuxProjectValidation.validate(snapshot.manifest) }
        catch { return fail(-1, error.localizedDescription) }
        guard snapshot.manifest.width * snapshot.manifest.height <= DocumentLimits.maxSurfacePixels,
              snapshot.images.values.allSatisfy({ $0.image.width * $0.image.height <= DocumentLimits.maxSurfacePixels }),
              snapshot.masks.values.allSatisfy({ $0.image.width * $0.image.height <= DocumentLimits.maxSurfacePixels })
        else { return fail(-1, ProjectError.tooLarge.localizedDescription) }
        guard session.canStartProjectOperation else { return fail(-3, "The editor is busy; the project was not imported") }
        nativeProjects.stopWatchingProject()
        session.installProject(snapshot, from: URL(fileURLWithPath: "/dev/null"))
        session.projectURL = nil // Qt owns the document path and save/autosave lifecycle.
        persistenceGeneration = UUID()
        pendingLayerImages = []; pendingLayerMasks = []
        loadingManifest = nil; loadingRevision = nil
        error = nil
        return 0
    }

    func exportManifest() throws -> Data {
        guard let snapshot = session.projectSnapshot() else { throw ExportError.render }
        return try JSONEncoder().encode(snapshot.manifest)
    }

    /// Installs the project's structure; layer images and masks then arrive through `installLayerAsset`.
    func importManifest(_ data: Data) -> Int32 {
        let manifest: ProjectManifest
        do {
            guard data.count <= 4 * 1024 * 1024 else { throw ProjectError.tooLarge }
            manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
            try LinuxProjectValidation.validate(manifest)
            guard manifest.width * manifest.height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
        } catch { return fail(-1, error.localizedDescription) }
        guard session.canStartProjectOperation else { return fail(-3, "The editor is busy; the project was not imported") }
        nativeProjects.stopWatchingProject()
        session.installProject(ProjectSnapshot(manifest: manifest, images: [:]), from: URL(fileURLWithPath: "/dev/null"))
        persistenceGeneration = UUID()
        session.projectURL = nil
        session.history.reset()
        pendingLayerImages = Set(manifest.layers.filter { $0.imageFile != nil }.map(\.id))
        pendingLayerMasks = Set(manifest.layers.filter { $0.maskFile != nil }.map(\.id))
        loadingManifest = pendingLayerImages.isEmpty && pendingLayerMasks.isEmpty ? nil : manifest
        loadingRevision = loadingManifest == nil ? nil : session.history.currentRevision
        error = nil
        return 0
    }

    func layerPixels(id: UUID, mask: Bool) -> PortableImage? {
        guard let layer = session.document?.layers.first(where: { $0.id == id }) else { return nil }
        return (mask ? layer.mask?.asset.image : layer.asset?.image)?.portableImage
    }

    func installLayerAsset(_ pixels: PortableImage, id: UUID, mask: Bool) -> Int32 {
        let s = session
        guard var document = s.document, let index = document.layers.firstIndex(where: { $0.id == id }) else { return fail(-5, "no such layer") }
        guard s.canStartProjectOperation, s.canEditLayers else { return fail(-3, "The editor is busy; the layer asset was not imported") }
        guard let manifest = loadingManifest, manifest.documentID == document.id,
              let record = manifest.layers.first(where: { $0.id == id }),
              mask ? pendingLayerMasks.contains(id) : pendingLayerImages.contains(id)
        else { return fail(-5, "The project has no pending asset for this layer") }
        // Installing load assets resets history. A caller must not erase edits made after staging began.
        guard loadingRevision == s.history.currentRevision, !s.history.isModified, !s.history.canUndo, !s.history.canRedo
        else { return fail(-5, "The project changed during asset loading") }
        let image = CGImage(pixels)
        if mask {
            guard let asset = try? LayerMask.asset(from: image) else { return fail(-1, "invalid mask") }
            document.layers[index].mask = LayerMask(asset: asset, isEnabled: record.maskEnabled ?? true, placement: record.maskPlacement, isLinked: record.maskLinked ?? true)
        } else {
            guard pixels.kind == .rgba, pixels.width > 0, pixels.height > 0, let thumbnail = try? PixelAdjust.thumbnail(of: image) else { return fail(-1, "invalid image") }
            document.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: document.layers[index].name)
            document.layers[index].shape = LayerShape.loaded(record.shape, image: image)
            document.layers[index].text = LayerText.loaded(record.text, image: image)
        }
        s.document = document
        s.history.reset()
        if mask { pendingLayerMasks.remove(id) } else { pendingLayerImages.remove(id) }
        if pendingLayerImages.isEmpty && pendingLayerMasks.isEmpty {
            loadingManifest = nil
            loadingRevision = nil
        } else {
            loadingRevision = s.history.currentRevision
        }
        error = nil
        return 0
    }

    private func point(_ command: Command) -> CGPoint? {
        guard let x = command.x, let y = command.y, x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The command's parameters laid over the settings the edit already has, as the fork's bridge did.
    private func filterSettings(_ command: Command, _ current: FilterSettings) -> FilterSettings {
        let p = command.parameters ?? [:]
        var settings = current
        settings.radius = p["radius"] ?? settings.radius
        settings.preserveTransparency = (p["preserveTransparency"] ?? (settings.preserveTransparency ? 1 : 0)) != 0
        settings.distance = p["distance"] ?? settings.distance
        settings.angle = p["angle"] ?? settings.angle
        settings.amount = p["amount"] ?? settings.amount
        settings.distortion = p["distortion"] ?? settings.distortion
        settings.gaussian = (p["gaussian"] ?? (settings.gaussian ? 1 : 0)) != 0
        settings.monochromatic = (p["monochromatic"] ?? (settings.monochromatic ? 1 : 0)) != 0
        return settings
    }

    private func select(_ path: CGPath, mode: SelectionMode) {
        if mode == .replace { session.setSelection(DocumentSelection(path: path), name: "Select") }
        else { session.applySelection(path, mode: mode, name: "Select") }
    }

    func stateJSON() throws -> Data {
        let s = session
        FloatingPanels.observe(self)
        let active = s.activeLayer
        let state = State(width: s.document?.width ?? 0, height: s.document?.height ?? 0, resolution: s.document?.resolution ?? 72,
            activeLayerID: s.activeLayerID, modified: s.history.isModified, canUndo: s.canUndo, canRedo: s.canRedo,
            undoName: s.history.undoName, redoName: s.history.redoName,
            busy: replacementImportSession != nil || s.isProjectBusy || s.pixelMove != nil
                || s.brushStroke != nil || s.filterEdit != nil || s.transformEdit != nil,
            filterPreviewRendering: s.filterEdit?.previewTask != nil || s.filterEdit?.pending != nil,
            canSwitch: replacementImportSession == nil && s.canStartProjectOperation && s.hueSaturation == nil
                && s.filterEdit == nil && s.gradientEdit == nil && s.pixelMove == nil && s.colorPicker == nil,
            layers: (s.document?.layers ?? []).map { State.Layer(id: $0.id, name: $0.name, visible: $0.isVisible, opacity: $0.opacity,
                blendMode: $0.blendMode.rawValue, parentID: $0.parentID, isGroup: $0.isGroup, hasMask: $0.mask != nil,
                maskEnabled: $0.mask?.isEnabled, maskLinked: $0.mask?.isLinked, maskPlacement: $0.mask?.placement,
                transform: s.displayedTransform(for: $0)) }, error: error,
            hasSelection: s.selection != nil,
            canTransformSelection: s.canTransformSelection,
            showsTransformControls: s.showsTransformControls,
            transformAutoSelect: s.transformAutoSelect,
            transforming: s.transformEdit != nil,
            transformPending: s.transformEdit?.persistent == true,
            isMaskSelected: s.isMaskSelected,
            viewsMaskAlone: s.viewsMaskAlone,
            activeLayerIsVisible: active?.isVisible ?? true,
            activeLayerIsGroup: active?.isGroup ?? false,
            activeLayerHasMask: active?.mask != nil,
            activeLayerHasParent: active?.parentID != nil,
            activeLayerIsClipped: active?.maskSourceID != nil,
            canToggleClippingMask: s.activeLayerID.map { s.canToggleClippingMask($0) } ?? false,
            canUngroupLayers: s.canUngroupLayers,
            canMergeLayers: s.canMergeLayers,
            mergeTitle: s.mergeTitle,
            brushError: s.brushError,
            canMoveActiveLayerUp: s.canMoveActiveLayer(by: 1),
            canMoveActiveLayerDown: s.canMoveActiveLayer(by: -1),
            tool: s.tool.rawValue,
            selectionMode: s.displayedSelectionMode.rawValue,
            lassoKind: s.lassoKind.rawValue,
            marqueeKind: s.marqueeKind.rawValue,
            foregroundColor: rgb(s.paletteColor(background: false)),
            backgroundColor: rgb(s.paletteColor(background: true)),
            brushDiameter: Double(s.brushSettings.diameter),
            brushHardness: Double(s.brushSettings.hardness),
            brushOpacity: Double(s.brushSettings.opacity),
            brushSmoothing: Double(s.brushSettings.smoothing),
            blurRadius: Double(s.brushSettings.blurRadius),
            blurMode: s.blurMode.rawValue,
            colorPickerTitle: s.colorPicker?.target.title,
            colorPickerColor: s.colorPicker.map { rgb($0.color) },
            gradientLine: s.gradientEdit.map { [Double($0.start.x), Double($0.start.y), Double($0.end.x), Double($0.end.y)] },
            shapeKind: s.shapeDraft.map { $0.kind.rawValue },
            shapeRect: s.shapeDraft.map { [Double($0.rect.minX), Double($0.rect.minY), Double($0.rect.width), Double($0.rect.height)] },
            shapeLine: s.shapeLineEnds.map { [Double($0.start.x), Double($0.start.y), Double($0.end.x), Double($0.end.y)] },
            cropRect: s.cropRect.map { [Double($0.origin.x), Double($0.origin.y), Double($0.size.width), Double($0.size.height)] },
            colorRange: s.colorRange.map { State.ColorRangeState(working: $0.isWorking, generation: $0.generation,
                hasColors: $0.hasColors, sampleMode: $0.effectiveMode.rawValue, error: $0.error) },
            textDraft: s.textDraft.map { draft in
                let style = draft.style
                return State.TextDraftState(id: draft.id, selectionLocation: draft.selection.location,
                    selectionLength: draft.selection.length, colorRuns: style.colorRuns,
                    fontRuns: style.fontRuns, tracking: Double(style.tracking), leading: Double(style.leading),
                    origin: [Double(draft.origin.x), Double(draft.origin.y)],
                    size: draft.transform.map { [Double($0.size.width), Double($0.size.height)] },
                    rotation: Double(draft.transform?.rotation ?? 0), content: style.content, fontName: style.fontName,
                    fontSize: Double(style.fontSize), color: [Double(style.red), Double(style.green), Double(style.blue)],
                    alignment: style.alignment.rawValue, boxSize: style.boxSize.map { [Double($0.width), Double($0.height)] },
                    padding: Double(LayerTextStyle.padding), editingLayer: draft.layerID != nil)
            },
            rawDevelopOpen: importSession.showsRawDevelop,
            conversionSheetOpen: importSession.showsConversionSheet,
            floatingPanels: FloatingPanels.open(in: self),
            showsImporter: s.showsImporter,
            openProjectRequested: openProjectRequested,
            showsRulers: s.showsRulers, showsGrid: s.showsGrid, showsPixelGrid: s.showsPixelGrid,
            proofsColors: s.proofsColors, showsGamutWarning: s.showsGamutWarning,
            proofProfileName: s.proofProfile?.name ?? "", showsGuides: s.showsGuides,
            guides: s.displayedGuides.map { State.GuideState(vertical: $0.axis == .vertical, position: $0.position) },
            guideDragging: s.guideDrag != nil, canEditGuides: s.canEditGuides,
            snapLines: [s.snapGuides.xs.map { Double($0) }, s.snapGuides.ys.map { Double($0) }],
            sheets: openSheets,
            exportFormat: pendingExport?.format.rawValue,
            canvasOnly: s.canvasOnly,
            canToggleCanvasOnly: s.canToggleCanvasOnly,
            escapeHasNothingToCancel: s.escapeHasNothingToCancel,
            zoom: Double(s.viewport.zoom),
            alert: s.brushError.map { State.AlertState(kind: "brush", title: "Couldn’t paint", message: $0) }
                ?? s.cropError.map { State.AlertState(kind: "crop", title: "Couldn’t crop", message: $0) },
            distortCorners: s.transformEdit?.corners.map { $0.map { [Double($0.x), Double($0.y)] } },
            shortcuts: [])
        // Sorted keys: the same state must encode to the same bytes, or the shell's pump sees a change on every tick
        // (dictionary order varies) and refreshes the whole window at 60 Hz.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var json = try encoder.encode(state)
        // The shortcut catalog is most of the state and changes only when a shortcut is edited: its encoded bytes are
        // reused while the chords match, and spliced in where the empty array was encoded.
        let shortcuts = ShortcutDefinition.all.map { definition in
            let chord = ShortcutSettings.shared.chord(definition)
            return State.ShortcutState(title: definition.title, group: definition.group, key: chord.key, modifiers: chord.modifiers,
                                       originalKey: definition.original.key, originalModifiers: definition.original.modifiers)
        }
        if Self.encodedShortcuts?.states != shortcuts { Self.encodedShortcuts = (shortcuts, try encoder.encode(shortcuts)) }
        let empty = Data(#""shortcuts":[]"#.utf8)
        if let range = json.range(of: empty), let encoded = Self.encodedShortcuts?.json {
            json.replaceSubrange(range, with: Data(#""shortcuts":"#.utf8) + encoded)
        }
        return json
    }
    private static var encodedShortcuts: (states: [State.ShortcutState], json: Data)?

    /// Adds premultiplied RGBA8 pixels as a layer (`replacing`: as a new one-layer document of that size, history cleared).
    func importRGBA(_ pixels: [UInt8], width: Int, height: Int, name: String, replacing: Bool) -> Int32 {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height), width * height <= DocumentLimits.maxSurfacePixels,
              pixels.count == width * height * 4, !name.isEmpty else { return fail(-1, "invalid image") }
        // Validate the canonical contract before any C pixel kernel can see it.
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i] > pixels[i + 3] || pixels[i + 1] > pixels[i + 3] || pixels[i + 2] > pixels[i + 3] {
            return fail(-1, "pixels are not premultiplied")
        }
        guard session.canStartProjectOperation else { return fail(-3, "The editor is busy; the image was not imported") }
        let image = CGImage(PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: width * 4, bytes: pixels))
        guard let thumbnail = try? PixelAdjust.thumbnail(of: image) else { return fail(-5, "thumbnail failed") }
        let asset = ImportedImage(image: image, thumbnail: thumbnail, name: name)
        let s = session
        if replacing || s.document == nil {
            nativeProjects.stopWatchingProject()
            s.projectURL = nil
            persistenceGeneration = UUID()
            let layer = ImageLayer(asset: asset, origin: .zero)
            s.document = CanvasDocument(width: width, height: height, layers: [layer])
            s.activeLayerID = layer.id
            s.history.reset()
        } else {
            s.insert(asset)
        }
        error = nil
        return 0
    }

    /// The project as the canvas shows it right now: pending transforms applied, live filter/levels/hue-saturation
    /// previews standing in for the layer they preview, and an in-progress brush stroke's touched tiles composited
    /// in (all the way upstream's own canvas draws them: `EditorCanvas.swift` calls this same `BrushStroke.paintSnapshot()`
    /// for its live paint, we just call it from here instead of an NSView draw pass).
    ///
    /// `strokeRegion` (document coordinates): only that part of the document will be drawn (a mid-stroke frame), so
    /// the stroke's layer is built for that region alone — the way EditorCanvas draws just the touched tiles — rather
    /// than the whole painted layer, its bounds scan and its thumbnail, every frame.
    func displayedSnapshot(strokeRegion: CGRect? = nil) -> ProjectSnapshot? {
        let s = session
        guard var snapshot = s.projectSnapshot(), let document = s.document else { return nil }
        var images = snapshot.images
        var masks = snapshot.masks
        var manifest = snapshot.manifest
        // EditorCanvas.applyFill() before drawing a pending gradient; without it paintSnapshot() is still the blank
        // raster and the Qt canvas shows no fade until Apply (commitGradient) fills it.
        if let edit = s.gradientEdit { try? edit.applyFill() }
        // Likewise a pixel move: upstream rebuilds the moved tiles only when something reads them (EditorCanvas does
        // before drawing), so without this the shell keeps showing the pixels where the drag began.
        if let move = s.pixelMove { try? move.applyOffset() }
        // A pending gradient previews through its own raster edit, drawn in place of the layer as a stroke is
        // (EditorCanvas draws `gradientEdit?.raster` the same way).
        let stroke = s.brushStroke ?? s.gradientEdit?.raster ?? s.pixelMove?.raster
        for (index, layer) in document.layers.enumerated() {
            var shown = s.displayedTransform(for: layer)
            var maskPlacement = s.displayedMaskPlacement(for: layer)
            let preview = s.filterEdit?.previewImage(for: layer.id) ?? s.levels?.previewImage(for: layer.id)
                ?? s.hueSaturation?.previewImage(for: layer.id)
            if let preview, let asset = layer.asset {
                images[layer.id] = ImportedImage(image: preview, thumbnail: asset.thumbnail, name: asset.name)
            } else if let warp = s.warpStroke, warp.layer.id == layer.id {
                // CanvasView draws the working warp in document coordinates. Show the same pixels here;
                // otherwise the cached Qt canvas stays frozen until finishWarp commits the layer.
                // Crop from the working buffer: warping then `makeImage()` of the whole canvas every
                // mid-stroke frame was the liquify/smear live-feedback regression (often >150 ms).
                let canvas = CGRect(origin: .zero, size: document.size)
                let crop = strokeRegion.map { $0.integral.insetBy(dx: -2, dy: -2).intersection(canvas) } ?? canvas
                if !crop.isNull, !crop.isEmpty, let cropped = warp.snapshot(in: crop) {
                    images[layer.id] = ImportedImage(image: cropped, thumbnail: cropped, name: layer.name)
                    shown = LayerTransform(origin: crop.origin, size: crop.size)
                    // A linked mask still covers the original layer placement, not the preview's cropped rect.
                    if layer.mask != nil { maskPlacement = layer.maskTransform }
                }
            } else if let stroke, stroke.layer.id == layer.id, !stroke.isMask, let strokeRegion,
                      let painted = Self.paintRegion(of: stroke, in: strokeRegion) {
                images[layer.id] = painted.asset
                shown = painted.transform
                if layer.mask != nil { maskPlacement = maskPlacement ?? layer.transform }
            } else if let stroke, stroke.layer.id == layer.id, !stroke.isMask, let painted = try? stroke.paintSnapshot() {
                // A stroke can grow the layer's painted bounds beyond its committed transform (a brush dab
                // outside the current edges); paintSnapshot() reports the new transform for exactly that,
                // the same value BrushCommit.Input.sourceRect/transform would carry at commit time.
                images[layer.id] = painted.asset
                shown = painted.transform
                if layer.mask != nil { maskPlacement = maskPlacement ?? layer.transform }
            } else if let distorted = s.distortPreview(for: layer), let asset = layer.asset {
                // A pending distortion shows the layer warped into its new shape (EditorCanvas draws distortPreview).
                images[layer.id] = ImportedImage(image: distorted.image, thumbnail: asset.thumbnail, name: asset.name)
                if let mask = distorted.mask { masks[layer.id] = ImportedImage(image: mask, thumbnail: asset.thumbnail, name: asset.name) }
                shown = distorted.transform
            } else if let stroke, stroke.layer.id == layer.id, stroke.isMask, let painted = try? stroke.paintSnapshot() {
                // Mask strokes are placed in the mask's own pixel grid (maskPlacement), not the layer transform.
                masks[layer.id] = painted.asset
            }
            // Text being edited is drawn by the shell's inline editor, not from the layer (EditorCanvas skips it too).
            let editing = s.textDraft?.layerID == layer.id
            let blendMode = s.displayedBlendMode(for: layer)
            if shown != layer.transform || maskPlacement != layer.mask?.placement || editing || blendMode != layer.blendMode {
                let record = manifest.layers[index]
                manifest.layers[index] = ProjectLayerRecord(id: record.id, name: record.name, isVisible: record.isVisible && !editing, transform: shown,
                    imageFile: record.imageFile, parentID: record.parentID, isGroup: record.isGroup, opacity: record.opacity,
                    blendMode: blendMode, maskFile: record.maskFile, maskEnabled: record.maskEnabled, maskSourceID: record.maskSourceID,
                    adjustment: record.adjustment, maskPlacement: maskPlacement, maskLinked: record.maskLinked,
                    shape: record.shape, effects: record.effects, text: record.text)
            }
        }
        // The shape being dragged out, in the color it will be made in, just above the active layer — where its layer
        // will go (EditorCanvas.drawShapeDraft, drawn inside the layer stack for the same reason).
        if let draft = shapeDraftLayer() {
            images[draft.record.id] = draft.asset
            let above = manifest.layers.firstIndex { $0.id == s.activeLayerID }.map { $0 + 1 } ?? manifest.layers.count
            manifest.layers.insert(draft.record, at: above)
        }
        snapshot = ProjectSnapshot(manifest: manifest, images: images, masks: masks)
        return snapshot
    }

    /// The Shape tool's draft as a layer the size of what it covers (document pixels), filled — or, for a line,
    /// stroked round-capped at the line width — with the foreground color.
    private func shapeDraftLayer() -> (record: ProjectLayerRecord, asset: ImportedImage)? {
        let s = session
        guard let draft = s.shapeDraft,
              draft.kind == .line ? (draft.rect.width > 0 || draft.rect.height > 0) : !draft.rect.isEmpty else { return nil }
        let color = s.foregroundColor.nsColor.cgColor
        var bounds = draft.rect
        let ends = s.shapeLineEnds
        if draft.kind == .line {
            guard ends != nil else { return nil }
            let half = max(1, CGFloat(s.shapeLineWidth)) / 2 + 1
            bounds = bounds.insetBy(dx: -half, dy: -half)
        }
        bounds = bounds.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0, width * height <= DocumentLimits.maxSurfacePixels else { return nil }
        let context = CGContext(width: width, height: height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        if draft.kind == .line, let ends {
            context.setStrokeColor(color)
            context.setLineWidth(max(1, CGFloat(s.shapeLineWidth)))
            context.setLineCap(.round)
            context.move(to: ends.start)
            context.addLine(to: ends.end)
            context.strokePath()
        } else {
            context.setFillColor(color)
            context.addPath(draft.kind.path(in: draft.rect, cornerRadius: draft.cornerRadius, smoothing: draft.smoothing))
            context.fillPath()
        }
        guard let image = context.makeImage() else { return nil }
        let id = UUID()
        let parent = s.activeLayer?.parentID
        let record = ProjectLayerRecord(id: id, name: "Shape", isVisible: true,
            transform: LayerTransform(origin: bounds.origin, size: bounds.size), imageFile: "\(id.uuidString).png", parentID: parent)
        return (record, ImportedImage(image: image, thumbnail: image, name: "Shape"))
    }

    /// Lets upstream's background work (a filter preview being prepared on a task) finish before a frame is read, by
    /// pumping the main run loop from the shell's plain callback. Bounded, so a stuck preview cannot hang the shell.
    func settle(timeout: TimeInterval = 3) {
        func waiting() -> Bool {
            // Adjustment editors render their settings through the layer composite; they
            // never start a preview task or fill preparedPreview. Waiting for that image
            // exhausted the timeout on every revision check and frame read.
            if let edit = session.filterEdit, edit.preview, edit.previewTask != nil,
               edit.preparedPreview == nil, edit.previewError == nil { return true }
            if let edit = session.levels, edit.preview, edit.previewTask != nil, edit.preparedPreview == nil { return true }
            return false
        }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while waiting(), Date() < deadline { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
    }

    /// Just `region` (document pixels, clamped to the canvas) of what `renderRGBA` returns, as premultiplied RGBA8 of the
    /// clamped region's size — the Linux counterpart of `EditorCanvas` redrawing only `BrushStroke.dirtyDocumentRect` on
    /// macOS. Upstream's exporter renders a whole manifest, so the region is expressed as a manifest: a canvas the
    /// region's size with every document-space placement (layer transforms, detached mask placements) shifted by
    /// the region's origin. Everything else — effects, masks, adjustments, blend modes — is the exporter's own code.
    /// `region` of the document at `scale` (display resolution: a 150 MP document fitted to a window is composited at a
    /// fraction of its pixels). Every placement is scaled with the canvas; the exporter then draws the layer images
    /// scaled, touching only output pixels. Returns the scaled bytes and the document rect they cover.
    /// The stroke's layer as painted so far, inside `region` (document coordinates) only: its original pixels with the
    /// stroke's tiles over them, cropped to the layer pixels that region covers (plus a pixel of margin for filtering).
    static func paintRegion(of stroke: BrushStroke, in region: CGRect) -> (asset: ImportedImage, transform: LayerTransform)? {
        let bounds = CGRect(x: 0, y: 0, width: stroke.width, height: stroke.height)
        let crop = region.applying(stroke.pixelToDocument.inverted()).integral.insetBy(dx: -2, dy: -2).intersection(bounds)
        guard !crop.isNull, !crop.isEmpty else { return nil }
        let raster = RasterSnapshot.replacing(source: stroke.layer.asset, sourceRect: stroke.sourceRect, patches: stroke.patches, crop: crop)
        guard let image = try? raster.makeImage() else { return nil }
        return (ImportedImage(image: image, thumbnail: image, name: stroke.layer.name, raster: raster), stroke.transform(for: crop))
    }

    func renderRegionRGBA(_ region: CGRect, scale: CGFloat = 1) throws -> (bytes: [UInt8], rect: CGRect, width: Int, height: Int) {
        let prepared = try regionSnapshot(region, scale: scale)
        let raster = try exportRGBA(prepared.snapshot, scale: prepared.scale)
        let crop = prepared.crop
        let width = Int(crop.width), height = Int(crop.height)
        if crop == CGRect(x: 0, y: 0, width: raster.width, height: raster.height) {
            return (raster.bytes, prepared.rect, width, height)
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in Int(crop.minY)..<Int(crop.maxY) {
            let start = (y * raster.width + Int(crop.minX)) * 4
            bytes.append(contentsOf: raster.bytes[start..<start + width * 4])
        }
        return (bytes, prepared.rect, width, height)
    }

    /// Stacked blurs can sample through one another, so add their supports. The
    /// canvas bounds cap the eventual allocation, including for deeply nested stacks.
    var spatialAdjustmentMargin: CGFloat {
        guard let document = session.document else { return 0 }
        let visible = document.effectiveVisibleIDs
        return document.layers.filter { visible.contains($0.id) }.reduce(0) { $0 + ($1.adjustment?.samplingMargin ?? 0) }
    }

    /// The snapshot `renderRegionRGBA` renders: taken on the main actor (it reads the session), rendered anywhere.
    func regionSnapshot(_ region: CGRect, scale: CGFloat = 1) throws -> (snapshot: ProjectSnapshot, rect: CGRect, scale: CGFloat, crop: CGRect) {
        settle()
        guard scale.isFinite, let document = session.document else { throw ExportError.render }
        let canvas = CGRect(origin: .zero, size: document.size)
        let rect = region.integral.intersection(canvas)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { throw ExportError.render }
        let k = min(1, max(1.0 / 64, scale))
        // Align partial draws to the full preview's pixel grid. Otherwise a crop
        // starting at an odd document pixel changes the downsampling phase.
        let output = CGRect(x: floor(rect.minX * k), y: floor(rect.minY * k),
                            width: ceil(rect.maxX * k) - floor(rect.minX * k),
                            height: ceil(rect.maxY * k) - floor(rect.minY * k))
        let outputCanvas = CGRect(x: 0, y: 0, width: ceil(canvas.width * k), height: ceil(canvas.height * k))
        let margin = spatialAdjustmentMargin
        let padding = margin > 0 ? ceil(min(margin, max(canvas.width, canvas.height)) * k) + 2 : 0
        let sampled = output.insetBy(dx: -padding, dy: -padding).intersection(outputCanvas)
        let sampledDocument = CGRect(x: sampled.minX / k, y: sampled.minY / k,
                                     width: sampled.width / k, height: sampled.height / k)
        guard let snapshot = displayedSnapshot(strokeRegion: sampledDocument) else { throw ExportError.render }
        func shifted(_ t: LayerTransform) -> LayerTransform {
            var moved = t
            moved.origin = CGPoint(x: (t.origin.x - sampledDocument.minX) * k, y: (t.origin.y - sampledDocument.minY) * k)
            moved.size = CGSize(width: t.size.width * k, height: t.size.height * k)
            return moved
        }
        let outW = Int(sampled.width), outH = Int(sampled.height)
        let m = snapshot.manifest
        let layers = m.layers.map { r in
            ProjectLayerRecord(id: r.id, name: r.name, isVisible: r.isVisible, transform: shifted(r.transform),
                imageFile: r.imageFile, parentID: r.parentID, isGroup: r.isGroup, opacity: r.opacity,
                blendMode: r.blendMode, maskFile: r.maskFile, maskEnabled: r.maskEnabled, maskSourceID: r.maskSourceID,
                adjustment: r.adjustment, maskPlacement: r.maskPlacement.map(shifted), maskLinked: r.maskLinked,
                shape: r.shape, effects: r.effects, text: r.text)
        }
        let manifest = ProjectManifest(format: m.format, version: m.version, colorSpace: m.colorSpace, resolution: m.resolution,
            documentID: m.documentID, width: outW, height: outH, activeLayerID: m.activeLayerID,
            layers: layers, guides: m.guides)
        let outputDocument = CGRect(x: output.minX / k, y: output.minY / k,
                                    width: output.width / k, height: output.height / k).intersection(canvas)
        return (ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks), outputDocument, k,
                output.offsetBy(dx: -sampled.minX, dy: -sampled.minY))
    }

    /// Renders a snapshot off the main thread (upstream's exporter actor), as premultiplied RGBA8.
    nonisolated static func renderInBackground(_ snapshot: ProjectSnapshot, scale: CGFloat = 1) async throws -> (bytes: [UInt8], width: Int, height: Int) {
        let image = try await ImageExporter.shared.renderPreview(snapshot, scale: scale).image
        return try rgbaBytes(of: image)
    }

    nonisolated static func rgbaBytes(of image: CGImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        return (Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)),
                image.width, image.height)
    }

    /// Everything the composite depends on, compared by identity for pixels (an image replaced is a new object) — the
    /// same ingredients as upstream's `EditorCanvas.DisplayState` (private there), which decides when the macOS canvas
    /// redraws, plus the live previews `displayedSnapshot` shows. Equal keys mean an identical render, so a panel
    /// action that changes no pixels (a brush setting, a tool, a menu) doesn't re-composite the document.
    struct RenderKey: Equatable {
        struct Layer: Equatable {
            let id: UUID
            let transform: LayerTransform
            let image: ObjectIdentifier?
            let mask: ObjectIdentifier?
            let maskEnabled: Bool
            let maskSourceID: UUID?
            let parentID: UUID?
            let isGroup: Bool
            let visible: Bool
            let opacity: Double
            let blendMode: LayerBlendMode
            let adjustment: LayerAdjustment?
            let effects: LayerEffects?
            let maskPlacement: LayerTransform?
            let preview: ObjectIdentifier?
        }
        let documentID: UUID?
        let size: CGSize?
        let brushRevision: Int
        let layers: [Layer]
        /// A distortion moves corners without changing the ordinary layer transform or source image.
        let distortionCorners: [CGPoint]?
        let editingTextLayer: UUID?
        /// The Shape tool's draft and the color it previews in (it is part of the composite, as on the Mac).
        let shapeDraft: ShapeDraft?
        let shapeColor: PaletteColor
        let shapeLineWidth: Double
    }

    func renderKey() -> RenderKey {
        let s = session
        let document = s.document
        let visible = document?.effectiveVisibleIDs ?? []
        let opacities = document?.effectiveOpacities ?? [:]
        let layers = (document?.layers ?? []).map { layer -> RenderKey.Layer in
            let preview = s.filterEdit?.previewImage(for: layer.id) ?? s.levels?.previewImage(for: layer.id)
                ?? s.hueSaturation?.previewImage(for: layer.id)
            return RenderKey.Layer(id: layer.id, transform: s.displayedTransform(for: layer),
                image: layer.asset.map { ObjectIdentifier($0.image) }, mask: layer.mask.map { ObjectIdentifier($0.asset.image) },
                maskEnabled: layer.mask?.isEnabled ?? false,
                maskSourceID: layer.maskSourceID, parentID: layer.parentID, isGroup: layer.isGroup,
                visible: visible.contains(layer.id), opacity: opacities[layer.id] ?? layer.opacity,
                blendMode: s.displayedBlendMode(for: layer), adjustment: layer.adjustment, effects: layer.effects,
                maskPlacement: s.displayedMaskPlacement(for: layer), preview: preview.map { ObjectIdentifier($0) })
        }
        return RenderKey(documentID: document?.id, size: document?.size, brushRevision: s.brushRevision, layers: layers,
                         distortionCorners: s.transformEdit?.corners, editingTextLayer: s.textDraft?.layerID,
                         shapeDraft: s.shapeDraft, shapeColor: s.foregroundColor,
                         shapeLineWidth: Double(s.shapeLineWidth))
    }

    /// View › CMYK › Proof Colors / Gamut Warning on the canvas: the displayed pixels (premultiplied RGBA8, top row
    /// first) on white paper through the proof profile, as upstream's canvas draws them (`EditorCanvas.gpuFrame`). Only
    /// what the canvas shows: the document, exports and copies keep their own colors. False when neither is on (or no
    /// profile is chosen), leaving `bytes` as they are.
    func proofForDisplay(_ bytes: inout [UInt8], width: Int, height: Int) -> Bool {
        let s = session
        guard s.proofsColors || s.showsGamutWarning, let profile = s.proofProfile, let lookups = CMYK.proofLookups(profile),
              width > 0, height > 0, bytes.count >= width * height * 4,
              let context = try? BrushRaster.context(width: width, height: height, mask: false), let data = context.data
        else { return false }
        bytes.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: width * height * 4) }
        guard let image = context.makeImage() else { return false }
        let lookup = s.proofsColors ? s.showsGamutWarning ? lookups.warning : lookups.proof : lookups.marked
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let proofed = CIImage(cgImage: image).composited(over: CIImage(color: .white).cropped(to: rect))
            .applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": CMYK.dimension,
                "inputCubeData": lookup,
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            ])
        guard let output = CIContext().createCGImage(proofed, from: rect),
              let raster = try? Self.rgbaBytes(of: output), raster.width == width, raster.height == height else { return false }
        bytes.replaceSubrange(0..<(width * height * 4), with: raster.bytes)
        return true
    }

    /// The composite as premultiplied RGBA8 (document size), from upstream's own exporter.
    func renderRGBA() throws -> (bytes: [UInt8], width: Int, height: Int) {
        settle()
        guard let snapshot = displayedSnapshot() else { throw ExportError.render }
        return try exportRGBA(snapshot)
    }

    private func exportRGBA(_ snapshot: ProjectSnapshot, scale: CGFloat = 1) throws -> (bytes: [UInt8], width: Int, height: Int) {
        // The exporter is an actor that never needs the main thread, so this blocks the caller on a plain semaphore:
        // safe from a Qt callback and from a main-actor test alike (pumping the main run loop would deadlock in the latter).
        nonisolated(unsafe) var outcome: Result<ExportRaster, Error>?
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let captured = snapshot
        Task.detached {
            do { outcome = .success(try await ImageExporter.shared.renderPreview(captured, scale: scale)) } catch { outcome = .failure(error) }
            done.signal()
        }
        done.wait()
        guard let raster = outcome else { throw ExportError.render }
        return try Self.rgbaBytes(of: try raster.get().image)
    }

    /// Tip `canPaint` / `canEditPixels` refuse Cut and Clear when the Layers panel has several selected.
    /// Clear every selected pixel layer inside the marquee (one undo), then put the multi-selection back.
    private static func clearThroughSelectedLayers(_ s: EditorSession) async {
        guard s.selection != nil, let document = s.document else { return }
        let selected = s.selectedLayerIDs
        let primary = s.activeLayerID
        let targets = document.layers.filter {
            selected.contains($0.id) && !$0.isGroup && $0.asset != nil
                && document.effectiveVisibleIDs.contains($0.id) && $0.adjustment == nil
        }
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            await withSingleLayerSelection(s) { await s.clearSelectedPixels() }
            return
        }
        // Nest tip clears so one Undo restores every layer.
        s.beginEdit("Clear")
        defer {
            s.endEdit()
            if let primary { s.selectLayers(selected, primary: primary) }
            else { s.selectLayers(selected, primary: targets.last?.id) }
        }
        for layer in targets {
            s.selectLayers([layer.id], primary: layer.id)
            await s.clearSelectedPixels()
        }
    }

    /// Cut through every selected pixel layer: clipboard gets the merged selection, then Clear as above.
    private static func cutThroughSelectedLayers(_ s: EditorSession) async {
        guard s.selection != nil else { return }
        let selected = s.selectedLayerIDs
        if selected.count <= 1 {
            await withSingleLayerSelection(s) { await s.cutSelection() }
            return
        }
        // Clipboard matches what the marquee shows across the stack.
        if s.canCopyMerged { s.copyMergedSelection() }
        else { await withSingleLayerSelection(s) { s.copySelection() } }
        await clearThroughSelectedLayers(s)
    }

    /// Tip `canPaint` refuses some edits when several layers are selected; collapse to the active layer for the body.
    private static func withSingleLayerSelection(_ s: EditorSession, _ body: () async -> Void) async {
        let selected = s.selectedLayerIDs
        let primary = s.activeLayerID
        if selected.count > 1, let primary {
            s.selectLayers([primary], primary: primary)
        }
        await body()
        if selected.count > 1, let primary {
            s.selectLayers(selected, primary: primary)
        }
    }
}
