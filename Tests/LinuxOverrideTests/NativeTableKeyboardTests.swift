import AppKit
import Testing

@MainActor
@Suite(.serialized) struct NativeTableKeyboardTests {
    private final class Model: NSTableViewDataSource, NSTableViewDelegate {
        var count = 12
        var changes = 0
        func numberOfRows(in tableView: NSTableView) -> Int { count }
        func tableViewSelectionDidChange(_ notification: Notification) { changes += 1 }
    }
    private final class Responder: NSResponder {
        var keys: [UInt16] = []
        override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    }
    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    private func table(_ model: Model) -> (NSTableView, NSScrollView) {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 180, height: 60))
        let table = NSTableView(frame: .zero)
        table.dataSource = model; table.delegate = model
        table.rowHeight = 20; table.intercellSpacing = .zero
        scroll.documentView = table
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        table.layoutSubtreeIfNeeded()
        return (table, scroll)
    }

    @Test func arrowsChangeSelectionNotifyAndRevealRows() {
        let model = Model()
        let (table, scroll) = table(model)
        model.changes = 0
        for _ in 0..<4 { table.keyDown(with: key(125)) }
        #expect(table.selectedRowIndexes == IndexSet(integer: 6))
        #expect(model.changes == 4)
        #expect(scroll.contentView.bounds.contains(table.rect(ofRow: 6)))
        table.keyDown(with: key(126))
        #expect(table.selectedRowIndexes == IndexSet(integer: 5))
        #expect(model.changes == 5)
    }

    @Test func shiftArrowsExtendAndContractAroundTheOriginalAnchor() {
        let model = Model()
        let (table, _) = table(model)
        table.allowsMultipleSelection = true
        // Switching from plain navigation to Shift keeps the last plain selection as the anchor.
        table.keyDown(with: key(125))
        table.keyDown(with: key(126))
        table.keyDown(with: key(125, modifiers: .shift))
        table.keyDown(with: key(125, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 2...4))
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 2...3))
        table.keyDown(with: key(126, modifiers: .shift))
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 1...2))
        table.selectRowIndexes(IndexSet(integer: 8), byExtendingSelection: false)
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 7...8))
    }

    @Test func singleSelectionAndBoundaryKeysStayValid() {
        let model = Model()
        let (table, _) = table(model)
        table.keyDown(with: key(125, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integer: 3))
        table.selectRowIndexes(IndexSet(integer: 11), byExtendingSelection: false)
        let changes = model.changes
        table.keyDown(with: key(125))
        #expect(table.selectedRowIndexes == IndexSet(integer: 11))
        #expect(model.changes == changes)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.keyDown(with: key(126))
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
    }

    @Test func unrelatedModifiedAndDisabledKeysReachTheNextResponder() {
        let model = Model()
        let (table, _) = table(model)
        let responder = Responder(); table.nextResponder = responder
        table.keyDown(with: key(123))
        table.keyDown(with: key(125, modifiers: .command))
        table.keyDown(with: key(126, modifiers: .option))
        table.isEnabled = false; table.keyDown(with: key(125))
        #expect(responder.keys == [123, 125, 126, 125])
        #expect(table.selectedRowIndexes == IndexSet(integer: 2))
        model.count = 0; table.isEnabled = true; table.reloadData()
        table.selectRowIndexes([], byExtendingSelection: false)
        table.keyDown(with: key(125))
        #expect(table.selectedRowIndexes.isEmpty)
    }

    @Test func removedRowsCannotLeaveAnOutOfRangeKeyboardAnchor() {
        let model = Model()
        let (table, _) = table(model)
        table.allowsMultipleSelection = true
        table.selectRowIndexes(IndexSet(integer: 11), byExtendingSelection: false)
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 10...11))
        model.count = 3
        table.reloadData()
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integer: 2))
    }
}
