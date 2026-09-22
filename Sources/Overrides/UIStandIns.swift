// STAND-INS for UI types the unmodified canvas view refers to (Compositor/UI is not compiled on Linux):
//   CanvasRulerNSView (UI/CanvasRulers.swift)          — the rulers NSView; the canvas only checks `view is CanvasRulerNSView`.
//     The real file's `draw(_:)` needs NSString.draw/size, NSFont.monospacedDigitSystemFont, NSAffineTransform.concat
//     — real AppKit text-drawing compat, a separate sub-project from SwiftUI compat; tried and reverted, see the plan.
// `FloatingPanelController`/`ColorPickerPanelController` are wired in for real (Compositor/UI/FloatingPanel.swift,
// ColorPickerSheet.swift) — their `NSPanel`s never actually become visible without a real display, so `show`/
// `makeKeyAndOrderFront`/etc. all still end up as no-ops in practice, same effect the old stand-ins had.

import Foundation
import AppKit
import SwiftUI

/// STAND-IN for the model part of UI/KeyboardShortcuts.swift (the file also holds the SwiftUI editor). Canvas and text
/// editing route events through it so user-remapped shortcuts reach the canvas as their original chords. With no
/// remapping (the Qt shell owns shortcut customisation) every event maps to itself.
@MainActor final class ShortcutSettings {
    static let shared = ShortcutSettings()
    private init() {}
    func canvasEvent(_ event: NSEvent) -> NSEvent? { event }
    func textEvent(_ event: NSEvent) -> NSEvent? { event }
}

struct BlendModePicker: View {
    let session: EditorSession
    var body: some View {
        Picker("Blend mode", selection: Binding(
            get: { session.activeLayer?.blendMode ?? .normal },
            set: { session.setLayerBlendMode($0); session.refreshCanvasPreview?() }
        )) {
            ForEach(LayerBlendMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
    }
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

extension LayersPanel: PrimitiveView {
    func _makeNode(children: [RenderNode]) -> RenderNode { RenderNode(kind: "_Native") }
}

/// STAND-IN for the `NSTableView` subclass in UI/NativeLayerList.swift, whose key handling (tool keys, nudges while the
/// layer list has focus) lives in the macOS layers panel. The Qt layers panel handles keys itself.
@MainActor final class LayerTableView: NSTableView {
    weak var session: EditorSession?
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if event.keyCode == 53, session?.transformEdit != nil {
            session?.cancelTransform()
        } else if [36, 76].contains(event.keyCode), session?.transformEdit != nil {
            session?.commitTransform()
        } else if plain, event.keyCode == 48 {
            session?.cycleToolMode()
        } else if plain, event.charactersIgnoringModifiers?.lowercased() == "x" {
            session?.swapPaletteColors()
        } else if plain, event.charactersIgnoringModifiers?.lowercased() == "d" {
            session?.resetPaletteColors()
        } else if plain, event.charactersIgnoringModifiers?.lowercased() == "t" {
            session?.selectTool(.type)
        } else if plain, ["a", "v", "h", "z", "b", "e", "g", "l", "m", "w", "j", "s", "u", "r", "i", "c"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "m" { if !event.isARepeat { session?.pressMarqueeKey() } }
            else if key == "l" { if !event.isARepeat { session?.pressLassoKey() } }
            else if key == "b" || key == "e" {
                session?.selectTool(.brush)
                session?.brushMode = key == "e" ? .erase : .paint
            }
            else if key == "w" { if !event.isARepeat { session?.pressWandKey() } }
            else { session?.selectTool(key == "a" ? .idle : key == "i" ? .eyedropper : key == "c" ? .crop : key == "r" ? .blur : key == "b" ? .brush : key == "g" ? .gradient : key == "l" ? .lasso : key == "m" ? .marquee : key == "j" ? .spotHealing : key == "s" ? .cloneStamp : key == "u" ? .shape : key == "v" ? .move : key == "h" ? .hand : .zoom) }
        } else if plain, let digit = Int(event.charactersIgnoringModifiers ?? ""), session?.usesOpacityKeys == true {
            session?.typeOpacityDigit(digit)
        // With the Move tool the arrows move the layer, as on the canvas, rather than changing the row selection.
        } else if plain, session?.transformEdit != nil || session?.tool == .move, [123, 124, 125, 126].contains(event.keyCode) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            session?.nudgeLayer(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
        } else if [51, 117].contains(event.keyCode), plain {
            session?.deleteKeyPressed()
        } else { super.keyDown(with: event) }
    }
}

