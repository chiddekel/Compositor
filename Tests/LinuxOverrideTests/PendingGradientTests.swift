import Foundation
import Dispatch
import Testing
@testable import Compositor

private extension BrushCommit {
    func holdForTest(started: DispatchSemaphore, release: DispatchSemaphore) {
        started.signal()
        release.wait()
    }
}

@MainActor
struct PendingGradientTests {
    private func send(_ editor: UpstreamEditor, _ action: String, _ fields: [String: Any] = [:]) async -> Int32 {
        var command = fields
        command["version"] = 1
        command["action"] = action
        return await editor.commandAsync(try! JSONSerialization.data(withJSONObject: command))
    }

    private func pending() async -> UpstreamEditor {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 0, count: 64 * 64 * 4), width: 64, height: 64,
                                  name: "Canvas", replacing: true) == 0)
        #expect(await send(editor, "gradientBegin", ["x": 0, "y": 0]) == 0)
        #expect(await send(editor, "gradientMove", ["x": 63, "y": 63]) == 0)
        #expect(await send(editor, "gradientEndDrag") == 0)
        return editor
    }

    @Test(arguments: ["addLayer", "gradientCommit"])
    func busyCommitIsRefusedAndCanBeRetried(_ action: String) async throws {
        let editor = await pending()
        let edit = try #require(editor.session.gradientEdit)
        let before = try editor.renderRGBA().bytes
        let revision = editor.session.history.currentRevision
        editor.session.isProjectBusy = true
        #expect(await send(editor, action) == -5)
        #expect(editor.error?.contains("busy") == true)
        #expect(editor.session.gradientEdit === edit)
        #expect(editor.session.document?.layers.count == 1)
        #expect(editor.session.history.currentRevision == revision)
        #expect(try editor.renderRGBA().bytes == before)
        editor.session.isProjectBusy = false
        #expect(await send(editor, action) == 0)
        #expect(editor.session.gradientEdit == nil)
        #expect(editor.session.document?.layers.count == (action == "addLayer" ? 2 : 1))
        #expect(try editor.renderRGBA().bytes.contains { $0 > 0 })
    }

    @Test(arguments: ["addLayer", "gradientCommit"])
    func failedFillDoesNotDispatchTheNextCommand(_ action: String) async throws {
        let editor = await pending()
        let edit = try #require(editor.session.gradientEdit)
        // Exercise the real allocation failure, rather than substituting a mock commit.
        edit.raster.pixelLimit = 1
        let revision = editor.session.history.currentRevision
        #expect(await send(editor, action) == -5)
        #expect(editor.error != nil && editor.error == editor.session.brushError)
        #expect(editor.session.document?.layers.count == 1)
        #expect(editor.session.history.currentRevision == revision)
        #expect(!editor.session.isProjectBusy)
        #expect(editor.session.gradientEdit == nil)
        #expect(try editor.renderRGBA().bytes.allSatisfy { $0 == 0 })
        #expect(await send(editor, "dismissAlert") == 0)
        #expect(await send(editor, "addLayer") == 0)
    }

    @Test func changedTargetDoesNotReportACommittedGradient() async throws {
        let editor = await pending()
        let edit = try #require(editor.session.gradientEdit)
        editor.session.document?.layers[0].transform.origin.x += 1
        let revision = editor.session.history.currentRevision
        #expect(await send(editor, "addLayer") == -5)
        #expect(editor.error?.contains("target changed") == true)
        #expect(editor.session.gradientEdit === edit)
        #expect(editor.session.document?.layers.count == 1)
        #expect(editor.session.history.currentRevision == revision)
        #expect(await send(editor, "gradientCancel") == 0)
        #expect(await send(editor, "addLayer") == 0)
    }

    @Test func successfulCommitPreservesAnOldAlertAndOrdersHistory() async throws {
        let editor = await pending()
        editor.session.brushError = "Earlier paint error"
        #expect(await send(editor, "addLayer") == 0)
        #expect(editor.session.brushError == "Earlier paint error")
        #expect(editor.session.gradientEdit == nil)
        #expect(editor.session.history.undoName == "New Blank Layer")
        #expect(await send(editor, "undo") == 0)
        #expect(editor.session.document?.layers.count == 1)
        #expect(try editor.renderRGBA().bytes.contains { $0 > 0 })
        #expect(await send(editor, "undo") == 0)
        #expect(try editor.renderRGBA().bytes.allSatisfy { $0 == 0 })
    }

    @Test(arguments: [false, true])
    func dependentCommandWaitsForTheRasterWorker(targetChanges: Bool) async throws {
        let editor = await pending()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let worker = Task.detached { await BrushCommit.shared.holdForTest(started: started, release: release) }
        defer { release.signal() }
        var workerStarted = false
        for _ in 0..<200 {
            if started.wait(timeout: .now()) == .success { workerStarted = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(workerStarted)
        var completed = false
        let command = Task { @MainActor in
            let result = await send(editor, "addLayer")
            completed = true
            return result
        }
        for _ in 0..<200 where !editor.session.isProjectBusy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(editor.session.isProjectBusy)
        let nativeState = try #require(try JSONSerialization.jsonObject(with: editor.stateJSON()) as? [String: Any])
        #expect(nativeState["busy"] as? Bool == true, "The native shell must wait for in-flight document work")
        #expect(nativeState["canSwitch"] as? Bool == false)
        #expect(!completed)
        #expect(editor.session.gradientEdit != nil)
        #expect(editor.session.document?.layers.count == 1)
        if targetChanges { editor.session.document?.layers[0].transform.origin.x += 1 }
        release.signal()
        await worker.value
        #expect(await command.value == (targetChanges ? -5 : 0))
        #expect(editor.session.gradientEdit == nil)
        #expect(editor.session.document?.layers.count == (targetChanges ? 1 : 2))
        if targetChanges {
            #expect(try editor.renderRGBA().bytes.allSatisfy { $0 == 0 })
        } else {
            #expect(try editor.renderRGBA().bytes.contains { $0 > 0 })
        }
    }
}
