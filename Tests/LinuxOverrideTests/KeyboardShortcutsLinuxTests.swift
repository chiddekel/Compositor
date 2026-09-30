import Testing
import Foundation
@testable import Compositor

/// Remappable shortcuts on Linux: ShortcutRecorder finishes via compatKeyCapture (KeyCaptureFilter in Qt).
@MainActor
@Suite struct KeyboardShortcutsLinuxTests {
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

    @Test func problemRejectsEmptyKey() {
        guard let first = ShortcutDefinition.all.first else { return }
        var values: [String: ShortcutChord] = [:]
        values[first.id] = ShortcutChord("", 0)
        #expect(ShortcutSettings.problem(in: values) != nil)
    }

    @Test func chordRoundTripsThroughJSON() throws {
        let chord = ShortcutChord("z", 1 | 8) // Ctrl+Shift+Z
        let data = try JSONEncoder().encode(["test": chord])
        let loaded = try JSONDecoder().decode([String: ShortcutChord].self, from: data)
        #expect(loaded["test"] == chord)
    }
}
