import Foundation
import CoreGraphics

// The Type tool's text stack uses Qt for attributed measurement and drawing,
// with an approximate fallback when the native text engine is unavailable.

open class NSFont: @unchecked Sendable {
    public struct Weight: RawRepresentable, Hashable, Sendable {
        public let rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public static let ultraLight = Weight(rawValue: -0.8), thin = Weight(rawValue: -0.6), light = Weight(rawValue: -0.4)
        public static let regular = Weight(rawValue: 0), medium = Weight(rawValue: 0.23), semibold = Weight(rawValue: 0.3)
        public static let bold = Weight(rawValue: 0.4), heavy = Weight(rawValue: 0.56), black = Weight(rawValue: 0.62)
    }
    public let fontName: String
    public var familyName: String? {
        if let family = InstalledFonts.familyName(fontName) { return family }
        if let family = TextBackend.familyName(fontName) { return family }
        // Qt's catalog names each non-regular face Family-Style; preserve families containing hyphens by matching
        // the longest installed family prefix before treating the final component as the style.
        let families = NSFontManager.shared.availableFonts.filter { candidate in
            fontName.hasPrefix(candidate + "-")
        }
        return families.max(by: { $0.count < $1.count }) ?? fontName.split(separator: "-").first.map(String.init)
    }
    public let pointSize: CGFloat
    /// Traits of the system font factories, retained for native text and SwiftUI lowering.
    public let _systemWeightName: String?
    public let _isMonospaced: Bool
    public let _usesMonospacedDigits: Bool
    var _backendName: String { fontName + (_usesMonospacedDigits ? "+monospacedDigit" : "") }
    /// Nil when no installed font answers to `name`, as in AppKit (a document naming a font this machine lacks).
    public init?(name: String, size: CGFloat) {
        guard !name.isEmpty, InstalledFonts.contains(name) else { return nil }
        fontName = name; pointSize = size
        _systemWeightName = nil; _isMonospaced = false; _usesMonospacedDigits = false
    }
    private init(system size: CGFloat, weight: Weight = .regular, monospaced: Bool = false, digits: Bool = false) {
        let weights: [(Weight, String)] = [(.ultraLight, "ultraLight"), (.thin, "thin"), (.light, "light"),
            (.regular, "regular"), (.medium, "medium"), (.semibold, "semibold"), (.bold, "bold"),
            (.heavy, "heavy"), (.black, "black")]
        let token = weight.rawValue.isFinite
            ? weights.min { abs($0.0.rawValue - weight.rawValue) < abs($1.0.rawValue - weight.rawValue) }!.1 : "regular"
        let family = monospaced ? "Monospace" : "System"
        fontName = family + (token == "regular" ? "" : "-" + token)
        pointSize = size
        _systemWeightName = token; _isMonospaced = monospaced; _usesMonospacedDigits = digits
    }
    /// The desktop's fixed-pitch face, retaining the requested weight.
    public static func monospacedSystemFont(ofSize size: CGFloat, weight: Weight) -> NSFont {
        NSFont(system: size, weight: weight, monospaced: true)
    }
    /// AppKit's vertical metrics: from the installed face through the Qt text engine; without it, typical proportions
    /// (0.8 em above the baseline, 0.2 below).
    public var ascender: CGFloat { TextBackend.metrics(self)?.ascender ?? pointSize * 0.8 }
    public var descender: CGFloat { TextBackend.metrics(self)?.descender ?? -pointSize * 0.2 }
    public var leading: CGFloat { TextBackend.metrics(self)?.leading ?? 0 }
    /// The size of the system font in controls.
    public static var systemFontSize: CGFloat { 13 }
    public static var smallSystemFontSize: CGFloat { 11 }
    /// The letters the face draws itself (Latin, Greek and Cyrillic, which font menus test names against), from the
    /// Qt text engine; without it, every one of them.
    public var coveredCharacterSet: CharacterSet {
        let scalars = (0x20...0x24F).compactMap(Unicode.Scalar.init) + (0x370...0x4FF).compactMap(Unicode.Scalar.init)
        guard let covered = TextBackend.covered(self, scalars) else {
            var all = CharacterSet(); scalars.forEach { all.insert($0) }; return all
        }
        var set = CharacterSet()
        for (scalar, yes) in zip(scalars, covered) where yes { set.insert(scalar) }
        return set
    }
    public static func systemFont(ofSize size: CGFloat) -> NSFont { NSFont(system: size) }
    public static func systemFont(ofSize size: CGFloat, weight: Weight) -> NSFont { NSFont(system: size, weight: weight) }
    public static func monospacedDigitSystemFont(ofSize size: CGFloat, weight: Weight = .regular) -> NSFont { NSFont(system: size, weight: weight, digits: true) }
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
    /// AppKit's NSStringDrawing on attributed text: the size of one unwrapped line set.
    public func size() -> CGSize { boundingRect(with: CGSize(width: 1e6, height: 1e6)).size }

    /// Draws the text with its own attributes, its first line's top-left at `point` (as `NSString.draw(at:)`).
    @MainActor public func draw(at point: CGPoint) {
        guard NSGraphicsContext.current?.cgContext != nil else { return }
        if length > 0, let color = attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            NSGraphicsContext.current?.cgContext.setFillColor(color.cgColor)
        }
        let storage = NSTextStorage(attributedString: self)
        let layout = NSLayoutManager()
        layout.addTextContainer(NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)))
        storage.addLayoutManager(layout)
        layout.drawGlyphs(forGlyphRange: NSRange(location: 0, length: length), at: point)
    }

    /// Measures the same attributed text used by the native glyph renderer.
    public func boundingRect(with size: CGSize, options: NSStringDrawingOptions = []) -> CGRect {
        let attrs = length > 0 ? attributes(at: 0, effectiveRange: nil) : [:]
        if let real = TextBackend.layout(self, maxWidth: size.width >= 1e5 ? 0 : size.width) {
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
    public weak var layoutManager: NSLayoutManager?
    public init(size: CGSize) { self.size = size }
    /// Puts `manager` in the current one's place, with the same text (AppKit's way to swap in a subclass).
    open func replaceLayoutManager(_ manager: NSLayoutManager) {
        let old = layoutManager
        old?.textStorage?.addLayoutManager(manager)
        manager.addTextContainer(self)
        layoutManager = manager
        replacedManagers.append(manager)
    }
    /// The container keeps the managers it was given alive (AppKit's text storage owns them).
    private var replacedManagers: [NSLayoutManager] = []
}

/// `@preconcurrency`: AppKit leaves text layout usable off the main thread (upstream builds PSD text layout there),
/// while a main-actor subclass (upstream's SeeThroughSelectionLayout) must match its isolation.
@preconcurrency @MainActor open class NSLayoutManager {
    /// Fills a selection's background rects; the host's text editor draws selections through its own painter, so the
    /// default only fills in the current graphics context (a subclass adjusts the color first, as upstream's does).
    open func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int, forCharacterRange charRange: NSRange,
                                      color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for index in 0..<rectCount { context.fill(rectArray[index]) }
    }
    nonisolated(unsafe) public weak var textStorage: NSTextStorage?
    nonisolated(unsafe) public private(set) var textContainers: [NSTextContainer] = []

    public init() {}

    nonisolated open func addTextContainer(_ container: NSTextContainer) {
        textContainers.append(container)
    }

    nonisolated open func glyphRange(for container: NSTextContainer) -> NSRange {
        NSRange(location: 0, length: textStorage?.attributedString.length ?? 0)
    }

    nonisolated open var numberOfGlyphs: Int {
        textStorage?.attributedString.length ?? 0
    }

    nonisolated open func ensureLayout(for container: NSTextContainer) {}

    /// The line a glyph sits on and its origin in that line, laid out exactly as `drawGlyphs` draws: fixed advances
    /// (0.55 em plus tracking), lines `minimumLineHeight` or 1.2 em apart, wrapping at the container's width, each
    /// glyph drawn in an em-tall box from the line's top — so its baseline is about 0.8 em down.
    nonisolated private func placement(ofGlyphAt index: Int) -> (line: Int, x: CGFloat, lineHeight: CGFloat, pointSize: CGFloat, width: CGFloat) {
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

    nonisolated open func lineFragmentRect(forGlyphAt glyphIndex: Int, effectiveRange: UnsafeMutablePointer<NSRange>?) -> CGRect {
        let p = placement(ofGlyphAt: glyphIndex)
        effectiveRange?.pointee = NSRange(location: 0, length: numberOfGlyphs)
        return CGRect(x: 0, y: CGFloat(p.line) * p.lineHeight, width: p.width == .greatestFiniteMagnitude ? 0 : p.width, height: p.lineHeight)
    }

    /// The glyph's origin (baseline) relative to its line fragment.
    nonisolated open func location(forGlyphAt glyphIndex: Int) -> CGPoint {
        let p = placement(ofGlyphAt: glyphIndex)
        let attrString = textStorage?.attributedString ?? NSAttributedString(string: "")
        if let real = TextBackend.layout(attrString, maxWidth: 0) {
            return CGPoint(x: p.x, y: real.baseline)
        }
        return CGPoint(x: p.x, y: p.pointSize * 0.8)
    }

    nonisolated open func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
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
        if let image = TextBackend.render(attrString, maxWidth: wrapWidth, alignment: alignment, boxWidth: wrapWidth) {
            let rect = CGRect(x: origin.x, y: origin.y, width: CGFloat(image.width), height: CGFloat(image.height))
            context.saveGState()
            // CGContext draws an image with its first row at the rect's max y; in this y-down space that is upside
            // down, so flip about the rect to put the first row at the top.
            if NSGraphicsContext.current?.isFlipped == true {
                context.translateBy(x: 0, y: rect.minY + rect.maxY)
                context.scaleBy(x: 1, y: -1)
            }
            context.draw(image, in: rect)
            context.restoreGState()
            return
        }

        var runs: [(NSRange, NSColor)] = []
        attrString.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attrString.length)) { value, range, _ in
            if let runColor = value as? NSColor, runColor != color { runs.append((range, runColor)) }
        }
        context.setFillColor(color.cgColor)

        let charAdvance = pointSize * 0.55 + tracking
        let scaleX = (pointSize * 0.55) / 6.0
        let scaleY = pointSize / 11.0

        var currentX = origin.x
        var currentY = origin.y

        let glyphTable = Self.lazyGlyphTable
        // Each letter in its own color when the text has color runs (UTF-16 offsets, as NSAttributedString's).
        var utf16Offset = 0
        var shownColor = color

        for ch in fullString {
            defer { utf16Offset += ch.utf16.count }
            if !runs.isEmpty {
                let letterColor = runs.first { NSLocationInRange(utf16Offset, $0.0) }?.1 ?? color
                if letterColor != shownColor { shownColor = letterColor; context.setFillColor(letterColor.cgColor) }
            }
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

    nonisolated private static func glyphBytes(for ch: Character, table: [UInt8]) -> [UInt8] {
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

    @MainActor public func draw(at point: CGPoint, withAttributes attrs: [NSAttributedString.Key: Any]? = nil) {
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

    @MainActor public func draw(at point: CGPoint, withAttributes attrs: [NSAttributedString.Key: Any]? = nil) {
        (self as NSString).draw(at: point, withAttributes: attrs)
    }
}

/// AppKit's font manager, as far as upstream uses it: the installed faces for its font menu (TypeControls).
public final class NSFontManager: @unchecked Sendable {
    public static let shared = NSFontManager()
    /// Every installed face by the name `NSFont(name:size:)` takes — sorted, as AppKit lists them.
    public var availableFonts: [String] {
        let postScript = InstalledFonts.postScriptNames
        return postScript.isEmpty ? TextBackend.fontNames : postScript
    }
    public func availableMembers(ofFontFamily family: String) -> [[Any]]? {
        let key = family.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let aliases: [String: [String]] = [
            "helvetica": ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique"],
            "courier": ["Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"],
            "times": ["Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic"]
        ]
        let resolved = InstalledFonts.contains(family) ? TextBackend.familyName(family) : nil
        let resolvedKey = resolved?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let installed = InstalledFonts.members(ofFamily: family)
        let faces = aliases[key] ?? (!installed.isEmpty ? installed : availableFonts.filter {
            let name = $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return name == key || name.hasPrefix(key + "-")
                || resolvedKey.map { name == $0 || name.hasPrefix($0 + "-") } == true
        })
        guard !faces.isEmpty else { return nil }
        return faces.sorted().map { [$0, $0, 5, 0] }
    }
}
