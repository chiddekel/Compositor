import SwiftUI
import Testing

struct SwiftUIListMaskDropProbeTests {
    @Test func maskDropSerializesIdentifiersAndDispatchesCopyCallback() {
        var copied: (String, String)?
        let list = List(0..<2, id: \.self) { Text("Row \($0)") }
            .compatListMaskDrop(dragIdentifiers: ["source", ""], dropTargetIdentifiers: ["", "target"]) {
                copied = ($0, $1)
            }
        let node = ViewResolver.resolve(list)
        var handlers: [String: [String: (Any) -> Void]] = [:]
        node.collectHandlers(into: &handlers)

        #expect(node.stringParams["listMaskDragIdentifiers"] == "source,")
        #expect(node.stringParams["listMaskDropIdentifiers"] == ",target")
        handlers[node.id]?["listMaskDrop"]?(["source", "target"])
        #expect(copied?.0 == "source" && copied?.1 == "target")
    }
}
