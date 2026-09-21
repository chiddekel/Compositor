// SwiftUI compat: upstream's model code imports SwiftUI only for a few value-level conveniences (and, on Apple
// platforms, for the Observation re-export). The views themselves are the Qt shell's job.

@_exported import Foundation
@_exported import CoreGraphics
@_exported import Observation
import AppKit

/// The view protocol; upstream's SwiftUI views are not compiled on Linux, but the sheet stand-ins conform to it.
public protocol View {}

/// A SwiftUI view whose real content is a native NSView (e.g. a layers panel that wraps an NSTableView).
@MainActor public protocol HostedNativeContent { func makeNativeView() -> NSView? }

/// Hosts a view tree as an NSView (the Qt shell renders the real UI).
@MainActor public final class NSHostingView<Root: View>: NSView {
    public var rootView: Root
    public init(rootView: Root) {
        self.rootView = rootView
        super.init(frame: .zero)
        // A root view that stands in for native content (a list, a table) puts that view in the hosted tree.
        if let content = (rootView as? any HostedNativeContent)?.makeNativeView() { addSubview(content) }
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// Carries a root view for `NSWindow.beginSheet`; the Qt shell (or a headless resolver) decides what to show.
@MainActor public final class NSHostingController<Root: View>: NSViewController {
    public var rootView: Root { didSet { representedRootView = rootView } }
    public init(rootView: Root) { self.rootView = rootView; super.init(); representedRootView = rootView }
}

extension MutableCollection where Self: RangeReplaceableCollection {
    /// SwiftUI's `move(fromOffsets:toOffset:)` used by list reordering (`onMove`): moves the elements at `source`
    /// so that they end up before the element originally at `destination` (or at the end).
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[index(startIndex, offsetBy: $0)] }
        var remaining: [Element] = []
        var insertAt = 0
        for (offset, element) in self.enumerated() {
            if offset == destination { insertAt = remaining.count }
            if !source.contains(offset) { remaining.append(element) }
        }
        if destination >= count { insertAt = remaining.count }
        remaining.insert(contentsOf: moving, at: insertAt)
        self = Self(remaining)
    }
}

public struct EventModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let capsLock = EventModifiers(rawValue: 1 << 0), shift = EventModifiers(rawValue: 1 << 1)
    public static let control = EventModifiers(rawValue: 1 << 2), option = EventModifiers(rawValue: 1 << 3)
    public static let command = EventModifiers(rawValue: 1 << 4), numericPad = EventModifiers(rawValue: 1 << 5)
    public static let function = EventModifiers(rawValue: 1 << 6)
    public static let all: EventModifiers = [.capsLock, .shift, .control, .option, .command, .numericPad, .function]
}

/// The bridge protocol between SwiftUI and AppKit views. The Qt shell owns the real view tree; this exists so upstream's
/// wrapper structs compile and so tests can instantiate the underlying `NSView` through `makeNSView`.
@MainActor public protocol NSViewRepresentable: View {
    associatedtype NSViewType: NSView
    associatedtype Coordinator = Void
    typealias Context = NSViewRepresentableContext<Self>
    func makeNSView(context: Context) -> NSViewType
    func updateNSView(_ nsView: NSViewType, context: Context)
    func makeCoordinator() -> Coordinator
    static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator)
}
public struct NSViewRepresentableContext<Representable: NSViewRepresentable> {
    public var coordinator: Representable.Coordinator
    public init(coordinator: Representable.Coordinator) { self.coordinator = coordinator }
}
extension NSViewRepresentable where Coordinator == Void {
    public func makeCoordinator() -> Void { () }
}
extension NSViewRepresentable {
    public static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator) {}
}
