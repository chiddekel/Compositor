import Foundation
import CoreGraphics

// AppKit drag and drop, headless. A source starts a session (`beginDraggingSession`) whose pasteboard holds its items;
// the host carries the drag (Qt draws it) and asks a destination to validate and accept it through `NSDraggingInfo`.
// `NSDraggingSession.current` is the session in flight, and `CompatDraggingInfo` is the info a host (or a test) hands
// a destination.

public struct NSDragOperation: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let copy = NSDragOperation(rawValue: 1), link = NSDragOperation(rawValue: 2)
    public static let generic = NSDragOperation(rawValue: 4), `private` = NSDragOperation(rawValue: 8)
    public static let move = NSDragOperation(rawValue: 16), delete = NSDragOperation(rawValue: 32)
    public static let every = NSDragOperation(rawValue: .max)
}

public enum NSDraggingContext: Int, Sendable { case outsideApplication = 0, withinApplication = 1 }

/// Something a pasteboard can hold: a `NSPasteboardItem` here.
public protocol NSPasteboardWriting: AnyObject {}

/// One item of a drag's (or the clipboard's) contents, by type.
public final class NSPasteboardItem: NSPasteboardWriting, @unchecked Sendable {
    private var values: [NSPasteboard.PasteboardType: Data] = [:]
    private var order: [NSPasteboard.PasteboardType] = []
    public init() {}
    public var types: [NSPasteboard.PasteboardType] { order }
    @discardableResult public func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        if values[type] == nil { order.append(type) }
        values[type] = data
        return true
    }
    @discardableResult public func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        setData(Data(string.utf8), forType: type)
    }
    public func data(forType type: NSPasteboard.PasteboardType) -> Data? { values[type] }
    public func string(forType type: NSPasteboard.PasteboardType) -> String? { values[type].map { String(decoding: $0, as: UTF8.self) } }
    public func availableType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        types.first { values[$0] != nil }
    }
}

extension NSPasteboard {
    /// The items written with `writeObjects`, as AppKit lists them; a drag's pasteboard has one per dragged item.
    public var pasteboardItems: [NSPasteboardItem]? { draggedObjects }
    @discardableResult public func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        let items = objects.compactMap { $0 as? NSPasteboardItem }
        if draggedObjects == nil { draggedObjects = [] }
        draggedObjects?.append(contentsOf: items)
        // The first item's values also answer the pasteboard-wide accessors, as on the Mac.
        if let first = items.first {
            for type in first.types { if let data = first.data(forType: type) { setData(data, forType: type) } }
        }
        return !items.isEmpty
    }
}

@MainActor public final class NSDraggingItem {
    public let item: NSPasteboardWriting
    public var draggingFrame: CGRect = .zero
    public private(set) var imageComponentsContents: Any?
    public init(pasteboardWriter: NSPasteboardWriting) { item = pasteboardWriter }
    public func setDraggingFrame(_ frame: CGRect, contents: Any?) { draggingFrame = frame; imageComponentsContents = contents }
}

@MainActor public protocol NSDraggingSource: AnyObject {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint)
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation)
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool
}
extension NSDraggingSource {
    public func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {}
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {}
    public func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
}

@MainActor public final class NSDraggingSession {
    public enum Formation: Int, Sendable { case `default`, none, pile, list, stack }
    public let draggingPasteboard: NSPasteboard
    public let items: [NSDraggingItem]
    public weak var source: NSDraggingSource?
    public var draggingLocation: NSPoint
    public var animatesToStartingPositionsOnCancelOrFail = true
    public var draggingFormation: Formation = .default
    public var draggingLeaderIndex = 0
    /// The drag in flight, from `beginDraggingSession` until the host ends it.
    public internal(set) static var current: NSDraggingSession?
    /// Installed by the host: carries a new drag (Qt's drag loop). Without one, the drag stays `current` for a caller
    /// to complete.
    public static var beginHandler: ((NSDraggingSession) -> Void)?

    init(items: [NSDraggingItem], source: NSDraggingSource, location: NSPoint) {
        draggingPasteboard = NSPasteboard.withUniqueName()
        draggingPasteboard.writeObjects(items.map(\.item))
        self.items = items
        self.source = source
        draggingLocation = location
    }

    /// The operations the source allows within the app (AppKit asks it per context).
    public var sourceOperationMask: NSDragOperation {
        source?.draggingSession(self, sourceOperationMaskFor: .withinApplication) ?? []
    }

    /// Ends the drag, telling the source how it ended.
    public func end(at point: NSPoint, operation: NSDragOperation) {
        source?.draggingSession(self, endedAt: point, operation: operation)
        if Self.current === self { Self.current = nil }
    }
}

extension NSView {
    @discardableResult
    public func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: NSDraggingSource) -> NSDraggingSession {
        let session = NSDraggingSession(items: items, source: source, location: event.locationInWindow)
        NSDraggingSession.current = session
        source.draggingSession(session, willBeginAt: event.locationInWindow)
        NSDraggingSession.beginHandler?(session)
        return session
    }
}

/// What a drop destination is told about a drag.
@MainActor public protocol NSDraggingInfo: AnyObject {
    var draggingSource: Any? { get }
    var draggingLocation: NSPoint { get }
    var draggingPasteboard: NSPasteboard { get }
    var draggingSourceOperationMask: NSDragOperation { get }
    var draggingDestinationWindow: NSWindow? { get }
    var numberOfValidItemsForDrop: Int { get set }
}

/// A drag as a destination sees it: from a session in flight, or built by a host for a drag Qt carried in.
@MainActor public final class CompatDraggingInfo: NSDraggingInfo {
    public let draggingSource: Any?
    public var draggingLocation: NSPoint
    public let draggingPasteboard: NSPasteboard
    public var draggingSourceOperationMask: NSDragOperation
    public weak var draggingDestinationWindow: NSWindow?
    public var numberOfValidItemsForDrop = 1
    public init(source: Any?, location: NSPoint, pasteboard: NSPasteboard, operationMask: NSDragOperation, window: NSWindow?) {
        draggingSource = source
        draggingLocation = location
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = operationMask
        draggingDestinationWindow = window
    }
    public convenience init(session: NSDraggingSession, location: NSPoint, window: NSWindow?) {
        self.init(source: session.source, location: location, pasteboard: session.draggingPasteboard,
                  operationMask: session.sourceOperationMask, window: window)
    }
}
