import Foundation
import Testing
@testable import Compositor

@MainActor
struct ProjectSaveSnapshotTests {
    // Swift Testing may run MainActor on a dispatch-main worker rather than the
    // process main thread. Enter the C bridge from a detached task so its queue
    // hop cannot recursively dispatch_sync the queue currently running this test.
    private func create() async throws -> (UInt64, UpstreamEditor) {
        let handle = await Task.detached { compositorSessionCreate() }.value
        let editor = try #require(Sessions.entries[handle]?.editor)
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 16 * 12 * 4), width: 16, height: 12, name: "Original", replacing: true) == 0)
        return (handle, editor)
    }

    nonisolated private static func manifest(_ token: UInt64) throws -> ProjectManifest {
        let size = compositorSaveExportManifest(token, nil, 0)
        #expect(size > 0)
        var bytes = [UInt8](repeating: 0, count: max(0, Int(size)))
        #expect(compositorSaveExportManifest(token, &bytes, bytes.count) == size)
        return try JSONDecoder().decode(ProjectManifest.self, from: Data(bytes))
    }

    @Test func workerReadsFrozenMetadataAndPixelsAfterEditsAndClose() async throws {
        let (handle, e) = try await create()
        let token = await Task.detached { compositorSaveCapture(handle) }.value
        defer { compositorSaveRelease(token) }
        #expect(token != 0)
        #expect(e.importRGBA([UInt8](repeating: 0, count: 8 * 8 * 4), width: 8, height: 8, name: "Replacement", replacing: true) == 0)
        await Task.detached { compositorSessionClose(handle) }.value
        let frozen = try await Task.detached {
            #expect(!Thread.isMainThread)
            let manifest = try Self.manifest(token)
            let id = Array(try #require(manifest.layers.first).id.uuidString.utf8)
            var width = 0, height = 0
            let size = compositorSaveExportLayer(token, id, id.count, 0, nil, 0, &width, &height)
            #expect(width == 16 && height == 12 && size == 16 * 12 * 4)
            var pixels = [UInt8](repeating: 0, count: Int(size))
            #expect(compositorSaveExportLayer(token, id, id.count, 0, &pixels, pixels.count, &width, &height) == size)
            #expect(pixels.allSatisfy { $0 == 255 })
            return manifest
        }.value
        #expect(frozen.layers.first?.name == "Original")
        #expect(await Task.detached { compositorSaveMarkSaved(token) }.value == -6)
        compositorSaveRelease(token)
        #expect(compositorSaveExportManifest(token, nil, 0) == -1)
    }

    @Test func completionMarksCapturedRevisionAndUndoReturnsToSavedState() async throws {
        let (handle, e) = try await create()
        defer { Sessions.entries.removeValue(forKey: handle) }
        let layer = try #require(e.session.activeLayerID)
        e.session.beginEdit("Before capture")
        e.session.document?.layers[0].name = "Captured"
        e.session.endEdit()
        let token = await Task.detached { compositorSaveCapture(handle) }.value
        defer { compositorSaveRelease(token) }
        e.session.beginEdit("After capture")
        e.session.document?.layers[0].name = "Newer edit"
        e.session.endEdit()
        #expect(await Task.detached { compositorSaveMarkSaved(token) }.value == 0)
        #expect(e.session.history.isModified)
        #expect(await e.commandAsync(Data(#"{"version":1,"action":"undo"}"#.utf8)) == 0)
        #expect(e.session.activeLayerID == layer)
        #expect(e.session.document?.layers[0].name == "Captured")
        #expect(!e.session.history.isModified)
        #expect(await e.commandAsync(Data(#"{"version":1,"action":"redo"}"#.utf8)) == 0)
        #expect(e.session.history.isModified)
    }

    @Test func autosaveReleaseAndReloadDoNotMarkCurrentDocumentSaved() async throws {
        let (handle, e) = try await create()
        defer { Sessions.entries.removeValue(forKey: handle) }
        e.session.beginEdit("Unsaved edit")
        e.session.document?.layers[0].name = "Unsaved"
        e.session.endEdit()
        let autosave = await Task.detached { compositorSaveCapture(handle) }.value
        compositorSaveRelease(autosave)
        #expect(e.session.history.isModified)
        let pending = await Task.detached { compositorSaveCapture(handle) }.value
        defer { compositorSaveRelease(pending) }
        let manifest = try e.exportManifest()
        #expect(e.importManifest(manifest) == 0)
        e.session.beginEdit("Edit reloaded document")
        e.session.document?.layers[0].name = "After reload"
        e.session.endEdit()
        #expect(await Task.detached { compositorSaveMarkSaved(pending) }.value == -1)
        #expect(e.session.history.isModified)
    }
}
