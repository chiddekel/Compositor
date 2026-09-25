import Foundation
import CoreGraphics

// The Type tool's text stack. Layout is approximate and drawing is a no-op until the Skia paragraph backend is
// wired in (Phase 3); the API mirrors what upstream's TypeTool.swift calls.

open class NSFont: @unchecked Sendable {
    public struct Weight: RawRepresentable, Hashable, Sendable {
        public let rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public static let ultraLight = Weight(rawValue: -0.8), thin = Weight(rawValue: -0.6), light = Weight(rawValue: -0.4)
        public static let regular = Weight(rawValue: 0), medium = Weight(rawValue: 0.23), semibold = Weight(rawValue: 0.3)
        public static let bold = Weight(rawValue: 0.4), heavy = Weight(rawValue: 0.56), black = Weight(rawValue: 0.62)
    }
    public let fontName: String
    public let pointSize: CGFloat
    /// Nil when no installed font answers to `name`, as in AppKit (a document naming a font this machine lacks).
    public init?(name: String, size: CGFloat) {
        guard !name.isEmpty, InstalledFonts.contains(name) else { return nil }
        fontName = name; pointSize = size
    }
    private init(system size: CGFloat) { fontName = "System"; pointSize = size }
    /// AppKit's vertical metrics: from the installed face through the Qt text engine; without it, typical proportions
    /// (0.8 em above the baseline, 0.2 below).
    public var ascender: CGFloat { TextBackend.metrics(self)?.ascender ?? pointSize * 0.8 }
    public var descender: CGFloat { TextBackend.metrics(self)?.descender ?? -pointSize * 0.2 }
    public var leading: CGFloat { TextBackend.metrics(self)?.leading ?? 0 }
    public static func systemFont(ofSize size: CGFloat) -> NSFont { NSFont(system: size) }
    public static func systemFont(ofSize size: CGFloat, weight: Weight) -> NSFont { NSFont(system: size) }
    public static func monospacedDigitSystemFont(ofSize size: CGFloat, weight: Weight = .regular) -> NSFont { NSFont(system: size) }
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
    public static let backgroundColor = NSAttributedString.Key("NSBackgroundColor")
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
        if let font = attrs[.font] as? NSFont,
           let real = TextBackend.layout(string, font: font, tracking: (attrs[.kern] as? CGFloat) ?? 0,
                                         lineHeight: (attrs[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight ?? 0,
                                         maxWidth: size.width >= 1e5 ? 0 : size.width) {
            return CGRect(x: 0, y: 0, width: min(real.width, size.width), height: min(real.height, size.height))
        }
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
    public var widthTracksTextView = false, heightTracksTextView = false
    public init(size: CGSize) { self.size = size }
}

open class NSLayoutManager {
    public weak var textStorage: NSTextStorage?
    public private(set) var textContainers: [NSTextContainer] = []

    public init() {}

    open func addTextContainer(_ container: NSTextContainer) {
        textContainers.append(container)
    }

    open func glyphRange(for container: NSTextContainer) -> NSRange {
        NSRange(location: 0, length: textStorage?.attributedString.length ?? 0)
    }

    open var numberOfGlyphs: Int {
        textStorage?.attributedString.length ?? 0
    }

    open func ensureLayout(for container: NSTextContainer) {}

    /// The line a glyph sits on and its origin in that line, laid out exactly as `drawGlyphs` draws: fixed advances
    /// (0.55 em plus tracking), lines `minimumLineHeight` or 1.2 em apart, wrapping at the container's width, each
    /// glyph drawn in an em-tall box from the line's top — so its baseline is about 0.8 em down.
    private func placement(ofGlyphAt index: Int) -> (line: Int, x: CGFloat, lineHeight: CGFloat, pointSize: CGFloat, width: CGFloat) {
        let attrString = textStorage?.attributedString ?? NSAttributedString(string: "")
        let attrs = attrString.length > 0 ? attrString.attributes(at: 0, effectiveRange: nil) : [:]
        let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 12)
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        let tracking = (attrs[.kern] as? CGFloat) ?? 0
        let pointSize = font.pointSize > 0 ? font.pointSize : 12
        let lineHeight = (paragraph?.minimumLineHeight ?? 0) > 0 ? paragraph!.minimumLineHeight : pointSize * 1.2
        let containerWidth = textContainers.first?.size.width ?? .greatestFiniteMagnitude
        let advance = pointSize * 0.55 + tracking
        var line = 0, x: CGFloat = 0
        for (i, ch) in attrString.string.enumerated() {
            if i == index { break }
            if ch == "\n" { line += 1; x = 0; continue }
            if ch != " ", x + advance > containerWidth, x > 0 { line += 1; x = 0 }
            x += advance
        }
        return (line, x, lineHeight, pointSize, containerWidth)
    }

    open func lineFragmentRect(forGlyphAt glyphIndex: Int, effectiveRange: UnsafeMutablePointer<NSRange>?) -> CGRect {
        let p = placement(ofGlyphAt: glyphIndex)
        effectiveRange?.pointee = NSRange(location: 0, length: numberOfGlyphs)
        return CGRect(x: 0, y: CGFloat(p.line) * p.lineHeight, width: p.width == .greatestFiniteMagnitude ? 0 : p.width, height: p.lineHeight)
    }

    /// The glyph's origin (baseline) relative to its line fragment.
    open func location(forGlyphAt glyphIndex: Int) -> CGPoint {
        let p = placement(ofGlyphAt: glyphIndex)
        let attrString = textStorage?.attributedString ?? NSAttributedString(string: "")
        let attrs = attrString.length > 0 ? attrString.attributes(at: 0, effectiveRange: nil) : [:]
        if let font = attrs[.font] as? NSFont,
           let real = TextBackend.layout(attrString.string, font: font, tracking: (attrs[.kern] as? CGFloat) ?? 0,
                                         lineHeight: p.lineHeight, maxWidth: 0) {
            return CGPoint(x: p.x, y: real.baseline)
        }
        return CGPoint(x: p.x, y: p.pointSize * 0.8)
    }

    open func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let attrString = storage.attributedString
        let fullString = attrString.string
        guard !fullString.isEmpty else { return }

        let containerWidth = textContainers.first?.size.width ?? CGFloat.greatestFiniteMagnitude
        let attrs = attrString.length > 0 ? attrString.attributes(at: 0, effectiveRange: nil) : [:]
        let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 12)
        let color = (attrs[.foregroundColor] as? NSColor) ?? NSColor.black
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        let tracking = (attrs[.kern] as? CGFloat) ?? 0

        let pointSize = font.pointSize > 0 ? font.pointSize : 12
        let lineHeight = (paragraph?.minimumLineHeight ?? 0) > 0 ? paragraph!.minimumLineHeight : pointSize * 1.2

        // Real fonts when the host's text engine is there: laid out and drawn by it, placed at `origin`, the way
        // upstream's text layers draw (a flipped context, y growing down from the text's top-left).
        let wrapWidth = containerWidth >= 1e5 ? 0 : containerWidth
        let alignment: Int32 = paragraph?.alignment == .center ? 1 : paragraph?.alignment == .right ? 2 : 0
        if let image = TextBackend.render(fullString, font: font, tracking: tracking, lineHeight: lineHeight, maxWidth: wrapWidth,
                                          alignment: alignment, boxWidth: wrapWidth, color: color) {
            let rect = CGRect(x: origin.x, y: origin.y, width: CGFloat(image.width), height: CGFloat(image.height))
            context.saveGState()
            // CGContext draws an image with its first row at the rect's max y; in this y-down space that is upside
            // down, so flip about the rect to put the first row at the top.
            context.translateBy(x: 0, y: rect.minY + rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: rect)
            context.restoreGState()
            return
        }

        context.setFillColor(color.cgColor)

        let charAdvance = pointSize * 0.55 + tracking
        let scaleX = (pointSize * 0.55) / 6.0
        let scaleY = pointSize / 11.0

        var currentX = origin.x
        var currentY = origin.y

        let glyphTable = Self.lazyGlyphTable

        for ch in fullString {
            if ch == "\n" {
                currentX = origin.x
                currentY += lineHeight
                continue
            }
            if ch == " " {
                currentX += charAdvance
                continue
            }
            if currentX + charAdvance > origin.x + containerWidth && currentX > origin.x {
                currentX = origin.x
                currentY += lineHeight
            }

            let glyph = Self.glyphBytes(for: ch, table: glyphTable)
            for row in 0..<11 {
                let rowByte = glyph[row]
                if rowByte == 0 { continue }
                var col = 0
                while col < 6 {
                    if (rowByte & (1 << (5 - col))) != 0 {
                        let startCol = col
                        while col < 6 && (rowByte & (1 << (5 - col))) != 0 {
                            col += 1
                        }
                        let span = col - startCol
                        let rx = currentX + CGFloat(startCol) * scaleX
                        let ry = currentY + CGFloat(row) * scaleY
                        context.fill(CGRect(x: rx, y: ry, width: max(1, CGFloat(span) * scaleX), height: max(1, ceil(scaleY))))
                    } else {
                        col += 1
                    }
                }
            }
            currentX += charAdvance
        }
    }

    private static let glyphBase64 = "AAAAAAAAAAAAAAAAABAQEBAQAAAQAAAAGBgYAAAAAAAAAAAKDAweFB4UGAAABA4VFRwGBRUOBAAAHBUVHgMFCQkAAAAOEBEPERERDwAAABAQEAAAAAAAAAAACBAQEBAQEAgIAAAAICAgICAgAAAAAAAAAAQVDgoAAAAAAAAEBB8EBAAAAAAAAAAAAAAAIAAAAAAAAAAwAAAAAAAAAAAAAAAAABAAAAAQECAgIAAAAAAAAA4bERERERsOAAAADBQEBAQEBAQAAAAMEgICBAgQPgAAABwiAgwCIiIcAAAAAgYKChI/AgIAAAAeICAsMgIiHAAAAA4JER4REREOAAAAPgIEBAgIEBAAAAAOEREOERERDgAAAA4REREPERIOAAAAAAAQAAAAABAAAAAAABAAAAAAECAAAAAAAAYYEAwCAAAAAAAAHgAeAAAAAAAAAAAYBgIMEAAAAAwSEgIEBAAEAAAAAwwLFBQVFggHAAAEDAoSHhERIQAAAB4RERIfEREeAAAABwgQEBAQCA8AAAAeERAQEBARHgAAAB8QEBAeEBAfAAAAHxAQEB4QEBAAAAAHCRAQExAJDgAAABAQEBAfEBAQAAAAEBAQEBAQEBAAAAACAgICAhISDAAAABESFBQcFBIRAAAAEBAQEBAQEB8AAAAYGBgVFRUWEgAAABkZGRUVFRMTAAAABwgQEBAQCAcAAAAeERERHhAQEAAAAAcIEBAQEAgHAAAAHhERER4TEREAAAAOERAIBwERDgAAAB8EBAQEBAQEAAAAEREREREREQ4AAAAhERESCgoMBAAAACMTExUVFAwIAAAAERIKDAwKEhEAAAAREQoKBAQEBAAAAB8BAgQECBAfAAAYEBAQEBAQEBAYAAAAAAAgICAgEBAAICAgICAgICAgIAAAAAAMFBQSAAAAAAAAAAAAAAAAAD4AAAAQAAAAAAAAAAAAAAAOEgYaEh4AAAAQEB4RERERHgAAAAAADhEQEBEOAAAAAQEPEREREQ8AAAAAAA4RHxARDgAACBAQOBAQEBAQAAAAAAAPEREREQ8RAAAQEB4ZEREREQAAABAAEBAQEBAQAAAAEAAQEBAQEBAQAAAQEBIUGBQUEgAAABAQEBAQEBAYAAAAAAAdEhISEhIAAAAAAB4ZEREREQAAAAAADhEREREOAAAAAAAeERERER4QAAAAAA8RERERDwEAAAAAHBAQEBAQAAAAAAAcEhgGEh4AAAAQEDgQEBAQGAAAAAAAERERERMPAAAAAAAiIhQUFAgAAAAAACYmFhoZCQAAAAAACCgQMCgIAAAAAAAiIhQUFAgIAAAAAB4CBAgQHgAAGBAQEBAQEBAQGAAQEBAQEBAQEBAQADAQEBAQEBAQEDAAAAAAAAAaFgAAAA=="

    private static let lazyGlyphTable: [UInt8] = {
        if let data = Data(base64Encoded: glyphBase64) {
            return [UInt8](data)
        }
        return []
    }()

    private static func glyphBytes(for ch: Character, table: [UInt8]) -> [UInt8] {
        guard let scalar = ch.unicodeScalars.first, scalar.isASCII else {
            return [0, 0, 0x1E, 0x12, 0x12, 0x12, 0x12, 0x12, 0x1E, 0, 0]
        }
        let val = Int(scalar.value)
        guard val >= 32 && val <= 126 else {
            return [0, 0, 0x1E, 0x12, 0x12, 0x12, 0x12, 0x12, 0x1E, 0, 0]
        }
        let offset = (val - 32) * 11
        guard offset + 11 <= table.count else {
            return [0, 0, 0x1E, 0x12, 0x12, 0x12, 0x12, 0x12, 0x1E, 0, 0]
        }
        return Array(table[offset..<(offset + 11)])
    }
}

open class NSTextStorage {
    public let attributedString: NSAttributedString
    public private(set) var layoutManagers: [NSLayoutManager] = []

    public init(attributedString: NSAttributedString) {
        self.attributedString = attributedString
    }

    open func addLayoutManager(_ manager: NSLayoutManager) {
        layoutManagers.append(manager)
        manager.textStorage = self
    }

    /// Attribute runs set on the text, latest last.
    private var runs: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
    open func setAttributes(_ attributes: [NSAttributedString.Key: Any]?, range: NSRange) {
        runs.append((range, attributes ?? [:]))
    }
    open func addAttribute(_ name: NSAttributedString.Key, value: Any, range: NSRange) {
        runs.append((range, [name: value]))
    }
    /// The attribute at `location`: the last run covering it that set `name` (then the whole text's attributes).
    open func attribute(_ name: NSAttributedString.Key, at location: Int, effectiveRange range: NSRangePointer?) -> Any? {
        for run in runs.reversed() where NSLocationInRange(location, run.range) || (run.range.length == 0 && location == run.range.location) {
            if let value = run.attributes[name] {
                range?.pointee = run.range
                return value
            }
        }
        guard location < attributedString.length else { return nil }
        return attributedString.attribute(name, at: location, effectiveRange: range)
    }
}

extension NSString {
    public func size(withAttributes attrs: [NSAttributedString.Key: Any]? = nil) -> CGSize {
        let font = (attrs?[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 12)
        if let real = TextBackend.layout(self as String, font: font, tracking: (attrs?[.kern] as? CGFloat) ?? 0,
                                         lineHeight: 0, maxWidth: 0) {
            return CGSize(width: real.width, height: real.height)
        }
        let w = CGFloat(length) * font.pointSize * 0.55
        let h = font.pointSize * 1.2
        return CGSize(width: w, height: h)
    }

    public func draw(at point: CGPoint, withAttributes attrs: [NSAttributedString.Key: Any]? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let font = (attrs?[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 12)
        let color = (attrs?[.foregroundColor] as? NSColor) ?? NSColor.black
        context.setFillColor(color.cgColor)
        // Delegate to NSLayoutManager glyph rasterizer
        let storage = NSTextStorage(attributedString: NSAttributedString(string: self as String, attributes: attrs ?? [:]))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.drawGlyphs(forGlyphRange: NSRange(location: 0, length: length), at: point)
    }
}

extension String {
    public func size(withAttributes attrs: [NSAttributedString.Key: Any]? = nil) -> CGSize {
        (self as NSString).size(withAttributes: attrs)
    }

    public func draw(at point: CGPoint, withAttributes attrs: [NSAttributedString.Key: Any]? = nil) {
        (self as NSString).draw(at: point, withAttributes: attrs)
    }
}

/// AppKit's font manager, as far as upstream uses it: the installed faces for its font menu (TypeControls).
public final class NSFontManager: @unchecked Sendable {
    public static let shared = NSFontManager()
    /// Every installed face by the name `NSFont(name:size:)` takes — sorted, as AppKit lists them.
    public var availableFonts: [String] { TextBackend.fontNames }
}
