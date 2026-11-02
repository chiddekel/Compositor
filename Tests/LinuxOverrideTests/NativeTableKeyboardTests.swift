import AppKit
import Testing

@MainActor
@Suite(.serialized) struct NativeTableKeyboardTests {
    private final class Model: NSTableViewDataSource, NSTableViewDelegate {
        var count = 12
        var changes = 0
        var names: [String] = []
        var typeSelectionAllowed = true
        var usesTextFieldOutlet = true
        var draggable = false
        var requestedDragRows: [Int] = []
        func numberOfRows(in tableView: NSTableView) -> Int { count }
        func tableViewSelectionDidChange(_ notification: Notification) { changes += 1 }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            requestedDragRows.append(row)
            guard draggable else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: .string)
            return item
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard names.indices.contains(row) else { return nil }
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: names[row])
            if usesTextFieldOutlet { cell.textField = field }
            else {
                let warning = NSTextField(labelWithString: "Hidden mask warning")
                warning.isHidden = true
                cell.addSubview(warning)
            }
            cell.addSubview(field)
            return cell
        }
        func tableView(_ tableView: NSTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch search: String?) -> Bool {
            typeSelectionAllowed
        }
    }
    private final class Responder: NSResponder {
        var keys: [UInt16] = []
        override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    }
    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    private func click(_ table: NSTableView, row: Int, modifiers: NSEvent.ModifierFlags = []) {
        let rect = table.rect(ofRow: row)
        let point = table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        table.mouseDown(with: event)
    }

    @Test func disjointSelectionUsesLastSelectedRowForRangeExpansionAndContraction() {
        let model = Model()
        let (table, _) = table(model)
        table.allowsMultipleSelection = true
        click(table, row: 8)
        click(table, row: 2, modifiers: .command)
        #expect(table.selectedRowIndexes == IndexSet([2, 8]))
        #expect(table.selectedRow == 2)
        table.keyDown(with: key(125, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet([2, 3, 8]))
        #expect(table.selectedRow == 3)
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet([2, 8]))
        #expect(table.selectedRow == 2)
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet([1, 2, 8]))
        #expect(table.selectedRow == 1)
    }

    @Test func shiftClicksKeepDisjointRowsAndRetainTheOriginalAnchor() {
        let model = Model()
        let (table, _) = table(model)
        table.allowsMultipleSelection = true
        click(table, row: 2)
        click(table, row: 8, modifiers: .command)
        click(table, row: 6, modifiers: .shift)
        #expect(table.selectedRowIndexes == IndexSet([2, 6, 7, 8]))
        #expect(table.selectedRow == 6)
        click(table, row: 9, modifiers: [.command, .shift])
        #expect(table.selectedRowIndexes == IndexSet([2, 8, 9]))
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet([2, 8]))
        let before = model.changes
        click(table, row: 8, modifiers: .command)
        #expect(table.selectedRowIndexes == IndexSet(integer: 2))
        #expect(table.selectedRow == 2)
        #expect(model.changes == before + 1)
    }

    @Test func programmaticDisjointSelectionAndReloadResetStaleRangeState() {
        let model = Model()
        let (table, _) = table(model)
        table.allowsMultipleSelection = true
        table.selectRowIndexes(IndexSet([2, 8]), byExtendingSelection: false)
        #expect(table.selectedRow == 8)
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet([2, 7, 8]))
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        table.keyDown(with: key(125, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 4...5))
        model.count = 3; table.reloadData()
        table.keyDown(with: key(126, modifiers: .shift))
        #expect(table.selectedRowIndexes == IndexSet(integer: 2))
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

    @Test(arguments: [true, false]) func draggingAnAlreadySelectedRowPreservesTheSetUntilRelease(draggable: Bool) {
        let model = Model(); model.draggable = draggable
        let (table, scroll) = table(model)
        table.allowsMultipleSelection = true
        let window = NSWindow(contentRect: scroll.frame, styleMask: [], backing: .buffered, defer: true)
        window.contentView = scroll
        table.selectRowIndexes(IndexSet([2, 8]), byExtendingSelection: false)
        model.changes = 0
        let rect = table.rect(ofRow: 2)
        let point = table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let dragged = NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: point.x + 4, y: point.y),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        let released = NSEvent.mouseEvent(with: .leftMouseUp, location: dragged.locationInWindow,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0)!
        window.postEvent(dragged, atStart: false)
        window.postEvent(released, atStart: false)
        click(table, row: 2)
        #expect(model.requestedDragRows == [2, 8])
        if draggable {
            #expect(table.selectedRowIndexes == IndexSet([2, 8]))
            #expect(model.changes == 0)
            #expect(NSDraggingSession.current?.items.count == 2)
            NSDraggingSession.current?.end(at: dragged.locationInWindow, operation: [])
        } else {
            #expect(table.selectedRowIndexes == IndexSet(integer: 2))
            #expect(model.changes == 1)
        }
    }

    @Test func releasingAnAlreadySelectedRowCollapsesTheSetOnce() {
        let model = Model()
        let (table, scroll) = table(model)
        table.allowsMultipleSelection = true
        let window = NSWindow(contentRect: scroll.frame, styleMask: [], backing: .buffered, defer: true)
        window.contentView = scroll
        table.selectRowIndexes(IndexSet([2, 8]), byExtendingSelection: false)
        model.changes = 0
        let point = table.convert(CGPoint(x: 90, y: table.rect(ofRow: 2).midY), to: nil)
        window.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: false)
        click(table, row: 2)
        #expect(table.selectedRowIndexes == IndexSet(integer: 2))
        #expect(table.selectedRow == 2)
        #expect(model.changes == 1)
        #expect(model.requestedDragRows.isEmpty)
    }

    @Test func pagingAndDocumentBoundaryKeysScrollWithoutChangingSelection() {
        let model = Model()
        let (table, scroll) = table(model)
        let original = table.selectedRowIndexes
        model.changes = 0
        table.keyDown(with: key(119))
        #expect(scroll.contentView.bounds.minY == 180)
        table.keyDown(with: key(116))
        #expect(scroll.contentView.bounds.minY == 120)
        table.keyDown(with: key(115))
        #expect(scroll.contentView.bounds.minY == 0)
        table.keyDown(with: key(121))
        #expect(scroll.contentView.bounds.minY == 60)
        #expect(table.selectedRowIndexes == original)
        #expect(model.changes == 0)
    }

    @Test func typeSelectionMatchesPrefixesCyclesAndRespectsDelegates() {
        let model = Model()
        model.names = ["Alpha", "Alpine", "Éclair", "Echo", "🦊 Fox"]
        model.count = model.names.count
        let (table, scroll) = table(model)
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        func type(_ value: String, time: TimeInterval, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: time,
                windowNumber: 0, context: nil, characters: value, charactersIgnoringModifiers: value,
                isARepeat: false, keyCode: 0xffff)!
            table.keyDown(with: event)
        }
        type("a", time: 1)
        #expect(table.selectedRow == 0)
        type("a", time: 1.2)
        #expect(table.selectedRow == 1)
        type("l", time: 1.3)
        type("p", time: 1.4)
        #expect(table.selectedRow == 1)
        type("E", time: 3, modifiers: .shift)
        #expect(table.selectedRow == 2)
        type("c", time: 3.2)
        #expect(table.selectedRow == 2)
        type("🦊", time: 5)
        #expect(table.selectedRow == 4)
        #expect(scroll.contentView.bounds.contains(table.rect(ofRow: 4)))
        model.typeSelectionAllowed = false
        type("a", time: 7)
        #expect(table.selectedRow == 4)
        model.typeSelectionAllowed = true
        table.allowsTypeSelect = false
        type("a", time: 9)
        #expect(table.selectedRow == 4)
    }

    @Test func typeSelectionIgnoresHiddenLabelsInCustomDrawnCells() {
        let model = Model()
        model.names = ["Xray", "Quartz"]
        model.count = model.names.count
        model.usesTextFieldOutlet = false
        let (table, _) = table(model)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: "q", charactersIgnoringModifiers: "q",
            isARepeat: false, keyCode: 0xffff)!
        table.keyDown(with: event)
        #expect(table.selectedRow == 1)
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
