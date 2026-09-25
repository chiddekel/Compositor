// The platform-agnostic tree a resolved SwiftUI view collapses into. The Qt host walks this generically (one
// interpreter for every panel) instead of Linux code hand-reimplementing each upstream panel — see
// docs/platform-abstraction.md and linux/upstream-parity.json.

/// A resolved node: a container/control kind, its parameters, and its already-resolved children. Leaf controls
/// (Text, Button, Slider, ...) carry their state in `params`/`stringParams`/`handlers`; containers (VStack, HStack,
/// ...) carry theirs the same way and additionally have `children`.
public struct RenderNode {
    /// A stable dot-path ("0.2.1") identifying this node's position in the tree — empty until `assignIDs()` runs.
    /// Not needed to resolve or unit-test the tree; only needed once a tree crosses into `RenderNodeWire` for the
    /// Qt bridge, where a later phase's action dispatch (button taps, slider drags) will look nodes up by it.
    public var id: String = ""
    public var kind: String
    public var stringParams: [String: String] = [:]
    public var doubleParams: [String: Double] = [:]
    public var boolParams: [String: Bool] = [:]
    /// Action/value-changed closures a control fires back into Swift (button taps, slider drags, text edits, ...).
    public var handlers: [String: (Any) -> Void] = [:]
    public var modifiers: [RenderModifier] = []
    public var children: [RenderNode] = []
    /// For a `"_Native"` node (an `NSViewRepresentable`): the representable itself, so an `NSHostingView` can make,
    /// update and place its real `NSView` (see `HostedLayout`).
    public var nativeSource: (any _NativeViewSource)?

    public init(kind: String) { self.kind = kind }
}

extension RenderNode {
    /// Assigns dot-path ids to this node and every descendant, in place. Call once, on the root, after resolving.
    public mutating func assignIDs(prefix: String = "0") {
        id = prefix
        for i in children.indices { children[i].assignIDs(prefix: "\(prefix).\(i)") }
    }

    /// Flattens this (already `assignIDs()`-ed) node and its descendants' `handlers` into a lookup keyed by node
    /// id, then handler key (`"action"`, `"value"`, `"isOn"`, `"text"`, ...). A resolved tree's closures only live
    /// as long as the `RenderNode` value itself; the Qt bridge keeps this registry around instead so a later
    /// button tap / slider drag can still reach the right one by id (see `Sources/LinuxBridge/SwiftUIBridge.swift`).
    public func collectHandlers(into registry: inout [String: [String: (Any) -> Void]]) {
        var h = handlers
        for m in modifiers {
            if case .sink(let key, let closure) = m {
                h[key] = closure
            }
        }
        if !h.isEmpty { registry[id] = h }
        for child in children { child.collectHandlers(into: &registry) }
    }
}

/// A style/layout annotation attached to a resolved node by a SwiftUI modifier (`.frame`, `.padding`, ...). Each
/// case mirrors one thing the Qt renderer needs to apply; unhandled cases are simply ignored by older renderers,
/// so adding a new modifier here never breaks existing panels.
public enum RenderModifier {
    case frame(width: Double?, height: Double?, minWidth: Double?, minHeight: Double?, maxWidth: Double?, maxHeight: Double?, alignment: String)
    case padding(top: Double, leading: Double, bottom: Double, trailing: Double)
    case font(String)
    case foregroundStyle(String)
    case background(String)
    /// `.border(_:width:)`: a line of this color and width just inside the view's edge.
    case border(String, Double)
    case opacity(Double)
    case disabled(Bool)
    case fixedSize(horizontal: Bool, vertical: Bool)
    case buttonStyle(String)
    case toggleStyle(String)
    case pickerStyle(String)
    case menuStyle(String)
    case controlSize(String)
    case textFieldStyle(String)
    case multilineTextAlignment(String)
    case contentShape(String)
    case clipShape(String)
    case overlay(RenderNode, alignment: String)
    case offset(x: Double, y: Double)
    case cornerRadius(Double)
    case shadow(radius: Double)
    case scaleEffect(Double)
    case rotationEffect(Double)
    case help(String)
    case accessibilityLabel(String)
    case accessibilityIdentifier(String)
    case identifier(String)
    case scrollIndicators(String)
    case keyboardShortcut(key: String, modifiers: Int)
    case tag(String)
    case onAppear(() -> Void)
    case onDisappear(() -> Void)
    case onSubmit(() -> Void)
    case onExitCommand(() -> Void)
    /// `.onChange`/`.focused` etc. read/write through a boxed value the Qt side polls or pushes into; keyed by an
    /// opaque tag so a node can carry more than one.
    case sink(String, (Any) -> Void)
    /// Share of a stack's space: higher priorities are sized first (`.layoutPriority`).
    case layoutPriority(Double)
    /// `.position(x:y:)`: the view's center in its parent's (a GeometryReader's) space.
    case position(x: Double, y: Double)
    /// A watched value (`.onChange(of:)`, `.task(id:)`); acted on by ChangeTracker, never sent to the shell.
    case observe(ChangeObserver)
}

/// `.onChange(of:)` / `.task(id:)`: a watched value and what to do when it changes between renders (see ChangeTracker).
public final class ChangeObserver {
    let value: Any
    /// Whether `value` equals a previously rendered one.
    let equals: (Any) -> Bool
    let initial: Bool
    /// `.onChange`: called with the previous value.
    let changed: ((Any) -> Void)?
    /// `.task(id:)`: started on first render and restarted (the old one cancelled) when the id changes.
    let task: (@MainActor () async -> Void)?
    init(value: Any, equals: @escaping (Any) -> Bool, initial: Bool, changed: ((Any) -> Void)?, task: (@MainActor () async -> Void)?) {
        self.value = value; self.equals = equals; self.initial = initial; self.changed = changed; self.task = task
    }
}

/// SwiftUI's observer semantics for resolved trees: each resolve of a panel compares every `.onChange` / `.task(id:)`
/// value with the one at the same place last time, fires `.onChange` actions for the ones that moved, and starts or
/// restarts `.task`s — after the walk, so actions never run mid-resolve. Places that disappear have their tasks
/// cancelled, as SwiftUI does when a view goes away.
@MainActor public enum ChangeTracker {
    private struct Entry { var value: Any; var task: Task<Void, Never>?; var disappear: (() -> Void)? = nil }
    private static var entries: [String: Entry] = [:]

    public static func process(scope: String, root: RenderNode) {
        var seen = Set<String>()
        var actions: [() -> Void] = []
        // A place is its position plus the `.id`s above it: a view given a new id is a new view, so its observers and
        // .onAppear start over.
        func visit(_ node: RenderNode, identity: String) {
            var identity = identity
            for modifier in node.modifiers { if case .identifier(let id) = modifier { identity += "#" + id } }
            let place = identity.isEmpty ? node.id : "\(node.id)\(identity)"
            for (index, modifier) in node.modifiers.enumerated() {
                // .onAppear / .onDisappear: once when the place first shows up, once when it goes away.
                if case .onAppear(let action) = modifier {
                    let key = "\(scope)|\(place)|\(index)|appear"
                    seen.insert(key)
                    if entries[key] == nil { entries[key] = Entry(value: (), task: nil); actions.append(action) }
                    continue
                }
                if case .onDisappear(let action) = modifier {
                    let key = "\(scope)|\(place)|\(index)|disappear"
                    seen.insert(key)
                    entries[key] = Entry(value: (), task: nil, disappear: action)
                    continue
                }
                guard case .observe(let observer) = modifier else { continue }
                let key = "\(scope)|\(place)|\(index)"
                seen.insert(key)
                if var entry = entries[key] {
                    guard !observer.equals(entry.value) else { continue }
                    let old = entry.value
                    entry.value = observer.value
                    if let task = observer.task {
                        entry.task?.cancel()
                        entry.task = Task { @MainActor in await task() }
                    }
                    entries[key] = entry
                    if let changed = observer.changed { actions.append { changed(old) } }
                } else {
                    var entry = Entry(value: observer.value, task: nil)
                    if let task = observer.task { entry.task = Task { @MainActor in await task() } }
                    else if observer.initial, let changed = observer.changed { actions.append { changed(observer.value) } }
                    entries[key] = entry
                }
            }
            for child in node.children { visit(child, identity: identity) }
        }
        visit(root, identity: "")
        for (key, entry) in entries where key.hasPrefix(scope + "|") && !seen.contains(key) {
            entry.task?.cancel()
            if let disappear = entry.disappear { actions.insert(disappear, at: 0) }
            entries.removeValue(forKey: key)
        }
        for action in actions { action() }
        lastActionCount = actions.count
    }

    /// How many actions (`.onChange`, `.onAppear`, ...) the last `process` ran — they may have changed state the tree
    /// was built from, so the caller resolves again.
    public private(set) static var lastActionCount = 0

    /// Cancels and forgets everything under `scope` (a panel that is closed for good).
    public static func discard(scope: String) {
        for (key, entry) in entries where key.hasPrefix(scope + "|") {
            entry.task?.cancel()
            entry.disappear?()
            entries.removeValue(forKey: key)
        }
    }
}

/// A view whose node in the render tree is produced directly (no `body` to recurse into) — SwiftUI's real
/// mechanism uses `Body == Never` for exactly this; every leaf control and every layout container in this compat
/// layer conforms here instead of composing further `View`s at resolve time.
public protocol PrimitiveView: View where Body == Never {
    /// Other views this one hosts (a container's stack content); leaves return `[]`.
    var _childViews: [any View] { get }
    /// Builds this view's node, given its children already resolved.
    func _makeNode(children: [RenderNode]) -> RenderNode
}

extension PrimitiveView {
    public var _childViews: [any View] { [] }
    public var body: Never { fatalError("\(Self.self) is a primitive view; it has no body") }
}

/// Views that stand for zero-or-more sibling views rather than one node (`TupleView`, `ForEach`, `Group`,
/// `EmptyView`, `if`/`if let` branches, arrays from `for` loops in a `@ViewBuilder`). The resolver splices these
/// into their parent's child list instead of giving them their own render node. Refines `PrimitiveView` purely to
/// inherit its default `body: Never` — `_makeNode` is never actually invoked for these (the resolver intercepts
/// `_ViewListProviding` first) so it gets a throwaway default too.
public protocol _ViewListProviding: PrimitiveView {
    var _viewList: [any View] { get }
}

extension _ViewListProviding {
    public func _makeNode(children: [RenderNode]) -> RenderNode { RenderNode(kind: "_ViewList") }
}

public enum ViewResolver {
    /// Resolves a full view (composite or primitive) into its render tree, recursing through `body` for composite
    /// (upstream) views and calling `_makeNode` once a primitive/leaf is reached.
    public static func resolve(_ view: any View) -> RenderNode {
        resolveList(view).first ?? RenderNode(kind: "_Empty")
    }

    /// The native view (`HostedNativeContent`) standing in for the first such view anywhere in `view`'s tree — what
    /// an `NSHostingView` of it would hold as a real AppKit subview (a layers table, a window bridge). Walks exactly
    /// the way `resolveList` does, stopping at the first match.
    @MainActor public static func firstNativeView(in view: any View) -> NSView? {
        if let native = view as? any HostedNativeContent { return native.makeNativeView() }
        if let list = view as? any _ViewListProviding {
            for child in list._viewList { if let found = firstNativeView(in: child) { return found } }
            return nil
        }
        if let primitive = view as? any PrimitiveView {
            for child in primitive._childViews { if let found = firstNativeView(in: child) { return found } }
            return nil
        }
        return firstNativeView(in: view.body)
    }

    /// Where in the tree the view being resolved sits: its composite views' types and child indices, plus `.id`s. A
    /// view keeps its `@State` for as long as it keeps its path (StateStore).
    nonisolated(unsafe) private static var currentPath = ""

    /// A view resolved while another's `body` is being built (an `.overlay`'s content) gets a path under that view.
    static func nestedPath(_ tag: String) -> String { currentPath + "/" + tag }

    static func resolveList(_ view: any View) -> [RenderNode] { resolveList(view, path: currentPath) }
    /// Every node a view resolves to (a list of siblings, e.g. an app's `.commands`), not just the first.
    public static func resolveAll(_ view: any View) -> [RenderNode] { resolveList(view) }

    static func resolveList(_ view: any View, path: String) -> [RenderNode] {
        if let list = view as? any _ViewListProviding {
            return list._viewList.enumerated().flatMap { resolveList($0.element, path: "\(path).\($0.offset)") }
        }
        if let reader = view as? any _GeometryReading {
            let key = "\(StateStore.currentScope ?? "")|\(path)"
            let size = GeometrySizes.sizes[key] ?? .zero
            var node = RenderNode(kind: "GeometryReader")
            node.children = resolveList(reader._content(size: size), path: path + ".0")
            node.stringParams["geometryKey"] = key
            node.doubleParams["width"] = Double(size.width)
            node.doubleParams["height"] = Double(size.height)
            // The shell reports the size it laid the reader out at: [width, height].
            node.handlers["size"] = { value in
                guard let pair = value as? [Any], pair.count == 2,
                      let w = (pair[0] as? Double) ?? (pair[0] as? Int).map(Double.init),
                      let h = (pair[1] as? Double) ?? (pair[1] as? Int).map(Double.init) else { return }
                GeometrySizes.sizes[key] = CGSize(width: w, height: h)
            }
            return [node]
        }
        if let primitive = view as? any PrimitiveView {
            let path = (primitive as? ModifiedContent)?.identity.map { "\(path)#\($0)" } ?? path
            let children = primitive._childViews.enumerated().flatMap { resolveList($0.element, path: "\(path).\($0.offset)") }
            return [primitive._makeNode(children: children)]
        }
        let path = path + "/" + String(describing: Swift.type(of: view))
        StateStore.link(view, path: path)
        let saved = currentPath
        currentPath = path
        defer { currentPath = saved }
        return resolveList(view.body, path: path)
    }
}
