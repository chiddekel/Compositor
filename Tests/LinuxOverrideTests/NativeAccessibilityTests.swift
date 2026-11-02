import Foundation
import AppKit
@testable import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct NativeAccessibilityTests {
    private final class Button: NSButton {
        var clicks = 0
        override func performClick(_ sender: Any?) { clicks += 1; super.performClick(sender) }
    }
    private final class Rows: NSTableViewDataSource, NSTableViewDelegate {
        var changes = 0
        var selectionsDuringEditing = 0
        func numberOfRows(in tableView: NSTableView) -> Int { 8 }
        func tableView(_ tableView: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? { "Row \(row)" }
        func tableViewSelectionDidChange(_ notification: Notification) {
            changes += 1
            if (notification.object as? NSTableView)?.window?.editedField != nil { selectionsDuringEditing += 1 }
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "Row \(row)")
            cell.textField = label; cell.addSubview(label)
            return cell
        }
    }
    private func tree(_ adapter: NativeAccessibility) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: adapter.snapshot()) as? [String: Any])
    }
    private func children(_ node: [String: Any]) -> [[String: Any]] { node["children"] as? [[String: Any]] ?? [] }

    @Test func controlMetadataAndPressUseTheOriginalButton() throws {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let button = Button(frame: CGRect(x: 18, y: 10, width: 50, height: 20))
        button.setAccessibilityLabel("Visibility")
        button.setAccessibilityIdentifier("visibility")
        button.setButtonType(.switch)
        button.toolTip = "Toggle the layer"
        let hidden = NSTextField(labelWithString: "Hidden warning"); hidden.isHidden = true
        root.addSubview(button); root.addSubview(hidden)
        let adapter = NativeAccessibility.adapter(for: root)
        let initial = try #require(children(tree(adapter)).first)
        #expect(children(try tree(adapter)).count == 1)
        #expect(initial["role"] as? String == "checkBox")
        #expect(initial["identifier"] as? String == "visibility")
        #expect(initial["label"] as? String == "Visibility")
        #expect(initial["help"] as? String == "Toggle the layer")
        #expect(initial["x"] as? Double == 18 && initial["y"] as? Double == 70)
        #expect(initial["checked"] as? Bool == false)
        let id = try #require(initial["id"] as? String)
        #expect(adapter.perform(["id": id, "action": "press"]))
        #expect(button.clicks == 1 && button.state == .on)
        #expect(try children(tree(adapter)).first?["checked"] as? Bool == true)
        button.isEnabled = false
        #expect(!adapter.perform(["id": id, "action": "press"]))
        #expect(try children(tree(adapter)).first?["enabled"] as? Bool == false)
        button.removeFromSuperview()
        #expect(!adapter.perform(["id": id, "action": "press"]))
    }

    @Test func offscreenRowsExposeSelectionAndRevealThroughTheirNativeTable() throws {
        let model = Rows()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 180, height: 40))
        let table = NSTableView()
        table.dataSource = model; table.delegate = model
        table.rowHeight = 20; table.intercellSpacing = .zero
        table.setAccessibilityIdentifier("rows")
        scroll.documentView = table
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        model.changes = 0
        let adapter = NativeAccessibility.adapter(for: table)
        let initial = try tree(adapter), rows = children(initial)
        #expect(initial["role"] as? String == "list" && initial["identifier"] as? String == "rows")
        #expect(rows.count == 8 && rows.first?["selected"] as? Bool == true)
        let last = try #require(rows.last)
        #expect(last["label"] as? String == "Row 7" && last["offscreen"] as? Bool == true)
        #expect(adapter.perform(["id": try #require(last["id"] as? String), "action": "press"]))
        #expect(table.selectedRowIndexes == IndexSet(integer: 7) && model.changes == 1)
        #expect(scroll.contentView.bounds.minY == 120)
        let selected = try #require(children(tree(adapter)).last)
        #expect(selected["selected"] as? Bool == true && selected["offscreen"] as? Bool == false)
    }

    @Test func staleHiddenAndUnknownActionsAreRejected() throws {
        let root = NSView(), group = NSControl(), button = Button()
        root.addSubview(group); group.addSubview(button)
        button.title = "Original"
        let adapter = NativeAccessibility.adapter(for: root)
        let id = try #require(children(tree(adapter)).first?["id"] as? String)
        group.isEnabled = false
        #expect(!adapter.perform(["id": id, "action": "press"]))
        group.isEnabled = true; button.isHidden = true
        #expect(!adapter.perform(["id": id, "action": "press"]))
        button.isHidden = false; button.title = "Changed"
        _ = try tree(adapter)
        #expect(!adapter.perform(["id": id, "action": "press"]))
        #expect(!adapter.perform(["id": "unknown", "action": "press"]))
        #expect(!adapter.perform(["id": id, "action": "delete"]))
        #expect(button.clicks == 0)
    }

    @Test func hiddenRootsExposeTheirStateWithoutDescendantActions() throws {
        let root = NSView(), button = Button()
        button.title = "Action"; root.addSubview(button)
        let adapter = NativeAccessibility.adapter(for: root)
        let id = try #require(children(tree(adapter)).first?["id"] as? String)
        root.isHidden = true
        let hidden = try tree(adapter)
        #expect(hidden["hidden"] as? Bool == true && hidden["enabled"] as? Bool == false)
        #expect(children(hidden).isEmpty)
        #expect(!adapter.perform(["id": id, "action": "press"]))
        root.isHidden = false
        #expect(adapter.perform(["id": id, "action": "press"]))
        #expect(button.clicks == 1)
    }

    @Test func accessibleRowSelectionEndsEditingBeforeNotifyingTheDelegate() throws {
        let model = Rows(), table = NSTableView()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 180, height: 40))
        table.dataSource = model; table.delegate = model; table.rowHeight = 20; table.intercellSpacing = .zero
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [], backing: .buffered, defer: true)
        window.contentView = scroll
        let adapter = NativeAccessibility.adapter(for: table)
        let rows = children(try tree(adapter))
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTableCellView)
        let field = try #require(cell.textField)
        field.isEditable = true
        #expect(window.makeFirstResponder(field))
        field.currentEditor()?.string = "Edited"
        #expect(adapter.perform(["id": try #require(rows.last?["id"] as? String), "action": "press"]))
        #expect(field.stringValue == "Edited" && window.editedField == nil)
        #expect(model.selectionsDuringEditing == 0 && table.selectedRow == 7)
        #expect(window.firstResponder === table)
    }
}
