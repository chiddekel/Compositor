import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor
@Suite(.serialized)
struct BusyImportRecoveryTests {
    @Test(arguments: [false, true])
    func replacementImportRetiresOldProjectWatch(fileImport: Bool) async throws {
        let editor = UpstreamEditor()
        let pixels = [UInt8](repeating: 255, count: 16 * 12 * 4)
        #expect(editor.importRGBA(pixels, width: 16, height: 12, name: "Original", replacing: true) == 0)
        let session = editor.session, controller = editor.nativeProjects
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { controller.stopWatchingProject(); try? FileManager.default.removeItem(at: package) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: package)
        session.projectURL = package
        await controller.rememberProjectDigest(for: package)
        controller.watchProject(at: package)
        let watcher = try #require(controller.externalChanges.watcher)
        let digest = controller.externalChanges.knownDigest

        // A refused replacement and an ordinary inserted layer keep the current package binding.
        #expect(editor.importRGBA([], width: 16, height: 12, name: "Invalid", replacing: true) == -1)
        session.isProjectBusy = true
        #expect(editor.importRGBA(pixels, width: 16, height: 12, name: "Busy", replacing: true) == -3)
        session.isProjectBusy = false
        #expect(editor.importRGBA(pixels, width: 16, height: 12, name: "Inserted", replacing: false) == 0)
        #expect(controller.externalChanges.watcher === watcher && controller.externalChanges.knownDigest == digest)
        #expect(session.projectURL == package)
        let generation = editor.persistenceGeneration
        if fileImport {
            let file = try ImageImportTests().fixture(.png)
            defer { try? FileManager.default.removeItem(at: file) }
            let missing = try JSONSerialization.data(withJSONObject: ["version": 1, "action": "importFiles",
                "paths": [file.path + ".missing"], "enabled": true])
            #expect(await editor.commandAsync(missing) == -5)
            #expect(controller.externalChanges.watcher === watcher && session.projectURL == package)
            let command = try JSONSerialization.data(withJSONObject: ["version": 1, "action": "importFiles",
                "paths": [file.path], "enabled": true])
            #expect(await editor.commandAsync(command) == 0)
        } else {
            #expect(editor.importRGBA(pixels, width: 16, height: 12, name: "Replacement", replacing: true) == 0)
        }
        #expect(session.projectURL == nil)
        #expect(controller.externalChanges.watcher == nil && controller.externalChanges.knownDigest == nil)
        #expect(!controller.externalChanges.pending && controller.externalChanges.recheck == nil)
        #expect(editor.persistenceGeneration != generation)
        let replacement = session.document, revision = session.history.currentRevision
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.manifest)) as? [String: Any])
        var layers = try #require(json["layers"] as? [[String: Any]])
        layers[0]["name"] = "Changed old package"
        json["layers"] = layers
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: JSONSerialization.data(withJSONObject: json))
        let changed = ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
        try await ProjectStore.shared.save(changed, to: package)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(session.document == replacement && session.history.currentRevision == revision)
        #expect(controller.externalChanges.reloadCount == 0)
    }

    nonisolated private static let blockers = ["project", "import", "newDocument", "importer", "conversion", "rename", "error", "adjustment"]
    nonisolated private static let operations = ["replaceRGBA", "appendRGBA", "manifest"]

    @Test(arguments: ["psd", "psb"])
    func folderImportIncludesPhotoshopFiles(ext: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["2 Layers." + ext.uppercased(), "10 Image.png", ".Hidden." + ext] {
            try Data([0]).write(to: folder.appendingPathComponent(name))
        }
        #expect(ImageFolder.images(in: folder).map(\.lastPathComponent) == ["2 Layers." + ext.uppercased(), "10 Image.png"])
    }

    @Test(arguments: ["selectLayer", "missingLayer", "renameLayer", "setVisible", "setOpacity", "setSelectedOpacity",
        "setBlendMode", "setMaskEnabled", "setMaskLinked", "moveLayer", "selectRectangle", "selectEllipse",
        "selectLasso", "shapeBegin", "shapeDrag", "textBegin", "textEditAt", "textBeginBox", "brushBegin",
        "brushMove", "cloneSetSource", "magicWand", "openFilter", "filterBegin", "addAdjustment", "addLayerEffect",
        "selectTool", "addShape", "warpBegin", "warpMove", "resizeCanvas", "cropCanvas", "resizeImage",
        "exportPNG", "exportPDF", "badAnchor", "badSampling", "zeroCanvas", "zeroImage", "emptyImport",
        "badBlend", "badTool", "badFilter", "badAdjustment", "badEffect", "badShape", "badWarp",
        "maskMissing", "maskLinkMissing", "cloneWithoutSource", "imageResolution", "cropOffset",
        "hugeFeather", "hugeExpand", "hugeContract", "hugeSelectionAmount", "hugeLayerMove",
        "hugeWand", "hugeDistort", "hugeHealingMode"])
    func malformedSupportedCommandPreservesGradientAndRecovers(request: String) async throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 16 * 12 * 4), width: 16, height: 12,
                                  name: "Original", replacing: true) == 0)
        func send(_ action: String, _ fields: [String: Any] = [:]) async throws -> Int32 {
            var command = fields; command["version"] = 1; command["action"] = action
            return await editor.commandAsync(try JSONSerialization.data(withJSONObject: command))
        }
        #expect(try await send("gradientBegin", ["x": 0, "y": 0]) == 0)
        #expect(try await send("gradientMove", ["x": 15, "y": 11]) == 0)
        #expect(try await send("gradientEndDrag") == 0)
        let session = editor.session, draft = try #require(editor.session.gradientEdit)
        let image = session.activeLayer?.asset?.image, revision = session.history.currentRevision
        let documentID = session.document?.id, layerID = session.activeLayerID
        let frame = try editor.renderRGBA().bytes
        var action = request, fields: [String: Any] = [:], expected: Int32 = -1
        switch request {
        case "missingLayer": action = "selectLayer"; fields["layerID"] = UUID().uuidString; expected = -5
        case "badAnchor": action = "resizeCanvas"; fields = ["width": 24, "height": 20, "parameters": ["anchor": 9]]
        case "badSampling": action = "resizeImage"; fields = ["width": 24, "height": 20, "kind": "invalid"]
        case "zeroCanvas": action = "resizeCanvas"; fields = ["width": 0, "height": 20]; expected = -5
        case "zeroImage": action = "resizeImage"; fields = ["width": 0, "height": 20]; expected = -5
        case "emptyImport": action = "importFiles"; fields["paths"] = [String]()
        case "badBlend": action = "setBlendMode"; fields["kind"] = "invalid"
        case "badTool": action = "selectTool"; fields["kind"] = "invalid"
        case "badFilter": action = "openFilter"; fields["kind"] = "invalid"
        case "badAdjustment": action = "addAdjustment"; fields["kind"] = "invalid"
        case "badEffect": action = "addLayerEffect"; fields["kind"] = "invalid"
        case "badShape": action = "addShape"; fields = ["kind": "invalid", "width": 24, "height": 20, "x": 0, "y": 0]
        case "badWarp": action = "warpBegin"; fields = ["kind": "invalid", "x": 4, "y": 3]
        case "maskMissing": action = "setMaskEnabled"; fields["enabled"] = true
        case "maskLinkMissing": action = "setMaskLinked"; fields["enabled"] = true
        case "cloneWithoutSource": action = "brushBegin"; fields = ["kind": "Clone", "x": 4, "y": 3]; expected = -5
        case "imageResolution": action = "resizeImage"; fields = ["width": 24, "height": 20, "value": 0]; expected = -5
        case "cropOffset": action = "cropCanvas"; fields = ["width": 24, "height": 20, "x": 1_000_001]; expected = -5
        case "hugeFeather": action = "featherSelection"; fields["parameters"] = ["amount": 1e300]
        case "hugeExpand": action = "expandSelection"; fields["parameters"] = ["amount": 1e300]
        case "hugeContract": action = "contractSelection"; fields["parameters"] = ["amount": 1e300]
        case "hugeSelectionAmount": action = "setSelectionExpandAmount"; fields["parameters"] = ["amount": 1e300]
        case "hugeLayerMove": action = "moveActiveLayer"; fields["value"] = 1e300
        case "hugeWand": action = "magicWand"; fields = ["x": 4, "y": 3, "parameters": ["tolerance": 1e300]]
        case "hugeDistort": action = "distortDragBegin"; fields = ["x": 4, "y": 3, "value": 1e300]
        case "hugeHealingMode": action = "brushBegin"; fields = ["x": 4, "y": 3, "parameters": ["healing": 1, "healingMode": 1e300]]
        default: break
        }
        #expect(UpstreamEditor.supportedActions.contains(action))
        #expect(try await send(action, fields) == expected)
        #expect(session.document?.id == documentID && session.activeLayerID == layerID)
        #expect(session.activeLayer?.asset?.image === image && session.gradientEdit === draft)
        #expect(session.history.currentRevision == revision && !session.history.canUndo)
        #expect(try editor.renderRGBA().bytes == frame)
        #expect(try await send("gradientCancel") == 0)
        #expect(session.gradientEdit == nil && session.activeLayer?.asset?.image === image)
        #expect(session.history.currentRevision == revision)
        #expect(try await send("setOpacity", ["value": 0.5]) == 0)
        #expect(session.activeLayer?.opacity == 0.5 && session.history.canUndo)
        #expect(editor.error == nil)
    }

    @Test(arguments: ["featherSelection", "expandSelection", "contractSelection", "setSelectionExpandAmount",
        "moveActiveLayer", "magicWand", "distortDragBegin", "brushBegin"],
        [1e300, -1e300, Double(Int.max), Double(Int.min).nextDown])
    func outOfRangeIntegerCommandRefusesWithoutDraftAndRecovers(action: String, value: Double) async throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 16 * 12 * 4), width: 16, height: 12,
                                  name: "Original", replacing: true) == 0)
        let session = editor.session, documentID = session.document?.id
        let image = session.activeLayer?.asset?.image, revision = session.history.currentRevision, tool = session.tool
        let frame = try editor.renderRGBA().bytes
        var fields: [String: Any] = ["version": 1, "action": action]
        switch action {
        case "moveActiveLayer": fields["value"] = value
        case "distortDragBegin": fields["value"] = value; fields["x"] = 4; fields["y"] = 3
        case "magicWand": fields["parameters"] = ["tolerance": value]; fields["x"] = 4; fields["y"] = 3
        case "brushBegin": fields["parameters"] = ["healing": 1, "healingMode": value]; fields["x"] = 4; fields["y"] = 3
        default: fields["parameters"] = ["amount": value]
        }
        #expect(await editor.commandAsync(try JSONSerialization.data(withJSONObject: fields)) == -1)
        #expect(session.document?.id == documentID && session.activeLayer?.asset?.image === image)
        #expect(session.history.currentRevision == revision && !session.history.canUndo)
        #expect(session.gradientEdit == nil && session.brushStroke == nil && session.transformEdit == nil)
        #expect(session.tool == tool)
        #expect(try editor.renderRGBA().bytes == frame)
        for amount in [1.75, -1.75] {
            let valid: [String: Any] = ["version": 1, "action": "setSelectionExpandAmount", "parameters": ["amount": amount]]
            #expect(await editor.commandAsync(try JSONSerialization.data(withJSONObject: valid)) == 0)
            #expect(session.selectionExpandAmount == Int(amount) && editor.error == nil)
        }
    }

    @Test
    func selectionSettingsRemainAdvertisedAndExecutable() async throws {
        let editor = UpstreamEditor()
        #expect(UpstreamEditor.supportedActions.contains("setSelectionExpandAmount"))
        #expect(UpstreamEditor.supportedActions.contains("setSelectionMode"))
        let amount = try JSONSerialization.data(withJSONObject: ["version": 1, "action": "setSelectionExpandAmount",
                                                                "parameters": ["amount": 7]])
        let mode = try JSONSerialization.data(withJSONObject: ["version": 1, "action": "setSelectionMode",
                                                              "kind": SelectionMode.subtract.rawValue])
        #expect(await editor.commandAsync(amount) == 0)
        #expect(editor.session.selectionExpandAmount == 7)
        #expect(await editor.commandAsync(mode) == 0)
        #expect(editor.session.selectionModeChoice == .subtract)
    }

    @Test(arguments: ["unsupported", "missingWidth", "missingHeight", "zeroWidth", "zeroHeight", "wide", "tall"])
    func invalidProjectCommandPreservesPendingGradientAndCanCancel(request: String) async throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 16 * 12 * 4), width: 16, height: 12,
                                  name: "Original", replacing: true) == 0)
        func send(_ action: String, _ fields: [String: Any] = [:]) async throws -> Int32 {
            var command = fields
            command["version"] = 1
            command["action"] = action
            return await editor.commandAsync(try JSONSerialization.data(withJSONObject: command))
        }
        #expect(try await send("gradientBegin", ["x": 0, "y": 0]) == 0)
        #expect(try await send("gradientMove", ["x": 15, "y": 11]) == 0)
        #expect(try await send("gradientEndDrag") == 0)
        let session = editor.session
        let draft = try #require(session.gradientEdit)
        let documentID = session.document?.id
        let layerID = session.activeLayerID
        let image = session.activeLayer?.asset?.image
        let revision = session.history.currentRevision
        let frame = try editor.renderRGBA().bytes
        var fields: [String: Any] = ["width": 24, "height": 20]
        switch request {
        case "missingWidth": fields.removeValue(forKey: "width")
        case "missingHeight": fields.removeValue(forKey: "height")
        case "zeroWidth": fields["width"] = 0
        case "zeroHeight": fields["height"] = 0
        case "wide": fields["width"] = 30_001
        case "tall": fields["height"] = 30_001
        default: break
        }
        #expect(try await send(request == "unsupported" ? "unknownAction" : "new", fields) == (request == "unsupported" ? -7 : -1))
        #expect(session.document?.id == documentID)
        #expect(session.activeLayerID == layerID)
        #expect(session.activeLayer?.asset?.image === image)
        #expect(session.gradientEdit === draft)
        #expect(session.history.currentRevision == revision)
        #expect(!session.history.canUndo)
        #expect(try editor.renderRGBA().bytes == frame)
        #expect(try await send("gradientCancel") == 0)
        #expect(session.gradientEdit == nil)
        #expect(session.activeLayer?.asset?.image === image)
        #expect(session.history.currentRevision == revision)
        #expect(editor.error == nil)
    }

    @Test(arguments: blockers)
    func newCanvasRefusesBlockedSessionBeforeResolvingGradientAndRecovers(blocker: String) async throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 16 * 12 * 4), width: 16, height: 12,
                                  name: "Original", replacing: true) == 0)
        func send(_ action: String, _ fields: [String: Any] = [:]) async throws -> Int32 {
            var command = fields
            command["version"] = 1
            command["action"] = action
            return await editor.commandAsync(try JSONSerialization.data(withJSONObject: command))
        }
        #expect(try await send("gradientBegin", ["x": 0, "y": 0]) == 0)
        #expect(try await send("gradientMove", ["x": 15, "y": 11]) == 0)
        #expect(try await send("gradientEndDrag") == 0)
        let session = editor.session
        let draft = try #require(session.gradientEdit)
        let documentID = session.document?.id
        let layerID = session.activeLayerID
        let image = session.activeLayer?.asset?.image
        let revision = session.history.currentRevision
        let frame = try editor.renderRGBA().bytes
        block(blocker, session: session, enabled: true)
        defer { block(blocker, session: session, enabled: false) }
        let originalError = session.importError
        let originalRename = session.renamingLayerID
        #expect(try await send("new", ["width": 24, "height": 20, "emptyLayer": true]) == -3)
        #expect(session.document?.id == documentID)
        #expect(session.activeLayerID == layerID)
        #expect(session.activeLayer?.asset?.image === image)
        #expect(session.gradientEdit === draft)
        #expect(session.history.currentRevision == revision)
        #expect(try editor.renderRGBA().bytes == frame)
        #expect(session.importError == originalError)
        #expect(session.renamingLayerID == originalRename)
        block(blocker, session: session, enabled: false)
        #expect(try await send("new", ["width": 24, "height": 20, "emptyLayer": true]) == 0)
        #expect(session.document?.id != documentID)
        #expect(session.document?.width == 24)
        #expect(session.document?.height == 20)
        #expect(session.gradientEdit == nil)
        #expect(editor.error == nil)
    }

    @Test
    func refusedFileImportLeavesPendingGradientUnchanged() async throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 0, count: 64 * 64 * 4), width: 64, height: 64,
                                  name: "Original", replacing: true) == 0)
        func send(_ action: String, _ fields: [String: Any] = [:]) async throws -> Int32 {
            var command = fields
            command["version"] = 1
            command["action"] = action
            return await editor.commandAsync(try JSONSerialization.data(withJSONObject: command))
        }
        #expect(try await send("gradientBegin", ["x": 0, "y": 0]) == 0)
        #expect(try await send("gradientMove", ["x": 63, "y": 63]) == 0)
        #expect(try await send("gradientEndDrag") == 0)
        let session = editor.session
        let pending = try #require(session.gradientEdit)
        let image = session.activeLayer?.asset?.image
        let revision = session.history.currentRevision
        let frame = try editor.renderRGBA().bytes
        session.renamingLayerID = session.activeLayerID
        #expect(try await send("importFiles", ["paths": ["/nonexistent/import.png"], "enabled": true]) == -3)
        #expect(session.gradientEdit === pending)
        #expect(session.activeLayer?.asset?.image === image)
        #expect(session.history.currentRevision == revision)
        #expect(try editor.renderRGBA().bytes == frame)
        session.renamingLayerID = nil
        #expect(try await send("gradientCancel") == 0)
        #expect(session.gradientEdit == nil)
        #expect(session.history.currentRevision == revision)
    }

    @Test(arguments: ["missing", "corrupt", "mixed"], [false, true])
    func replacementDecodeFailurePreservesDocumentHistoryAndRetry(failure: String, pendingGradient: Bool) async throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 16 * 12 * 4), width: 16, height: 12,
                                  name: "Original", replacing: true) == 0)
        let session = editor.session
        session.beginEdit("Rename")
        session.document?.layers[0].name = "Unsaved"
        session.endEdit()
        if pendingGradient {
            let command: [String: Any] = ["version": 1, "action": "gradientBegin", "x": 0, "y": 0]
            #expect(await editor.commandAsync(try JSONSerialization.data(withJSONObject: command)) == 0)
            session.moveGradient(end: CGPoint(x: 15, y: 11))
            session.endGradientDrag()
        }
        let gradient = session.gradientEdit
        let document = session.document, image = session.activeLayer?.asset?.image
        let revision = session.history.currentRevision, frame = try editor.renderRGBA().bytes
        let valid = try ImageImportTests().fixture(.png)
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data("invalid PNG".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: valid); try? FileManager.default.removeItem(at: corrupt) }
        let paths = failure == "missing" ? [corrupt.path + ".missing"] : failure == "mixed" ? [valid.path, corrupt.path] : [corrupt.path]
        func send(_ paths: [String]) async throws -> Int32 {
            await editor.commandAsync(try JSONSerialization.data(withJSONObject:
                ["version": 1, "action": "importFiles", "paths": paths, "enabled": true]))
        }
        #expect(try await send(paths) == -5)
        #expect(session.gradientEdit === gradient && !session.isProjectBusy)
        #expect(session.document == document && session.activeLayer?.asset?.image === image)
        #expect(session.history.currentRevision == revision && session.history.isModified && session.history.canUndo)
        #expect(try editor.renderRGBA().bytes == frame)
        session.cancelGradient()
        session.undo()
        #expect(session.activeLayer?.name == "Original" && session.history.canRedo)
        session.redo()
        #expect(session.activeLayer?.name == "Unsaved" && session.history.currentRevision == revision)
        #expect(try await send([valid.path]) == 0)
        #expect(session.document?.id != document?.id && session.document?.width == 64)
        #expect(session.history.canUndo && session.history.isModified && editor.error == nil)
        session.undo()
        #expect(session.document == nil)
        session.redo()
        #expect(session.document?.width == 64)
    }

    @Test
    func replacementFileImportWhileRenamingDoesNotClearProject() async throws {
        let editor = UpstreamEditor()
        let pixels = [UInt8](repeating: 255, count: 16 * 12 * 4)
        #expect(editor.importRGBA(pixels, width: 16, height: 12, name: "Original", replacing: true) == 0)
        let session = editor.session
        session.beginEdit("Unsaved rename")
        session.document?.layers[0].name = "Unsaved"
        session.endEdit()
        let documentID = session.document?.id
        let layerID = session.activeLayerID
        let revision = session.history.currentRevision
        let file = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: file) }
        let command = try JSONSerialization.data(withJSONObject: ["version": 1, "action": "importFiles",
                                                                  "paths": [file.path], "enabled": true])
        session.renamingLayerID = layerID
        #expect(await editor.commandAsync(command) == -3)
        #expect(session.document?.id == documentID)
        #expect(session.activeLayerID == layerID)
        #expect(session.renamingLayerID == layerID)
        #expect(session.activeLayer?.name == "Unsaved")
        #expect(session.history.currentRevision == revision)
        #expect(session.history.canUndo)
    }

    private func block(_ name: String, session: EditorSession, enabled: Bool) {
        switch name {
        case "project": session.isProjectBusy = enabled
        case "import": session.isImporting = enabled
        case "newDocument": session.showsNewDocument = enabled
        case "importer": session.showsImporter = enabled
        case "conversion": session.showsConversionSheet = enabled
        case "rename": session.renamingLayerID = enabled ? session.activeLayerID : nil
        case "error": session.importError = enabled ? "Decode failed" : nil
        case "adjustment": session.adjustmentEditingID = enabled ? session.activeLayerID : nil
        default: preconditionFailure("Unknown import blocker")
        }
    }

    @Test(arguments: blockers, [false, true])
    func fileImportRefusesBlockedSessionAndRecovers(blocker: String, replacing: Bool) async throws {
        let editor = UpstreamEditor()
        let pixels = [UInt8](repeating: 255, count: 16 * 12 * 4)
        #expect(editor.importRGBA(pixels, width: 16, height: 12, name: "Original", replacing: true) == 0)
        let session = editor.session
        session.beginEdit("Unsaved rename")
        session.document?.layers[0].name = "Unsaved"
        session.endEdit()
        let documentID = session.document?.id
        let layerID = session.activeLayerID
        let image = session.activeLayer?.asset?.image
        let revision = session.history.currentRevision
        let file = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: file) }
        let command = try JSONSerialization.data(withJSONObject: ["version": 1, "action": "importFiles",
                                                                  "paths": [file.path], "enabled": replacing])
        block(blocker, session: session, enabled: true)
        defer { block(blocker, session: session, enabled: false) }
        let originalError = session.importError
        let originalRename = session.renamingLayerID
        #expect(await editor.commandAsync(command) == -3)
        #expect(!session.canStartProjectOperation)
        #expect(session.document?.id == documentID)
        #expect(session.document?.layers.map(\.id) == [layerID].compactMap { $0 })
        #expect(session.activeLayerID == layerID)
        #expect(session.activeLayer?.asset?.image === image)
        #expect(session.activeLayer?.name == "Unsaved")
        #expect(session.history.currentRevision == revision)
        #expect(session.history.canUndo)
        #expect(session.importError == originalError)
        #expect(session.renamingLayerID == originalRename)
        block(blocker, session: session, enabled: false)
        #expect(session.canStartProjectOperation)
        #expect(await editor.commandAsync(command) == 0)
        #expect(editor.error == nil)
        #expect(session.activeLayer?.asset?.image.width == 64)
        #expect(session.activeLayer?.asset?.image.height == 32)
        if replacing {
            #expect(session.document?.id != documentID)
            #expect(session.document?.layers.count == 1)
        } else {
            #expect(session.document?.id == documentID)
            #expect(session.document?.layers.count == 2)
            session.undo()
            #expect(session.document?.layers.map(\.id) == [layerID].compactMap { $0 })
            #expect(session.activeLayer?.asset?.image === image)
            #expect(session.history.currentRevision == revision)
        }
    }

    @Test(arguments: blockers, operations)
    func directImportRefusesBlockedSessionAndRecovers(blocker: String, operation: String) throws {
        let editor = UpstreamEditor()
        let pixels = [UInt8](repeating: 255, count: 16 * 12 * 4)
        #expect(editor.importRGBA(pixels, width: 16, height: 12, name: "Original", replacing: true) == 0)
        let session = editor.session
        session.beginEdit("Unsaved rename")
        session.document?.layers[0].name = "Unsaved"
        session.endEdit()
        let manifest = try editor.exportManifest()
        let documentID = session.document?.id
        let layerIDs = session.document?.layers.map(\.id)
        let activeID = session.activeLayerID
        let image = session.activeLayer?.asset?.image
        let revision = session.history.currentRevision
        #expect(session.history.canUndo)
        func runImport() -> Int32 {
            if operation == "manifest" { return editor.importManifest(manifest) }
            return editor.importRGBA(pixels, width: 16, height: 12, name: "Imported", replacing: operation == "replaceRGBA")
        }
        block(blocker, session: session, enabled: true)
        defer { block(blocker, session: session, enabled: false) }
        #expect(!session.canStartProjectOperation)
        #expect(runImport() == -3)
        #expect(session.document?.id == documentID)
        #expect(session.document?.layers.map(\.id) == layerIDs)
        #expect(session.activeLayerID == activeID)
        #expect(session.activeLayer?.asset?.image === image)
        #expect(session.activeLayer?.name == "Unsaved")
        #expect(session.history.currentRevision == revision)
        #expect(session.history.canUndo)
        block(blocker, session: session, enabled: false)
        #expect(session.canStartProjectOperation)
        #expect(runImport() == 0)
        #expect(editor.error == nil)
        if operation == "appendRGBA" {
            #expect(session.document?.layers.count == 2)
            #expect(session.activeLayer?.name == "Imported")
            #expect(session.history.canUndo)
            session.undo()
            #expect(session.document?.layers.map(\.id) == layerIDs)
            #expect(session.activeLayer?.asset?.image === image)
        } else {
            #expect(!session.history.canUndo)
        }
    }
}
