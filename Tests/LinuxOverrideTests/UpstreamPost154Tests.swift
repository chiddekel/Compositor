import AppKit
import Foundation
import Testing
@testable import Compositor

@Suite(.serialized) @MainActor struct UpstreamPost154Tests {
    @Test func filePanelsOwnTextEditingAndRestoreNestedPresentation() {
        let saveHandler = NSSavePanel.handler
        let openHandler = NSOpenPanel.openHandler
        defer { NSSavePanel.handler = saveHandler; NSOpenPanel.openHandler = openHandler }
        let outer = NSSavePanel()
        let inner = NSOpenPanel()
        NSOpenPanel.openHandler = { panel in
            #expect(NSSavePanel.activePanel === panel)
            #expect(NSApp.isEditingText)
            return .cancel
        }
        NSSavePanel.handler = { panel in
            #expect(NSSavePanel.activePanel === panel)
            #expect(NSApp.isEditingText)
            #expect(inner.runModal() == .cancel)
            #expect(NSSavePanel.activePanel === panel)
            return .OK
        }
        #expect(NSSavePanel.activePanel == nil)
        #expect(outer.runModal() == .OK)
        #expect(NSSavePanel.activePanel == nil)
    }

    @Test func layoutTranslationUsesNativeLatinLabelAndPreservesEventMetadata() throws {
        let original = NSKeyboardLayout.latinCharacter(for: 16, shift: false) ?? "y"
        defer { NSKeyboardLayout.recordLatinCharacter(original, for: 16, shift: false) }
        // A German Latin layout types Z on the physical Y key; the active Russian layout types н.
        NSKeyboardLayout.recordLatinCharacter("z", for: 16, shift: false)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: CGPoint(x: 12, y: 34),
            modifierFlags: [.option], timestamp: 123, windowNumber: 17, context: nil,
            characters: "н", charactersIgnoringModifiers: "н", isARepeat: true, keyCode: 16))
        let translated = LatinKeys.event(event)
        #expect(translated.charactersIgnoringModifiers == "z")
        #expect(translated.keyCode == 16)
        #expect(translated.timestamp == 123)
        #expect(translated.windowNumber == 17)
        #expect(translated.locationInWindow == CGPoint(x: 12, y: 34))
        #expect(translated.modifierFlags == [.option])
        #expect(translated.isARepeat)
    }

    @Test func latinInputAndUnknownHardwareKeysAreNotRewritten() throws {
        let latin = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z",
            isARepeat: false, keyCode: 16))
        #expect(LatinKeys.event(latin) === latin)
        let unknown = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "и", charactersIgnoringModifiers: "и",
            isARepeat: false, keyCode: 0xffff))
        #expect(LatinKeys.event(unknown) === unknown)
    }
}
