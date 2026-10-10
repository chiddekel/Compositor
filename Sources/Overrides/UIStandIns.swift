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

// `ShortcutSettings`/`configuredNativeShortcut`/`configuredKeyboardShortcut` are real now
// (Sources/Overrides/KeyboardShortcuts.swift, a faithful override of Compositor/UI/KeyboardShortcuts.swift).

/// STAND-IN for the `NSPopUpButton` in UI/BlendModePicker.swift (an `NSViewRepresentable` with an `NSMenuDelegate`):
/// the same modes, grouped as Photoshop groups them with a line between, spanning its row as the pop-up does.
struct BlendModePicker: View {
    let session: EditorSession
    var body: some View {
        Picker("Blend mode", selection: Binding(
            get: { session.activeLayer?.blendMode ?? .normal },
            set: { session.setLayerBlendMode($0); session.refreshCanvasPreview?() }
        )) {
            ForEach(Array(LayerBlendMode.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        }
        .labelsHidden()   // an NSPopUpButton on the Mac: no title beside it
        .frame(maxWidth: .infinity)
        .disabled(!session.canEditAppearance)
        .accessibilityLabel("Blend mode")
        // The Coordinator's menu tracking: each highlighted mode previews on the canvas; closing restores the layer's.
        .compatPickerHighlight { tag in
            if let tag, let mode = LayerBlendMode(rawValue: tag) {
                if BlendPreview.layerID == nil { BlendPreview.layerID = session.activeLayerID }
                session.previewBlendMode(mode, for: BlendPreview.layerID)
            } else {
                BlendPreview.layerID = nil
                session.previewBlendMode(nil, for: nil)
            }
            session.refreshCanvasPreview?()
        }
    }
}

/// The layer a blend-mode menu opened on, while it is open.
@MainActor enum BlendPreview { static var layerID: UUID? }

// `LayersPanel` is wired in for real (Compositor/UI/LayersPanel.swift); it uses `NativeLayerList`, which is
// overridden (`Sources/Overrides/NativeLayerListOverride.swift` — a real functional backend swap, not a stand-in;
// see that file for why the actual NSTableView-based `NativeLayerList.swift` is blocked).


