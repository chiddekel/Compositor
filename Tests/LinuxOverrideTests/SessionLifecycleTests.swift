import Foundation
import AppKit
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct SessionLifecycleTests {
    private func watch(_ editor: UpstreamEditor) async throws -> URL {
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 16 * 12 * 4), width: 16, height: 12,
                                 name: "Watched", replacing: true) == 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        try await ProjectStore.shared.save(try #require(editor.session.projectSnapshot()), to: url)
        editor.session.projectURL = url
        await editor.nativeProjects.rememberProjectDigest(for: url)
        editor.nativeProjects.watchProject(at: url)
        return url
    }

    @Test func standaloneCloseReleasesCanvasAndWatch() async throws {
        let handle = await Task.detached { compositorSessionCreate() }.value
        defer { Task.detached { compositorSessionClose(handle) } }
        let entry = try #require(Sessions.entries[handle])
        let url = try await watch(entry.editor)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = entry.editor.nativeProjects
        var canvas: UpstreamCanvas? = UpstreamCanvases.canvas(handle, entry)
        controller.window = canvas?.window
        weak var weakCanvas = canvas
        weak var weakWindow = canvas?.window
        canvas = nil
        await Task.detached { compositorSessionClose(handle) }.value
        #expect(Sessions.entries[handle] == nil && UpstreamCanvases.canvases[handle] == nil)
        #expect(weakCanvas == nil && weakWindow == nil)
        #expect(controller.externalChanges.watcher == nil && controller.externalChanges.knownDigest == nil)
        #expect(entry.editor.session.document == nil && entry.editor.session.projectURL == nil)
    }

    @Test(arguments: [false, true])
    func workspaceClosePreservesOtherOwnerUntilLastClose(tabClose: Bool) async throws {
        let tab = Workspace.shared.addTab(reuseEmpty: false)
        let first = await Task.detached { compositorWorkspaceBootstrap() }.value
        let second = await Task.detached { compositorWorkspaceBootstrap() }.value
        defer { Task.detached { compositorSessionClose(first); compositorSessionClose(second) } }
        let entry = try #require(Sessions.entries[first])
        let other = try #require(Sessions.entries[second])
        #expect(entry.editor.session === other.editor.session)
        let url = try await watch(entry.editor)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = entry.editor.nativeProjects
        let watcher = try #require(controller.externalChanges.watcher)
        var canvas: UpstreamCanvas? = UpstreamCanvases.canvas(first, entry)
        let otherCanvas = UpstreamCanvases.canvas(second, other)
        otherCanvas.window.orderFront(nil)
        controller.window = canvas?.window
        weak var weakCanvas = canvas
        canvas = nil
        let document = entry.editor.session.document
        if tabClose {
            #expect(await Task.detached { compositorWorkspaceCloseTab(first) }.value == second)
        } else {
            await Task.detached { compositorSessionClose(first) }.value
        }
        #expect(Sessions.entries[first] == nil && UpstreamCanvases.canvases[first] == nil && weakCanvas == nil)
        #expect(Workspace.shared.tabs.contains(where: { $0.id == tab.id }))
        #expect(other.editor.session.document == document && other.editor.session.projectURL == url)
        #expect(controller.externalChanges.watcher === watcher && controller.window === otherCanvas.window)
        var replacement: UInt64 = 0
        if tabClose {
            replacement = await Task.detached { compositorWorkspaceCloseTab(second) }.value
        } else {
            await Task.detached { compositorSessionClose(second) }.value
        }
        #expect(!Workspace.shared.tabs.contains(where: { $0.id == tab.id }))
        #expect(Sessions.entries[second] == nil && UpstreamCanvases.canvases[second] == nil)
        #expect(!otherCanvas.window.isVisible)
        #expect(controller.externalChanges.watcher == nil && controller.externalChanges.knownDigest == nil)
        #expect(other.editor.session.document == nil && other.editor.session.projectURL == nil)
        if replacement != 0 {
            let cleanup = replacement
            await Task.detached { compositorSessionClose(cleanup) }.value
        }
    }
}
