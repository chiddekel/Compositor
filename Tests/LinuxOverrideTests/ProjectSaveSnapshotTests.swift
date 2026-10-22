import Foundation
import Testing
import CoreGraphics
import ImageIO
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

    @Test(arguments: [false, true]) func recoveryLoadHasNoSaveDestinationOrWatcher(recovery: Bool) async throws {
        let (source, editor) = try await create()
        defer { Sessions.entries.removeValue(forKey: source) }
        let token = await Task.detached { compositorSaveCapture(source) }.value
        defer { compositorSaveRelease(token) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-load-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("autosave.comp", isDirectory: true)
        #expect(await Task.detached { package.path.withCString { compositorSaveWritePackage(token, $0, 0) } }.value == 0)
        let handle = await Task.detached { compositorSessionCreate() }.value
        defer { Sessions.entries.removeValue(forKey: handle) }
        let result = await Task.detached {
            var width: Int32 = 0, height: Int32 = 0
            let code = package.path.withCString {
                recovery ? compositorSessionLoadRecovery(handle, $0, &width, &height)
                    : compositorSessionLoadPackage(handle, $0, &width, &height)
            }
            return (code, width, height)
        }.value
        #expect(result.0 == 0 && result.1 == 16 && result.2 == 12)
        let loaded = try #require(Sessions.entries[handle]?.editor)
        #expect(loaded.session.activeLayerID == editor.session.activeLayerID)
        #expect(loaded.session.activeLayer?.name == "Original")
        let changes = loaded.nativeProjects.externalChanges
        if recovery {
            #expect(loaded.session.projectURL == nil)
            #expect(changes.watcher == nil && changes.knownDigest == nil)
        } else {
            #expect(loaded.session.projectURL == package)
            #expect(changes.watcher?.url == package && changes.knownDigest != nil)
            loaded.nativeProjects.stopWatchingProject()
        }
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

    nonisolated private static func preview(_ token: UInt64) throws -> Data {
        let size = compositorSaveExportPreview(token, nil, 0)
        #expect(size > 0)
        guard size > 0 else { return Data() }
        var short = [UInt8](repeating: 73, count: Int(size) - 1)
        #expect(compositorSaveExportPreview(token, &short, short.count) == size)
        #expect(short.allSatisfy { $0 == 73 })
        var bytes = [UInt8](repeating: 0, count: Int(size))
        #expect(compositorSaveExportPreview(token, &bytes, bytes.count) == size)
        return Data(bytes)
    }

    @Test func workerPreviewRetainsCapturedCompositeAfterReplacementAndClose() async throws {
        let (handle, e) = try await create()
        var pixels = [UInt8](repeating: 0, count: 16 * 12 * 4)
        for y in 0..<12 { for x in 0..<8 {
            pixels[(y * 16 + x) * 4] = 255
            pixels[(y * 16 + x) * 4 + 3] = 255
        } }
        #expect(e.importRGBA(pixels, width: 16, height: 12, name: "Captured red", replacing: true) == 0)
        let frozen = try #require(e.session.projectSnapshot())
        let token = await Task.detached { compositorSaveCapture(handle) }.value
        defer { compositorSaveRelease(token) }
        #expect(e.importRGBA([UInt8](repeating: 255, count: 8 * 8 * 4), width: 8, height: 8, name: "New white", replacing: true) == 0)
        await Task.detached { compositorSessionClose(handle) }.value
        let data = try await Task.detached {
            #expect(!Thread.isMainThread)
            return try Self.preview(token)
        }.value
        let expected = try #require(await ImageExporter.shared.quickLookImages(frozen))
        #expect(data == expected.preview)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 16 && image.height == 12)
        let decoded = image.portableImage
        let red = (6 * 16 + 2) * 4, white = (6 * 16 + 13) * 4
        #expect(decoded.bytes[red] > 240 && decoded.bytes[red + 1] < 15 && decoded.bytes[red + 2] < 15)
        #expect(decoded.bytes[white] > 240 && decoded.bytes[white + 1] > 240 && decoded.bytes[white + 2] > 240)
        #expect(decoded.bytes[red + 3] == 255 && decoded.bytes[white + 3] == 255)
        #expect(try await Task.detached { try Self.preview(token) }.value == data)
        #expect(compositorSaveExportPreview(token, nil, -1) == -1)
        compositorSaveRelease(token)
        #expect(compositorSaveExportPreview(token, nil, 0) == -1)
    }

    @Test func previewUsesUpstreamSizeAndLargeCanvasLimit() async throws {
        let (handle, e) = try await create()
        defer { Sessions.entries.removeValue(forKey: handle) }
        #expect(e.importRGBA([UInt8](repeating: 255, count: 2050 * 8 * 4), width: 2050, height: 8, name: "Wide", replacing: true) == 0)
        let token = await Task.detached { compositorSaveCapture(handle) }.value
        defer { compositorSaveRelease(token) }
        let data = try await Task.detached { try Self.preview(token) }.value
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1024 && image.height == 4)
        let manifest = ProjectManifest(documentID: UUID(), width: 8000, height: 8000, activeLayerID: nil, layers: [])
        #expect(e.importManifest(try JSONEncoder().encode(manifest)) == 0)
        let large = await Task.detached { compositorSaveCapture(handle) }.value
        defer { compositorSaveRelease(large) }
        #expect(await Task.detached { compositorSaveExportPreview(large, nil, 0) }.value == 0)
    }

    @Test(arguments: [false, true]) func workerPackagePreservesDeepPixelsAfterReplacementAndClose(hdr: Bool) async throws {
        let (handle, e) = try await create()
        #expect(e.importRGBA([UInt8](repeating: 255, count: 256 * 8 * 4), width: 256, height: 8, name: "Frozen deep", replacing: true) == 0)
        let context = try DeepLayer.context(width: 256, height: 8, hdr: hdr)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        for i in 0..<(256 * 8) {
            let alpha16 = [0, 16384, 32768, 65535][i % 4]
            let alpha = Float(alpha16) / 65535
            let value = hdr ? Float16((2 + Float(i % 256) / 256) * alpha).bitPattern
                : UInt16(((25000 + i % 256) * alpha16 + 32767) / 65535)
            pixels[i * 4] = value; pixels[i * 4 + 1] = value; pixels[i * 4 + 2] = value
            pixels[i * 4 + 3] = hdr ? Float16(alpha).bitPattern : UInt16(alpha16)
        }
        let image = try #require(context.makeImage())
        e.session.document?.layers[0].asset = try hdr ? DeepLayer.wideAsset(image, name: "Frozen deep") : DeepLayer.asset(image, name: "Frozen deep")
        let token = await Task.detached { compositorSaveCapture(handle) }.value
        defer { compositorSaveRelease(token) }
        #expect(e.importRGBA([UInt8](repeating: 0, count: 4 * 4 * 4), width: 4, height: 4, name: "Newer", replacing: true) == 0)
        await Task.detached { compositorSessionClose(handle) }.value
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deep-save-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("saved.comp")
        #expect(await Task.detached { package.path.withCString { compositorSaveWritePackage(token, $0, 1) } }.value == 0)
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("QuickLook/Preview.jpg").path))
        let loaded = try await ProjectStore.shared.load(from: package)
        let asset = try #require(loaded.images.values.first)
        let deep = try #require(asset.deep)
        #expect(deep.bitsPerComponent == 16 && DeepLayer.isHDR(deep) == hdr)
        #expect(loaded.manifest.layers.first?.name == "Frozen deep")
        #expect(loaded.manifest.layers.first?.imageFile?.hasSuffix(hdr ? ".exr" : ".png") == true)
        let decoded = try hdr ? DeepLayer.hdr(deep) : DeepLayer.canonical(deep)
        let actual = try #require(decoded.data).assumingMemoryBound(to: UInt16.self)
        for i in 0..<(256 * 8 * 4) {
            if hdr { #expect(abs(Float(Float16(bitPattern: actual[i])) - Float(Float16(bitPattern: pixels[i]))) < 0.008) }
            else { #expect(abs(Int(actual[i]) - Int(pixels[i])) <= 1) }
        }
        let autosave = directory.appendingPathComponent("autosave.comp")
        #expect(await Task.detached { autosave.path.withCString { compositorSaveWritePackage(token, $0, 0) } }.value == 0)
        #expect(!FileManager.default.fileExists(atPath: autosave.appendingPathComponent("QuickLook/Preview.jpg").path))
        let reopened = await Task.detached { compositorSessionCreate() }.value
        defer { Sessions.entries.removeValue(forKey: reopened) }
        let reopenedResult = await Task.detached {
            var width: Int32 = 0, height: Int32 = 0
            let code = package.path.withCString { compositorSessionLoadPackage(reopened, $0, &width, &height) }
            return (code, width, height)
        }.value
        #expect(reopenedResult.0 == 0 && reopenedResult.1 == 256 && reopenedResult.2 == 8)
        #expect(Sessions.entries[reopened]?.editor.session.activeLayer?.asset?.deep != nil)
        #expect("relative.comp".withCString { compositorSaveWritePackage(token, $0, 0) } == -1)
        compositorSaveRelease(token)
        #expect(package.path.withCString { compositorSaveWritePackage(token, $0, 0) } == -1)
        withExtendedLifetime(context) {}
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
