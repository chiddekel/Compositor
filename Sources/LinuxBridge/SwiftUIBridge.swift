// SwiftUIBridge.swift — the C ABI (`compositor_session_render_tree`) the Qt host calls to get a resolved
// `Compositor/UI` panel as JSON, so it can build real Qt widgets generically instead of hand-mirroring each panel.
// Same conventions as SessionABI.swift: opaque session handles, JSON-blob-with-size-query for structured data.

import Foundation
import Observation
import SwiftUI
import AppKit

/// A positive width updates the native dock; zero reads its saved, clamped width. Geometry is UI state, not an edit.
@_cdecl("compositor_session_layers_panel_width")
nonisolated public func compositorSessionLayersPanelWidth(_ handle: UInt64, _ width: Double) -> Double {
    onMain {
        guard let entry = Sessions.entries[handle] else { return 0 }
        let previous = entry.layersPanelWidth
        let value = updateLayersPanelWidth(width, entry: entry)
        if value != previous, pendingTree?.handle == handle, pendingTree?.panel == "LayersPanel" { pendingTree = nil }
        return value
    }
}

@MainActor func updateLayersPanelWidth(_ width: Double, entry: Entry) -> Double {
    if width.isFinite, width > 0 {
        let value = min(LayersPanel.widths.upperBound, max(LayersPanel.widths.lowerBound, width))
        if entry.layersPanelWidth != value {
            entry.layersPanelWidth = value
            UserDefaults.standard.set(value, forKey: "layersPanelWidth")
            DirtyPanels.mark(.init(entry: entry.renderScopeID, panel: "LayersPanel"))
        }
    }
    return entry.layersPanelWidth
}

/// Resolves the named panel against `entry`'s session into a wire-ready tree, and refreshes `entry`'s action-handler
/// registry for it so a later Qt-side interaction can dispatch back to the right closure by node id.
@MainActor func resolvePanel(_ panel: String, entry: Entry) -> RenderNodeWire? {
    let scope = entry.panelScope(panel)
    if !panel.hasPrefix("NativeWindow:") { entry.editor.nativePanelScopes.insert(scope) }
    entry.renderedPanels.insert(panel)
    // .onAppear / .onChange actions run after a resolve and usually change the @State it was built from (a field
    // seeding its text on appear); SwiftUI would render again, so resolve again until the tree settles.
    var wire: RenderNodeWire?
    for _ in 0..<3 {
        guard StateStore.begin(scope: scope) else { return nil }
        // As SwiftUI does: whatever observable state the body read, a change to it invalidates the panel — the shell
        // re-fetches just the panels that changed (compositor_session_dirty_panels) instead of polling them all.
        DirtyPanels.clear(entry, panel)
        let key = DirtyPanels.Key(entry: entry.renderScopeID, panel: panel)
        // The shell draws the tree itself: NSViewRepresentables resolve to what their AppKit views show.
        NativeLowering.isActive = true
        let node = withObservationTracking { resolvePanelTree(panel, entry: entry) } onChange: { DirtyPanels.mark(key) }
        NativeLowering.isActive = false
        StateStore.end()
        guard var node else {
            StateStore.discard(scope: scope)
            ChangeTracker.discard(scope: scope)
            NativeLowering.discard(scope: scope)
            entry.actionHandlers.removeValue(forKey: panel)
            entry.resultHandlers.removeValue(forKey: panel)
            entry.renderedPanels.remove(panel)
            return nil
        }
        node.assignIDs()
        // .onChange / .task(id:) observers, compared with this panel's previous resolve (SwiftUI semantics).
        ChangeTracker.process(scope: scope, root: node)
        var handlers: [String: [String: (Any) -> Void]] = [:]
        node.collectHandlers(into: &handlers)
        entry.actionHandlers[panel] = handlers
        var resultHandlers: [String: [String: (Any) -> Int32]] = [:]
        node.collectResultHandlers(into: &resultHandlers)
        entry.resultHandlers[panel] = resultHandlers
        wire = node.wire()
        if ChangeTracker.lastActionCount == 0 { break }
    }
    // A GeometryReader reported a new size: whoever fetched this resolve may rebuild only that reader, so tell the
    // shell the whole panel changed (it rebuilds only if the tree's bytes differ).
    if GeometrySizes.takeChanged(scope) { DirtyPanels.mark(DirtyPanels.Key(entry: entry.renderScopeID, panel: panel)) }
    return wire
}

/// Closing one handle releases only its hosted views and observers, including handles sharing a document.
@MainActor func discardRenderedPanels(_ handle: UInt64, entry: Entry) {
    DirtyPanels.discard(entry.renderScopeID)
    for panel in entry.renderedPanels {
        let scope = entry.panelScope(panel)
        ChangeTracker.discard(scope: scope)
        StateStore.discard(scope: scope)
        NativeLowering.discard(scope: scope)
    }
    entry.renderedPanels.removeAll()
    entry.actionHandlers.removeAll()
    entry.resultHandlers.removeAll()
    entry.rawDevelopSheet = nil
    if pendingTree?.handle == handle { pendingTree = nil }
    if pendingAccessibility?.handle == handle { pendingAccessibility = nil }
}

@_cdecl("compositor_session_dispatch_swiftui_drop_event")
nonisolated public func compositorSessionDispatchSwiftUIDropEvent(_ handle: UInt64, _ panel: UnsafePointer<CChar>?,
                                                                   _ nodeID: UnsafePointer<CChar>?, _ handlerKey: UnsafePointer<CChar>?,
                                                                   _ payload: UnsafePointer<UInt8>?, _ payloadCount: Int) -> Int32 {
    guard let panel, let nodeID, let handlerKey, payloadCount > 0, let payload else { return -1 }
    let panelName = String(cString: panel), nodeIDString = String(cString: nodeID), handlerKeyString = String(cString: handlerKey)
    let payloadData = Data(bytes: payload, count: payloadCount)
    guard let value = try? JSONSerialization.jsonObject(with: payloadData, options: [.fragmentsAllowed]) else { return -1 }
    return Int32(withEntry(handle) { entry in
        guard let action = entry.resultHandlers[panelName]?[nodeIDString]?[handlerKeyString] else { return -1 }
        return Int64(action(value))
    })
}

@MainActor private func resolvePanelTree(_ panel: String, entry: Entry) -> RenderNode? {
    if panel.hasPrefix("NativeWindow:"), let number = Int(panel.dropFirst("NativeWindow:".count)) {
        return NativeLowering.childWindowNode(number)
    }
    let session = entry.editor.session
    let resolved: RenderNode
    switch panel {
    // ContentView's own pieces (Sources/Overrides/ContentView.swift), not copies of them.
    case "ToolHeaders": resolved = ViewResolver.resolve(ContentView(session: session).toolHeaders)
    case "ToolRail": resolved = ViewResolver.resolve(ContentView(session: session).toolRail)
    case "GIFTimeline":
        guard !session.canvasOnly, let id = session.gifTimelineLayerID,
              session.activeLayerID == id, !session.gifTimelineFrames.isEmpty else { return nil }
        resolved = ViewResolver.resolve(GIFTimeline(frames: session.gifTimelineFrames,
            selectedFrameIndex: session.gifTimelineSelectedFrameIndex,
            isPlaying: session.gifTimelineIsPlaying, canPlay: session.gifTimelineCanPlay,
            timing: session.gifTimelineTiming, canEditFrames: session.gifTimelineCanEditFrames,
            canEditTiming: session.gifTimelineCanEditTiming,
            onSelectFrame: { index in
                guard session.activeLayerID == id else { return }
                await session.selectGIFTimelineFrame(index)
            },
            onTogglePlayback: { session.toggleGIFPlayback(for: id) },
            onStopPlayback: { session.stopGIFPlayback(for: id) },
            onChangeTiming: { session.setGIFFrameTiming($0, for: id) },
            onDuplicateFrame: { await session.duplicateGIFFrame(at: $0, for: id) },
            onDeleteFrame: { await session.deleteGIFFrames(at: [$0], for: id) }).id(id))
    case "StatusBar": resolved = ViewResolver.resolve(ContentView(session: session).statusBar)
    case "NavigationToolHeader": resolved = ViewResolver.resolve(NavigationToolHeader(session: session))
    case "TransformInspector": resolved = ViewResolver.resolve(TransformInspector(session: session))
    case "BrushControls": resolved = ViewResolver.resolve(BrushControls(session: session))
    case "CropControls": resolved = ViewResolver.resolve(CropControls(session: session))
    case "LassoControls": resolved = ViewResolver.resolve(LassoControls(session: session))
    case "ShapeControls": resolved = ViewResolver.resolve(ShapeControls(session: session))
    case "GradientControls": resolved = ViewResolver.resolve(GradientControls(session: session))
    case "TypeControls": resolved = ViewResolver.resolve(TypeControls(session: session))
    case "ColorPaletteControls": resolved = ViewResolver.resolve(ColorPaletteControls(session: session))
    case "LevelsSheet": resolved = ViewResolver.resolve(LevelsSheet(session: session))
    case "ColorRangeSheet": resolved = ViewResolver.resolve(ColorRangeSheet(session: session))
    case "HueSaturationSheet": resolved = ViewResolver.resolve(HueSaturationSheet(session: session))
    case "FilterSheet": resolved = ViewResolver.resolve(FilterSheet(session: session))
    case "LayersPanel": resolved = ViewResolver.resolve(LayersPanel(session: session, width: CGFloat(entry.layersPanelWidth)))
    case "ColorPickerSheet":
        guard let picker = session.colorPicker else { return nil }
        resolved = ViewResolver.resolve(ColorPickerSheet(state: picker) { [weak session] commit in
            session?.closeColorPicker(commit: commit)
        }.id(ObjectIdentifier(picker).hashValue))
    case "SelectionAmountSheet":
        guard let operation = session.selectionAmountOperation else { return nil }
        resolved = ViewResolver.resolve(SelectionAmountSheet(session: session, operation: operation).id(operation.rawValue))
    case "Welcome":
        // ContentView's `welcome`: the New Canvas sheet over the canvas while the tab has no document.
        guard session.document == nil else { return nil }
        let editor = entry.editor
        resolved = ViewResolver.resolve(NewCanvasSheet(session: session,
            onCreate: { session.createNewProject(width: $0, height: $1, resolution: $2, background: $3) },
            onOpen: { editor.openProjectRequested = true }))
    case "RawDevelopSheet":
        // One sheet per develop request, kept while it is open: its sliders and preview live in its @State.
        let session = entry.editor.importSession
        guard let develop = session.rawDevelop else { entry.rawDevelopSheet = nil; return nil }
        if entry.rawDevelopSheet?.url != develop.url || entry.rawDevelopSheet?.view.session !== session {
            entry.rawDevelopSheet = (develop.url, RawDevelopSheet(session: session, url: develop.url, settings: develop.settings))
        }
        resolved = ViewResolver.resolve(entry.rawDevelopSheet!.view)
    case "EffectsSheet":
        guard let editing = session.effectsEditing else { return nil }
        resolved = ViewResolver.resolve(EffectsSheet(session: session, kind: editing.kind))
    case "KeyboardShortcutsSheet":
        guard let sheet = ShortcutSettings.shared.sheet else { return nil }
        resolved = ViewResolver.resolve(sheet)
    case "CanvasSizeSheet":
        guard let sheet = entry.editor.canvasSizeSheet else { return nil }
        resolved = ViewResolver.resolve(sheet)
    case "ImageSizeSheet":
        guard let sheet = entry.editor.imageSizeSheet else { return nil }
        resolved = ViewResolver.resolve(sheet)
    case "ExportAsSheet":
        guard let sheet = entry.editor.exportAsSheet else { return nil }
        resolved = ViewResolver.resolve(sheet)
    case "NavigatorMinimap":
        // View › Navigator, from 300% zoom, while not Canvas Only — same gates as tip ContentView.
        let shows = (UserDefaults.standard.object(forKey: "navigator.visible") as? Bool) ?? false
        guard shows, !session.canvasOnly, session.document != nil,
              session.viewport.zoom >= NavigatorMinimap.zoomShown else { return nil }
        resolved = ViewResolver.resolve(NavigatorMinimap(session: session))
    case "GridSettingsSheet":
        guard let backup = entry.editor.gridSettingsBackup else { return nil }
        let editor = entry.editor
        let session = entry.editor.session
        resolved = ViewResolver.resolve(GridSettingsSheet(
            session: session, grid: backup.grid, appearance: backup.appearance,
            preview: { grid, appearance in
                session.layoutGrid = grid
                session.gridAppearance = appearance
            },
            finish: { editor.finishGridSettings($0) }))
    case "TrimSheet":
        guard let sheet = entry.editor.trimSheet else { return nil }
        resolved = ViewResolver.resolve(sheet)
    case "PSDConversionSheet":
        // Upstream's Photoshop conversion sheet: "Reading…" while the file parses, then the list and Import / Cancel.
        let session = entry.editor.importSession
        guard let request = session.conversionRequest else { return nil }
        resolved = ViewResolver.resolve(PSDConversionSheet(request: request, finish: session.finishConversion))
    case "CurvesControls":
        var settings = CurvesSettings()
        let binding = Binding<CurvesSettings>(get: { settings }, set: { settings = $0 })
        resolved = ViewResolver.resolve(CurvesControls(settings: binding))
    default: return nil
    }
    return resolved
}


/// The pixels behind an `Image` node's `pixels:<token>`: premultiplied RGBA8, `width` x `height`. Returns the byte count
/// (call with a nil output to size the buffer), -1 for an unknown token.
@_cdecl("compositor_swiftui_image")
nonisolated public func compositorSwiftUIImage(_ token: UnsafePointer<CChar>?, _ width: UnsafeMutablePointer<Int32>?,
                                               _ height: UnsafeMutablePointer<Int32>?, _ output: UnsafeMutablePointer<UInt8>?,
                                               _ capacity: Int) -> Int64 {
    guard let token, let image = ImageRegistry.image(for: String(cString: token)) else { return -1 }
    let raster = image.portableImage
    width?.pointee = Int32(raster.width); height?.pointee = Int32(raster.height)
    let bytes = raster.bytes
    if let output, capacity >= bytes.count { bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: bytes.count) } }
    return Int64(bytes.count)
}

@_cdecl("compositor_session_render_tree")
nonisolated public func compositorSessionRenderTree(_ handle: UInt64, _ panel: UnsafePointer<CChar>?,
                                                     _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard let panel, capacity >= 0 else { return -1 }
    let panelName = String(cString: panel)
    return withEntry(handle) { entry in
        // The shell asks for the size, then the bytes: the fill call takes the tree the size query resolved, instead of
        // resolving (and running its .onChange actions) a second time.
        if let output, let pending = pendingTree, pending.handle == handle, pending.panel == panelName {
            pendingTree = nil
            guard capacity >= pending.data.count else { return Int64(pending.data.count) }
            pending.data.copyBytes(to: output, count: pending.data.count)
            return Int64(pending.data.count)
        }
        pendingTree = nil
        guard let wire = resolvePanel(panelName, entry: entry) else { return -1 }
        // Sorted keys: the same tree must serialise to the same bytes, so the Qt shell can skip rebuilding an unchanged
        // panel (swiftUIRenderPanelIfChanged).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(wire) else { return -5 }
        // COMPOSITOR_DUMP_TREE=<panel>: that panel's resolved tree on stderr, for renderer debugging.
        if ProcessInfo.processInfo.environment["COMPOSITOR_DUMP_TREE"] == panelName {
            FileHandle.standardError.write(data + Data("\n".utf8))
        }
        if let output, capacity >= data.count { data.copyBytes(to: output, count: data.count) }
        if output == nil { pendingTree = (handle, panelName, data) }
        return Int64(data.count)
    }
}

/// The tree a `compositor_session_render_tree` size query resolved, waiting for the fill call that follows it.
nonisolated(unsafe) private var pendingTree: (handle: UInt64, panel: String, data: Data)?

/// Tracking loops query the live viewport without resolving and rasterizing the panel on every tick.
@_cdecl("compositor_session_scroll_offset")
nonisolated public func compositorSessionScrollOffset(_ handle: UInt64, _ panel: UnsafePointer<CChar>?,
                                                     _ nodeID: UnsafePointer<CChar>?, _ output: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let panel, let nodeID, let output else { return -1 }
    let panelName = String(cString: panel), node = String(cString: nodeID)
    return Int32(withEntry(handle) { entry in
        guard let query = entry.actionHandlers[panelName]?[node]?["scrollOffset"] else { return -1 }
        let box = NativeScrollOffsetBox(); query(box)
        guard let offset = box.offset, offset.x.isFinite, offset.y.isFinite else { return -1 }
        output[0] = Double(offset.x); output[1] = Double(offset.y)
        return 0
    })
}

/// Accessibility is queried independently from painting; offscreen table rows need not be created on every frame.
@_cdecl("compositor_session_accessibility_tree")
nonisolated public func compositorSessionAccessibilityTree(_ handle: UInt64, _ panel: UnsafePointer<CChar>?,
                                                          _ nodeID: UnsafePointer<CChar>?, _ output: UnsafeMutablePointer<UInt8>?,
                                                          _ capacity: Int) -> Int64 {
    guard let panel, let nodeID, capacity >= 0 else { return -1 }
    let panelName = String(cString: panel), node = String(cString: nodeID)
    return withEntry(handle) { entry in
        if let output, let pending = pendingAccessibility, pending.handle == handle,
           pending.panel == panelName, pending.node == node {
            pendingAccessibility = nil
            guard capacity >= pending.data.count else { return Int64(pending.data.count) }
            pending.data.copyBytes(to: output, count: pending.data.count)
            return Int64(pending.data.count)
        }
        pendingAccessibility = nil
        guard let snapshot = entry.actionHandlers[panelName]?[node]?["accessibilitySnapshot"] else { return -1 }
        let box = NativeAccessibilityBox(); snapshot(box)
        guard !box.data.isEmpty else { return -1 }
        if let output, capacity >= box.data.count { box.data.copyBytes(to: output, count: box.data.count) }
        if output == nil { pendingAccessibility = (handle, panelName, node, box.data) }
        return Int64(box.data.count)
    }
}
nonisolated(unsafe) private var pendingAccessibility: (handle: UInt64, panel: String, node: String, data: Data)?

/// Draws a `Canvas` node's `draw` handler into a fresh `width`×`height` RGBA context (via the existing
/// Skia-backed `CGContext`, `Sources/Compat/CoreGraphics/CoreGraphicsCompat`) and returns the raw pixels, so the
/// Qt renderer can blit them without knowing anything about `GraphicsContext`/`Path` itself — the same "one
/// generic bridge, no per-panel Qt code" shape as every other node kind. Same size-query convention: called with
/// `output == nil` an implementation could size-probe, but a Canvas's byte count is always `width*height*4`, known
/// up front, so callers skip straight to the fill call.
@_cdecl("compositor_session_render_swiftui_canvas")
nonisolated public func compositorSessionRenderSwiftUICanvas(_ handle: UInt64, _ panel: UnsafePointer<CChar>?, _ nodeID: UnsafePointer<CChar>?,
                                                              _ width: Int, _ height: Int,
                                                              _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard let panel, let nodeID, width > 0, height > 0, width * height <= 100_000_000, capacity >= 0 else { return -1 }
    let panelName = String(cString: panel), nodeIDString = String(cString: nodeID)
    return withEntry(handle) { entry in
        guard let draw = entry.actionHandlers[panelName]?[nodeIDString]?["draw"] else { return -1 }
        let cgContext = CGContext(width: width, height: height)
        let box = GraphicsContextBox(context: GraphicsContext(cgContext: cgContext), size: CGSize(width: Double(width), height: Double(height)))
        draw(box)
        let bytes = cgContext.buffer.bytes
        guard capacity >= bytes.count else { return Int64(bytes.count) }
        if let output { bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) } }
        return Int64(bytes.count)
    }
}

/// Dispatches a Qt-side interaction (a button tap, a slider drag, ...) back to the Swift closure the last
/// `compositor_session_render_tree` call for this `panel` recorded for `nodeID`/`handlerKey`. `payload` is a JSON
/// fragment (`true`, `42.5`, `"text"`, or empty for a no-argument action like a button tap) matching what that
/// control's handler expects (see `Controls.swift`'s `_makeNode` implementations). Applying the change mutates
/// `EditorSession` directly (real `Observation`), so the *next* `compositor_session_render_tree` call already
/// reflects it — there is no separate "commit" step.
@_cdecl("compositor_session_dispatch_swiftui_action")
nonisolated public func compositorSessionDispatchSwiftUIAction(_ handle: UInt64, _ panel: UnsafePointer<CChar>?,
                                                                _ nodeID: UnsafePointer<CChar>?, _ handlerKey: UnsafePointer<CChar>?,
                                                                _ payload: UnsafePointer<UInt8>?, _ payloadCount: Int) -> Int32 {
    guard let panel, let nodeID, let handlerKey, payloadCount >= 0 else { return -1 }
    let panelName = String(cString: panel), nodeIDString = String(cString: nodeID), handlerKeyString = String(cString: handlerKey)
    let payloadData = payload.map { Data(bytes: $0, count: payloadCount) } ?? Data()
    return Int32(withEntry(handle) { entry in
        guard let action = entry.actionHandlers[panelName]?[nodeIDString]?[handlerKeyString] else { return -1 }
        let value: Any = payloadData.isEmpty ? () : ((try? JSONSerialization.jsonObject(with: payloadData, options: [.fragmentsAllowed])) ?? ())
        let previousEvent = NSApp.currentEvent
        let previousModifiers = NSEvent.modifierFlags
        var scopesActivation = false
        if handlerKeyString == "action", let data = value as? [String: Any], let bits = data["modifiers"] as? Int {
            scopesActivation = true
            var flags: NSEvent.ModifierFlags = []
            if bits & 1 != 0 { flags.insert(.command) }
            if bits & 2 != 0 { flags.insert(.option) }
            if bits & 4 != 0 { flags.insert(.control) }
            if bits & 8 != 0 { flags.insert(.shift) }
            NSApp.currentEvent = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0)
            NSEvent.modifierFlags = flags
        }
        defer {
            if scopesActivation { NSApp.currentEvent = previousEvent; NSEvent.modifierFlags = previousModifiers }
        }
        action(value)
        // A toolbar button or picker finishes its field change in one interaction. Numeric fields and label
        // scrubs keep their draft until focus leaves or the drag ends; explicit Free Transform still waits.
        if panelName == "ToolHeaders", handlerKeyString == "action" || handlerKeyString == "selection",
           let edit = entry.editor.session.transformEdit, edit.fromFields, !edit.persistent {
            entry.editor.session.commitTransform()
        }
        // The host keeps a field's widgets while it is being edited, and does not resolve the panel then. Settle focus
        // observers now so both gaining and losing focus are observed, and a draft commits before the next button
        // action (such as the picker's OK). Typed text is often view @State, which in SwiftUI re-evaluates the body:
        // resolve so its .onChange runs while typing (the transform fields preview each typed value live). Only on
        // the main thread, where the host types: a main-queue block run on a C-ABI caller's thread cannot cast to
        // the main-actor-isolated NSViewRepresentable conformance, so such a resolve would not lower native views.
        if handlerKeyString == "focused" || (handlerKeyString == "text" && Thread.isMainThread)
            || handlerKeyString == "onSubmit" || handlerKeyString == "onExitCommand" {
            _ = resolvePanel(panelName, entry: entry)
        }
        // No blanket invalidation: compositor_session_render re-renders only when its RenderKey changed.
        return 0
    })
}

/// Panels whose observed state changed since they were last resolved (withObservationTracking's onChange, which may
/// fire on any thread).
enum DirtyPanels {
    nonisolated struct Key: Hashable, Sendable { let entry: UUID; let panel: String }
    nonisolated(unsafe) private static var dirty: Set<Key> = []
    nonisolated(unsafe) private static var live: Set<UUID> = []
    private static let lock = NSLock()
    static func register(_ id: UUID) { lock.lock(); live.insert(id); lock.unlock() }
    static func discard(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        live.remove(id)
        dirty = dirty.filter { $0.entry != id }
    }
    static func mark(_ key: Key) {
        lock.lock(); defer { lock.unlock() }
        if live.contains(key.entry) { dirty.insert(key) }
    }
    static func clear(_ entry: Entry, _ panel: String) {
        lock.lock(); dirty.remove(Key(entry: entry.renderScopeID, panel: panel)); lock.unlock()
    }
    /// The entry's dirty panels, taken (the shell refreshes them now).
    static func take(_ entry: Entry) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let id = entry.renderScopeID
        let names = dirty.filter { $0.entry == id }
        dirty.subtract(names)
        return names.map(\.panel).sorted()
    }
}

/// The session's panels whose state changed since the shell last fetched them, newline-separated (size query with a
/// nil output, as the other blobs; the fill takes them).
@_cdecl("compositor_session_dirty_panels")
nonisolated public func compositorSessionDirtyPanels(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    withEntry(handle) { entry in
        let data = Data(DirtyPanels.take(entry).joined(separator: "\n").utf8)
        guard let output, capacity >= data.count else { return Int64(data.count) }
        data.copyBytes(to: output, count: data.count)
        return Int64(data.count)
    }
}
