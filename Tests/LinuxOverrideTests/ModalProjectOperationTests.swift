import Foundation
import Testing
@testable import Compositor

/// Upstream ProjectController.begin(): Trim, Canvas Size, Image Size and Export As hold the project busy while their
/// sheet (and Export As's save panel) is up. Undo, layer edits and other project operations are refused meanwhile
/// without changing the document, and everything works again once the sheet is answered.
@MainActor
@Suite(.serialized)
struct ModalProjectOperationTests {
    private func editor() -> UpstreamEditor {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 200, count: 16 * 12 * 4), width: 16, height: 12,
                                  name: "Original", replacing: true) == 0)
        return editor
    }
    private func send(_ editor: UpstreamEditor, _ action: String, _ fields: [String: Any] = [:]) async throws -> Int32 {
        var command = fields; command["version"] = 1; command["action"] = action
        return await editor.commandAsync(try JSONSerialization.data(withJSONObject: command))
    }
    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test(arguments: ["trim", "canvasSizeSheet", "imageSizeSheet", "exportAsSheet"])
    func anOpenSheetHoldsTheProjectUntilAnswered(sheet: String) async throws {
        let editor = editor()
        #expect(try await send(editor, "addLayer") == 0)
        let session = editor.session
        let layers = session.document?.layers.map(\.id), revision = session.history.currentRevision
        let opened = Task { try await send(editor, sheet) }
        await waitFor { editor.trimSheet != nil || editor.canvasSizeSheet != nil || editor.imageSizeSheet != nil
            || editor.exportAsSheet != nil }
        #expect(session.isProjectBusy && !session.canStartProjectOperation && !session.canUndo)
        // Commands arriving meanwhile (a menu, a shortcut through the event pump) change nothing.
        _ = try await send(editor, "addLayer")
        _ = try await send(editor, "undo")
        #expect(try await send(editor, "new", ["width": 8, "height": 8]) == -3)
        #expect(try await send(editor, "imageSizeSheet") == -3)
        #expect(session.document?.layers.map(\.id) == layers && session.history.currentRevision == revision)
        switch sheet {
        case "trim": editor.finishTrim(nil)
        case "exportAsSheet": editor.finishExportAsSheet(nil)
        default: editor.finishSizeSheet(nil)
        }
        let result = try await opened.value
        #expect(result == (sheet == "exportAsSheet" ? -7 : 0))
        #expect(!session.isProjectBusy && session.canStartProjectOperation)
        #expect(session.document?.layers.map(\.id) == layers && session.history.currentRevision == revision)
        #expect(try await send(editor, "undo") == 0)
        #expect(session.document?.layers.count == 1)
        #expect(try await send(editor, "addLayer") == 0)
        #expect(session.document?.layers.count == 2)
    }

    @Test(arguments: [false, true])
    func exportAsHoldsTheProjectThroughTheSavePanel(written: Bool) async throws {
        let editor = editor()
        let session = editor.session
        let opened = Task { try await send(editor, "exportAsSheet", ["kind": "png"]) }
        await waitFor { editor.exportAsSheet != nil }
        let format = ExportFormat.png
        editor.finishExportAsSheet((data: Data([1, 2, 3]), format: format))
        #expect(try await opened.value == 0)
        // The shell's save panel is open now; the project stays busy until it answers.
        #expect(session.isProjectBusy && !session.canStartProjectOperation)
        #expect(try await send(editor, "new", ["width": 8, "height": 8]) == -3)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: destination) }
        let answered = try await send(editor, "writeExport", written ? ["paths": [destination.path]] : [:])
        #expect(answered == (written ? 0 : -7))
        #expect(FileManager.default.fileExists(atPath: destination.path) == written)
        #expect(!session.isProjectBusy && session.canStartProjectOperation)
        #expect(try await send(editor, "addLayer") == 0)
    }

    @Test(arguments: ["trim", "canvasSizeSheet", "imageSizeSheet", "exportAsSheet", "exportPNG", "exportPDF"])
    func aBusyProjectRefusesBeforeApplyingAPendingGradient(operation: String) async throws {
        let editor = editor()
        let session = editor.session
        #expect(try await send(editor, "gradientBegin", ["x": 0, "y": 0]) == 0)
        #expect(try await send(editor, "gradientMove", ["x": 15, "y": 11]) == 0)
        #expect(try await send(editor, "gradientEndDrag") == 0)
        let draft = try #require(session.gradientEdit)
        let revision = session.history.currentRevision
        session.isProjectBusy = true
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fields: [String: Any] = operation.hasPrefix("export") && !operation.hasSuffix("Sheet") ? ["paths": [destination.path]] : [:]
        #expect(try await send(editor, operation, fields) == -3)
        #expect(session.gradientEdit === draft && session.history.currentRevision == revision)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        session.isProjectBusy = false
        #expect(try await send(editor, "gradientCancel") == 0)
    }
}
