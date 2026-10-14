import AppKit
@testable import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct NativeFocusTests {
    private final class KeyView: NSView {
        var keys: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys.append(event.characters ?? "") }
    }
    private final class EditingDelegate: NSObject, NSTextFieldDelegate {
        var endings = 0
        func controlTextDidEndEditing(_ notification: Notification) { endings += 1 }
    }
    private func window(_ root: NSView) -> NSWindow {
        let window = NSWindow()
        window.contentView = root
        return window
    }

    @Test func detachingResponderSubtreeClearsFormerWindowFocus() {
        let root = KeyView(), container = NSView(), child = KeyView()
        root.addSubview(container); container.addSubview(child)
        let window = window(root)
        #expect(window.makeFirstResponder(child))
        container.removeFromSuperview()
        #expect(window.firstResponder == nil)
        PointerRouter.for(root).key(["characters": "a", "keyCode": 0])
        #expect(root.keys == ["a"])
        #expect(child.keys.isEmpty)
    }

    @Test func detachingEditedFieldCommitsAndEndsSharedEditorOnce() {
        let root = KeyView(), container = NSView(), field = NSTextField()
        let delegate = EditingDelegate()
        field.isEditable = true; field.delegate = delegate
        root.addSubview(container); container.addSubview(field)
        let window = window(root)
        #expect(window.makeFirstResponder(field))
        field.currentEditor()?.string = "Renamed"
        container.removeFromSuperview()
        #expect(field.stringValue == "Renamed")
        #expect(delegate.endings == 1)
        #expect(window.editedField == nil && window.firstResponder == nil)
    }

    @Test func focusLossEndsOwnedEditorButPreservesSiblingResponder() {
        let root = KeyView(), sibling = KeyView(), field = NSTextField(), container = NSView()
        container.addSubview(root); container.addSubview(sibling); root.addSubview(field)
        field.isEditable = true
        let window = window(container)
        let router = PointerRouter.for(root)
        #expect(window.makeFirstResponder(field))
        router.focus(true)
        #expect(window.editedField === field)
        router.focus(false)
        #expect(window.editedField == nil && window.firstResponder == nil)
        #expect(window.makeFirstResponder(sibling))
        router.focus(false)
        #expect(window.firstResponder === sibling)
        router.key(["characters": "b", "keyCode": 11])
        #expect(root.keys == ["b"] && sibling.keys.isEmpty)
        router.focus(true)
        #expect(window.firstResponder === root)
    }

    @Test func removingUnfocusedSiblingPreservesEditingOwner() {
        let root = NSView(), sibling = NSView(), field = NSTextField()
        root.addSubview(sibling); root.addSubview(field); field.isEditable = true
        let window = window(root)
        #expect(window.makeFirstResponder(field))
        sibling.removeFromSuperview()
        #expect(window.editedField === field)
        #expect(window.firstResponder === field.currentEditor())
    }

    @Test func movingContentRootEndsOldWindowEditingAndReleasesResponder() {
        let root = NSView(), field = NSTextField()
        root.addSubview(field); field.isEditable = true
        let first = window(root), second = NSWindow()
        #expect(first.makeFirstResponder(field))
        field.currentEditor()?.string = "Moved"
        second.contentView = root
        #expect(first.contentView == nil && first.firstResponder == nil && first.editedField == nil)
        #expect(root.window === second && field.stringValue == "Moved")
        #expect(second.makeFirstResponder(field))
        second.contentView = NSView()
        #expect(second.firstResponder == nil && second.editedField == nil)
        #expect(root.window == nil)
    }
}
