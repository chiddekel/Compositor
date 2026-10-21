import Foundation
import CoreGraphics

/// Text-field cell properties used by the font search panel. The field and the native host share their value.
@MainActor public final class NSTextFieldCell {
    public var usesSingleLineMode = false
    public var isScrollable = false
}

/// Menu material drawn in the application's dark appearance. Linux does not provide AppKit's backdrop blur.
@MainActor open class NSVisualEffectView: NSView {
    public enum Material { case menu }
    public enum State { case active, inactive, followsWindowActiveState }
    public var material: Material = .menu
    public var state: State = .active
    open override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.16, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

@MainActor open class NSTableRowView: NSView {
    open func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
