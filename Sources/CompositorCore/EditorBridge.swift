import Foundation

private struct EditorCommand: Decodable {
    let version: Int
    let action: String
    var width: Int?
    var height: Int?
    var layerID: UUID?
    var name: String?
    var kind: String?
    var value: Double?
    var enabled: Bool?
    var x: Double?
    var y: Double?
    var parameters: [String: Double]?
}

private struct EditorState: Encodable {
    struct Layer: Encodable {
        let id: UUID
        let name: String
        let visible: Bool
        let opacity: Double
        let blendMode: String
        let parentID: UUID?
        let isGroup: Bool
        let hasMask: Bool
        let transform: LayerTransform
    }
    let version = 1
    let width: Int
    let height: Int
    let activeLayerID: UUID?
    let modified: Bool
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String
    let redoName: String
    let busy: Bool
    let layers: [Layer]
    let error: String?
}

private final class EditorEntry {
    let lock = NSLock()
    let session = EditorSession()
    var error: String?
    var rendered: PortableImage?
}

/// Handles are monotonically allocated IDs, never dereferenced foreign pointers.
/// Lookup retains the entry through each call, including a concurrent close.
private enum Editors {
    static let lock = NSLock()
    static var next: UInt64 = 1
    static var entries: [UInt64: EditorEntry] = [:]
    static func entry(_ id: UInt64) -> EditorEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]
    }
    static func withEntry(_ id: UInt64, _ body: (EditorEntry) throws -> Int64) -> Int64 {
        guard let entry = entry(id) else { return -6 }
        entry.lock.lock(); defer { entry.lock.unlock() }
        do { return try body(entry) }
        catch {
            entry.error = String(describing: error)
            if case EditorSession.Failure.busy = error { return -3 }
            if case EditorSession.Failure.noDocument = error { return -2 }
            if case EditorSession.Failure.invalidArgument = error { return -1 }
            return -5
        }
    }
}

@_cdecl("compositor_session_create")
public func compositorSessionCreate() -> UInt64 {
    Editors.lock.lock(); defer { Editors.lock.unlock() }
    guard Editors.next < UInt64.max else { return 0 }
    let handle = Editors.next
    Editors.next += 1
    Editors.entries[handle] = EditorEntry()
    return handle
}

@_cdecl("compositor_session_close")
public func compositorSessionClose(_ handle: UInt64) {
    Editors.lock.lock(); defer { Editors.lock.unlock() }
    Editors.entries.removeValue(forKey: handle)
}

@_cdecl("compositor_session_command")
public func compositorSessionCommand(_ handle: UInt64, _ json: UnsafePointer<UInt8>?, _ count: Int) -> Int32 {
    guard let json, count > 0, count <= 1_048_576 else { return -1 }
    return Int32(Editors.withEntry(handle) { entry in
        let command: EditorCommand
        do { command = try JSONDecoder().decode(EditorCommand.self, from: Data(bytes: json, count: count)) }
        catch { entry.error = "Invalid command JSON"; return -1 }
        guard command.version == 1 else { entry.error = "Unsupported command version"; return -4 }
        let s = entry.session
        let p = command.parameters ?? [:]
        func number(_ name: String, _ fallback: Double) -> Double { p[name] ?? fallback }
        func point() throws -> CGPoint {
            guard let x = command.x, let y = command.y, x.isFinite, y.isFinite,
                  abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { throw EditorSession.Failure.invalidArgument }
            return CGPoint(x: x, y: y)
        }
        func filterSettings() -> FilterSettings {
            var settings = s.filterEdit?.settings ?? FilterSettings()
            settings.radius = number("radius", settings.radius)
            settings.distance = number("distance", settings.distance)
            settings.angle = number("angle", settings.angle)
            settings.amount = number("amount", settings.amount)
            settings.distortion = number("distortion", settings.distortion)
            settings.gaussian = number("gaussian", settings.gaussian ? 1 : 0) != 0
            settings.monochromatic = number("monochromatic", settings.monochromatic ? 1 : 0) != 0
            settings.exposure.exposure = number("exposure", settings.exposure.exposure)
            settings.grain.amount = number("amount", settings.grain.amount)
            settings.grain.size = number("size", settings.grain.size)
            settings.grain.roughness = number("roughness", settings.grain.roughness)
            return settings
        }
        switch command.action {
        case "new":
            guard let width = command.width, let height = command.height else { throw EditorSession.Failure.invalidArgument }
            try s.createDocument(width: width, height: height)
        case "addLayer": try s.addBlankLayer()
        case "selectLayer":
            guard let id = command.layerID else { throw EditorSession.Failure.invalidArgument }
            try s.selectLayer(id)
        case "deleteLayer": try s.deleteLayer()
        case "renameLayer":
            guard let name = command.name else { throw EditorSession.Failure.invalidArgument }
            try s.updateLayer(name: name)
        case "setVisible":
            guard let enabled = command.enabled else { throw EditorSession.Failure.invalidArgument }
            try s.updateLayer(visible: enabled)
        case "setOpacity":
            guard let value = command.value else { throw EditorSession.Failure.invalidArgument }
            try s.updateLayer(opacity: value)
        case "setBlendMode":
            guard let name = command.kind, let mode = LayerBlendMode(rawValue: name) else { throw EditorSession.Failure.invalidArgument }
            try s.updateLayer(blendMode: mode)
        case "transform":
            guard var transform = s.activeLayer?.transform else { throw EditorSession.Failure.noLayer }
            transform.origin.x = number("x", transform.origin.x)
            transform.origin.y = number("y", transform.origin.y)
            transform.size.width = number("width", transform.size.width)
            transform.size.height = number("height", transform.size.height)
            transform.rotation = number("rotation", transform.rotation)
            try s.updateLayer(transform: transform)
        case "undo": try s.undo()
        case "redo": try s.redo()
        case "invert": try s.invertPixels()
        case "deselect": try s.setSelection(nil)
        case "selectRectangle", "selectEllipse":
            let origin = try point()
            guard let width = command.width, let height = command.height,
                  (0...30_000).contains(width), (0...30_000).contains(height) else { throw EditorSession.Failure.invalidArgument }
            let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))
            try s.setSelection(DocumentSelection(path: command.action == "selectEllipse" ? .ellipse(rect) : .rectangle(rect)))
        case "brushBegin":
            var settings = BrushSettings()
            settings.diameter = number("diameter", 40)
            settings.hardness = number("hardness", 1)
            settings.opacity = number("opacity", 1)
            settings.red = number("red", 0); settings.green = number("green", 0); settings.blue = number("blue", 0)
            settings.erasing = number("erasing", 0) != 0
            try s.beginBrush(at: point(), settings: settings, mask: number("mask", 0) != 0)
        case "brushMove": try s.continueBrush(at: point())
        case "brushEnd": try s.finishBrush()
        case "brushCancel": s.cancelBrush()
        case "filterBegin":
            guard let name = command.kind, let kind = FilterKind(rawValue: name) else { throw EditorSession.Failure.invalidArgument }
            try s.beginFilter(kind, settings: filterSettings())
        case "filterPreview": try s.updateFilter(filterSettings())
        case "filterCommit": try s.commitFilter()
        case "filterCancel": s.cancelFilter()
        default: entry.error = "Unknown command: \(command.action)"; return -1
        }
        entry.error = nil
        entry.rendered = nil
        return 0
    })
}

@_cdecl("compositor_session_import_rgba")
public func compositorSessionImportRGBA(_ handle: UInt64, _ pixels: UnsafePointer<UInt8>?, _ count: Int,
                                       _ width: Int, _ height: Int, _ name: UnsafePointer<UInt8>?, _ nameCount: Int,
                                       _ replacing: Int32) -> Int32 {
    guard (1...30_000).contains(width), (1...30_000).contains(height), width * height <= 100_000_000,
          count == width * height * 4, let pixels, let name, (1...16_384).contains(nameCount),
          let title = String(data: Data(bytes: name, count: nameCount), encoding: .utf8) else { return -1 }
    // Validate the canonical contract before any C pixel kernel can see it.
    for i in stride(from: 0, to: count, by: 4) {
        guard pixels[i] <= pixels[i + 3], pixels[i + 1] <= pixels[i + 3], pixels[i + 2] <= pixels[i + 3] else { return -1 }
    }
    return Int32(Editors.withEntry(handle) { entry in
        let image = PortableImage(PixelBuffer(width: width, height: height, bytes: Array(UnsafeBufferPointer(start: pixels, count: count))))
        try entry.session.importImage(image, name: title, replacing: replacing != 0)
        entry.rendered = nil; entry.error = nil
        return 0
    })
}

@_cdecl("compositor_session_state")
public func compositorSessionState(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0 else { return -1 }
    return Editors.withEntry(handle) { entry in
        let s = entry.session
        let state = EditorState(width: s.document?.width ?? 0, height: s.document?.height ?? 0,
            activeLayerID: s.activeLayerID, modified: s.history.isModified,
            canUndo: s.history.canUndo, canRedo: s.history.canRedo, undoName: s.history.undoName, redoName: s.history.redoName,
            busy: s.brushStroke != nil || s.filterEdit != nil,
            layers: (s.document?.layers ?? []).map { EditorState.Layer(id: $0.id, name: $0.name, visible: $0.isVisible,
                opacity: $0.opacity, blendMode: $0.blendMode.rawValue, parentID: $0.parentID, isGroup: $0.isGroup,
                hasMask: $0.mask != nil, transform: $0.transform) }, error: entry.error)
        let data = try JSONEncoder().encode(state)
        if let output, capacity >= data.count { data.copyBytes(to: output, count: data.count) }
        return Int64(data.count)
    }
}

@_cdecl("compositor_session_render")
public func compositorSessionRender(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0 else { return -1 }
    return Editors.withEntry(handle) { entry in
        let image: PortableImage
        if let cached = entry.rendered { image = cached }
        else { image = try entry.session.render(); entry.rendered = image }
        if let output, capacity >= image.bytes.count {
            image.bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }
        }
        return Int64(image.bytes.count)
    }
}
