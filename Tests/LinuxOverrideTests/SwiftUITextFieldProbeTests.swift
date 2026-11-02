import Foundation
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct SwiftUITextFieldProbeTests {
    @Test func textFieldFocusAndSubmitReachTheTypedDraft() throws {
        var draft = "FF0000"
        var submitted = ""
        let focus = FocusState<Bool>()
        let field = TextField("Hex", text: Binding(get: { draft }, set: { draft = $0 }))
            .focused(focus)
            .onSubmit { submitted = draft }
        var node = ViewResolver.resolve(field)
        node.assignIDs()
        var handlers: [String: [String: (Any) -> Void]] = [:]
        node.collectHandlers(into: &handlers)
        let keys = node.wire().handlerKeys
        #expect(keys.contains("text") && keys.contains("focused") && keys.contains("onSubmit"))

        let setFocus = try #require(handlers[node.id]?["focused"])
        let setText = try #require(handlers[node.id]?["text"])
        let submit = try #require(handlers[node.id]?["onSubmit"])
        setFocus(true)
        #expect(focus.wrappedValue)
        setText("00FF00")
        #expect(submitted.isEmpty)
        submit(())
        #expect(submitted == "00FF00")
        setFocus(false)
        #expect(!focus.wrappedValue)
    }

    @Test func colorPickerCommitsTheHexDraftWhenFocusLeaves() throws {
        let picker = ColorPickerState(background: false, original: .black)
        let scope = "color-picker-focus-\(UUID().uuidString)"
        defer { StateStore.discard(scope: scope); ChangeTracker.discard(scope: scope) }
        var handlers: [String: [String: (Any) -> Void]] = [:]
        var fieldID = ""
        func resolve() throws {
            for _ in 0..<3 {
                #expect(StateStore.begin(scope: scope))
                var node = ViewResolver.resolve(ColorPickerSheet(state: picker) { _ in })
                StateStore.end()
                node.assignIDs()
                ChangeTracker.process(scope: scope, root: node)
                handlers = [:]
                node.collectHandlers(into: &handlers)
                func flatten(_ node: RenderNode) -> [RenderNode] { [node] + node.children.flatMap(flatten) }
                fieldID = try #require(flatten(node).first { $0.kind == "TextField" && $0.stringParams["placeholder"] == "Hex" }).id
                if ChangeTracker.lastActionCount == 0 { break }
            }
        }

        try resolve()
        let focus = try #require(handlers[fieldID]?["focused"])
        focus(true)
        try resolve()
        let edit = try #require(handlers[fieldID]?["text"])
        edit("00FF00")
        #expect(picker.color.hex == "000000")
        let blur = try #require(handlers[fieldID]?["focused"])
        blur(false)
        try resolve()
        #expect(picker.color.hex == "00FF00")
    }
}
