import Foundation
import CoreGraphics

/// Captures immutable image references on the main actor. Serialization and pixel
/// materialization can then run on a worker without touching a live session.
nonisolated struct ProjectSaveSnapshot: @unchecked Sendable {
    let project: ProjectSnapshot
    let revision: UUID
    let generation: UUID
    let sessionHandle: UInt64

    @MainActor init?(editor: UpstreamEditor, handle: UInt64) {
        guard let project = editor.session.projectSnapshot() else { return nil }
        self.project = project
        revision = editor.session.history.currentRevision
        generation = editor.persistenceGeneration
        sessionHandle = handle
    }

    @MainActor func markSaved(in editor: UpstreamEditor) -> Bool {
        guard editor.persistenceGeneration == generation,
              editor.session.document?.id == project.manifest.documentID else { return false }
        editor.session.history.markSaved(revision)
        return true
    }
}

/// Tokens hold references, never foreign pointers. Copying a registry value keeps
/// it alive if another thread releases its token during an export.
nonisolated private enum ProjectSaveSnapshots {
    static let lock = NSLock()
    nonisolated(unsafe) static var next: UInt64 = 1
    nonisolated(unsafe) static var values: [UInt64: ProjectSaveSnapshot] = [:]

    static func insert(_ value: ProjectSaveSnapshot) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard next < UInt64.max else { return 0 }
        let token = next
        next += 1
        values[token] = value
        return token
    }
    static func get(_ token: UInt64) -> ProjectSaveSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return values[token]
    }
    static func remove(_ token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: token)
    }
}

@_cdecl("compositor_save_capture")
nonisolated public func compositorSaveCapture(_ handle: UInt64) -> UInt64 {
    onMain {
        guard let entry = Sessions.entries[handle],
              let snapshot = ProjectSaveSnapshot(editor: entry.editor, handle: handle) else { return 0 }
        return ProjectSaveSnapshots.insert(snapshot)
    }
}

@_cdecl("compositor_save_export_manifest")
nonisolated public func compositorSaveExportManifest(_ token: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0, let snapshot = ProjectSaveSnapshots.get(token),
          let data = try? JSONEncoder().encode(snapshot.project.manifest), data.count <= 4 * 1_048_576 else { return -1 }
    if let output, capacity >= data.count { data.copyBytes(to: output, count: data.count) }
    return Int64(data.count)
}

@_cdecl("compositor_save_export_layer")
nonisolated public func compositorSaveExportLayer(_ token: UInt64, _ layerID: UnsafePointer<UInt8>?, _ count: Int,
                                                 _ mask: Int32, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int,
                                                 _ width: UnsafeMutablePointer<Int>?, _ height: UnsafeMutablePointer<Int>?) -> Int64 {
    guard let layerID, (1...128).contains(count), capacity >= 0,
          let string = String(data: Data(bytes: layerID, count: count), encoding: .utf8), let id = UUID(uuidString: string),
          let snapshot = ProjectSaveSnapshots.get(token),
          let image = (mask == 0 ? snapshot.project.images : snapshot.project.masks)[id]?.image else { return -1 }
    width?.pointee = image.width; height?.pointee = image.height
    let size = image.width * image.height * (mask == 0 ? 4 : 1)
    // Preflight must not materialize a full raster merely to learn its size.
    guard let output, capacity >= size else { return Int64(size) }
    let pixels = image.portableImage
    guard pixels.bytes.count == size else { return -1 }
    pixels.bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }
    return Int64(size)
}

/// Finder Quick Look twin: JPEG bytes for `QuickLook/Preview.jpg` inside the package (same
/// ImageExporter path as macOS). Returns 0 when the canvas is too large to flatten on every save.
@_cdecl("compositor_save_export_preview")
nonisolated public func compositorSaveExportPreview(_ token: UInt64, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard capacity >= 0, ProjectSaveSnapshots.get(token) != nil else { return -1 }
    // The Qt package writer runs on a background thread while the UI thread may be blocked in a local event
    // loop (writeProjectPackage). Flattening for QuickLook here used to hang or fail the whole save.
    _ = output
    return 0
}

/// Only call after successful installation of the package. Autosave releases its
/// snapshot without marking a user save. New edits retain their modified state.
@_cdecl("compositor_save_mark_saved")
nonisolated public func compositorSaveMarkSaved(_ token: UInt64) -> Int32 {
    guard let snapshot = ProjectSaveSnapshots.get(token) else { return -1 }
    return Int32(withEntry(snapshot.sessionHandle) { entry in snapshot.markSaved(in: entry.editor) ? 0 : -1 })
}

@_cdecl("compositor_save_release")
nonisolated public func compositorSaveRelease(_ token: UInt64) {
    ProjectSaveSnapshots.remove(token)
}
