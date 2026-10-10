// Linux override of Compositor/UI/LayerMaskMenu.swift: MaskAloneBadgeView without NSStackView/#selector.
// LayerMaskMenu and MaskAloneBadge match tip (Option-click reveal/hide).
import SwiftUI
import AppKit

/// Adds a mask in one click, as Photoshop's button does: all white, or with a selection, revealing just the
/// selection. Option-click adds the opposite: all black, or hiding the selection.
/// Enable/Disable and Delete live in the layer's context menu.
struct LayerMaskMenu: View {
    let session: EditorSession
    var body: some View {
        Button {
            session.addMask(revealing: NSApp.currentEvent?.modifierFlags.contains(.option) != true)
        } label: { FooterIcon(systemName: "rectangle.inset.filled") }
            .help(session.selection == nil ? "Add layer mask (Option-click for a black mask)"
                  : "Add layer mask revealing the selection (Option-click to hide it)")
            .accessibilityLabel("Add layer mask")
            // Tip 1.4.8 (06313a9): dim only for real work, not a click's brief busy moment.
            .disabled(!session.layersLookEditable || session.selectedLayerIDs.count != 1 || session.activeLayer == nil
                      || session.activeLayer?.mask != nil)
    }
}

/// Over the canvas while it shows a mask by itself: whose mask it is, and a way back to the composite besides
/// Option-clicking the thumbnail again. Built in AppKit, as the canvas under it is, so its button gets its clicks.
struct MaskAloneBadge: NSViewRepresentable {
    let session: EditorSession
    let layer: ImageLayer
    func makeNSView(context: Context) -> MaskAloneBadgeView {
        MaskAloneBadgeView { [session] in session.viewsMaskAlone = false }
    }
    func updateNSView(_ view: MaskAloneBadgeView, context: Context) { view.layerName = layer.name }
}

/// Tip's badge without NSStackView and the #selector close button (no Objective-C runtime on Linux): the same
/// icon, "Layer Mask", the layer's name (at most 220 points) and an xmark, 26 points high. A click on the xmark
/// shows the image again. The Qt shell draws its own copy over the canvas (SessionWindow::ensureMaskAloneBadge).
final class MaskAloneBadgeView: NSView {
    var layerName = "" { didSet { invalidateIntrinsicContentSize() } }
    private let close: () -> Void
    /// Leading inset, icon, title, the three 7-point gaps, xmark and trailing inset.
    private static let chrome: CGFloat = 11 + 11 + 7 + 70 + 7 + 7 + 16 + 8

    init(close: @escaping () -> Void) {
        self.close = close
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.chrome + min(220, CGFloat(layerName.count) * 7), height: 26)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= bounds.maxX - 8 - 16 { close() }
    }
}
