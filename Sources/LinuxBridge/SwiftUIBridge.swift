// SwiftUIBridge.swift — the C ABI (`compositor_session_render_tree`) the Qt host calls to get a resolved
// `Compositor/UI` panel as JSON, so it can build real Qt widgets generically instead of hand-mirroring each panel.
// Same conventions as SessionABI.swift: opaque session handles, JSON-blob-with-size-query for structured data.

import Foundation
import Observation
import SwiftUI

/// Resolves the named panel against `entry`'s session into a wire-ready tree, and refreshes `entry`'s action-handler
/// registry for it so a later Qt-side interaction can dispatch back to the right closure by node id.
@MainActor private func resolvePanel(_ panel: String, entry: Entry) -> RenderNodeWire? {
    let scope = "\(ObjectIdentifier(entry).hashValue)|\(panel)"
    // .onAppear / .onChange actions run after a resolve and usually change the @State it was built from (a field
    // seeding its text on appear); SwiftUI would render again, so resolve again until the tree settles.
    var wire: RenderNodeWire?
    for _ in 0..<3 {
        guard StateStore.begin(scope: scope) else { return nil }
        // As SwiftUI does: whatever observable state the body read, a change to it invalidates the panel — the shell
        // re-fetches just the panels that changed (compositor_session_dirty_panels) instead of polling them all.
        DirtyPanels.clear(entry, panel)
        let key = DirtyPanels.Key(entry: ObjectIdentifier(entry), panel: panel)
        let node = withObservationTracking { resolvePanelTree(panel, entry: entry) } onChange: { DirtyPanels.mark(key) }
        StateStore.end()
        guard var node else {
            StateStore.discard(scope: scope)
            ChangeTracker.discard(scope: scope)
            entry.resultHandlers[panel] = [:]
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
    return wire
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
    let session = entry.editor.session
    let resolved: RenderNode
    switch panel {
    // ContentView's own pieces (Sources/Overrides/ContentView.swift), not copies of them.
    case "ToolHeaders": resolved = ViewResolver.resolve(ContentView(session: session).toolHeaders)
    case "ToolRail": resolved = ViewResolver.resolve(ContentView(session: session).toolRail)
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
    case "HueSaturationSheet": resolved = ViewResolver.resolve(HueSaturationSheet(session: session))
    case "FilterSheet": resolved = ViewResolver.resolve(FilterSheet(session: session))
    case "LayersPanel": resolved = ViewResolver.resolve(LayersPanel(session: session))
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
            onCreate: { session.createNewProject(width: $0, height: $1) },
            onOpen: { editor.openProjectRequested = true }))
    case "RawDevelopSheet":
        // One sheet per develop request, kept while it is open: its sliders and preview live in its @State.
        guard let develop = session.rawDevelop else { entry.rawDevelopSheet = nil; return nil }
        if entry.rawDevelopSheet?.url != develop.url {
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
    case "JPEGExportSheet":
        guard let sheet = entry.editor.jpegExportSheet else { return nil }
        resolved = ViewResolver.resolve(sheet)
    case "TrimSheet":
        guard let sheet = entry.editor.trimSheet else { return nil }
        resolved = ViewResolver.resolve(sheet)
    case "PSDConversionSheet":
        // Upstream's Photoshop conversion sheet: "Reading…" while the file parses, then the list and Import / Cancel.
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
        action(value)
        // No blanket invalidation: compositor_session_render re-renders only when its RenderKey changed.
        return 0
    })
}

/// Panels whose observed state changed since they were last resolved (withObservationTracking's onChange, which may
/// fire on any thread).
enum DirtyPanels {
    struct Key: Hashable, Sendable { let entry: ObjectIdentifier; let panel: String }
    nonisolated(unsafe) private static var dirty: Set<Key> = []
    private static let lock = NSLock()
    static func mark(_ key: Key) { lock.lock(); dirty.insert(key); lock.unlock() }
    static func clear(_ entry: Entry, _ panel: String) {
        lock.lock(); dirty.remove(Key(entry: ObjectIdentifier(entry), panel: panel)); lock.unlock()
    }
    /// The entry's dirty panels, taken (the shell refreshes them now).
    static func take(_ entry: Entry) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(entry)
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
