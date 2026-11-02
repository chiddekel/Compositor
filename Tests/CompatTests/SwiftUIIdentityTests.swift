import SwiftUI
import XCTest

final class SwiftUIIdentityTests: XCTestCase {
    private func nodes(_ node: RenderNode) -> [RenderNode] { [node] + node.children.flatMap(nodes) }
    private func button(_ title: String, in tree: RenderNode) throws -> RenderNode {
        try XCTUnwrap(nodes(tree).first { node in
            node.kind == "Button" && nodes(node).contains { $0.kind == "Text" && $0.stringParams["text"] == title }
        })
    }
    private func resolve(_ view: some View) -> RenderNode {
        var node = ViewResolver.resolve(view); node.assignIDs(); return node
    }

    func testFollowingActionSurvivesConditionalArityChange() throws {
        var activations = 0
        func panel(_ expanded: Bool) -> some View {
            VStack {
                TextField("Resolution", value: .constant(72))
                if expanded {
                    Text("Sampling")
                    Button("High") {}
                } else { Text("Print dimensions") }
                Button("Resize") { activations += 1 }
            }
        }
        let shown = resolve(panel(true)), fresh = resolve(panel(false))
        let visibleID = try button("Resize", in: shown).id
        XCTAssertEqual(visibleID, try button("Resize", in: fresh).id)
        var handlers: [String: [String: (Any) -> Void]] = [:]
        fresh.collectHandlers(into: &handlers)
        try XCTUnwrap(handlers[visibleID]?["action"])(())
        XCTAssertEqual(activations, 1)
    }

    func testFollowingActionSurvivesOptionalAndCollectionChanges() throws {
        func panel(_ count: Int) -> some View {
            HStack {
                if count > 0 { Text("Optional") }
                ForEach(0..<count) { index in Text("Row \(index)") }
                Button("Done") {}
            }
        }
        let hidden = resolve(panel(0)), shown = resolve(panel(4))
        XCTAssertEqual(try button("Done", in: hidden).id, try button("Done", in: shown).id)
        XCTAssertEqual(Set(nodes(shown).map(\.id)).count, nodes(shown).count)
    }

    func testConditionalBranchesHaveDistinctControlIdentities() throws {
        func panel(_ first: Bool) -> some View {
            VStack {
                if first { Button("First") {} } else { Button("Second") {} }
                Button("Following") {}
            }
        }
        let first = resolve(panel(true)), second = resolve(panel(false))
        XCTAssertNotEqual(try button("First", in: first).id, try button("Second", in: second).id)
        XCTAssertEqual(try button("Following", in: first).id, try button("Following", in: second).id)
    }

    func testModifiedGroupsKeepUniqueIdentitiesWithoutChangingLayout() {
        let tree = resolve(VStack {
            Group { Text("One"); Text("Two") }.padding(4)
            Text("Three")
        })
        XCTAssertEqual(tree.children.count, 3)
        XCTAssertEqual(tree.children.map { $0.stringParams["text"] }, ["One", "Two", "Three"])
        XCTAssertEqual(Set(nodes(tree).map(\.id)).count, nodes(tree).count)
    }

    func testHandBuiltNodesRetainPositionalIDs() {
        var node = RenderNode(kind: "VStack")
        node.children = [RenderNode(kind: "Text"), RenderNode(kind: "Button")]
        node.assignIDs(prefix: "root")
        XCTAssertEqual(node.id, "root")
        XCTAssertEqual(node.children.map(\.id), ["root.0", "root.1"])
    }

    func testModifiedGroupRetainsSlotsWhenItsArityChanges() throws {
        func panel(_ expanded: Bool) -> some View {
            VStack {
                Group {
                    if expanded { Text("Extra") }
                    Button("Resize") {}
                }.padding(4)
            }
        }
        XCTAssertEqual(try button("Resize", in: resolve(panel(false))).id,
            try button("Resize", in: resolve(panel(true))).id)
    }

    func testModifiedConditionalBranchesRemainDistinct() throws {
        func panel(_ first: Bool) -> some View {
            VStack { Group {
                if first { Button("First") {} } else { Button("Second") {} }
            }.padding(4) }
        }
        XCTAssertNotEqual(try button("First", in: resolve(panel(true))).id,
            try button("Second", in: resolve(panel(false))).id)
    }

    func testIndependentResolvedChildrenCannotAlias() {
        var tree = RenderNode(kind: "VStack")
        tree.children = [ViewResolver.resolve(Group { Text("One") }), ViewResolver.resolve(Group { Text("Two") })]
        tree.assignIDs()
        XCTAssertEqual(Set(nodes(tree).map(\.id)).count, nodes(tree).count)
    }

    func testBackgroundAndOverlayWrappersKeepUniqueIDs() {
        let tree = resolve(VStack {
            Group { Text("One"); Text("Two") }.padding(4)
        }.background { Group { Text("Background"); Text("Other") } }
         .overlay { Text("Overlay") })
        XCTAssertEqual(Set(nodes(tree).map(\.id)).count, nodes(tree).count)
    }

    func testConditionalBackgroundDoesNotRetireItsBaseAction() throws {
        func panel(_ visible: Bool) -> some View {
            VStack { Button("Resize") {}.background { if visible { Text("Hint") } } }
        }
        let absent = resolve(panel(false)), present = resolve(panel(true))
        XCTAssertEqual(try button("Resize", in: absent).id, try button("Resize", in: present).id)
        XCTAssertEqual(Set(nodes(present).map(\.id)).count, nodes(present).count)
    }

    func testConditionalSheetKeepsItsBaseAction() throws {
        func panel(_ visible: Bool) -> some View {
            Button("Open") {}.sheet(isPresented: .constant(visible)) { Text("Sheet") }
        }
        XCTAssertEqual(try button("Open", in: resolve(panel(false))).id,
            try button("Open", in: resolve(panel(true))).id)
    }

    func testTypeErasurePreservesChildDeclarationSlots() throws {
        func panel(_ expanded: Bool) -> AnyView {
            AnyView(VStack {
                if expanded { Text("Extra"); Text("Other") }
                Button("Done") {}
            })
        }
        XCTAssertEqual(try button("Done", in: resolve(panel(false))).id,
            try button("Done", in: resolve(panel(true))).id)
    }

    func testTypeErasedConditionalBranchesRemainDistinct() throws {
        func panel(_ first: Bool) -> some View {
            VStack {
                AnyView(Group {
                    if first { Button("First") {} } else { Button("Second") {} }
                })
                Button("Following") {}
            }
        }
        let first = resolve(panel(true)), second = resolve(panel(false))
        XCTAssertNotEqual(try button("First", in: first).id, try button("Second", in: second).id)
        XCTAssertEqual(try button("Following", in: first).id, try button("Following", in: second).id)
    }

    func testLeadingOptionalTupleRetainsItsDeclarationSlot() throws {
        func panel(_ expanded: Bool) -> some View {
            VStack {
                if expanded { Text("Extra"); Text("Other") }
                Button("Done") {}
            }
        }
        XCTAssertEqual(try button("Done", in: resolve(panel(false))).id,
            try button("Done", in: resolve(panel(true))).id)
    }

    func testPassiveConditionalTextKeepsARefreshSlotAcrossBranches() throws {
        func panel(_ valid: Bool) -> some View {
            VStack {
                if valid { Text("Valid").foregroundStyle(.secondary) }
                else { Text("Warning").foregroundStyle(.orange) }
                Button("Done") {}
            }
        }
        let first = resolve(panel(true)), second = resolve(panel(false))
        let valid = try XCTUnwrap(nodes(first).first { $0.kind == "Text" && $0.stringParams["text"] == "Valid" })
        let warning = try XCTUnwrap(nodes(second).first { $0.kind == "Text" && $0.stringParams["text"] == "Warning" })
        XCTAssertNotEqual(valid.id, warning.id)
        XCTAssertNotNil(valid.stringParams["_conditionalSlot"])
        XCTAssertEqual(valid.stringParams["_conditionalSlot"], warning.stringParams["_conditionalSlot"])
        XCTAssertNil(try button("Done", in: first).stringParams["_conditionalSlot"])
    }
}
