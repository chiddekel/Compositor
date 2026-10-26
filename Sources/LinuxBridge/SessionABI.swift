// SessionABI.swift — the C ABI the Qt shell calls (`compositor_session_*`), over upstream's unmodified EditorSession.
//
// Same functions, signatures and return codes as the fork's EditorBridge, which this replaces. Handles are allocated IDs,
// never foreign pointers. Every entry point must be called on the process main thread (the Qt shell does; the Swift
// `@main` bootstrap owns it): sessions are main-actor objects, entered with `MainActor.assumeIsolated`, and async
// upstream operations are awaited by pumping the run loop (see UpstreamEditor.command).

import Foundation
import CoreGraphics
import AppKit

// Not `private`: SwiftUIBridge.swift's `compositor_session_render_tree` reuses this same handle/session registry
// (a Qt-visible tree of the same session's panels, not a separate one) rather than duplicating it.
final class Entry {
    let editor: UpstreamEditor
    /// Panel caches outlive individual resolves; allocator addresses cannot identify their owner safely.
    let renderScopeID = UUID()
    var renderedPanels: Set<String> = []
    func panelScope(_ panel: String) -> String { "\(renderScopeID)|\(panel)" }
    var rendered: (bytes: [UInt8], width: Int, height: Int)?
    /// What `rendered` was made from, and a counter that moves whenever a new render differs.
    var renderedKey: UpstreamEditor.RenderKey?
    /// Display-resolution renders (compositor_session_render_scaled): the last one and what it was made from.
    var scaled: (key: UpstreamEditor.RenderKey, scale: Double, bytes: [UInt8], width: Int, height: Int)?
    /// A display render at another scale, running in the background (compositor_session_render_scaled_async): the
    /// shell keeps showing the previous one, stretched, until this lands in `scaled`.
    var scaledJob: (key: UpstreamEditor.RenderKey, scale: Double, task: Task<Void, Never>)?
    /// The scale stroke patches are rendered at (the shell's current display scale).
    var strokeScale: Double = 1
    var renderRevision: Int64 = 0
    /// Document area the brush stroke in progress changed since the last `compositor_session_render_dirty`.
    var strokeDirty: CGRect?
    private weak var trackedWarp: WarpStroke?
    private var warpPointCount = 0
    /// The RAW Develop sheet being shown for this session (see resolvePanel "RawDevelopSheet").
    var rawDevelopSheet: (url: URL, view: RawDevelopSheet)?
    /// The last resolved SwiftUI tree's action handlers, per panel: panel name -> node id -> handler key -> closure.
    /// Populated by `SwiftUIBridge.swift`'s `resolvePanel`, read by `compositor_session_dispatch_swiftui_action`.
    var actionHandlers: [String: [String: [String: (Any) -> Void]]] = [:]
    var resultHandlers: [String: [String: [String: (Any) -> Int32]]] = [:]
    /// Set only for a handle registered through `compositor_workspace_*`: the `ProjectTab.id` (in `Workspace.shared`)
    /// whose `EditorSession` this entry's editor wraps. A plain `compositor_session_create` handle leaves this nil —
    /// it isn't a document tab, just a bare session (e.g. the SwiftUI render-tree debug path).
    var workspaceTabID: UUID?
    /// The native Layers dock's width, shared with its upstream SwiftUI body.
    var layersPanelWidth: Double = 252

    /// BrushStroke.dirtyDocumentRect covers only its latest publish; several moves can land between two frames, so
    /// the area painted since the last frame accumulates here (compositor_session_render_dirty takes it). Called after
    /// anything that can advance a stroke: a bridge command, a pointer event on the hosted canvas.
    func noteStrokeProgress() {
        func affected(_ rect: CGRect) -> CGRect {
            let margin = editor.spatialAdjustmentMargin
            guard margin > 0, let document = editor.session.document else { return rect }
            return rect.insetBy(dx: -margin, dy: -margin).integral.intersection(CGRect(origin: .zero, size: document.size))
        }
        // A pixel move's tiles follow the drag only once read (EditorCanvas applies the offset before drawing).
        if editor.session.brushStroke == nil, let move = editor.session.pixelMove { try? move.applyOffset() }
        if let stroke = editor.session.brushStroke ?? editor.session.pixelMove?.raster {
            trackedWarp = nil
            warpPointCount = 0
            if let dirty = stroke.dirtyDocumentRect.map(affected) { strokeDirty = strokeDirty.map { $0.union(dirty) } ?? dirty }
        } else if let warp = editor.session.warpStroke {
            if trackedWarp !== warp {
                trackedWarp = warp
                warpPointCount = 0
                strokeDirty = nil
            }
            // WarpStroke records every interpolated dab. Include only new dabs, with rounding/filter margin,
            // then accumulate until the next frame, exactly as for a tiled BrushStroke.
            let radius = ceil(warp.diameter / 2) + 2
            let canvas = CGRect(x: 0, y: 0, width: warp.width, height: warp.height)
            for point in warp.points.dropFirst(warpPointCount) {
                let dirty = affected(CGRect(x: point.x - radius, y: point.y - radius,
                                   width: radius * 2, height: radius * 2).integral.intersection(canvas))
                if !dirty.isNull, !dirty.isEmpty { strokeDirty = strokeDirty.map { $0.union(dirty) } ?? dirty }
            }
            warpPointCount = warp.points.count
        } else {
            trackedWarp = nil
            warpPointCount = 0
            strokeDirty = nil
        }
    }

    init(editor: UpstreamEditor = UpstreamEditor()) {
        self.editor = editor
        DirtyPanels.register(renderScopeID)
        let saved = (UserDefaults.standard.object(forKey: "layersPanelWidth") as? NSNumber)?.doubleValue ?? 252
        if saved.isFinite {
            layersPanelWidth = min(LayersPanel.widths.upperBound, max(LayersPanel.widths.lowerBound, saved))
        }
    }

    deinit { DirtyPanels.discard(renderScopeID) }
}

enum Sessions {
    nonisolated(unsafe) static var next: UInt64 = 1
    nonisolated(unsafe) static var entries: [UInt64: Entry] = [:]
}

/// The single upstream `ProjectWorkspace` (the same open-documents/tabs model the macOS app manages) backing the
/// Qt shell's document tab bar. One workspace per process, same as one `NSDocumentController` per app on macOS.
enum Workspace {
    @MainActor static let shared = ProjectWorkspace()
}

@MainActor private func registerWorkspaceTab(_ tab: ProjectTab) -> UInt64 {
    guard Sessions.next < UInt64.max else { return 0 }
    let handle = Sessions.next
    Sessions.next += 1
    let entry = Entry(editor: UpstreamEditor(session: tab.session))
    entry.workspaceTabID = tab.id
    Sessions.entries[handle] = entry
    return handle
}

@MainActor private func handleForWorkspaceTab(_ id: UUID) -> UInt64? {
    Sessions.entries.first { $0.value.workspaceTabID == id }?.key
}

/// Registers the workspace's already-existing first tab (created by `ProjectWorkspace.init()`) as a handle. Called
/// once at startup instead of `compositor_session_create`, so document #1 is a real workspace tab from the start.
@_cdecl("compositor_workspace_bootstrap")
nonisolated public func compositorWorkspaceBootstrap() -> UInt64 {
    onMain { registerWorkspaceTab(Workspace.shared.current) }
}

/// Opens a brand-new document tab (never reusing an empty one — matches upstream's `newCanvas()`) and returns its handle.
/// As `newCanvas()`, nothing opens (0) while the current project cannot switch (a sheet, an edit or an import is active).
@_cdecl("compositor_workspace_add_tab")
nonisolated public func compositorWorkspaceAddTab() -> UInt64 {
    onMain {
        guard Workspace.shared.canSwitch else { return 0 }
        Workspace.shared.current.session.commitTransform()
        return registerWorkspaceTab(Workspace.shared.addTab(reuseEmpty: false))
    }
}

/// Makes `handle`'s tab current. Returns 0 if selected (including an already-current tab), -5 if upstream
/// refuses the switch, or -6 for a non-workspace handle. The shell must keep its previous tab on refusal.
@_cdecl("compositor_workspace_select_tab")
nonisolated public func compositorWorkspaceSelectTab(_ handle: UInt64) -> Int32 {
    onMain {
        guard let id = Sessions.entries[handle]?.workspaceTabID else { return -6 }
        Workspace.shared.select(id)
        if Workspace.shared.current.id == id, let entry = Sessions.entries[handle] {
            entry.editor.nativeProjects.window = UpstreamCanvases.canvas(handle, entry).window
            entry.editor.nativeProjects.resumeExternalChangeCheck()
        }
        return Workspace.shared.current.id == id ? 0 : -5
    }
}

/// ProjectTabStrip's drag-start gate, including workspace-wide project operations.
@_cdecl("compositor_workspace_can_reorder")
nonisolated public func compositorWorkspaceCanReorder() -> Int32 {
    onMain { Workspace.shared.canSwitch ? 1 : 0 }
}

/// Closes `handle`'s tab (`ProjectWorkspace.removeTab`, which always leaves at least one tab open) and returns a
/// handle for whatever tab is current afterward — an existing handle if that tab already had one, otherwise a
/// freshly registered one for the replacement tab upstream created. 0 means `handle` wasn't a workspace tab.
@_cdecl("compositor_workspace_close_tab")
nonisolated public func compositorWorkspaceCloseTab(_ handle: UInt64) -> UInt64 {
    onMain {
        guard Sessions.entries[handle]?.workspaceTabID != nil else { return 0 }
        releaseSessionHandle(handle)
        let current = Workspace.shared.current
        return handleForWorkspaceTab(current.id) ?? registerWorkspaceTab(current)
    }
}

/// Reorders `handle`'s tab by dragging it in the strip (`ProjectWorkspace.moveTab`). Chrome, not a document edit.
@_cdecl("compositor_workspace_move_tab")
nonisolated public func compositorWorkspaceMoveTab(_ handle: UInt64, _ toIndex: Int32) -> Int32 {
    onMain {
        guard let id = Sessions.entries[handle]?.workspaceTabID else { return -6 }
        Workspace.shared.moveTab(id, to: Int(toIndex))
        return 0
    }
}

@MainActor private func layerDropIDs(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> [UUID]? {
    guard let bytes, count > 0, count <= 1048576,
          let strings = try? JSONDecoder().decode([String].self, from: Data(bytes: bytes, count: count)),
          !strings.isEmpty else { return nil }
    let ids = strings.compactMap(UUID.init(uuidString:))
    return ids.count == strings.count ? ids : nil
}

@MainActor private func layerDropAllowed(_ destination: UInt64, _ ids: [UUID], _ modifiers: Int32) -> Bool {
    let workspace = Workspace.shared
    guard modifiers & 2 == 0, workspace.canSwitch, let first = ids.first,
          let source = workspace.tabs.first(where: { $0.session.document?.layers.contains(where: { $0.id == first }) == true }),
          source.session.canEditLayers,
          ids.allSatisfy({ id in source.session.document?.layers.contains(where: { $0.id == id }) == true }) else { return false }
    if destination == 0 { return true }
    guard let id = Sessions.entries[destination]?.workspaceTabID,
          id != source.id,
          let target = workspace.tabs.first(where: { $0.id == id }) else { return false }
    return target.session.canStartProjectOperation
}

@_cdecl("compositor_workspace_layer_drop_allowed")
nonisolated public func compositorWorkspaceLayerDropAllowed(_ destination: UInt64, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ modifiers: Int32) -> Int32 {
    onMain {
        guard let ids = layerDropIDs(bytes, count) else { return 0 }
        return layerDropAllowed(destination, ids, modifiers) ? 1 : 0
    }
}

/// Supplies the live upstream row drag to the Qt pointer adapter; other native drag kinds stay in their view.
@_cdecl("compositor_current_layer_drag")
nonisolated public func compositorCurrentLayerDrag(_ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0 else { return -1 }
    return onMain {
        guard let drag = NSDraggingSession.current, drag.sourceOperationMask.contains(.copy),
              let items = drag.draggingPasteboard.pasteboardItems else { return 0 }
        let strings = items.compactMap { $0.string(forType: .init(ProjectWorkspace.layerType)) }
        guard !strings.isEmpty, strings.count == items.count,
              let data = try? JSONEncoder().encode(strings) else { return 0 }
        if let output, capacity >= data.count { data.copyBytes(to: output, count: data.count) }
        return Int64(data.count)
    }
}

/// Retires a row drag if its native source widget was replaced during delivery.
@_cdecl("compositor_end_layer_drag")
nonisolated public func compositorEndLayerDrag(_ copied: Int32) {
    onMain {
        NSDraggingSession.current?.end(at: .zero, operation: copied == 1 ? .copy : [])
    }
}

/// Runs upstream provider delivery, including its folder/mask/effect copying and history semantics.
@_cdecl("compositor_workspace_drop_layers")
nonisolated public func compositorWorkspaceDropLayers(_ destination: UInt64, _ bytes: UnsafePointer<UInt8>?, _ count: Int,
                                                     _ modifiers: Int32, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard let output, capacity >= 1048576 else { return -1 }
    guard let ids = onMain({ layerDropIDs(bytes, count) }) else { return -1 }
    let (result, response): (Int64, Data) = awaitOnMain({
        guard layerDropAllowed(destination, ids, modifiers) else { return (-5, Data()) }
        let workspace = Workspace.shared
        let before = Set(workspace.tabs.map(\.id))
        let target = destination == 0 ? nil : Sessions.entries[destination]?.workspaceTabID
        let providers = ids.map { NSItemProvider(item: Data($0.uuidString.utf8) as NSData, typeIdentifier: ProjectWorkspace.layerType) }
        await workspace.receiveProviders(providers, into: target)
        let newHandles = workspace.tabs.filter { !before.contains($0.id) }.map { String(handleForWorkspaceTab($0.id) ?? registerWorkspaceTab($0)) }
        let selected = destination != 0 && Sessions.entries[destination]?.workspaceTabID == workspace.current.id
            ? destination : handleForWorkspaceTab(workspace.current.id) ?? registerWorkspaceTab(workspace.current)
        let response = (try? JSONSerialization.data(withJSONObject: ["newHandles": newHandles, "selectedHandle": String(selected)])) ?? Data()
        return (0, response)
    }, whileWaiting: {
        if let pump = ImportPrompts.waitPump { pump(ImportPrompts.waitPumpContext) }
    })
    guard result == 0 else { return result }
    guard !response.isEmpty, response.count <= capacity else { return -1 }
    response.copyBytes(to: output, count: response.count)
    return Int64(response.count)
}

/// UTF-8 title for `handle`'s tab (upstream's `ProjectTab.title`: the project filename, or "Untitled"/"Untitled N"),
/// same output-buffer convention as `compositor_session_state`: call with `capacity` 0 first to size the buffer.
@_cdecl("compositor_workspace_tab_title")
nonisolated public func compositorWorkspaceTabTitle(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0 else { return -1 }
    return onMain {
        guard let id = Sessions.entries[handle]?.workspaceTabID,
              let tab = Workspace.shared.tabs.first(where: { $0.id == id }) else { return -6 }
        guard let data = tab.title.data(using: .utf8) else { return -1 }
        if let output, capacity >= data.count { data.copyBytes(to: output, count: data.count) }
        return Int64(data.count)
    }
}

/// Tip ProjectWorkspace.settlePendingEdits / finishTextEditing before Quit or closing the window: apply canvas
/// drafts (gradient, pixel move), cancel open dialogs, finish in-progress text — so Quit is not refused mid-edit.
@_cdecl("compositor_workspace_settle")
nonisolated public func compositorWorkspaceSettle() -> Int32 {
    Int32(awaitOnMain({
        let workspace = Workspace.shared
        for tab in workspace.quitOrder where tab.session.textDraft != nil {
            guard tab.session.finishText() else { return Int64(-5) }
        }
        await workspace.settlePendingEdits()
        return workspace.canSwitch ? 0 : -5
    }, whileWaiting: {
        if let pump = ImportPrompts.waitPump { pump(ImportPrompts.waitPumpContext) }
    }))
}

private enum BridgeMainQueue {
    static let key: DispatchSpecificKey<Bool> = {
        let key = DispatchSpecificKey<Bool>()
        DispatchQueue.main.setSpecific(key: key, value: true)
        return key
    }()
}

/// Runs `body` on the main actor from a C entry point (which the shell calls on the main thread).
func onMain<Result>(_ body: @MainActor () -> Result) -> Result {
    // Linux can drain the main queue on a worker; a nested callback must not synchronously dispatch there again.
    if Thread.isMainThread || DispatchQueue.getSpecific(key: BridgeMainQueue.key) == true {
        return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}

func withEntry(_ handle: UInt64, _ body: @MainActor (Entry) -> Int64) -> Int64 {
    onMain {
        guard let entry = Sessions.entries[handle] else { return -6 }
        return ShellProjects.$requestOwner.withValue(handle) { body(entry) }
    }
}

/// Kept for source compatibility with the fork's composition root: brush acceleration is chosen by the Metal override
/// (`BrushCoverageBackends.automatic()`), which honours `COMPOSITOR_BRUSH_BACKEND`.
nonisolated public func compositorConfigureBrushAcceleration(_ enabled: Bool) {
    if !enabled { setenv("COMPOSITOR_BRUSH_BACKEND", "cpu", 1) }
}

@_cdecl("compositor_session_create")
nonisolated public func compositorSessionCreate() -> UInt64 {
    onMain {
        guard Sessions.next < UInt64.max else { return 0 }
        let handle = Sessions.next
        Sessions.next += 1
        Sessions.entries[handle] = Entry()
        return handle
    }
}

@_cdecl("compositor_session_close")
nonisolated public func compositorSessionClose(_ handle: UInt64) {
    onMain { releaseSessionHandle(handle) }
}

@MainActor private func releaseSessionHandle(_ handle: UInt64) {
    ShellProjects.$requestOwner.withValue(handle) {
        releaseOwnedSessionHandle(handle)
    }
}

@MainActor private func releaseOwnedSessionHandle(_ handle: UInt64) {
    PopUpMenus.cancel(for: handle)
    ShellProjects.pending.removeAll { $0.handle == handle }
    let canvas = UpstreamCanvases.canvases.removeValue(forKey: handle)
    guard let entry = Sessions.entries.removeValue(forKey: handle) else {
        canvas?.window.close()
        return
    }
    let remaining = Sessions.entries.filter { $0.value.editor.session === entry.editor.session }
    let controller = entry.editor.nativeProjects
    if remaining.isEmpty {
        controller.externalChanges.watcher?.stop()
        controller.stopWatchingProject()
        entry.editor.session.clearProject()
        if let id = entry.workspaceTabID { Workspace.shared.removeTab(id) }
    } else if let canvas, controller.window === canvas.window {
        controller.window = remaining.keys.compactMap { UpstreamCanvases.canvases[$0]?.window }.first
    }
    discardRenderedPanels(handle, entry: entry)
    canvas?.window.close()
}

@_cdecl("compositor_session_command")
nonisolated public func compositorSessionCommand(_ handle: UInt64, _ json: UnsafePointer<UInt8>?, _ count: Int) -> Int32 {
    guard let json, count > 0, count <= 4 * 1_048_576 else { return -1 }
    let data = Data(bytes: json, count: count)
    // Restoring rich text may carry the same metadata as a valid project. Keep
    // every other command within its original 1 MiB budget.
    if count > 1_048_576 {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["action"] as? String == "textRestore" else { return -1 }
    }
    return Int32(withEntry(handle) { entry in
        let knownTabs = Set(Workspace.shared.tabs.map(\.id))
        let code = entry.editor.command(data)
        if entry.workspaceTabID != nil {
            for tab in Workspace.shared.tabs where !knownTabs.contains(tab.id) {
                let newHandle = handleForWorkspaceTab(tab.id) ?? registerWorkspaceTab(tab)
                if newHandle != 0 { ShellProjects.pending.append(.init(name: "adoptTab:\(newHandle)", handle: handle)) }
            }
        }
        if code == 0 { entry.rendered = nil }
        entry.noteStrokeProgress()
        return Int64(code)
    })
}

@_cdecl("compositor_session_import_rgba")
nonisolated public func compositorSessionImportRGBA(_ handle: UInt64, _ pixels: UnsafePointer<UInt8>?, _ count: Int,
                                                    _ width: Int, _ height: Int, _ name: UnsafePointer<UInt8>?, _ nameCount: Int,
                                                    _ replacing: Int32) -> Int32 {
    guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height), width * height <= DocumentLimits.maxSurfacePixels,
          count == width * height * 4, let pixels, let name, (1...16_384).contains(nameCount),
          let title = String(data: Data(bytes: name, count: nameCount), encoding: .utf8) else { return -1 }
    let bytes = Array(UnsafeBufferPointer(start: pixels, count: count))
    return Int32(withEntry(handle) { entry in
        let code = entry.editor.importRGBA(bytes, width: width, height: height, name: title, replacing: replacing != 0)
        if code == 0 { entry.rendered = nil }
        return Int64(code)
    })
}

/// The document's unsaved-changes flag alone (the `modified` field of `compositor_session_state`): the tab strip asks
/// for every tab on each repaint, so it must not encode the whole session state. 1 modified, 0 clean, negative error.
@_cdecl("compositor_session_is_modified")
nonisolated public func compositorSessionIsModified(_ handle: UInt64) -> Int64 {
    withEntry(handle) { entry in entry.editor.session.history.isModified ? 1 : 0 }
}

@_cdecl("compositor_session_state")
nonisolated public func compositorSessionState(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0 else { return -1 }
    return withEntry(handle) { entry in
        // Size query, then fill: the fill copies what the size query encoded rather than encoding the state again.
        if let output, let pending = pendingState, pending.handle == handle {
            pendingState = nil
            if capacity >= pending.data.count { pending.data.copyBytes(to: output, count: pending.data.count) }
            return Int64(pending.data.count)
        }
        pendingState = nil
        guard let data = try? entry.editor.stateJSON() else { return -5 }
        if let output, capacity >= data.count { data.copyBytes(to: output, count: data.count) }
        if output == nil { pendingState = (handle, data) }
        return Int64(data.count)
    }
}

/// The state a `compositor_session_state` size query encoded, waiting for the fill call that follows it.
nonisolated(unsafe) private var pendingState: (handle: UInt64, data: Data)?

@_cdecl("compositor_session_render")
nonisolated public func compositorSessionRender(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0 else { return -1 }
    return withEntry(handle) { entry in
        entry.strokeScale = 1   // the shell shows the full composite: stroke patches at full resolution too
        let image: (bytes: [UInt8], width: Int, height: Int)
        // Commands clear `rendered`; SwiftUI panel actions don't, because most change no pixels. Either way, a render
        // is only redone when what it depends on (RenderKey) changed.
        // Settle first: a filter preview being prepared finishes here, and the key must describe what is rendered.
        entry.editor.settle()
        let key = entry.editor.renderKey()
        if let cached = entry.rendered, entry.renderedKey == key { image = cached }
        else {
            guard entry.editor.session.document != nil else { return -2 }
            guard let made = try? entry.editor.renderRGBA() else { return -5 }
            image = made; entry.rendered = made
            if entry.renderedKey != key { entry.renderRevision += 1 }
            entry.renderedKey = key
        }
        if let output, capacity >= image.bytes.count { image.bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) } }
        return Int64(image.bytes.count)
    }
}

/// Advances deferred WarpStroke dabs after a dirty frame. 1 = more remain, 0 = idle/done, negative = error.
@_cdecl("compositor_session_warp_continue")
nonisolated public func compositorSessionWarpContinue(_ handle: UInt64) -> Int32 {
    Int32(withEntry(handle) { entry in
        guard entry.editor.session.warpStroke?.hasPendingDabs == true else { return 0 }
        let more = entry.editor.session.continueWarpPending()
        entry.noteStrokeProgress()
        return more ? 1 : 0
    })
}

/// Proofs a canvas display buffer in place (`width`×`height` premultiplied RGBA8, top row first) while View › CMYK ›
/// Proof Colors or Gamut Warning is on. 1 when proofed, 0 when the canvas shows the document's own colors, negative
/// on bad arguments. The shell calls it on what it shows only, never on exports.
@_cdecl("compositor_session_proof_display")
nonisolated public func compositorSessionProofDisplay(_ handle: UInt64, _ pixels: UnsafeMutablePointer<UInt8>?,
                                                      _ width: Int32, _ height: Int32) -> Int32 {
    guard let pixels, width > 0, height > 0 else { return -1 }
    return Int32(withEntry(handle) { entry in
        let count = Int(width) * Int(height) * 4
        var bytes = Array(UnsafeBufferPointer(start: pixels, count: count))
        guard entry.editor.proofForDisplay(&bytes, width: Int(width), height: Int(height)) else { return 0 }
        bytes.withUnsafeBufferPointer { pixels.update(from: $0.baseAddress!, count: count) }
        return 1
    })
}

@_cdecl("compositor_session_render_dirty")
nonisolated public func compositorSessionRenderDirty(_ handle: UInt64, _ rect: UnsafeMutablePointer<Int32>?,
                                                     _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard let rect, let output, capacity >= 0 else { return -1 }
    return withEntry(handle) { entry in
        guard entry.editor.session.brushStroke != nil || entry.editor.session.warpStroke != nil
                || entry.editor.session.pixelMove != nil else { return -3 }
        guard let dirty = entry.strokeDirty else { return 0 }
        // Liquify/Smudge live feedback: when only one pixel layer is visible, the warp working
        // buffer *is* the composite. Blit the dirty tip straight out and skip ImageExporter —
        // that path was the bulk of the >150 ms first-feedback regression on Full HD + 256 px tips.
        if let warp = entry.editor.session.warpStroke,
           let document = entry.editor.session.document {
            let visiblePixels = document.layers.filter {
                document.effectiveVisibleIDs.contains($0.id) && !$0.isGroup && $0.asset != nil
            }
            if visiblePixels.count == 1, visiblePixels[0].id == warp.layer.id,
               visiblePixels[0].opacity >= 0.999, visiblePixels[0].blendMode == .normal,
               visiblePixels[0].mask == nil,
               visiblePixels[0].effects?.visible.isEmpty != false,
               let patch = warp.copyPremultiplied(in: dirty) {
                guard capacity >= patch.bytes.count else { return -1 }
                patch.bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }
                rect[0] = Int32(patch.rect.minX); rect[1] = Int32(patch.rect.minY)
                rect[2] = Int32(patch.rect.width); rect[3] = Int32(patch.rect.height)
                rect[4] = Int32(patch.rect.width); rect[5] = Int32(patch.rect.height)
                entry.strokeDirty = nil
                return Int64(patch.bytes.count)
            }
        }
        // At full resolution: shrinking the region through the high-quality downsampler every frame costs more than
        // the stroke; the shell scales the patch into its display image (the committed stroke re-renders properly).
        guard let made = try? entry.editor.renderRegionRGBA(dirty, scale: 1) else { return -5 }
        guard capacity >= made.bytes.count else { return -1 }
        made.bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }
        rect[0] = Int32(made.rect.minX); rect[1] = Int32(made.rect.minY)
        rect[2] = Int32(made.rect.width); rect[3] = Int32(made.rect.height)
        rect[4] = Int32(made.width); rect[5] = Int32(made.height)   // the scaled pixel size of the bytes
        entry.strokeDirty = nil
        return Int64(made.bytes.count)
    }
}

/// Moves whenever the composite would differ from the last one `compositor_session_render` produced: computing it is
/// cheap (no pixels), so the shell can skip re-rendering and re-converting an image that hasn't changed.
@_cdecl("compositor_session_render_revision")
nonisolated public func compositorSessionRenderRevision(_ handle: UInt64) -> Int64 {
    withEntry(handle) { entry in
        guard entry.editor.session.document != nil else { return -2 }
        entry.editor.settle()   // same key the next render will compute (a pending preview lands first)
        entry.editor.prefetchLayerPixels()   // a stroke just committed: its layer is ready before the next one starts
        return entry.renderedKey == entry.editor.renderKey() && entry.rendered != nil ? entry.renderRevision : entry.renderRevision + 1
    }
}

/// The canvas viewport (upstream `CanvasViewport`, the one source of truth for zoom and pan, as EditorCanvas uses it):
/// `out` = zoom, pan x, pan y, backing scale, view width, view height (points). Returns 0, or -2 without a document.
@_cdecl("compositor_session_viewport")
nonisolated public func compositorSessionViewport(_ handle: UInt64, _ out: UnsafeMutablePointer<Double>?) -> Int32 {
    Int32(withEntry(handle) { entry in
        let session = entry.editor.session
        let v = session.viewport
        if let out {
            out[0] = Double(v.zoom); out[1] = Double(v.pan.width); out[2] = Double(v.pan.height)
            out[3] = Double(v.backingScale); out[4] = Double(v.viewSize.width); out[5] = Double(v.viewSize.height)
        }
        return session.document == nil ? -2 : 0
    })
}

/// Changes the viewport as EditorCanvas / ContentView do. `op`: 0 resize (a = width, b = height, c = backing scale;
/// EditorCanvas.syncGeometry), 1 fit (session.fit), 2 zoom to a (anchored at b, c in view points, or the center when
/// both are NaN; session.zoom), 3 keyboard zoom by step a (session.zoomKeyboard), 4 pan by a, b (viewport.translate).
@_cdecl("compositor_session_viewport_update")
nonisolated public func compositorSessionViewportUpdate(_ handle: UInt64, _ op: Int32, _ a: Double, _ b: Double, _ c: Double) -> Int32 {
    Int32(withEntry(handle) { entry in
        let session = entry.editor.session
        switch op {
        case 0:
            let size = CGSize(width: a, height: b)
            guard session.viewport.viewSize != size || session.viewport.backingScale != CGFloat(c) else { return 0 }
            session.viewport.resize(to: size, backingScale: CGFloat(c), documentSize: session.document?.size)
        case 1: session.fit()
        case 2: session.zoom(to: CGFloat(a), anchor: b.isNaN || c.isNaN ? nil : CGPoint(x: b, y: c))
        case 3: session.zoomKeyboard(by: Int(a))
        case 4: session.viewport.translate(by: CGSize(width: a, height: b))
        default: return -1
        }
        return 0
    })
}

/// Runs whatever is waiting on the main actor/queue (upstream async work started from a panel: previews, `Task {}` in
/// button actions). An already-expired deadline can starve task starts and worker continuations under Qt;
/// allow at most one millisecond for ready sources. The shell calls this from its timer and pointer callbacks.
@_cdecl("compositor_pump_main")
nonisolated public func compositorPumpMain() {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
}

/// Cancels upstream's RAW Develop sheet (the shell's dialog was closed without Import).
@_cdecl("compositor_session_raw_develop_cancel")
nonisolated public func compositorSessionRawDevelopCancel(_ handle: UInt64) {
    _ = withEntry(handle) { entry in
        // Closing the shell's dialog answers Cancel for whichever upstream sheet it was showing.
        let importing = entry.editor.importSession
        if importing.showsRawDevelop { importing.finishRawDevelop(nil) }
        if importing.showsConversionSheet { importing.finishConversion(false) }
        if entry.editor.trimSheet != nil { entry.editor.finishTrim(nil) }
        if entry.editor.canvasSizeSheet != nil || entry.editor.imageSizeSheet != nil { entry.editor.finishSizeSheet(nil) }
        if entry.editor.exportAsSheet != nil { entry.editor.finishExportAsSheet(nil) }
        if entry.editor.gridSettingsBackup != nil { entry.editor.finishGridSettings(nil) }
        return 0
    }
}

/// The whole document composited at `scale` (0 < scale <= 1): what the canvas shows when zoomed out, at a fraction of
/// the full composite's cost. Cached by render key and scale. Returns the byte count, sizes in `width` / `height`.
@_cdecl("compositor_session_render_scaled")
nonisolated public func compositorSessionRenderScaled(_ handle: UInt64, _ scale: Double, _ output: UnsafeMutablePointer<UInt8>?,
                                                      _ capacity: Int, _ width: UnsafeMutablePointer<Int32>?,
                                                      _ height: UnsafeMutablePointer<Int32>?) -> Int64 {
    withEntry(handle) { entry in
        guard let document = entry.editor.session.document else { return -2 }
        entry.strokeScale = scale
        entry.editor.settle()
        let key = entry.editor.renderKey()
        if entry.scaled == nil || entry.scaled!.key != key || entry.scaled!.scale != scale {
            guard let made = try? entry.editor.renderRegionRGBA(CGRect(origin: .zero, size: document.size), scale: CGFloat(scale))
            else { return -5 }
            entry.scaled = (key, scale, made.bytes, made.width, made.height)
        }
        let image = entry.scaled!
        width?.pointee = Int32(image.width); height?.pointee = Int32(image.height)
        if let output, capacity >= image.bytes.count {
            image.bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }
        }
        return Int64(image.bytes.count)
    }
}

/// Starts rendering the display image at `scale` in the background (a zoom that crossed to another display scale —
/// the content didn't change). Returns 1 when it is ready now (compositor_session_render_scaled then answers without
/// rendering), 0 when it is under way, negative on error. Poll it until it returns 1.
@_cdecl("compositor_session_render_scaled_async")
nonisolated public func compositorSessionRenderScaledAsync(_ handle: UInt64, _ scale: Double) -> Int32 {
    Int32(withEntry(handle) { entry in
        guard let document = entry.editor.session.document else { return -2 }
        entry.editor.settle()
        let key = entry.editor.renderKey()
        if let ready = entry.scaled, ready.key == key, ready.scale == scale { return 1 }
        if let job = entry.scaledJob, job.key == key, job.scale == scale { return 0 }
        entry.scaledJob?.task.cancel()
        guard let prepared = try? entry.editor.regionSnapshot(CGRect(origin: .zero, size: document.size), scale: CGFloat(scale))
        else { return -5 }
        nonisolated(unsafe) let snapshot = prepared.snapshot
        let task = Task.detached(priority: .userInitiated) {
            guard let made = try? await UpstreamEditor.renderInBackground(snapshot, scale: prepared.scale, samplingOrigin: prepared.samplingOrigin), !Task.isCancelled else { return }
            await MainActor.run {
                guard let job = entry.scaledJob, job.key == key, job.scale == scale else { return }
                entry.scaled = (key, scale, made.bytes, made.width, made.height)
                entry.scaledJob = nil
            }
        }
        entry.scaledJob = (key, scale, task)
        return 0
    })
}

@_cdecl("compositor_session_export_manifest")
nonisolated public func compositorSessionExportManifest(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0 else { return -1 }
    return withEntry(handle) { entry in
        guard let data = try? entry.editor.exportManifest() else { return -2 }
        if let output, capacity >= data.count { data.copyBytes(to: output, count: data.count) }
        return Int64(data.count)
    }
}

@_cdecl("compositor_session_import_manifest")
nonisolated public func compositorSessionImportManifest(_ handle: UInt64, _ json: UnsafePointer<UInt8>?, _ count: Int) -> Int32 {
    guard let json, count > 0, count <= 4 * 1_048_576 else { return -1 }
    let data = Data(bytes: json, count: count)
    return Int32(withEntry(handle) { entry in
        let code = entry.editor.importManifest(data)
        if code == 0 { entry.rendered = nil }
        return Int64(code)
    })
}

@_cdecl("compositor_session_export_layer")
nonisolated public func compositorSessionExportLayer(_ handle: UInt64, _ layerID: UnsafePointer<UInt8>?, _ layerIDCount: Int,
                                                     _ mask: Int32, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int,
                                                     _ width: UnsafeMutablePointer<Int>?, _ height: UnsafeMutablePointer<Int>?) -> Int64 {
    guard let layerID, (1...128).contains(layerIDCount), capacity >= 0,
          let idString = String(data: Data(bytes: layerID, count: layerIDCount), encoding: .utf8),
          let id = UUID(uuidString: idString) else { return -1 }
    return withEntry(handle) { entry in
        guard let image = entry.editor.layerPixels(id: id, mask: mask != 0) else { return -5 }
        width?.pointee = image.width
        height?.pointee = image.height
        guard image.bytes.count <= capacity || output == nil else { return Int64(image.bytes.count) }
        if let output { image.bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) } }
        return Int64(image.bytes.count)
    }
}

@_cdecl("compositor_session_import_layer")
nonisolated public func compositorSessionImportLayer(_ handle: UInt64, _ layerID: UnsafePointer<UInt8>?, _ layerIDCount: Int,
                                                     _ mask: Int32, _ pixels: UnsafePointer<UInt8>?, _ count: Int,
                                                     _ width: Int, _ height: Int) -> Int32 {
    guard let layerID, (1...128).contains(layerIDCount), let pixels, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
          width * height <= DocumentLimits.maxSurfacePixels,
          let idString = String(data: Data(bytes: layerID, count: layerIDCount), encoding: .utf8),
          let id = UUID(uuidString: idString) else { return -1 }
    let expected = width * height * (mask == 0 ? 4 : 1)
    guard count == expected else { return -1 }
    if mask == 0 {
        for i in stride(from: 0, to: count, by: 4) {
            guard pixels[i] <= pixels[i + 3], pixels[i + 1] <= pixels[i + 3], pixels[i + 2] <= pixels[i + 3] else { return -1 }
        }
    }
    let image = PortableImage(width: width, height: height, kind: mask == 0 ? .rgba : .mask, bytesPerRow: width * (mask == 0 ? 4 : 1),
                              bytes: Array(UnsafeBufferPointer(start: pixels, count: count)))
    return Int32(withEntry(handle) { entry in
        let code = entry.editor.installLayerAsset(image, id: id, mask: mask != 0)
        if code == 0 { entry.rendered = nil }
        return Int64(code)
    })
}

/// Upstream validates and decodes the entire package before any document is installed.
@_cdecl("compositor_session_load_package")
nonisolated public func compositorSessionLoadPackage(_ handle: UInt64, _ path: UnsafePointer<CChar>?,
                                                    _ width: UnsafeMutablePointer<Int32>?, _ height: UnsafeMutablePointer<Int32>?) -> Int32 {
    loadProjectPackage(handle, path, width, height, recovery: false)
}

/// Recovery imports committed content without making the autosave package a save destination.
@_cdecl("compositor_session_load_recovery")
nonisolated public func compositorSessionLoadRecovery(_ handle: UInt64, _ path: UnsafePointer<CChar>?,
                                                     _ width: UnsafeMutablePointer<Int32>?, _ height: UnsafeMutablePointer<Int32>?) -> Int32 {
    loadProjectPackage(handle, path, width, height, recovery: true)
}

nonisolated private func loadProjectPackage(_ handle: UInt64, _ path: UnsafePointer<CChar>?,
                                           _ width: UnsafeMutablePointer<Int32>?, _ height: UnsafeMutablePointer<Int32>?,
                                           recovery: Bool) -> Int32 {
    guard let path else { return -1 }
    let string = String(cString: path)
    guard string.hasPrefix("/") else { return -1 }
    let url = URL(fileURLWithPath: string)
    guard case .success(let loaded) = projectStoreOperation({
        let snapshot = try await ProjectStore.shared.load(from: url)
        return (snapshot, try? ProjectDigest.compute(for: url))
    }) else { return -1 }
    let snapshot = loaded.0
    let code = withEntry(handle) { entry in
        let result = entry.editor.importProjectSnapshot(snapshot)
        if result == 0 {
            entry.rendered = nil
            if recovery {
                entry.editor.nativeProjects.stopWatchingProject()
                entry.editor.session.projectURL = nil
            } else {
                bindNativeProject(handle, entry, url: url, digest: loaded.1)
            }
        }
        return Int64(result)
    }
    if code == 0 {
        width?.pointee = Int32(snapshot.manifest.width)
        height?.pointee = Int32(snapshot.manifest.height)
    }
    return Int32(code)
}

@MainActor private func bindNativeProject(_ handle: UInt64, _ entry: Entry, url: URL, digest: ProjectDigest?) {
    let controller = entry.editor.nativeProjects
    entry.editor.session.projectURL = url
    controller.window = UpstreamCanvases.canvas(handle, entry).window
    controller.externalChanges.knownDigest = digest
    controller.watchProject(at: url)
}

@_cdecl("compositor_project_save_state")
nonisolated public func compositorProjectSaveState(_ handle: UInt64, _ saving: Int32) {
    _ = withEntry(handle) { entry in
        entry.editor.nativeProjects.externalChanges.saving = saving != 0
        return 0
    }
}

@_cdecl("compositor_project_did_save")
nonisolated public func compositorProjectDidSave(_ handle: UInt64, _ path: UnsafePointer<CChar>?) {
    guard let path else { return }
    let url = URL(fileURLWithPath: String(cString: path))
    let digest = try? ProjectDigest.compute(for: url)
    _ = withEntry(handle) { entry in
        bindNativeProject(handle, entry, url: url, digest: digest)
        return 0
    }
}

public typealias NativeAlertPresenter = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
public typealias NativeSessionAlertPresenter = @convention(c) (UInt64, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32

@_cdecl("compositor_set_alert_presenter")
nonisolated public func compositorSetAlertPresenter(_ presenter: NativeAlertPresenter?) {
    onMain {
        guard let presenter else { NSAlert.handler = nil; return }
        NSAlert.handler = { alert in presentNativeAlert(alert) { presenter($0, $1, $2) } }
    }
}

@MainActor private func presentNativeAlert(_ alert: NSAlert,
    presenter: (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32) -> NSApplication.ModalResponse {
    guard let data = try? JSONEncoder().encode(alert.buttonTitles), let buttons = String(data: data, encoding: .utf8) else { return .cancel }
    let index = alert.messageText.withCString { title in
        alert.informativeText.withCString { detail in buttons.withCString { presenter(title, detail, $0) } }
    }
    return index >= 0 ? NSApplication.ModalResponse(rawValue: 1000 + Int(index)) ?? .cancel : .cancel
}

@_cdecl("compositor_set_session_alert_presenter")
nonisolated public func compositorSetSessionAlertPresenter(_ presenter: NativeSessionAlertPresenter?) {
    onMain {
        guard let presenter else { NSAlert.handler = nil; return }
        NSAlert.handler = { alert in
            guard let handle = nativePresentationOwner(alert.presentationWindow) else { return .cancel }
            return presentNativeAlert(alert) { presenter(handle, $0, $1, $2) }
        }
    }
}

/// Explicit window, then dispatch owner; zero denotes an application-level presentation, nil a closed owner.
@MainActor func nativePresentationOwner(_ window: NSWindow?) -> UInt64? {
    if let window {
        guard let owner = UpstreamCanvases.canvases.first(where: { $0.value.window === window })?.key,
              Sessions.entries[owner] != nil else { return nil }
        return owner
    }
    if let owner = ShellProjects.requestOwner { return Sessions.entries[owner] != nil ? owner : nil }
    return 0
}
