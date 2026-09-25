// SessionABI.swift — the C ABI the Qt shell calls (`compositor_session_*`), over upstream's unmodified EditorSession.
//
// Same functions, signatures and return codes as the fork's EditorBridge, which this replaces. Handles are allocated IDs,
// never foreign pointers. Every entry point must be called on the process main thread (the Qt shell does; the Swift
// `@main` bootstrap owns it): sessions are main-actor objects, entered with `MainActor.assumeIsolated`, and async
// upstream operations are awaited by pumping the run loop (see UpstreamEditor.command).

import Foundation
import CoreGraphics

// Not `private`: SwiftUIBridge.swift's `compositor_session_render_tree` reuses this same handle/session registry
// (a Qt-visible tree of the same session's panels, not a separate one) rather than duplicating it.
final class Entry {
    let editor: UpstreamEditor
    var rendered: (bytes: [UInt8], width: Int, height: Int)?
    /// What `rendered` was made from, and a counter that moves whenever a new render differs.
    var renderedKey: UpstreamEditor.RenderKey?
    /// Display-resolution renders (compositor_session_render_scaled): the last one and what it was made from.
    var scaled: (key: UpstreamEditor.RenderKey, scale: Double, bytes: [UInt8], width: Int, height: Int)?
    /// The scale stroke patches are rendered at (the shell's current display scale).
    var strokeScale: Double = 1
    var renderRevision: Int64 = 0
    /// Document area the brush stroke in progress changed since the last `compositor_session_render_dirty`.
    var strokeDirty: CGRect?
    /// The RAW Develop sheet being shown for this session (see resolvePanel "RawDevelopSheet").
    var rawDevelopSheet: (url: URL, view: RawDevelopSheet)?
    /// The last resolved SwiftUI tree's action handlers, per panel: panel name -> node id -> handler key -> closure.
    /// Populated by `SwiftUIBridge.swift`'s `resolvePanel`, read by `compositor_session_dispatch_swiftui_action`.
    var actionHandlers: [String: [String: [String: (Any) -> Void]]] = [:]
    /// Set only for a handle registered through `compositor_workspace_*`: the `ProjectTab.id` (in `Workspace.shared`)
    /// whose `EditorSession` this entry's editor wraps. A plain `compositor_session_create` handle leaves this nil —
    /// it isn't a document tab, just a bare session (e.g. the SwiftUI render-tree debug path).
    var workspaceTabID: UUID?

    init(editor: UpstreamEditor = UpstreamEditor()) {
        self.editor = editor
    }
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
@_cdecl("compositor_workspace_add_tab")
nonisolated public func compositorWorkspaceAddTab() -> UInt64 {
    onMain { registerWorkspaceTab(Workspace.shared.addTab(reuseEmpty: false)) }
}

/// Makes `handle`'s tab the workspace's current one. No-op (but not an error) if it already is, or if upstream
/// refuses the switch (`canSwitch`, e.g. mid-transform) — the shell keeps showing whatever is actually selected.
@_cdecl("compositor_workspace_select_tab")
nonisolated public func compositorWorkspaceSelectTab(_ handle: UInt64) -> Int32 {
    onMain {
        guard let id = Sessions.entries[handle]?.workspaceTabID else { return -6 }
        Workspace.shared.select(id)
        return 0
    }
}

/// Closes `handle`'s tab (`ProjectWorkspace.removeTab`, which always leaves at least one tab open) and returns a
/// handle for whatever tab is current afterward — an existing handle if that tab already had one, otherwise a
/// freshly registered one for the replacement tab upstream created. 0 means `handle` wasn't a workspace tab.
@_cdecl("compositor_workspace_close_tab")
nonisolated public func compositorWorkspaceCloseTab(_ handle: UInt64) -> UInt64 {
    onMain {
        guard let id = Sessions.entries[handle]?.workspaceTabID else { return 0 }
        Sessions.entries.removeValue(forKey: handle)
        Workspace.shared.removeTab(id)
        let current = Workspace.shared.current
        return handleForWorkspaceTab(current.id) ?? registerWorkspaceTab(current)
    }
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

/// Runs `body` on the main actor from a C entry point (which the shell calls on the main thread).
func onMain<Result>(_ body: @MainActor () -> Result) -> Result {
    if Thread.isMainThread { return MainActor.assumeIsolated(body) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}

func withEntry(_ handle: UInt64, _ body: @MainActor (Entry) -> Int64) -> Int64 {
    onMain {
        guard let entry = Sessions.entries[handle] else { return -6 }
        return body(entry)
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
    onMain { _ = Sessions.entries.removeValue(forKey: handle) }
}

@_cdecl("compositor_session_command")
nonisolated public func compositorSessionCommand(_ handle: UInt64, _ json: UnsafePointer<UInt8>?, _ count: Int) -> Int32 {
    guard let json, count > 0, count <= 1_048_576 else { return -1 }
    let data = Data(bytes: json, count: count)
    return Int32(withEntry(handle) { entry in
        let code = entry.editor.command(data)
        if code == 0 { entry.rendered = nil }
        // BrushStroke.dirtyDocumentRect covers only its latest publish; several moves can land between two frames.
        if let stroke = entry.editor.session.brushStroke {
            if let dirty = stroke.dirtyDocumentRect { entry.strokeDirty = entry.strokeDirty.map { $0.union(dirty) } ?? dirty }
        } else {
            entry.strokeDirty = nil
        }
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

@_cdecl("compositor_session_state")
nonisolated public func compositorSessionState(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0 else { return -1 }
    return withEntry(handle) { entry in
        guard let data = try? entry.editor.stateJSON() else { return -5 }
        if let output, capacity >= data.count { data.copyBytes(to: output, count: data.count) }
        return Int64(data.count)
    }
}

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

@_cdecl("compositor_session_render_dirty")
nonisolated public func compositorSessionRenderDirty(_ handle: UInt64, _ rect: UnsafeMutablePointer<Int32>?,
                                                     _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard let rect, let output, capacity >= 0 else { return -1 }
    return withEntry(handle) { entry in
        guard entry.editor.session.brushStroke != nil else { return -3 }
        guard let dirty = entry.strokeDirty else { return 0 }
        guard let made = try? entry.editor.renderRegionRGBA(dirty, scale: CGFloat(entry.strokeScale)) else { return -5 }
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
/// button actions), without blocking. The shell calls it from a timer; nothing else drains that queue under Qt.
@_cdecl("compositor_pump_main")
nonisolated public func compositorPumpMain() {
    RunLoop.main.run(mode: .default, before: Date())
}

/// Cancels upstream's RAW Develop sheet (the shell's dialog was closed without Import).
@_cdecl("compositor_session_raw_develop_cancel")
nonisolated public func compositorSessionRawDevelopCancel(_ handle: UInt64) {
    _ = withEntry(handle) { entry in
        // Closing the shell's dialog answers Cancel for whichever upstream sheet it was showing.
        if entry.editor.session.showsRawDevelop { entry.editor.session.finishRawDevelop(nil) }
        if entry.editor.session.showsConversionSheet { entry.editor.session.finishConversion(false) }
        if entry.editor.trimSheet != nil { entry.editor.finishTrim(nil) }
        if entry.editor.canvasSizeSheet != nil || entry.editor.imageSizeSheet != nil { entry.editor.finishSizeSheet(nil) }
        if entry.editor.jpegExportSheet != nil { entry.editor.finishJPEGSheet(nil) }
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
