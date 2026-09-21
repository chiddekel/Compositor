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

/// Runs `operation` (main-actor, async) to completion from a synchronous call on the main thread.
func awaitOnMain<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async -> Value) -> Value {
    nonisolated(unsafe) var result: Value?
    Task { @MainActor in result = await operation() }
    while result == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001)) }
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
    let layers: [Layer]
    let error: String?
}

/// Result codes shared with the C ABI: 0 ok, -1 invalid argument, -2 no document, -3 busy, -4 unsupported version,
/// -5 operation failed, -6 unknown handle, -7 command not supported by this bridge yet.
final class UpstreamEditor {
    let session = EditorSession()
    private(set) var error: String?

    /// Commands this adapter can run today; the rest report -7 so callers (and the parity tests) see the gap explicitly.
    static let supportedActions: Set<String> = [
        "new", "addLayer", "addGroup", "groupSelectedLayers", "selectLayer", "deleteLayer", "renameLayer", "setVisible",
        "setOpacity", "setBlendMode", "setSelectedOpacity", "cycleBlendMode", "flipLayer", "flipCanvas", "undo", "redo",
    ]

    func command(_ json: Data) -> Int32 {
        guard let command = try? JSONDecoder().decode(Command.self, from: json) else { error = "Invalid command JSON"; return -1 }
        guard command.version == 1 else { error = "Unsupported command version"; return -4 }
        let s = session
        switch command.action {
        case "new":
            guard let width = command.width, let height = command.height, (1...30_000).contains(width), (1...30_000).contains(height)
            else { return fail(-1, "invalid size") }
            s.createDocument(width: width, height: height)
        case "addLayer":
            guard s.document != nil else { return fail(-2, "no document") }
            s.addBlankLayer()
        case "addGroup": s.addGroup()
        case "groupSelectedLayers": s.groupSelectedLayers()
        case "selectLayer":
            guard let id = command.layerID else { return fail(-1, "layerID required") }
            guard s.document?.layers.contains(where: { $0.id == id }) == true else { return fail(-5, "no such layer") }
            s.selectLayer(id)
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
        case "undo": s.undo()
        case "redo": s.redo()
        default:
            return fail(-7, "Unsupported by the upstream bridge yet: \(command.action)")
        }
        error = nil
        return 0
    }

    private func fail(_ code: Int32, _ message: String) -> Int32 { error = message; return code }

    func stateJSON() throws -> Data {
        let s = session
        let state = State(width: s.document?.width ?? 0, height: s.document?.height ?? 0, resolution: s.document?.resolution ?? 72,
            activeLayerID: s.activeLayerID, modified: s.history.isModified, canUndo: s.history.canUndo, canRedo: s.history.canRedo,
            undoName: s.history.undoName, redoName: s.history.redoName,
            busy: s.brushStroke != nil || s.filterEdit != nil || s.transformEdit != nil,
            layers: (s.document?.layers ?? []).map { State.Layer(id: $0.id, name: $0.name, visible: $0.isVisible, opacity: $0.opacity,
                blendMode: $0.blendMode.rawValue, parentID: $0.parentID, isGroup: $0.isGroup, hasMask: $0.mask != nil,
                maskEnabled: $0.mask?.isEnabled, maskLinked: $0.mask?.isLinked, maskPlacement: $0.mask?.placement,
                transform: s.displayedTransform(for: $0)) }, error: error)
        return try JSONEncoder().encode(state)
    }

    /// Adds premultiplied RGBA8 pixels as a layer (`replacing`: as a new one-layer document of that size, history cleared).
    func importRGBA(_ pixels: [UInt8], width: Int, height: Int, name: String, replacing: Bool) -> Int32 {
        guard (1...30_000).contains(width), (1...30_000).contains(height), width * height <= 100_000_000,
              pixels.count == width * height * 4, !name.isEmpty else { return fail(-1, "invalid image") }
        // Validate the canonical contract before any C pixel kernel can see it.
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i] > pixels[i + 3] || pixels[i + 1] > pixels[i + 3] || pixels[i + 2] > pixels[i + 3] {
            return fail(-1, "pixels are not premultiplied")
        }
        let image = CGImage(PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: width * 4, bytes: pixels))
        guard let thumbnail = try? PixelAdjust.thumbnail(of: image) else { return fail(-5, "thumbnail failed") }
        let asset = ImportedImage(image: image, thumbnail: thumbnail, name: name)
        let s = session
        if replacing || s.document == nil {
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

    /// The composite as premultiplied RGBA8 (document size), from upstream's own exporter.
    func renderRGBA() throws -> (bytes: [UInt8], width: Int, height: Int) {
        guard let snapshot = session.projectSnapshot() else { throw ExportError.render }
        // The exporter is an actor that never needs the main thread, so this blocks the caller on a plain semaphore:
        // safe from a Qt callback and from a main-actor test alike (pumping the main run loop would deadlock in the latter).
        nonisolated(unsafe) var outcome: Result<ExportRaster, Error>?
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let captured = snapshot
        Task.detached {
            do { outcome = .success(try await ImageExporter.shared.render(captured)) } catch { outcome = .failure(error) }
            done.signal()
        }
        done.wait()
        guard let raster = outcome else { throw ExportError.render }
        let image = try raster.get().image
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        return (Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)),
                image.width, image.height)
    }
}
