// Linux override of Compositor/UI/LayerMaskMenu.swift: MaskAloneBadge is SwiftUI (no
// NSStackView/#selector). LayerMaskMenu itself matches tip (Option-click reveal/hide).
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
        } label: { Image(systemName: "rectangle.inset.filled").footerHitArea() }
            .buttonStyle(.borderless)
            .help(session.selection == nil ? "Add layer mask (Option-click for a black mask)"
                  : "Add layer mask revealing the selection (Option-click to hide it)")
            .accessibilityLabel("Add layer mask")
            .disabled(!session.canEditMask || session.activeLayer?.mask != nil)
    }
}

/// Over the canvas while it shows a mask by itself: whose mask it is, and a way back to the composite besides
/// Option-clicking the thumbnail again.
struct MaskAloneBadge: View {
    let session: EditorSession
    let layer: ImageLayer
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.inset.filled").font(.system(size: 11))
            Text("Layer Mask").font(.system(size: 12, weight: .semibold))
            Text(layer.name).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6)).lineLimit(1)
            Button {
                session.viewsMaskAlone = false
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Show the image again (or Option-click the mask thumbnail)")
        }
        .foregroundStyle(.white)
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(Color.black.opacity(0.75), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// Tip AppKit badge type kept for MaskAloneTests (Linux badge is SwiftUI `MaskAloneBadge`).
final class MaskAloneBadgeView: NSView {
    var layerName = ""
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension ImageLayer {
    /// The layer's size on the canvas and, once it's scaled, by how much (from tip NativeLayerList).
    var sizeLabel: String {
        let text = "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px"
        guard let pixels = asset?.image.width, pixels > 0 else { return text }
        let percent = Double(size.width) / Double(pixels) * 100
        guard abs(percent - 100) >= 0.05 else { return text }
        return text + " · " + percent.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
}
