// Portable port of Compositor/Document/DocumentHistory.swift (file-map tier: "Keep
// logic; replace Apple operations"). The undo/redo/trim logic is ported verbatim.
// The macOS original is `@Observable final class` (SwiftUI Observation); on Linux
// the `@Observable` macro is not available, so the class is a plain `final class`.
// Its mutation surface (begin/end/undo/redo/markSaved/reset) is unchanged — the
// Qt-side document controller will observe it through signals where SwiftUI used
// `@Observable`. The logic operates on `CanvasDocument` (ported) and tracks image
// retention via `ObjectIdentifier` on `RasterImage` (the reference-typed CGImage
// stand-in), exactly as macOS tracked `CGImage` identity.
//
// SOLID: the class keeps its responsibility and contract (bounded undo/redo with
// byte-retention trimming); the Apple API surface (@Observable) is exchanged.
// The macOS original stays the source of truth.

import Foundation

/// Value snapshots share immutable rasters; no pixel copies for layer edits.
final class DocumentHistory {
    struct Snapshot {
        let document: CanvasDocument?
        let activeLayerID: UUID?
        let revision: UUID
    }
    private struct Entry {
        let name: String
        let before: Snapshot
        let after: Snapshot
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    private var revision = UUID()
    private var savedRevision: UUID?
    private var pending: Snapshot?
    private var pendingName = "Edit"
    private var depth = 0
    let entryLimit: Int
    let retainedByteLimit: Int

    init(entryLimit: Int = 100, retainedByteLimit: Int = 256 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.retainedByteLimit = max(0, retainedByteLimit)
        savedRevision = revision
    }

    var canUndo: Bool { depth == 0 && !past.isEmpty }
    var canRedo: Bool { depth == 0 && !future.isEmpty }
    var undoName: String { past.last?.name ?? "" }
    var redoName: String { future.last?.name ?? "" }
    var isModified: Bool { revision != savedRevision }
    var undoCount: Int { past.count }
    func markSaved() { savedRevision = revision }
    func reset() {
        past.removeAll()
        future.removeAll()
        pending = nil
        depth = 0
        revision = UUID()
        savedRevision = revision
    }

    func begin(_ name: String, document: CanvasDocument?, selection: UUID?) {
        if depth == 0 {
            pending = Snapshot(document: document, activeLayerID: selection, revision: revision)
            pendingName = name
        }
        depth += 1
    }

    func end(document: CanvasDocument?, selection: UUID?) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0, let before = pending else { return }
        pending = nil
        // Selecting, navigating, and no-op edits must preserve redo history.
        guard before.document != document else { return }
        revision = UUID()
        past.append(Entry(name: pendingName, before: before,
            after: Snapshot(document: document, activeLayerID: selection, revision: revision)))
        future.removeAll()
        trim(current: document)
    }

    func undo() -> Snapshot? {
        guard canUndo, let entry = past.popLast() else { return nil }
        future.append(entry)
        revision = entry.before.revision
        trim(current: entry.before.document)
        return entry.before
    }

    func redo() -> Snapshot? {
        guard canRedo, let entry = future.popLast() else { return nil }
        past.append(entry)
        revision = entry.after.revision
        trim(current: entry.after.document)
        return entry.after
    }

    /// Bytes retained only by history, excluding images in the live document.
    func retainedBytes(current: CanvasDocument?) -> Int {
        var seen = Set<ObjectIdentifier>()
        for layer in current?.layers ?? [] {
            for asset in [layer.asset, layer.mask?.asset].compactMap({ $0 }) {
                seen.insert(ObjectIdentifier(asset.image))
                seen.insert(ObjectIdentifier(asset.thumbnail))
            }
        }
        var bytes = 0
        for entry in past + future {
            for snapshot in [entry.before, entry.after] {
                for layer in snapshot.document?.layers ?? [] {
                    for asset in [layer.asset, layer.mask?.asset].compactMap({ $0 }) {
                        for image in [asset.image, asset.thumbnail] where seen.insert(ObjectIdentifier(image)).inserted {
                            bytes += image.bytesPerRow * image.height
                        }
                    }
                }
            }
        }
        return bytes
    }

    private func trim(current: CanvasDocument?) {
        while past.count + future.count > entryLimit || retainedBytes(current: current) > retainedByteLimit {
            if !past.isEmpty { past.removeFirst() }
            else if !future.isEmpty { future.removeFirst() }
            else { break }
        }
    }
}