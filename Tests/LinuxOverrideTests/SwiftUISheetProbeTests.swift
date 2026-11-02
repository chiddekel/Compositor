import SwiftUI
import Testing

private struct SheetProbeItem: Identifiable {
    let id: Int
    let title: String
}

struct SwiftUISheetProbeTests {
    @Test func sheetPresentationTracksItsBindingAndDismissal() {
        var isPresented = true
        var didDismiss = false
        let view = Text("base").sheet(
            isPresented: Binding(get: { isPresented }, set: { isPresented = $0 }),
            onDismiss: { didDismiss = true }
        ) {
            Text("modal")
        }

        var node = ViewResolver.resolve(view)
        #expect(node.kind == "Sheet")
        #expect(node.boolParams["isPresented"] == true)
        #expect(node.children.count == 2)
        #expect(node.children[1].kind == "VStack")
        #expect(node.children[1].children[0].stringParams["text"] == "modal")

        node.assignIDs()
        var handlers: [String: [String: (Any) -> Void]] = [:]
        node.collectHandlers(into: &handlers)
        handlers[node.id]?["dismiss"]?(())
        #expect(!isPresented)
        #expect(didDismiss)
    }

    @Test func itemSheetClearsItsSelectionOnDismissal() {
        var selection: SheetProbeItem? = SheetProbeItem(id: 1, title: "selected")
        let view = Text("base").sheet(
            item: Binding(get: { selection }, set: { selection = $0 })
        ) { item in
            Text(item.title)
        }

        var node = ViewResolver.resolve(view)
        #expect(node.boolParams["isPresented"] == true)
        #expect(node.children[1].children[0].stringParams["text"] == "selected")

        node.assignIDs()
        var handlers: [String: [String: (Any) -> Void]] = [:]
        node.collectHandlers(into: &handlers)
        handlers[node.id]?["dismiss"]?(())
        #expect(selection?.id == nil)
    }
}
