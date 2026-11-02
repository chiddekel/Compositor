import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct Upstream154Tests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func postScriptFontNamesBringTheirInstalledFamilyFaces() throws {
        let font = try #require(NSFont(name: "DejaVuSansMono-BoldOblique", size: 13))
        #expect(font.familyName == "DejaVu Sans Mono")
        #expect(NSFontManager.shared.availableFonts.contains(font.fontName))
        let names = FontMenuFaces.names(available: [], inUse: [font.fontName])
        #expect(names.contains("DejaVuSansMono"))
        #expect(names.contains("DejaVuSansMono-BoldOblique"))
    }

    @Test func fontPanelSearchAndKeyboardSelectionUseUpstreamCallbacks() throws {
        let panel = FontListPanel(names: ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique"],
                                  selected: "Helvetica", styledName: { _ in nil })
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [], backing: .buffered, defer: false)
        var highlights: [String] = [], choices: [String?] = []
        panel.onHighlight = { highlights.append($0) }
        panel.onClose = { choices.append($0) }
        panel.show(below: CGRect(x: 100, y: 500, width: 210, height: 24), in: parent)
        defer { panel.dismiss(choosing: nil) }
        let root = try #require(panel.contentView)
        let search = try #require(descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let viewport = try #require(descendants(root).compactMap { $0 as? NSScrollView }.first)
        #expect(viewport.frame.height == panel.frame.height - 47)
        #expect(search.superview?.frame.maxY == root.bounds.height - 8)
        let table = try #require(descendants(root).compactMap { $0 as? NSTableView }.first)
        #expect(parent.childWindows.contains { $0 === panel })
        search.stringValue = "bold"
        search.delegate?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(panel.numberOfRows(in: table) == 1)
        let label = try #require(panel.tableView(table, viewFor: nil, row: 0) as? NSTextField)
        #expect(label.stringValue == "Helvetica-Bold")
        #expect(panel.control(search, textView: NSTextView(), doCommandBy: Selector("moveDown:")))
        #expect(highlights.last == "Helvetica-Bold")
        #expect(panel.control(search, textView: NSTextView(), doCommandBy: Selector("insertNewline:")))
        #expect(choices.count == 1 && choices[0] == "Helvetica-Bold")
        #expect(parent.childWindows.isEmpty && !panel.isVisible)
    }

    @Test func escapeClearsSearchBeforeClosingTheFontPanel() throws {
        let panel = FontListPanel(names: ["Helvetica", "Helvetica-Bold"], selected: "Helvetica", styledName: { _ in nil })
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [], backing: .buffered, defer: false)
        var closed = false
        panel.onClose = { _ in closed = true }
        panel.show(below: CGRect(x: 100, y: 500, width: 210, height: 24), in: parent)
        defer { panel.dismiss(choosing: nil) }
        let root = try #require(panel.contentView)
        let search = try #require(descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        search.stringValue = "missing face"
        search.delegate?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(panel.control(search, textView: NSTextView(), doCommandBy: Selector("cancelOperation:")))
        #expect(search.stringValue.isEmpty && !closed && panel.isVisible)
        #expect(panel.control(search, textView: NSTextView(), doCommandBy: Selector("cancelOperation:")))
        #expect(closed && !panel.isVisible)
    }

    @Test func lockedPDFImportPreservesTheExistingDocumentAndHistory() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("tests/fixtures/password-protected.pdf")
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        let before = session.document, revision = session.history.currentRevision
        await session.importImages([url])
        #expect(session.document == before)
        #expect(session.history.currentRevision == revision)
        #expect(session.importError?.contains("password") == true)
    }

    @Test func tabletCanvasDispatchPreservesPressureAndMouseRemainsFullStrength() async throws {
        let handle = await Task.detached { compositorSessionCreate() }.value
        defer { Task.detached { compositorSessionClose(handle) } }
        let entry = try #require(Sessions.entries[handle])
        let session = entry.editor.session
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings.pressureSize = true
        session.brushSettings.pressureOpacity = true
        let canvas = UpstreamCanvases.canvas(handle, entry)
        canvas.resize(width: 100, height: 100, scale: 1)
        session.zoom(to: 1)
        let point = session.viewport.viewPoint(from: CGPoint(x: 50, y: 50), documentSize: CGSize(width: 100, height: 100))
        let x = Double(point.x), y = Double(point.y)
        let press = await Task.detached { compositorCanvasTablet(handle, 0, x, y, 0, 0.25) }.value
        #expect(press >= 0 && session.brushPressure == 0.25 && PenInput.shared.seen)
        let release = await Task.detached { compositorCanvasTablet(handle, 2, x, y, 0, 0) }.value
        #expect(release >= 0 && session.brushStroke == nil)
        let mouse = await Task.detached { compositorCanvasMouse(handle, 0, x, y, 0, 1) }.value
        #expect(mouse >= 0 && session.brushPressure == 1)
        _ = await Task.detached { compositorCanvasMouse(handle, 2, x, y, 0, 1) }.value
        #expect(session.history.canUndo)
    }
}
