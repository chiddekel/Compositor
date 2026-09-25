import Foundation
import CompatSupport
import UniformTypeIdentifiers

/// General pasteboard. In-process store with Apple's change-count semantics; the host can mirror it to the desktop
/// clipboard through `backend` (see `IClipboardService`).
public final class NSPasteboard: @unchecked Sendable {
    public struct Name: Hashable, RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let general = Name(rawValue: "general")
        public static let drag = Name(rawValue: "drag")
    }

    public struct PasteboardType: Hashable, RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let png = PasteboardType(rawValue: "public.png")
        public static let tiff = PasteboardType(rawValue: "public.tiff")
        public static let string = PasteboardType(rawValue: "public.utf8-plain-text")
        public static let fileURL = PasteboardType(rawValue: "public.file-url")
    }
    public struct ReadingOptionKey: Hashable, RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public protocol Backend: AnyObject {
        func write(_ items: [PasteboardType: Data])
        func read() -> [PasteboardType: Data]
        /// One type's data (a desktop clipboard converts on demand instead of producing every type).
        func data(forType type: PasteboardType) -> Data?
        /// The types the clipboard holds now.
        func availableTypes() -> [PasteboardType]
        /// How many times something other than this app changed the clipboard (AppKit's changeCount counts those too).
        var externalChangeCount: Int { get }
    }

    public static let backendSlot = ServiceSlot<Backend>()
    public static var backend: Backend? {
        get { backendSlot.installedValue }
        set { backendSlot.install(newValue) }
    }
    /// Runs `body` with `backend` as the clipboard the general pasteboard mirrors, then restores the previous one.
    public static func withBackend<Result>(_ backend: Backend?, _ body: () throws -> Result) rethrows -> Result {
        try backendSlot.withOverride(backend, body)
    }
    public static let general = NSPasteboard(isGeneral: true)
    public static let drag = NSPasteboard()

    /// Only the general pasteboard mirrors the desktop clipboard; the drag pasteboard stays in process.
    private let isGeneral: Bool
    private init(isGeneral: Bool) { self.isGeneral = isGeneral }
    public init(name: Name = .general) { isGeneral = false }
    private var mirror: Backend? { isGeneral ? Self.backend : nil }
    public static func withName(_ name: Name) -> NSPasteboard {
        name == .drag ? drag : general
    }

    private var items: [PasteboardType: Data] = [:]
    private var localChangeCount = 0
    /// AppKit's: it moves whenever anyone — this app or another — changes the clipboard.
    public var changeCount: Int { localChangeCount + (mirror?.externalChangeCount ?? 0) }
    /// The external count when this app last wrote: while it holds, the clipboard is still ours.
    private var externalAtWrite = 0

    @discardableResult public func clearContents() -> Int {
        items = [:]
        localChangeCount += 1
        externalAtWrite = mirror?.externalChangeCount ?? 0
        return changeCount
    }
    @discardableResult public func setData(_ data: Data?, forType type: PasteboardType) -> Bool {
        guard let data else { return false }
        items[type] = data
        mirror?.write(items)
        externalAtWrite = mirror?.externalChangeCount ?? 0
        return true
    }
    /// Another app wrote the desktop clipboard since this app last did: what it holds is theirs.
    private var ownedByOthers: Bool { mirror.map { $0.externalChangeCount != externalAtWrite } ?? false }
    public func data(forType type: PasteboardType) -> Data? {
        guard let mirror else { return items[type] }
        if !ownedByOthers, let own = items[type] { return own }
        return mirror.data(forType: type)
    }
    public var types: [PasteboardType]? {
        guard let mirror, ownedByOthers else { return Array(items.keys) }
        return mirror.availableTypes()
    }
    public func canReadObject(forClasses classes: [AnyClass], options: [ReadingOptionKey: Any]?) -> Bool {
        let held = Set(types ?? [])
        if classes.contains(where: { $0 is NSImage.Type }) { return held.contains(.png) || held.contains(.tiff) }
        return !held.isEmpty
    }
    public func string(forType type: PasteboardType) -> String? {
        guard let d = data(forType: type) else { return nil }
        return String(data: d, encoding: .utf8)
    }
    @discardableResult public func setString(_ string: String, forType type: PasteboardType) -> Bool {
        setData(string.data(using: .utf8), forType: type)
    }
    public func availableType(from types: [PasteboardType]) -> PasteboardType? {
        for t in types {
            if data(forType: t) != nil { return t }
        }
        return nil
    }
}

extension NSPasteboard.Backend {
    public func data(forType type: NSPasteboard.PasteboardType) -> Data? { read()[type] }
    public func availableTypes() -> [NSPasteboard.PasteboardType] { Array(read().keys) }
    public var externalChangeCount: Int { 0 }
}
