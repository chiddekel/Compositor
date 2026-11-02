import Testing
import Foundation
import SwiftUI
import AppKit
@testable import Compositor

/// Remappable shortcuts on Linux: ShortcutRecorder finishes via compatKeyCapture (KeyCaptureFilter in Qt).
@MainActor
@Suite struct KeyboardShortcutsLinuxTests {
    @Test func shortcutSearchSurvivesCABIAction() async throws {
        let handle = await Task.detached { compositorSessionCreate() }.value
        defer {
            if let entry = Sessions.entries.removeValue(forKey: handle) {
                let scope = "\(ObjectIdentifier(entry).hashValue)|KeyboardShortcutsSheet"
                StateStore.discard(scope: scope); ChangeTracker.discard(scope: scope); NativeLowering.discard(scope: scope)
            }
        }
        let entry = try #require(Sessions.entries[handle])
        let settings = ShortcutSettings.shared
        settings.show()
        defer { settings.close() }
        func search(in node: RenderNodeWire) -> RenderNodeWire? {
            if node.kind == "TextField", node.stringParams["placeholder"] == "Search shortcuts" { return node }
            for child in node.children { if let found = search(in: child) { return found } }
            return nil
        }
        let initial = try #require(resolvePanel("KeyboardShortcutsSheet", entry: entry))
        let field = try #require(search(in: initial))
        let nodeID = field.id
        let payload = try JSONEncoder().encode("Brush tool")
        let result = await Task.detached {
            "KeyboardShortcutsSheet".withCString { panel in
                nodeID.withCString { node in
                    "text".withCString { key in
                        payload.withUnsafeBytes { bytes in
                            compositorSessionDispatchSwiftUIAction(handle, panel, node, key,
                                bytes.bindMemory(to: UInt8.self).baseAddress, payload.count)
                        }
                    }
                }
            }
        }.value
        #expect(result == 0)
        let refreshed = try #require(resolvePanel("KeyboardShortcutsSheet", entry: entry))
        #expect(try #require(search(in: refreshed)).stringParams["text"] == "Brush tool")
        settings.close()
        // The host observes the closed panel before the next opening.
        #expect(resolvePanel("KeyboardShortcutsSheet", entry: entry) == nil)
        #expect(entry.actionHandlers["KeyboardShortcutsSheet"]?.isEmpty != false)
        settings.show()
        let reopened = try #require(resolvePanel("KeyboardShortcutsSheet", entry: entry))
        #expect(try #require(search(in: reopened)).stringParams["text"] == "")
    }

    @Test func chordAcceptsSingleCharacterKeys() {
        let chord = ShortcutChord("a", 1) // Ctrl/Command + A
        #expect(chord.key == "a")
        #expect(chord.modifiers == 1)
        #expect(!chord.label.isEmpty)
    }

    @Test func escapeIsAValidSingleKeyChord() {
        let chord = ShortcutChord("\u{1b}", 0)
        #expect(chord.key.count == 1)
    }

    @Test func problemAcceptsClearedShortcut() {
        guard let first = ShortcutDefinition.all.first else { return }
        var values: [String: ShortcutChord] = [:]
        values[first.id] = ShortcutChord("", 0)
        #expect(ShortcutSettings.problem(in: values) == nil)
    }

    @Test func chordRoundTripsThroughJSON() throws {
        let chord = ShortcutChord("z", 1 | 8) // Ctrl+Shift+Z
        let data = try JSONEncoder().encode(["test": chord])
        let loaded = try JSONDecoder().decode([String: ShortcutChord].self, from: data)
        #expect(loaded["test"] == chord)
    }
}
