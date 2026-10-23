import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct CanvasSizeBridgeTests {
    private func send(_ editor: UpstreamEditor, _ action: String, _ fields: [String: Any] = [:]) async throws -> Int32 {
        var command = fields
        command["version"] = 1
        command["action"] = action
        return await editor.commandAsync(try JSONSerialization.data(withJSONObject: command))
    }

    @Test(arguments: ["resizeCanvas", "canvasSizeSheet"])
    func nativeCanvasSizePreservesZoom(action: String) async throws {
        let editor = UpstreamEditor()
        let session = editor.session
        session.viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 2, documentSize: nil)
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 600 * 400 * 4),
                                  width: 600, height: 400, name: "Canvas", replacing: true) == 0)
        session.zoom(to: 1.75)
        session.viewport.translate(by: CGSize(width: 35, height: -12))
        let zoom = session.viewport.zoom
        let undo = session.history.undoCount
        if action == "resizeCanvas" {
            #expect(try await send(editor, action, ["width": 300, "height": 200]) == 0)
        } else {
            let opened = Task { try await send(editor, action) }
            let deadline = ContinuousClock.now + .seconds(5)
            while editor.canvasSizeSheet == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            _ = try #require(editor.canvasSizeSheet)
            editor.finishSizeSheet(CanvasSizeOptions(width: 300, height: 200))
            #expect(try await opened.value == 0)
        }
        #expect(session.document?.size == CGSize(width: 300, height: 200))
        #expect(session.viewport.zoom == zoom)
        #expect(session.history.undoCount == undo + 1)
        session.undo()
        #expect(session.document?.size == CGSize(width: 600, height: 400))
        session.redo()
        #expect(session.document?.size == CGSize(width: 300, height: 200))
    }
}
