// STAND-INS for UI types the unmodified canvas view refers to (Compositor/UI is not compiled on Linux):
//   CanvasRulerNSView (UI/CanvasRulers.swift)          — the rulers NSView; the canvas only checks `view is CanvasRulerNSView`
//   FloatingPanelController (UI/FloatingPanel.swift)    — brings a floating panel back to the front after canvas edits
//   ColorPickerPanelController (UI/ColorPickerSheet.swift) — same for the colour picker panel
// The Qt shell provides the real panels; these are inert so focus requests are no-ops until it registers a handler.

import Foundation
import AppKit
import SwiftUI

@MainActor final class CanvasRulerNSView: NSView {}

@MainActor final class FloatingPanelController {
    init(name: String) {}
    /// Installed by the host so the canvas can ask a panel to take focus back.
    static var onRefocus: ((NSUserInterfaceItemIdentifier) -> Void)?
    static func refocus(_ identifier: NSUserInterfaceItemIdentifier) { onRefocus?(identifier) }
}

@MainActor enum ColorPickerPanelController {
    static var onRefocus: (() -> Void)?
    static func refocus() { onRefocus?() }
}

/// STAND-IN for the model part of UI/KeyboardShortcuts.swift (the file also holds the SwiftUI editor). Canvas and text
/// editing route events through it so user-remapped shortcuts reach the canvas as their original chords. With no
/// remapping (the Qt shell owns shortcut customisation) every event maps to itself.
@MainActor final class ShortcutSettings {
    static let shared = ShortcutSettings()
    private init() {}
    func canvasEvent(_ event: NSEvent) -> NSEvent? { event }
    func textEvent(_ event: NSEvent) -> NSEvent? { event }
}

/// STAND-IN for UI/LayersPanel.swift (the SwiftUI layers list). Tests only build it to host next to the canvas.
@MainActor struct LayersPanel: View {
    let session: EditorSession
    init(session: EditorSession) { self.session = session }
}

extension LayersPanel: HostedNativeContent {
    func makeNativeView() -> NSView? {
        let table = LayerTableView(frame: CGRect(x: 0, y: 0, width: 252, height: 600))
        table.session = session
        return table
    }
}

/// STAND-IN for the `NSTableView` subclass in UI/NativeLayerList.swift, whose key handling (tool keys, nudges while the
/// layer list has focus) lives in the macOS layers panel. The Qt layers panel handles keys itself.
@MainActor final class LayerTableView: NSTableView {
    weak var session: EditorSession?
}
