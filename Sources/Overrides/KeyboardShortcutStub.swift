// TEMP STAND-IN for `configuredNativeShortcut`/`configuredKeyboardShortcut` and `releasesFocusOnCommit`, real
// upstream code in Compositor/UI/KeyboardShortcuts.swift and Compositor/ContentView.swift (neither wired in yet —
// KeyboardShortcuts.swift also declares the real `ShortcutSettings`, which would collide with the STAND-IN of the
// same name already in UIStandIns.swift). With no user remapping installed (the Qt shell owns shortcut
// customisation — see UIStandIns.swift's `ShortcutSettings`), every key maps to itself, so these are simply
// `.keyboardShortcut` directly / `onSubmit`+`onExitCommand`. Remove once those files are wired in for real.

import SwiftUI

extension View {
    func configuredNativeShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = []) -> some View {
        keyboardShortcut(key, modifiers: modifiers)
    }
    func configuredKeyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        keyboardShortcut(key, modifiers: modifiers)
    }
    func releasesFocusOnCommit(_ session: EditorSession) -> some View {
        onSubmit { session.canvasFocusRequest += 1 }
            .onExitCommand { session.canvasFocusRequest += 1 }
    }
}

/// TEMP STAND-IN for `View.roundedControls()`, real upstream code in Compositor/ContentView.swift (not wired in
/// yet, same reason as above). Remove once ContentView.swift joins the Linux build for real.
extension View {
    func roundedControls() -> some View { buttonBorderShape(.capsule) }
}
