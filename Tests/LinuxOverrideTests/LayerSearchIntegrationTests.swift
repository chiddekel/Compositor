import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct LayerSearchIntegrationTests {
    private func session() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 64, height: 48)
        for name in ["Portrait", "Sky", "Sky foreground"] {
            session.addBlankLayer()
            session.renameLayer(session.activeLayerID!, to: name)
        }
        return session
    }

    private func nodes(_ tree: RenderNode) -> [RenderNode] {
        [tree] + tree.children.flatMap(nodes)
    }

    private func identified(_ name: String, in tree: RenderNode) -> RenderNode? {
        nodes(tree).first { node in
            node.modifiers.contains {
                switch $0 {
                case .accessibilityIdentifier(let value), .identifier(let value): value == name
                default: false
                }
            }
        }
    }

    @Test func filteredTableSelectionAndDragUseDisplayedRows() throws {
        let session = session()
        let sky = try #require(session.document?.layers.first { $0.name == "Sky" }?.id)
        session.layerSearchText = "sky"
        let list = NativeLayerList(session: session)
        let coordinator = list.makeCoordinator()
        let scroll = list.makeNSView(context: .init(coordinator: coordinator))
        let table = try #require(scroll.documentView as? LayerTableView)
        #expect(table.displayedRows.map(\.name) == ["Sky foreground", "Sky"])
        #expect(table.numberOfRows == 2)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(session.activeLayerID == sky)
        let drag = try #require(coordinator.tableView(table, pasteboardWriterForRow: 1) as? NSPasteboardItem)
        #expect(drag.string(forType: NativeLayerList.Coordinator.layerType) == sky.uuidString)
        session.clearLayerSearch()
        coordinator.update(table)
        #expect(table.displayedRows.map(\.name) == ["Sky foreground", "Sky", "Portrait"])
        #expect(table.selectedRowIndexes == IndexSet(integer: 1))
    }

    @Test func originalSearchFieldClearsThenClosesOnEscape() throws {
        let scope = "layer-search-\(UUID())"
        let active = NativeLowering.isActive
        NativeLowering.isActive = true
        try #require(StateStore.begin(scope: scope))
        defer {
            StateStore.end()
            NativeLowering.discard(scope: scope)
            NativeLowering.isActive = active
        }
        let session = session()
        let header = LayersHeader(session: session)
        let closed = ViewResolver.resolve(header)
        let button = try #require(identified("layerSearchButton", in: closed)?.handlers["action"])
        button(())
        let opened = ViewResolver.resolve(header)
        let field = try #require(identified("layerSearch", in: opened))
        for flag in ["nativeFieldBordered", "nativeFieldBezeled", "nativeFieldDrawsBackground", "nativeFieldFocusRing"] {
            #expect(field.boolParams[flag] == false)
        }
        let edit = try #require(field.handlers["text"])
        edit("sky")
        #expect(session.layerSearchText == "sky")
        #expect(session.filteredLayerRows.count == 2)
        var commands: [String: [String: (Any) -> Int32]] = [:]
        field.collectResultHandlers(into: &commands)
        let escape = try #require(commands[field.id]?["fieldCommand"])
        #expect(escape("cancelOperation:") == 1)
        #expect(session.layerSearchText.isEmpty)
        #expect(identified("layerSearch", in: ViewResolver.resolve(header)) != nil)
        #expect(escape("cancelOperation:") == 1)
        #expect(identified("layerSearch", in: ViewResolver.resolve(header)) == nil)
    }

    @Test func typeToggleLabelsAndBindingsReachTheSessionWithoutHistory() throws {
        let session = session()
        let header = LayersHeader(session: session)
        let before = session.history.undoCount
        let tree = ViewResolver.resolve(header)
        for type in LayerType.allCases {
            let toggle = try #require(identified(type.accessibilityID, in: tree))
            #expect(toggle.kind == "Toggle")
            #expect(toggle.doubleParams["labelReservedIconWidth"] == 16)
            #expect(nodes(toggle).contains { $0.stringParams["source"] == "system:\(type.systemImageName)" })
        }
        let selected = try #require(identified("layerFilterSelected", in: tree)?.handlers["isOn"])
        selected(true)
        #expect(session.layerTypeFilter == [.selected])
        #expect(session.filteredLayerRows.map { $0.layer.id } == [session.activeLayerID!])
        session.selectLayer(try #require(session.document?.layers.first?.id))
        #expect(session.filteredLayerRows.map { $0.layer.id } == [session.activeLayerID!])
        let all = try #require(identified("layerFilterAll", in: ViewResolver.resolve(header))?.handlers["isOn"])
        all(true)
        #expect(session.layerTypeFilter.isEmpty)
        #expect(session.filteredLayerRows.count == 3)
        #expect(session.history.undoCount == before)
    }
}
