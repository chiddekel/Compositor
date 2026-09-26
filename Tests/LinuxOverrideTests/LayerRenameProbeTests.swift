import Foundation
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct LayerRenameProbeTests {
    @Test(arguments: ["return", "escape", "blur", "empty"])
    func inlineRenameEndsWithoutLockingLayerActions(_ finish: String) throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        session.addBlankLayer()
        let layer = try #require(session.activeLayer)
        session.renamingLayerID = layer.id
        let scope = "rename-\(UUID().uuidString)"
        defer { StateStore.discard(scope: scope); ChangeTracker.discard(scope: scope) }
        var handlers: [String: [String: (Any) -> Void]] = [:]
        var node = RenderNode(kind: "EmptyView")
        func resolve() throws {
            for _ in 0..<3 {
                #expect(StateStore.begin(scope: scope))
                node = ViewResolver.resolve(LayerRenameField(session: session, layerID: layer.id, name: layer.name))
                StateStore.end()
                node.assignIDs()
                ChangeTracker.process(scope: scope, root: node)
                handlers = [:]
                node.collectHandlers(into: &handlers)
                if ChangeTracker.lastActionCount == 0 { break }
            }
        }
        try resolve()
        #expect(node.wire().boolParams["focused"] == true)
        #expect(!session.canEditLayers)
        let edit = try #require(handlers[node.id]?["text"])
        edit(finish == "empty" ? "   " : "  Foreground  ")
        let key = finish == "escape" ? "onExitCommand" : finish == "blur" ? "focused" : "onSubmit"
        #expect(node.wire().handlerKeys.contains(key))
        let action = try #require(handlers[node.id]?[key])
        if finish == "blur" { action(false) } else { action(()) }
        try resolve()
        #expect(session.renamingLayerID == nil)
        #expect(session.canEditLayers)
        #expect(node.wire().boolParams["focused"] == false)
        let renamed = finish == "return" || finish == "blur"
        #expect(session.activeLayer?.name == (renamed ? "Foreground" : layer.name))
        #expect(session.activeLayerID == layer.id)
        if renamed {
            session.undo()
            #expect(session.activeLayer?.name == layer.name)
            session.redo()
            #expect(session.activeLayer?.name == "Foreground")
        }
    }
}
