// SwiftUI compat: upstream's model code imports SwiftUI only for a few value-level conveniences (and, on Apple
// platforms, for the Observation re-export). The views themselves are the Qt shell's job.

@_exported import Foundation
@_exported import CoreGraphics
@_exported import Observation
@_exported import Combine
@_exported import FoundationCompat
// Real macOS SwiftUI transitively exposes AppKit types (`NSColor`, ...) to any file that only `import SwiftUI` —
// several upstream panels rely on exactly this and never `import AppKit` themselves.
@_exported import AppKit

// `View` itself, `@ViewBuilder`, and the render-tree resolver now live in ViewBuilder.swift/RenderTree.swift —
// `Compositor/UI/*.swift` compiles and resolves through them instead of being excluded from the Linux build.

/// A SwiftUI view whose real content is a native NSView (e.g. a layers panel that wraps an NSTableView).
@MainActor public protocol HostedNativeContent { func makeNativeView() -> NSView? }

/// Hosts a view tree as an NSView (the Qt shell renders the real UI).
@MainActor public final class NSHostingView<Root: View>: NSView {
    public var rootView: Root { didSet { layoutHostedViews() } }
    public init(rootView: Root) {
        self.rootView = rootView
        super.init(frame: .zero)
        // A view that stands in for native content (a list, a table) — the root or anywhere below it — puts that view
        // in the hosted tree, as real SwiftUI does for an `NSViewRepresentable` inside the hosted hierarchy.
        if let content = ViewResolver.firstNativeView(in: rootView) { addSubview(content) }
        layoutHostedViews()
    }
    public override var frame: CGRect { didSet { if frame.size != oldValue.size { layoutHostedViews() } } }
    /// Real SwiftUI re-lays out whenever state changes; compat `@State` doesn't notify, so an explicit layout request
    /// always re-resolves (cheap for the small trees that host native views).
    public override func layoutSubtreeIfNeeded() {
        layoutHostedViews()
        super.layoutSubtreeIfNeeded()
    }
    public override func layout() { layoutHostedViews() }

    /// The `NSViewRepresentable`s in the tree, by tree position: made once, then re-framed and updated every layout.
    private var hosted: [String: (type: ObjectIdentifier, view: NSView, state: AnyObject)] = [:]

    private func layoutHostedViews() {
        var root = ViewResolver.resolve(rootView)
        guard Self.containsNative(root) || !hosted.isEmpty else { return }
        root.assignIDs()
        let placements = HostedLayout.place(root, in: CGRect(origin: .zero, size: bounds.size))
        var live = Set<String>()
        for placement in placements {
            live.insert(placement.path)
            var entry = hosted[placement.path]
            if entry?.type != placement.source._nativeTypeID {
                entry?.view.removeFromSuperview()
                let made = placement.source._makeNativeView()
                entry = (placement.source._nativeTypeID, made.view, made.state)
                addSubview(made.view)
                hosted[placement.path] = entry
            }
            guard let entry else { continue }
            // Layout is top-left based; this view is not flipped, so y counts up from the bottom edge.
            let rect = placement.frame
            entry.view.frame = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
            placement.source._updateNativeView(entry.view, state: entry.state)
        }
        for (path, entry) in hosted where !live.contains(path) {
            entry.view.removeFromSuperview()
            hosted.removeValue(forKey: path)
        }
    }
    private static func containsNative(_ node: RenderNode) -> Bool {
        node.nativeSource != nil || node.children.contains(where: containsNative)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    /// The size the hosted view would take up. No real layout engine runs the resolved tree yet, so this is a
    /// fixed placeholder rather than a measured value — enough for callers that only need *a* nonzero size.
    public var fittingSize: CGSize { CGSize(width: 320, height: 240) }
    /// Real SwiftUI's `NSHostingSizingOptions` — controls whether AppKit measures the hosted view's intrinsic
    /// size. No real layout engine runs here, so this is inert; it exists so `host.sizingOptions = []` compiles.
    public var sizingOptions: NSHostingSizingOptions = .standardBounds
}

public struct NSHostingSizingOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let standardBounds = NSHostingSizingOptions(rawValue: 1 << 0)
    public static let minSize = NSHostingSizingOptions(rawValue: 1 << 1)
    public static let maxSize = NSHostingSizingOptions(rawValue: 1 << 2)
    public static let intrinsicContentSize = NSHostingSizingOptions(rawValue: 1 << 3)
}

/// Erases any `View` to a single concrete type, the same way real SwiftUI's `AnyView` does — needed wherever
/// upstream code stores a heterogeneous view (e.g. a floating panel's content).
public struct AnyView: View, PrimitiveView {
    let base: any View
    public init(_ view: some View) { base = view }
    public var _childViews: [any View] { [base] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        if children.count == 1 {
            return children[0]
        }
        var node = RenderNode(kind: "_ViewList")
        node.children = children
        return node
    }
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

/// The bridge protocol between SwiftUI and AppKit views. This is the sanctioned escape hatch for the handful of
/// upstream views wrapping a real native control (an NSPopUpButton-backed picker, a table-backed list, ...) that
/// the "generic compat" approach explicitly doesn't try to reinterpret — the Qt renderer sees a `"_Native"` node
/// and slots in `makeNSView`'s real widget directly. Refines `PrimitiveView` so it plugs into the render tree like
/// every other view, but its content is opaque to the resolver.
@MainActor public protocol NSViewRepresentable: PrimitiveView, _NativeViewSource {
    associatedtype NSViewType: NSView
    associatedtype Coordinator = Void
    typealias Context = NSViewRepresentableContext<Self>
    func makeNSView(context: Context) -> NSViewType
    func updateNSView(_ nsView: NSViewType, context: Context)
    func makeCoordinator() -> Coordinator
    static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator)
}
extension NSViewRepresentable {
    /// The Qt bridge (a later phase) recognises `"_Native"` and calls `makeNSView`/`updateNSView` itself, rather
    /// than interpreting this node generically.
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "_Native")
        node.nativeSource = self
        return node
    }
}

/// Type-erased make/update for an `NSViewRepresentable`, so `HostedLayout` can drive any representable's lifecycle
/// (coordinator once, `makeNSView` once, `updateNSView` on every layout) without knowing its concrete type.
@MainActor public protocol _NativeViewSource {
    /// Stable per representable type: a hosted view is reused only for the same type at the same tree position.
    var _nativeTypeID: ObjectIdentifier { get }
    func _makeNativeView() -> (view: NSView, state: AnyObject)
    func _updateNativeView(_ view: NSView, state: AnyObject)
}
final class _CoordinatorBox<Value> { let value: Value; init(_ value: Value) { self.value = value } }
extension NSViewRepresentable {
    public var _nativeTypeID: ObjectIdentifier { ObjectIdentifier(Self.self) }
    public func _makeNativeView() -> (view: NSView, state: AnyObject) {
        let coordinator = makeCoordinator()
        return (makeNSView(context: Context(coordinator: coordinator)), _CoordinatorBox(coordinator))
    }
    public func _updateNativeView(_ view: NSView, state: AnyObject) {
        guard let view = view as? NSViewType, let box = state as? _CoordinatorBox<Coordinator> else { return }
        updateNSView(view, context: Context(coordinator: box.value))
    }
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
