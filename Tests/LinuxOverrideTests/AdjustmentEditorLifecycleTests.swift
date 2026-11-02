import Foundation
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct AdjustmentEditorLifecycleTests {
    private func send(_ editor: UpstreamEditor, _ action: String, _ fields: [String: Any] = [:]) async throws -> Int32 {
        var command = fields
        command["action"] = action
        command["version"] = 1
        return await editor.commandAsync(try JSONSerialization.data(withJSONObject: command))
    }

    @Test(arguments: [false, true])
    func noneditableRequestPreservesHistoryAndCanOpenTheNextEditor(explicitTarget: Bool) async throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 200, count: 8 * 8 * 4), width: 8, height: 8,
                                  name: "Original", replacing: true) == 0)
        let session = editor.session
        session.addAdjustment(.invert)
        let id = try #require(session.activeLayerID)
        let ids = session.document?.layers.map(\.id)
        let revision = session.history.currentRevision
        let pixels = try editor.renderRGBA().bytes
        var command: [String: Any] = ["action": "beginAdjustmentEditing", "version": 1]
        if explicitTarget { command["layerID"] = id.uuidString }
        let result = await editor.commandAsync(try JSONSerialization.data(withJSONObject: command))
        #expect(result == -1, "Invert has no editable settings, so the request must be refused before starting an edit")
        #expect(session.adjustmentEditingID == nil)
        #expect(session.adjustmentOriginal == nil)
        #expect(session.filterEdit == nil && session.levels == nil && session.hueSaturation == nil)
        #expect(session.canEditLayers)
        #expect(session.activeLayerID == id && session.document?.layers.map(\.id) == ids)
        #expect(session.history.currentRevision == revision)
        #expect(try editor.renderRGBA().bytes == pixels)

        let next = try JSONSerialization.data(withJSONObject: ["action": "addAdjustment", "kind": "Exposure", "version": 1])
        #expect(await editor.commandAsync(next) == 0)
        #expect(session.activeLayerID != id)
        #expect(session.filterEdit?.kind == .exposure)
        #expect(session.adjustmentOriginal?.kind == .exposure)
        #expect(session.document?.layers.count == 3)
        #expect(try editor.renderRGBA().bytes == pixels, "The next editor must open without changing the original composite")
        #expect(session.finishAdjustmentEditing(commit: false))
        #expect(session.canEditLayers)
    }

    @Test func noneditableRequestDoesNotCommitAnUnrelatedGradient() async throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 200, count: 8 * 8 * 4), width: 8, height: 8,
                                  name: "Original", replacing: true) == 0)
        let session = editor.session
        let source = try #require(session.activeLayerID)
        session.addAdjustment(.invert)
        let invert = try #require(session.activeLayerID)
        session.selectLayer(source)
        let original = try editor.renderRGBA().bytes
        #expect(try await send(editor, "gradientBegin", ["x": 0, "y": 0]) == 0)
        #expect(try await send(editor, "gradientMove", ["x": 7, "y": 7]) == 0)
        #expect(try await send(editor, "gradientEndDrag") == 0)
        let draft = try #require(session.gradientEdit)
        let revision = session.history.currentRevision
        let ids = session.document?.layers.map(\.id)
        let preview = try editor.renderRGBA().bytes
        #expect(try await send(editor, "beginAdjustmentEditing", ["layerID": invert.uuidString]) == -1)
        #expect(session.gradientEdit === draft)
        #expect(session.adjustmentEditingID == nil && session.adjustmentOriginal == nil)
        #expect(session.activeLayerID == source && session.document?.layers.map(\.id) == ids)
        #expect(session.history.currentRevision == revision)
        #expect(try editor.renderRGBA().bytes == preview)
        #expect(try await send(editor, "gradientCancel") == 0)
        #expect(session.canEditLayers)
        #expect(try editor.renderRGBA().bytes == original)
        _ = session.finishAdjustmentEditing(commit: false)
    }
}
