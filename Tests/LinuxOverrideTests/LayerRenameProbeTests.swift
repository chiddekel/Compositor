import Foundation
import SwiftUI
import Testing
@testable import Compositor

/// LayerCell's rename probe: Return or ending editing keeps the name; Escape restores it.
/// Tip 8f7d344: same size as the label, layer-row background (quaternary), not a bezeled field.
private struct LayerRenameField: View {
    let session: EditorSession
    let layerID: UUID
    @State private var text: String
    @FocusState private var focused: Bool
    init(session: EditorSession, layerID: UUID, name: String) {
        self.session = session; self.layerID = layerID
        _text = State(initialValue: name)
    }
    var body: some View {
        TextField("Layer name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { finish(keeping: true) }
            .onExitCommand { finish(keeping: false) }
            .onChange(of: focused) { _, focused in if !focused { finish(keeping: true) } }
    }

    private func finish(keeping: Bool) {
        guard session.renamingLayerID == layerID else { return }
        if keeping { session.renameLayer(layerID, to: text) }
        session.renamingLayerID = nil
        focused = false
    }
}

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
