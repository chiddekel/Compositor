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
    var forward: Bool?
    var horizontally: Bool?
    var x: Double?
    var y: Double?
    var parameters: [String: Double]?
    var adjustment: LayerAdjustment?
    var points: [[Double]]?
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
    let layers: [Layer]
    let error: String?
}

private final class EditorEntry {
    let lock = NSLock()
    let session: EditorSession
    init(coverageFactory: @escaping () -> BrushCoverageComputing) {
        session = EditorSession(coverageFactory: coverageFactory)
    }
    var error: String?
    var rendered: PortableImage?
}

/// Handles are monotonically allocated IDs, never dereferenced foreign pointers.
/// Lookup retains the entry through each call, including a concurrent close.
private enum Editors {
    static let lock = NSLock()
    static var coverageFactory: () -> BrushCoverageComputing = BrushCoverageBackends.cpu
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

/// Configure future sessions at the application composition root. Existing
/// sessions retain their injected factory; tests can explicitly keep CPU mode.
public func compositorConfigureBrushAcceleration(_ enabled: Bool) {
    Editors.lock.lock(); defer { Editors.lock.unlock() }
    Editors.coverageFactory = enabled ? BrushCoverageBackends.automatic : BrushCoverageBackends.cpu
}

@_cdecl("compositor_session_create")
public func compositorSessionCreate() -> UInt64 {
    Editors.lock.lock(); defer { Editors.lock.unlock() }
    guard Editors.next < UInt64.max else { return 0 }
    let handle = Editors.next
    Editors.next += 1
    Editors.entries[handle] = EditorEntry(coverageFactory: Editors.coverageFactory)
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
            settings.exposure.offset = number("offset", settings.exposure.offset)
            settings.exposure.gamma = number("gamma", settings.exposure.gamma)
            settings.grain.amount = number("amount", settings.grain.amount)
            settings.grain.size = number("size", settings.grain.size)
            settings.grain.roughness = number("roughness", settings.grain.roughness)
            return settings
        }
        switch command.action {
        case "new":
            guard let width = command.width, let height = command.height else { throw EditorSession.Failure.invalidArgument }
            try s.createDocument(width: width, height: height)
        case "resizeCanvas":
            guard let width = command.width, let height = command.height else { throw EditorSession.Failure.invalidArgument }
            let anchor = number("anchor", 4)
            guard (0...8).contains(anchor), anchor.rounded() == anchor else { throw EditorSession.Failure.invalidArgument }
            let fill = command.enabled == true ? CanvasExtensionColor(red: number("red", 0),
                green: number("green", 0), blue: number("blue", 0)) : nil
            try s.resizeCanvas(width: width, height: height, anchor: Int(anchor), fill: fill)
        case "cropCanvas":
            guard let width = command.width, let height = command.height else { throw EditorSession.Failure.invalidArgument }
            try s.cropCanvas(to: CGRect(x: CGFloat(command.x ?? 0), y: CGFloat(command.y ?? 0),
                                        width: CGFloat(width), height: CGFloat(height)))
        case "resizeImage":
            guard let width = command.width, let height = command.height else { throw EditorSession.Failure.invalidArgument }
            let sampling: LayerSampling
            if let kind = command.kind {
                guard let selected = LayerSampling(rawValue: kind) else { throw EditorSession.Failure.invalidArgument }
                sampling = selected
            } else { sampling = .high }
            try s.resizeImage(width: width, height: height, resolution: command.value, sampling: sampling)
        case "addLayer": try s.addBlankLayer()
        case "addGroup": s.addGroup()
        case "groupSelectedLayers": s.groupSelectedLayers()
        case "selectLayer":
            guard let id = command.layerID else { throw EditorSession.Failure.invalidArgument }
            guard s.document?.layers.contains(where: { $0.id == id }) == true else { throw EditorSession.Failure.noLayer }
            s.selectLayer(id)
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
        case "setSelectedOpacity":
            guard let value = command.value else { throw EditorSession.Failure.invalidArgument }
            s.setSelectedLayersOpacity(value)
        case "cycleBlendMode":
            s.cycleBlendMode(forward: command.forward ?? true)
        case "flipLayer":
            s.flipLayers(horizontally: command.horizontally ?? true)
        case "flipCanvas":
            s.flipCanvas(horizontally: command.horizontally ?? true)
        case "addShape":
            guard let kindName = command.kind, let kind = ShapeKind(rawValue: kindName),
                  let width = command.width, let height = command.height else { throw EditorSession.Failure.invalidArgument }
            let color = PaletteColor(red: number("red", 0), green: number("green", 0), blue: number("blue", 0))
            try s.addShape(kind: kind, rect: CGRect(x: CGFloat(command.x ?? 0), y: CGFloat(command.y ?? 0),
                                                     width: CGFloat(width), height: CGFloat(height)), color: color,
                           cornerRadius: number("cornerRadius", 0))
        case "transform":
            guard var transform = s.activeLayer?.transform else { throw EditorSession.Failure.noLayer }
            transform.origin.x = number("x", transform.origin.x)
            transform.origin.y = number("y", transform.origin.y)
            transform.size.width = number("width", transform.size.width)
            transform.size.height = number("height", transform.size.height)
            transform.rotation = number("rotation", transform.rotation)
            try s.updateLayer(transform: transform)
        case "transformBegin": s.beginTransform()
        case "setMaskSelected":
            s.isMaskSelected = command.enabled ?? false
            if s.isMaskSelected, s.activeLayer?.mask?.isLinked == false { s.beginTransform() }
        case "transformPreview":
            guard var draft = s.transformEdit?.draft ?? s.activeLayer?.transform else { throw EditorSession.Failure.noLayer }
            draft.origin.x = number("x", draft.origin.x)
            draft.origin.y = number("y", draft.origin.y)
            draft.size.width = number("width", draft.size.width)
            draft.size.height = number("height", draft.size.height)
            draft.rotation = number("rotation", draft.rotation)
            s.previewTransform(draft)
        case "transformCommit": s.commitTransform()
        case "transformCancel": s.cancelTransform()
        case "undo": try s.undo()
        case "redo": try s.redo()
        case "invert": try s.invertPixels()
        case "deselect": try s.setSelection(nil)
        case "copy": s.copySelection()
        case "copyMerged": s.copyMergedSelection()
        case "paste": s.paste()
        case "cut": s.cutSelection()
        case "duplicateLayer": s.duplicateActiveLayer()
        case "layerViaCopy": s.layerViaCopy()
        case "fillForeground": s.fillSelection(with: .foreground)
        case "fillBackground": s.fillSelection(with: .background)
        case "clearSelection": s.clearSelectedPixels()
        case "addRevealMask": s.addLayerMask(revealing: true)
        case "addHideMask": s.addLayerMask(revealing: false)
        case "deleteMask": s.deleteLayerMask()
        case "invertMask": s.invertLayerMask()
        case "setMaskEnabled":
            guard let enabled = command.enabled else { throw EditorSession.Failure.invalidArgument }
            s.setLayerMaskEnabled(enabled)
        case "setMaskLinked":
            guard let linked = command.enabled else { throw EditorSession.Failure.invalidArgument }
            s.setLayerMaskLinked(linked)
        case "moveLayer":
            guard let dx = command.x, let dy = command.y, dx.isFinite, dy.isFinite else {
                throw EditorSession.Failure.invalidArgument
            }
            try s.moveLayer(dx: CGFloat(dx), dy: CGFloat(dy))
        case "selectRectangle", "selectEllipse":
            let origin = try point()
            guard let width = command.width, let height = command.height,
                  (0...30_000).contains(width), (0...30_000).contains(height) else { throw EditorSession.Failure.invalidArgument }
            let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))
            try s.setSelection(DocumentSelection(path: command.action == "selectEllipse" ? .ellipse(rect) : .rectangle(rect)))
        case "selectLasso":
            guard let ptList = command.points, ptList.count >= 3 else {
                throw EditorSession.Failure.invalidArgument
            }
            let cgPoints = ptList.compactMap { arr -> CGPoint? in
                guard arr.count == 2, arr[0].isFinite, arr[1].isFinite else { return nil }
                return CGPoint(x: arr[0], y: arr[1])
            }
            guard cgPoints.count == ptList.count else { throw EditorSession.Failure.invalidArgument }
            try s.setSelection(DocumentSelection(path: .polygon(cgPoints), antialiased: true))
        case "magicWand":
            let pt = try point()
            var settings = WandSettings()
            settings.tolerance = Int(number("tolerance", Double(settings.tolerance)))
            settings.contiguous = number("contiguous", settings.contiguous ? 1 : 0) != 0
            settings.sampleAllLayers = number("sampleAllLayers", settings.sampleAllLayers ? 1 : 0) != 0
            let modeStr = command.kind ?? "New"
            let mode = SelectionMode(rawValue: modeStr) ?? .replace
            try s.magicWand(at: pt, settings: settings, mode: mode, antialiased: true)
        case "distortBegin":
            s.beginTransform()
            s.beginDistort()
        case "distortCommit":
            guard let edit = s.transformEdit, let ptList = command.points, ptList.count == 4 else {
                throw EditorSession.Failure.invalidArgument
            }
            let cgPoints = ptList.compactMap { arr -> CGPoint? in
                guard arr.count == 2, arr[0].isFinite, arr[1].isFinite else { return nil }
                return CGPoint(x: arr[0], y: arr[1])
            }
            guard cgPoints.count == 4 else { throw EditorSession.Failure.invalidArgument }
            s.commitDistort(edit, corners: cgPoints)
            s.transformEdit = nil
        case "brushBegin":
            var settings = BrushSettings()
            settings.diameter = number("diameter", 40)
            settings.hardness = number("hardness", 1)
            settings.opacity = number("opacity", 1)
            settings.red = number("red", 0); settings.green = number("green", 0); settings.blue = number("blue", 0)
            settings.erasing = number("erasing", 0) != 0
            settings.healing = number("healing", 0) != 0
            if let healModeIdx = command.parameters?["healingMode"] {
                let idx = Int(healModeIdx)
                if (0..<SpotHealingMode.allCases.count).contains(idx) {
                    settings.healingMode = SpotHealingMode.allCases[idx]
                }
            }
            let cloneX = command.parameters?["cloneOffsetX"]
            let cloneY = command.parameters?["cloneOffsetY"]
            let cloneOffset = (cloneX != nil && cloneY != nil) ? CGSize(width: cloneX!, height: cloneY!) : nil
            let sampleAll = number("sampleAllLayers", 0) != 0
            try s.beginBrush(at: point(), settings: settings, mask: number("mask", 0) != 0,
                             cloneOffset: cloneOffset, sampleAllLayers: sampleAll)
        case "brushMove": try s.continueBrush(at: point())
        case "brushEnd": try s.finishBrush()
        case "brushCancel": s.cancelBrush()
        case "warpBegin":
            guard let name = command.kind, let mode = BlurToolMode(rawValue: name) else { throw EditorSession.Failure.invalidArgument }
            var settings = BrushSettings()
            settings.diameter = number("diameter", 40)
            settings.hardness = number("hardness", 1)
            settings.opacity = number("opacity", 1)
            try s.beginWarp(at: point(), mode: mode, settings: settings)
        case "warpMove": try s.continueWarp(at: point())
        case "warpEnd": try s.finishWarp()
        case "warpCancel": s.cancelWarp()
        case "filterBegin":
            guard let name = command.kind, let kind = FilterKind(rawValue: name) else { throw EditorSession.Failure.invalidArgument }
            try s.beginFilter(kind, settings: filterSettings())
        case "filterPreview": try s.updateFilter(filterSettings())
        case "filterSetPreview":
            guard let enabled = command.enabled, let edit = s.filterEdit else { throw EditorSession.Failure.invalidArgument }
            edit.preview = enabled
        case "filterCommit": try s.commitFilter()
        case "filterCancel": s.cancelFilter()
        case "adjustmentBegin":
            guard let id = command.layerID else { throw EditorSession.Failure.invalidArgument }
            try s.beginAdjustmentEditing(id)
        case "addAdjustment":
            guard let name = command.kind, let kind = AdjustmentKind(rawValue: name) else { throw EditorSession.Failure.invalidArgument }
            try s.addAdjustment(kind)
        case "adjustmentPreview":
            guard let value = command.adjustment else { throw EditorSession.Failure.invalidArgument }
            try s.previewAdjustmentEditing(value)
        case "adjustmentCommit":
            guard let value = command.adjustment else { throw EditorSession.Failure.invalidArgument }
            try s.previewAdjustmentEditing(value)
            try s.finishAdjustmentEditing(commit: true)
        case "adjustmentCancel":
            try s.finishAdjustmentEditing(commit: false)
        case "contentFill":
            try s.beginFilter(.contentAwareFill, settings: filterSettings())
            try s.commitFilter()
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
            resolution: s.document?.resolution ?? 72, activeLayerID: s.activeLayerID, modified: s.history.isModified,
            canUndo: s.history.canUndo, canRedo: s.history.canRedo, undoName: s.history.undoName, redoName: s.history.redoName,
            busy: s.brushStroke != nil || s.filterEdit != nil || s.warpStroke != nil || s.adjustmentEditingID != nil
                || s.transformEdit != nil,
            layers: (s.document?.layers ?? []).map { EditorState.Layer(id: $0.id, name: $0.name, visible: $0.isVisible,
                opacity: $0.opacity, blendMode: $0.blendMode.rawValue, parentID: $0.parentID, isGroup: $0.isGroup,
                hasMask: $0.mask != nil, maskEnabled: $0.mask?.isEnabled, maskLinked: $0.mask?.isLinked,
                maskPlacement: $0.mask?.placement, transform: s.displayedTransform(for: $0)) }, error: entry.error)
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

// MARK: - Project manifest serialization (IO milestone: file-map "IO / codec mapping")

@_cdecl("compositor_session_export_manifest")
public func compositorSessionExportManifest(_ handle: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0 else { return -1 }
    return Editors.withEntry(handle) { entry in
        let data = try entry.session.exportManifest()
        if let output, capacity >= data.count {
            data.copyBytes(to: output, count: data.count)
        }
        return Int64(data.count)
    }
}

@_cdecl("compositor_session_import_manifest")
public func compositorSessionImportManifest(_ handle: UInt64, _ json: UnsafePointer<UInt8>?, _ count: Int) -> Int32 {
    guard let json, count > 0, count <= 4 * 1_048_576 else { return -1 }
    return Int32(Editors.withEntry(handle) { entry in
        try entry.session.importManifest(Data(bytes: json, count: count))
        entry.error = nil
        entry.rendered = nil
        return 0
    })
}

@_cdecl("compositor_session_export_layer")
public func compositorSessionExportLayer(_ handle: UInt64, _ layerID: UnsafePointer<UInt8>?, _ layerIDCount: Int,
                                         _ mask: Int32, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int,
                                         _ width: UnsafeMutablePointer<Int>?, _ height: UnsafeMutablePointer<Int>?) -> Int64 {
    guard let layerID, (1...128).contains(layerIDCount), capacity >= 0,
          let idString = String(data: Data(bytes: layerID, count: layerIDCount), encoding: .utf8),
          let id = UUID(uuidString: idString) else { return -1 }
    return Editors.withEntry(handle) { entry in
        let image = try entry.session.layerAsset(id: id, mask: mask != 0)
        width?.pointee = image.width
        height?.pointee = image.height
        guard image.bytes.count <= capacity || output == nil else { return Int64(image.bytes.count) }
        if let output { image.bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) } }
        return Int64(image.bytes.count)
    }
}

@_cdecl("compositor_session_import_layer")
public func compositorSessionImportLayer(_ handle: UInt64, _ layerID: UnsafePointer<UInt8>?, _ layerIDCount: Int,
                                         _ mask: Int32, _ pixels: UnsafePointer<UInt8>?, _ count: Int,
                                         _ width: Int, _ height: Int) -> Int32 {
    guard let layerID, (1...128).contains(layerIDCount),
          let pixels, (1...30_000).contains(width), (1...30_000).contains(height),
          width * height <= 100_000_000,
          let idString = String(data: Data(bytes: layerID, count: layerIDCount), encoding: .utf8),
          let id = UUID(uuidString: idString) else { return -1 }
    let kind: PortableImage.Kind = mask == 0 ? .rgba : .mask
    let expected = width * height * (mask == 0 ? 4 : 1)
    guard count == expected else { return -1 }
    if mask == 0 {
        for i in stride(from: 0, to: count, by: 4) {
            guard pixels[i] <= pixels[i + 3], pixels[i + 1] <= pixels[i + 3], pixels[i + 2] <= pixels[i + 3] else { return -1 }
        }
    }
    return Int32(Editors.withEntry(handle) { entry in
        let image = PortableImage(width: width, height: height, kind: kind,
                                  bytesPerRow: width * (mask == 0 ? 4 : 1),
                                  bytes: Array(UnsafeBufferPointer(start: pixels, count: count)))
        try entry.session.installLayerAsset(image, id: id, mask: mask != 0)
        entry.rendered = nil
        entry.error = nil
        return 0
    })
}

// Extend EditorSession for manifest serialization
private extension EditorSession {
    func exportManifest() throws -> Data {
        guard let doc = document else { throw Failure.noDocument }
        let snapshot = try ProjectSnapshot(document: doc, activeLayerID: activeLayerID)
        return try JSONEncoder().encode(snapshot.manifest)
    }

    func importManifest(_ data: Data) throws {
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        try importManifest(manifest)
    }
}
