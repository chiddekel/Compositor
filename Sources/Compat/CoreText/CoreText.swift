// Core Text's single-line API on Linux (CTLineCreateWithAttributedString, CTLineGetTypographicBounds, CTLineDraw), over
// the Qt text engine the AppKit compat's text drawing uses. Upstream's Dither filter draws its ASCII glyph cells this way.
import AppKit
import CoreGraphics
import Foundation

public final class CTLine {
    let string: NSAttributedString
    init(_ string: NSAttributedString) { self.string = string }

    var font: NSFont {
        (string.length > 0 ? string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil) ?? NSFont.systemFont(ofSize: 12)
    }
    var color: NSColor {
        (string.length > 0 ? string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil) ?? .black
    }
    var tracking: CGFloat {
        (string.length > 0 ? string.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat : nil) ?? 0
    }
}

public func CTLineCreateWithAttributedString(_ string: NSAttributedString) -> CTLine { CTLine(string) }

/// The line's width; `ascent`, `descent` (positive, below the baseline) and `leading` from the font.
public func CTLineGetTypographicBounds(_ line: CTLine, _ ascent: UnsafeMutablePointer<CGFloat>?, _ descent: UnsafeMutablePointer<CGFloat>?,
                                       _ leading: UnsafeMutablePointer<CGFloat>?) -> Double {
    let font = line.font
    ascent?.pointee = font.ascender
    descent?.pointee = -font.descender
    leading?.pointee = font.leading
    if let layout = TextBackend.layout(line.string.string, font: font, tracking: line.tracking, lineHeight: 0, maxWidth: 0) {
        return Double(layout.width)
    }
    return Double((line.string.string as NSString).size(withAttributes: [.font: font]).width)
}

/// Draws the line with its baseline origin at the context's `textPosition` (y-up user space, as Core Graphics).
public func CTLineDraw(_ line: CTLine, _ context: CGContext) {
    let font = line.font
    guard let layout = TextBackend.layout(line.string.string, font: font, tracking: line.tracking, lineHeight: 0, maxWidth: 0),
          let image = TextBackend.render(line.string.string, font: font, tracking: line.tracking, lineHeight: 0, maxWidth: 0,
                                         alignment: 0, boxWidth: 0, color: line.color) else { return }
    // The image's first baseline is `layout.baseline` below its top; in y-up space its bottom sits that far under it.
    let height = CGFloat(image.height)
    let origin = CGPoint(x: context.textPosition.x, y: context.textPosition.y - (height - layout.baseline))
    context.draw(image, in: CGRect(origin: origin, size: CGSize(width: CGFloat(image.width), height: height)))
}
