import Foundation
import AppKit

/// A host asks for accessibility separately from drawing, so a table only materializes offscreen rows when queried.
@MainActor public final class NativeAccessibilityBox {
    public var data = Data()
    public init() {}
}

@MainActor final class NativeAccessibility {
    private static var adapters: [ObjectIdentifier: NativeAccessibility] = [:]
    static func adapter(for view: NSView) -> NativeAccessibility {
        adapters = adapters.filter { $0.value.root != nil }
        let key = ObjectIdentifier(view)
        if let adapter = adapters[key], adapter.root === view { return adapter }
        let adapter = NativeAccessibility(view)
        adapters[key] = adapter
        return adapter
    }
    private weak var root: NSView?
    private struct Identity {
        weak var view: NSView?
        let id: String
    }
    private var identities: [ObjectIdentifier: Identity] = [:]
    private var actions: [String: () -> Bool] = [:]
    private init(_ root: NSView) { self.root = root }

    private struct Element: Encodable {
        var id: String, role: String, label: String
        var identifier = "", help = ""
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        var enabled = true, selected = false, focused = false, offscreen = false, hidden = false, press = false
        var checked: Bool?
        var children: [Element] = []
    }
    private func identity(_ view: NSView, label: String) -> String {
        let key = ObjectIdentifier(view)
        if identities[key]?.view !== view { identities[key] = Identity(view: view, id: UUID().uuidString) }
        return identities[key]!.id + "|" + label
    }
    private func available(_ view: NSView) -> Bool {
        guard let root, view === root || view.isDescendant(of: root), !view.isHiddenOrHasHiddenAncestor else { return false }
        var current: NSView? = view
        while let ancestor = current {
            if let control = ancestor as? NSControl, !control.isEnabled { return false }
            if ancestor === root { break }
            current = ancestor.superview
        }
        return true
    }
    private func geometry(_ view: NSView, element: inout Element) {
        guard let root else { return }
        let frame = view.convert(view.bounds, to: root)
        element.x = Double(frame.minX)
        element.y = Double(root.isFlipped ? frame.minY : root.bounds.maxY - frame.maxY)
        element.width = Double(frame.width); element.height = Double(frame.height)
        element.offscreen = !root.visibleRect.intersects(frame)
        element.hidden = view.isHiddenOrHasHiddenAncestor
        element.enabled = available(view)
        element.identifier = view.accessibilityIdentifier() ?? ""
        element.help = view.toolTip ?? ""
        element.focused = root.window?.firstResponder === view || root.window?.editedField === view
    }
    private func elements(_ view: NSView) -> [Element] {
        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
        var role = "", label = view.accessibilityLabel() ?? ""
        var press = false
        if let button = view as? NSButton {
            role = [.switch, .radio, .toggle, .onOff, .pushOnPushOff].contains(button.buttonType) ? "checkBox" : "button"
            if label.isEmpty { label = button.title.isEmpty ? (button.image?.accessibilityDescription ?? "") : button.title }
            press = true
        } else if let field = view as? NSTextField {
            if root?.window?.editedField === field { return [] } // the host exposes the real overlaid text editor
            role = field.isEditable ? "textField" : "text"
            if label.isEmpty { label = field.stringValue }
        } else if let image = view as? NSImageView {
            role = "image"
            if label.isEmpty { label = image.image?.accessibilityDescription ?? "" }
        } else if view.isAccessibilityElement() {
            role = view.accessibilityRole()?.rawValue == "AXButton" ? "button" : "group"
            press = true
        }
        let children = view.subviews.flatMap(elements)
        guard !role.isEmpty, !label.isEmpty else { return children }
        let id = identity(view, label: label)
        var element = Element(id: id, role: role, label: label)
        geometry(view, element: &element)
        element.press = press
        element.children = children
        if let button = view as? NSButton, role == "checkBox" { element.checked = button.state == .on }
        if press {
            actions[id] = { [weak self, weak view] in
                guard let self, let view, self.available(view) else { return false }
                return view.accessibilityPerformPress()
            }
        }
        return [element]
    }
    func snapshot() -> Data {
        actions = [:]
        identities = identities.filter { $0.value.view != nil }
        guard let root else { return Data() }
        root.layoutSubtreeIfNeeded()
        var result = Element(id: "root", role: root is NSTableView ? "list" : "group", label: root.accessibilityLabel() ?? "")
        geometry(root, element: &result)
        if let table = root as? NSTableView {
            if result.label.isEmpty { result.label = "List" }
            for row in 0..<table.numberOfRows {
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true), !cell.isHiddenOrHasHiddenAncestor else { continue }
                cell.layoutSubtreeIfNeeded()
                let label = table.delegate?.tableView(table, typeSelectStringFor: nil, row: row) ?? ""
                let item = table.dataSource?.tableView(table, pasteboardWriterForRow: row) as? NSPasteboardItem
                let modelID = item?.types.compactMap { item?.string(forType: $0) }.first ?? label
                let id = identity(cell, label: modelID)
                var entry = Element(id: id, role: "listItem", label: label)
                geometry(cell, element: &entry)
                entry.selected = table.selectedRowIndexes.contains(row)
                entry.focused = entry.selected && table.window?.firstResponder === table
                entry.press = true
                entry.children = cell.subviews.flatMap(elements)
                actions[id] = { [weak self, weak table, weak cell] in
                    guard let self, let table, let cell, self.available(table),
                          table.view(atColumn: 0, row: row, makeIfNecessary: false) === cell,
                          table.delegate?.tableView(table, typeSelectStringFor: nil, row: row) == label else { return false }
                    table.window?.makeFirstResponder(table)
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    table.scrollRowToVisible(row)
                    return true
                }
                result.children.append(entry)
            }
        } else { result.children = root.subviews.flatMap(elements) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(result)) ?? Data()
    }
    func perform(_ payload: Any) -> Bool {
        guard let values = payload as? [String: Any], values["action"] as? String == "press",
              let id = values["id"] as? String else { return false }
        _ = snapshot() // reject an old identity after a model update, row reuse, rename or visibility change
        guard let action = actions[id] else { return false }
        var result = false
        NativeLowering.act { result = action() }
        return result
    }
}
