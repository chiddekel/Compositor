import AppKit
import Testing

@MainActor struct PasteboardDragLifetimeTests {
    @Test func clearingDropsPreviousDragItems() {
        let board = NSPasteboard.withUniqueName()
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        board.writeObjects([first])
        board.clearContents()
        #expect(board.pasteboardItems?.isEmpty != false)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        board.writeObjects([second])
        #expect(board.pasteboardItems?.count == 1)
        #expect(board.pasteboardItems?.first?.string(forType: .string) == "second")
        board.releaseGlobally()
        #expect(board.pasteboardItems?.isEmpty != false)
    }

    @Test func endingPasteboardLifetimeReleasesItsWriters() {
        weak var writer: NSPasteboardItem?
        do {
            let board = NSPasteboard.withUniqueName()
            let item = NSPasteboardItem()
            writer = item
            item.setString("temporary", forType: .string)
            board.writeObjects([item])
        }
        #expect(writer == nil)
    }
}
