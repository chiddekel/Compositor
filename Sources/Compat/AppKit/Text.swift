import Foundation
import CoreGraphics

// The Type tool's text stack. Layout is approximate and drawing is a no-op until the Skia paragraph backend is
// wired in (Phase 3); the API mirrors what upstream's TypeTool.swift calls.

open class NSFont: @unchecked Sendable {
    public let fontName: String
    public let pointSize: CGFloat
    public init?(name: String, size: CGFloat) {
        guard !name.isEmpty else { return nil }
        fontName = name; pointSize = size
    }
    private init(system size: CGFloat) { fontName = "System"; pointSize = size }
    public static func systemFont(ofSize size: CGFloat) -> NSFont { NSFont(system: size) }
}

public enum NSTextAlignment: Int, Sendable { case left, right, center, justified, natural }
public enum NSLineBreakMode: Int, Sendable { case byWordWrapping, byCharWrapping, byClipping, byTruncatingHead, byTruncatingTail, byTruncatingMiddle }

open class NSParagraphStyle: @unchecked Sendable {
    open var alignment: NSTextAlignment = .natural
    open var minimumLineHeight: CGFloat = 0
    open var maximumLineHeight: CGFloat = 0
    open var lineBreakMode: NSLineBreakMode = .byWordWrapping
    public init() {}
}
open class NSMutableParagraphStyle: NSParagraphStyle, @unchecked Sendable {}

extension NSAttributedString.Key {
    public static let font = NSAttributedString.Key("NSFont")
    public static let foregroundColor = NSAttributedString.Key("NSColor")
    public static let paragraphStyle = NSAttributedString.Key("NSParagraphStyle")
    public static let kern = NSAttributedString.Key("NSKern")
}

public struct NSStringDrawingOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let usesLineFragmentOrigin = NSStringDrawingOptions(rawValue: 1 << 0)
    public static let usesFontLeading = NSStringDrawingOptions(rawValue: 1 << 1)
}

extension NSAttributedString {
    /// Approximate measure (0.55 em per character, one line height per line) until real shaping is available.
    public func boundingRect(with size: CGSize, options: NSStringDrawingOptions = []) -> CGRect {
        let attrs = length > 0 ? attributes(at: 0, effectiveRange: nil) : [:]
        let point = (attrs[.font] as? NSFont)?.pointSize ?? 12
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
        let widest = lines.map { CGFloat($0.count) * point * 0.55 }.max() ?? 0
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        let lineHeight = (paragraph?.minimumLineHeight ?? 0) > 0 ? paragraph!.minimumLineHeight : point * 1.2
        return CGRect(x: 0, y: 0, width: min(widest, size.width), height: min(CGFloat(lines.count) * lineHeight, size.height))
    }
}

open class NSTextContainer {
    public var size: CGSize
    public var lineFragmentPadding: CGFloat = 5
    public init(size: CGSize) { self.size = size }
}
open class NSLayoutManager {
    public init() {}
    open func addTextContainer(_ container: NSTextContainer) {}
    open func glyphRange(for container: NSTextContainer) -> NSRange { NSRange(location: 0, length: 0) }
    open func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {}
}
open class NSTextStorage {
    public let attributedString: NSAttributedString
    public init(attributedString: NSAttributedString) { self.attributedString = attributedString }
    open func addLayoutManager(_ manager: NSLayoutManager) {}
}
