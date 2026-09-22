// View modifiers. Each one wraps its content in `ModifiedContent`, a `PrimitiveView` whose `_makeNode` just tags
// the already-resolved child node with a `RenderModifier` — so adding a modifier here is a small, mechanical
// addition that every panel using it picks up automatically, with no Qt-side per-panel code.

public struct ModifiedContent<Content: View>: View, PrimitiveView {
    let content: Content
    let apply: (inout RenderNode) -> Void
    public var _childViews: [any View] { [content] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = children.first ?? RenderNode(kind: "_Empty")
        apply(&node)
        return node
    }
}

extension View {
    private func modified(_ apply: @escaping (inout RenderNode) -> Void) -> ModifiedContent<Self> {
        ModifiedContent(content: self, apply: apply)
    }

    public func frame(width: Double? = nil, height: Double? = nil, alignment: Alignment = .center) -> some View {
        modified { $0.modifiers.append(.frame(width: width, height: height, minWidth: nil, minHeight: nil, maxWidth: nil, maxHeight: nil, alignment: alignment.name)) }
    }
    public func frame(minWidth: Double? = nil, idealWidth: Double? = nil, maxWidth: Double? = nil,
                       minHeight: Double? = nil, idealHeight: Double? = nil, maxHeight: Double? = nil,
                       alignment: Alignment = .center) -> some View {
        modified { $0.modifiers.append(.frame(width: idealWidth, height: idealHeight, minWidth: minWidth, minHeight: minHeight, maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment.name)) }
    }
    public func padding(_ edges: Edge.Set = .all, _ length: Double? = nil) -> some View {
        let amount = length ?? 8
        return modified {
            $0.modifiers.append(.padding(
                top: edges.contains(.top) ? amount : 0, leading: edges.contains(.leading) ? amount : 0,
                bottom: edges.contains(.bottom) ? amount : 0, trailing: edges.contains(.trailing) ? amount : 0))
        }
    }
    public func padding(_ length: Double) -> some View { padding(.all, length) }
    public func font(_ font: Font) -> some View { modified { $0.modifiers.append(.font(font.name)) } }
    public func foregroundStyle(_ style: ShapeStyle) -> some View {
        modified { $0.modifiers.append(.foregroundStyle(style.name)) }
    }
    public func foregroundColor(_ color: Color?) -> some View {
        modified { $0.modifiers.append(.foregroundStyle(color?.name ?? "primary")) }
    }
    public func background(_ style: ShapeStyle) -> some View {
        modified { $0.modifiers.append(.background(style.name)) }
    }
    public func background<V: View>(@ViewBuilder _ content: () -> V) -> some View { self }
    public func background<V: View>(_ content: V, alignment: Alignment = .center) -> some View { self }
    public func sheet<V: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> V) -> some View { self }
    public func sheet<Item: Identifiable, V: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                    @ViewBuilder content: (Item) -> V) -> some View { self }
    public func background<S: Shape>(_ style: ShapeStyle, in shape: S) -> some View {
        modified { $0.modifiers.append(.background(style.name)) }
    }
    public func opacity(_ value: Double) -> some View { modified { $0.modifiers.append(.opacity(value)) } }
    public func disabled(_ value: Bool) -> some View { modified { $0.modifiers.append(.disabled(value)) } }
    public func fixedSize(horizontal: Bool = true, vertical: Bool = true) -> some View {
        modified { $0.modifiers.append(.fixedSize(horizontal: horizontal, vertical: vertical)) }
    }
    public func fixedSize() -> some View { fixedSize(horizontal: true, vertical: true) }
    public func buttonStyle(_ style: StyleToken) -> some View { modified { $0.modifiers.append(.buttonStyle(style.name)) } }
    public func toggleStyle(_ style: StyleToken) -> some View { modified { $0.modifiers.append(.toggleStyle(style.name)) } }
    public func controlSize(_ size: StyleToken) -> some View { modified { $0.modifiers.append(.controlSize(size.name)) } }
    public func textFieldStyle(_ style: StyleToken) -> some View { modified { $0.modifiers.append(.textFieldStyle(style.name)) } }
    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
        modified { $0.modifiers.append(.multilineTextAlignment(alignment.name)) }
    }
    public func contentShape(_ shape: StyleToken) -> some View { modified { $0.modifiers.append(.contentShape(shape.name)) } }
    public func contentShape<S: Shape>(_ shape: S) -> some View { modified { $0.modifiers.append(.contentShape("\(S.self)")) } }
    public func monospacedDigit() -> some View { modified { $0.modifiers.append(.font("monospacedDigit")) } }
    public func position(x: Double = 0, y: Double = 0) -> some View { self }
    public func coordinateSpace(name: some Hashable) -> some View { self }
    public func tint(_ color: Color?) -> some View { modified { $0.modifiers.append(.foregroundStyle(color?.name ?? "accentColor")) } }
    public func clipShape(_ shape: StyleToken) -> some View { modified { $0.modifiers.append(.clipShape(shape.name)) } }
    public func clipShape<S: Shape>(_ shape: S) -> some View { modified { $0.modifiers.append(.clipShape("\(S.self)")) } }
    public func labelsHidden() -> some View { self }
    public func cornerRadius(_ radius: Double) -> some View { modified { $0.modifiers.append(.cornerRadius(radius)) } }
    public func offset(x: Double = 0, y: Double = 0) -> some View { modified { $0.modifiers.append(.offset(x: x, y: y)) } }
    public func shadow(radius: Double = 1) -> some View { modified { $0.modifiers.append(.shadow(radius: radius)) } }
    public func shadow(color: Color = .black, radius: Double, x: Double = 0, y: Double = 0) -> some View {
        modified { $0.modifiers.append(.shadow(radius: radius)) }
    }
    public func scaleEffect(_ scale: Double) -> some View { modified { $0.modifiers.append(.scaleEffect(scale)) } }
    public func scaleEffect(x: Double = 1, y: Double = 1, anchor: UnitPoint = .center) -> some View {
        modified { $0.modifiers.append(.scaleEffect(max(x, y))) }
    }
    public func rotationEffect(_ radians: Double) -> some View { modified { $0.modifiers.append(.rotationEffect(radians)) } }
    public func rotationEffect(_ angle: Angle) -> some View { modified { $0.modifiers.append(.rotationEffect(angle.radians)) } }
    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder _ content: () -> V) -> some View {
        let overlayNode = ViewResolver.resolve(content())
        return modified { $0.modifiers.append(.overlay(overlayNode, alignment: alignment.name)) }
    }
    public func overlay<V: View>(_ overlayView: V, alignment: Alignment = .center) -> some View {
        overlay(alignment: alignment) { overlayView }
    }
    public func help(_ text: String) -> some View { modified { $0.modifiers.append(.help(text)) } }
    public func accessibilityLabel(_ text: String) -> some View { modified { $0.modifiers.append(.accessibilityLabel(text)) } }
    public func accessibilityIdentifier(_ text: String) -> some View {
        modified { $0.modifiers.append(.accessibilityIdentifier(text)) }
    }
    public func accessibilityHidden(_ hidden: Bool) -> some View { self }
    public func accessibilityValue(_ value: String) -> some View { self }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View {
        modified {
            if traits.contains(.isSelected) {
                $0.boolParams["isSelected"] = true
            }
        }
    }
    public func buttonBorderShape(_ shape: StyleToken) -> some View { self }
    public func pickerStyle(_ style: StyleToken) -> some View { self }
    public func menuStyle(_ style: StyleToken) -> some View { self }
    public func onDisappear(perform action: @escaping () -> Void = {}) -> some View { self }
    public func task(id: some Equatable, priority: TaskPriority = .userInitiated, _ action: @escaping () async -> Void) -> some View { self }
    public func task(priority: TaskPriority = .userInitiated, _ action: @escaping () async -> Void) -> some View { self }
    public func id<ID: Hashable>(_ id: ID) -> some View { modified { $0.modifiers.append(.identifier("\(id)")) } }
    public func tag<V: Hashable>(_ tag: V) -> some View { modified { $0.modifiers.append(.tag("\(tag)")) } }
    public func scrollIndicators(_ visibility: StyleToken, axes: Axis.Set = [.horizontal, .vertical]) -> some View {
        modified { $0.modifiers.append(.scrollIndicators(visibility.name)) }
    }
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        modified { $0.modifiers.append(.keyboardShortcut(key: String(key.character), modifiers: modifiers.rawValue)) }
    }
    public func onAppear(perform action: @escaping () -> Void = {}) -> some View {
        modified { $0.modifiers.append(.onAppear(action)) }
    }
    public func onSubmit(_ action: @escaping () -> Void) -> some View { modified { $0.modifiers.append(.onSubmit(action)) } }
    public func onExitCommand(perform action: @escaping () -> Void) -> some View {
        modified { $0.modifiers.append(.onExitCommand(action)) }
    }
    public func focused(_ condition: FocusState<Bool>) -> some View {
        modified { $0.modifiers.append(.sink("focused", { newValue in
            if let bool = newValue as? Bool { condition.wrappedValue = bool }
        })) }
    }
    /// `.focused($field, equals: .someCase)` — sets `field` to `value` while this view holds focus, `nil` otherwise.
    public func focused<Value: Hashable>(_ binding: FocusState<Value?>, equals value: Value) -> some View {
        modified { $0.modifiers.append(.sink("focused", { newValue in
            if let isFocused = newValue as? Bool { binding.wrappedValue = isFocused ? value : nil }
        })) }
    }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        modified { $0.modifiers.append(.sink("onChange", { newValue in
            if let typed = newValue as? V { action(value, typed) }
        })) }
    }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        modified { $0.modifiers.append(.sink("onChange", { _ in action() })) }
    }
    public func gesture<G>(_ gesture: G) -> some View { self }
    public func animation<V: Equatable>(_ animation: StyleToken?, value: V) -> some View { self }
    public func aspectRatio(_ aspectRatio: Double? = nil, contentMode: ContentMode) -> some View { self }
    public func aspectRatio(contentMode: ContentMode) -> some View { self }
    public func popover<V: View>(isPresented: Binding<Bool>, @ViewBuilder content: () -> V) -> some View { self }
    public func clipped() -> some View { self }
    public func scrollBounceBehavior(_ behavior: ScrollBounceBehavior, axes: Axis.Set = [.vertical]) -> some View { self }


    /// Applies a custom `ViewModifier` (the mechanism `Compositor/UI`'s own modifiers — e.g. `NewProjectDropTarget`
    /// — use). Delegates to the modifier's own `body`, so it composes normally instead of needing a `RenderModifier`
    /// case of its own.
    public func modifier<M: ViewModifier>(_ modifier: M) -> some View {
        _CustomModified(content: self, modifier: modifier)
    }
}

public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = _ViewModifierContent
    @ViewBuilder func body(content: Content) -> Body
}

public struct _ViewModifierContent: View, _ViewListProviding {
    let view: any View
    public var _viewList: [any View] { [view] }
}

struct _CustomModified<Content: View, M: ViewModifier>: View {
    let content: Content
    let modifier: M
    var body: some View { modifier.body(content: _ViewModifierContent(view: content)) }
}

extension View {
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View { self }
}

public enum AccessibilityChildBehavior: Sendable {
    case ignore, contain, combine
}

public struct ScrollGeometry: Sendable {
    public var contentOffset: CGPoint
    public var contentSize: CGSize
    public init(contentOffset: CGPoint = .zero, contentSize: CGSize = .zero) {
        self.contentOffset = contentOffset
        self.contentSize = contentSize
    }
}

public struct DropProposal {
    public enum Operation { case cancel, move, copy, forbidden }
    public var operation: Operation
    public init(operation: Operation) { self.operation = operation }
}

public protocol DropDelegate {
    func validateDrop(info: DropInfo) -> Bool
    func dropEntered(info: DropInfo)
    func dropUpdated(info: DropInfo) -> DropProposal?
    func dropExited(info: DropInfo)
    func performDrop(info: DropInfo) -> Bool
}

public extension DropDelegate {
    func validateDrop(info: DropInfo) -> Bool { true }
    func dropEntered(info: DropInfo) {}
    func dropUpdated(info: DropInfo) -> DropProposal? { nil }
    func dropExited(info: DropInfo) {}
}

public struct DropInfo {
    public let location: CGPoint
    public init(location: CGPoint = .zero) { self.location = location }
    public func hasItemsConforming(to types: [String]) -> Bool { false }
    public func itemProviders(for types: [String]) -> [NSItemProvider] { [] }
}

extension View {
    public func onReceive<P: Publisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some View { self }
    public func mask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View { self }
    public func onScrollGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (ScrollGeometry) -> T, action: @escaping (T, T) -> Void) -> some View { self }
    public func onDrop(of supportedTypes: [String], isTargeted: Binding<Bool>? = nil, perform action: @escaping ([NSItemProvider]) -> Bool) -> some View { self }
    public func onDrop(of supportedTypes: [String], delegate: DropDelegate) -> some View { self }
}


