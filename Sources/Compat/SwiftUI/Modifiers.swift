import Foundation
// View modifiers. Each one wraps its content in `ModifiedContent`, a `PrimitiveView` whose `_makeNode` just tags
// the already-resolved child node with a `RenderModifier` — so adding a modifier here is a small, mechanical
// addition that every panel using it picks up automatically, with no Qt-side per-panel code.

import Combine
import UniformTypeIdentifiers

private final class GeometryChangeTracker<Value: Equatable> {
    private var previous: Value?

    func update(_ value: Value, action: (Value) -> Void) {
        guard previous != value else { return }
        previous = value
        action(value)
    }
}

private func resolvedSheetContent<V: View>(_ content: V) -> RenderNode {
    var node = RenderNode(kind: "VStack")
    node.children = ViewResolver.resolveList(content, path: ViewResolver.nestedPath("sheet"))
    return node
}

/// Deliberately NOT generic over its content (real SwiftUI's `ModifiedContent<Content, Modifier>` is, but pays for
/// it with compiler-privileged fast paths this compat layer doesn't have). A generic `ModifiedContent<Content>`
/// nests one new type layer per modifier in a chain — `ModifiedContent<ModifiedContent<ModifiedContent<...>>>` for
/// a 15-modifier chain — which is exactly what makes Swift's constraint solver time out on long real-world modifier
/// chains (confirmed: `Compositor/ContentView.swift`'s `editorChrome`, ~15 modifiers deep, timed out on the generic
/// version and compiles instantly with this one). Erasing `content` to `any View` makes every `modified(_:)` call
/// return the *same* concrete type, so chain length no longer grows the type the solver has to explore.
public struct ModifiedContent: View, PrimitiveView {
    let content: any View
    let apply: (inout RenderNode) -> Void
    /// `.id(_:)`: part of the content's identity, so a new id is a new view (fresh `@State`, `.onAppear` again).
    var identity: String? = nil
    public var _childViews: [any View] { [content] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = children.first ?? RenderNode(kind: "_Empty")
        apply(&node)
        return node
    }
}

extension View {
    func modified(_ apply: @escaping (inout RenderNode) -> Void) -> ModifiedContent {
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
    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder _ content: () -> V) -> some View {
        let backgroundNode = ViewResolver.resolveList(content(), path: ViewResolver.nestedPath("background")).first ?? RenderNode(kind: "_Empty")
        return modified { base in
            var wrapper = RenderNode(kind: "Background")
            wrapper.stringParams["alignment"] = alignment.name
            wrapper.children = [base, backgroundNode]
            base = wrapper
        }
    }
    public func background<V: View>(_ content: V, alignment: Alignment = .center) -> some View {
        background(alignment: alignment) { content }
    }
    public func sheet<V: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> V) -> some View {
        let presentedContent = isPresented.wrappedValue ? resolvedSheetContent(content()) : nil
        return modified { base in
            var sheet = RenderNode(kind: "Sheet")
            sheet.boolParams["isPresented"] = isPresented.wrappedValue
            sheet.children = [base]
            if let presentedContent { sheet.children.append(presentedContent) }
            sheet.handlers["dismiss"] = { _ in
                isPresented.wrappedValue = false
                onDismiss?()
            }
            base = sheet
        }
    }
    public func sheet<Item: Identifiable, V: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                    @ViewBuilder content: (Item) -> V) -> some View {
        let presentedContent = item.wrappedValue.map { resolvedSheetContent(content($0)) }
        return modified { base in
            var sheet = RenderNode(kind: "Sheet")
            sheet.boolParams["isPresented"] = item.wrappedValue != nil
            sheet.children = [base]
            if let presentedContent { sheet.children.append(presentedContent) }
            sheet.handlers["dismiss"] = { _ in
                item.wrappedValue = nil
                onDismiss?()
            }
            base = sheet
        }
    }
    public func background<S: Shape>(_ style: ShapeStyle, in shape: S) -> some View {
        // The fill takes the shape's corners (a capsule or circle rounds by half its height; the renderer caps it).
        let radius = shape.shapeKind == "capsule" || shape.shapeKind == "circle" ? 1000 : shape.cornerRadiusValue
        return modified {
            if radius > 0 { $0.modifiers.append(.cornerRadius(radius)) }
            $0.modifiers.append(.background(style.name))
        }
    }
    public func opacity(_ value: Double) -> some View { modified { $0.modifiers.append(.opacity(value)) } }
    public func border(_ style: ShapeStyle, width: Double = 1) -> some View { modified { $0.modifiers.append(.border(style.name, width)) } }
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
    public func position(x: Double = 0, y: Double = 0) -> some View { modified { $0.modifiers.append(.position(x: x, y: y)) } }
    public func position(_ point: CGPoint) -> some View { position(x: point.x, y: point.y) }
    public func coordinateSpace(name: some Hashable) -> some View {
        modified { $0.modifiers.append(.coordinateSpace("\(name)")) }
    }
    public func tint(_ color: Color?) -> some View { modified { $0.modifiers.append(.foregroundStyle(color?.name ?? "accentColor")) } }
    public func clipShape(_ shape: StyleToken) -> some View { modified { $0.modifiers.append(.clipShape(shape.name)) } }
    public func clipShape<S: Shape>(_ shape: S) -> some View { modified { $0.modifiers.append(.clipShape("\(S.self)")) } }
    public func labelsHidden() -> some View { modified { $0.boolParams["labelsHidden"] = true } }
    public func cornerRadius(_ radius: Double) -> some View { modified { $0.modifiers.append(.cornerRadius(radius)) } }
    public func offset(x: Double = 0, y: Double = 0) -> some View { modified { $0.modifiers.append(.offset(x: x, y: y)) } }
    public func shadow(radius: Double = 1) -> some View { modified { $0.modifiers.append(.shadow(radius: radius)) } }
    public func shadow(color: Color = .black, radius: Double, x: Double = 0, y: Double = 0) -> some View {
        modified { $0.modifiers.append(.shadow(radius: radius)) }
    }
    public func scaleEffect(_ scale: Double) -> some View { modified { $0.modifiers.append(.scaleEffect(scale)) } }
    public func scaleEffect(x: Double = 1, y: Double = 1, anchor: UnitPoint = .center) -> some View {
        modified {
            // A negative scale mirrors (a HueArrow pointing the other way); the renderer flips shapes for it.
            if x < 0 { $0.boolParams["mirrorX"] = true }
            if y < 0 { $0.boolParams["mirrorY"] = true }
            $0.modifiers.append(.scaleEffect(max(abs(x), abs(y))))
        }
    }
    public func rotationEffect(_ radians: Double) -> some View { modified { $0.modifiers.append(.rotationEffect(radians)) } }
    public func rotationEffect(_ angle: Angle) -> some View { modified { $0.modifiers.append(.rotationEffect(angle.radians)) } }
    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder _ content: () -> V) -> some View {
        let overlayNode = ViewResolver.resolveList(content(), path: ViewResolver.nestedPath("overlay")).first ?? RenderNode(kind: "_Empty")
        // An "Overlay" node: the view, then what lies over it (sized to the view, at `alignment`).
        return modified { base in
            var wrapper = RenderNode(kind: "Overlay")
            wrapper.stringParams["alignment"] = alignment.name
            wrapper.children = [base, overlayNode]
            base = wrapper
        }
    }
    public func overlay<V: View>(_ overlayView: V, alignment: Alignment = .center) -> some View {
        overlay(alignment: alignment) { overlayView }
    }
    public func help(_ text: String) -> some View { modified { $0.modifiers.append(.help(text)) } }
    public func accessibilityLabel(_ text: String) -> some View { modified { $0.modifiers.append(.accessibilityLabel(text)) } }
    public func accessibilityIdentifier(_ text: String) -> some View {
        modified { $0.modifiers.append(.accessibilityIdentifier(text)) }
    }
    public func accessibilityHidden(_ hidden: Bool) -> some View {
        modified { $0.modifiers.append(.accessibilityHidden(hidden)) }
    }
    public func lineLimit(_ number: Int?) -> some View {
        modified { node in
            node.modifiers.removeAll { if case .lineLimit = $0 { return true }; return false }
            if let number { node.modifiers.append(.lineLimit(number)) }
        }
    }
    public func accessibilityValue(_ value: String) -> some View {
        modified { $0.modifiers.append(.accessibilityValue(value)) }
    }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View {
        modified {
            if traits.contains(.isSelected) {
                $0.boolParams["isSelected"] = true
            }
        }
    }
    public func buttonBorderShape(_ shape: StyleToken) -> some View {
        modified { $0.modifiers.append(.buttonBorderShape(shape.name)) }
    }
    public func pickerStyle(_ style: StyleToken) -> some View { modified { $0.modifiers.append(.pickerStyle(style.name)) } }
    public func menuStyle(_ style: StyleToken) -> some View { modified { $0.modifiers.append(.menuStyle(style.name)) } }
    public func onDisappear(perform action: @escaping () -> Void = {}) -> some View {
        modified { $0.modifiers.append(.onDisappear(action)) }
    }
    public func task<ID: Equatable>(id: ID, priority: TaskPriority = .userInitiated, _ action: @escaping () async -> Void) -> some View {
        nonisolated(unsafe) let work = action
        return modified { $0.modifiers.append(.observe(ChangeObserver(value: id, equals: { ($0 as? ID) == id }, initial: true,
                                                                     changed: nil, task: { await work() }))) }
    }
    public func id<ID: Hashable>(_ id: ID) -> some View {
        ModifiedContent(content: self, apply: { $0.modifiers.append(.identifier("\(id)")) }, identity: "\(id)")
    }
    public func tag<V: Hashable>(_ tag: V) -> some View {
        let str: String
        if let raw = (tag as? any RawRepresentable)?.rawValue {
            str = "\(raw)"
        } else {
            str = "\(tag)"
        }
        return modified { $0.modifiers.append(.tag(str)) }
    }
    public func scrollIndicators(_ visibility: StyleToken, axes: Axis.Set = [.horizontal, .vertical]) -> some View {
        modified { $0.modifiers.append(.scrollIndicators(visibility.name)) }
    }
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        let modifiers = key.isAction ? [] : modifiers
        return modified { $0.modifiers.append(.keyboardShortcut(key: String(key.character), modifiers: modifiers.rawValue)) }
    }
    public func onAppear(perform action: @escaping () -> Void = {}) -> some View {
        modified { $0.modifiers.append(.onAppear(action)) }
    }
    public func onSubmit(_ action: @escaping () -> Void) -> some View { modified { $0.modifiers.append(.onSubmit(action)) } }
    public func onExitCommand(perform action: @escaping () -> Void) -> some View {
        modified { $0.modifiers.append(.onExitCommand(action)) }
    }
    /// Compat-only (the Mac does this with an NSMenuDelegate's `willHighlight`, e.g. BlendModePicker): while this
    /// Picker's menu is open, `highlight` gets the tag of the item under the pointer; when it closes, `nil`.
    public func compatPickerHighlight(_ highlight: @escaping (String?) -> Void) -> some View {
        modified {
            $0.modifiers.append(.sink("pickerHighlight", { value in highlight(value as? String) }))
        }
    }
    /// Compat-only (the Mac does this with an NSButton tracking its own drag, e.g. NativeLayerList's EyeSwipeButton):
    /// pressing this view runs `began`; dragging over other views in the same `group` runs their `entered`; letting go
    /// runs the pressed view's `ended`.
    public func compatSwipe(group: String, began: @escaping () -> Void, entered: @escaping () -> Void,
                            ended: @escaping () -> Void) -> some View {
        modified {
            $0.stringParams["swipeGroup"] = group
            $0.modifiers.append(.sink("swipeBegan", { _ in began() }))
            $0.modifiers.append(.sink("swipeEntered", { _ in entered() }))
            $0.modifiers.append(.sink("swipeEnded", { _ in ended() }))
        }
    }
    /// Compat-only (no SwiftUI counterpart — AppKit's NSTableView drag-and-drop stands in for it on the Mac): lets the
    /// Qt shell drag this List's rows. `folders` marks the rows a drop can land *into*; `perform` gets the dragged row,
    /// the row under the drop, where in that row it landed (0 top ... 1 bottom) and whether Option/Alt copies.
    public func compatListDrop(folders: [Bool], layerIdentifiers: [String] = [],
                               perform action: @escaping (_ source: Int, _ row: Int, _ fraction: Double, _ copying: Bool) -> Void) -> some View {
        modified {
            $0.stringParams["listFolders"] = folders.map { $0 ? "1" : "0" }.joined()
            $0.stringParams["listLayerIdentifiers"] = layerIdentifiers.joined(separator: ",")
            $0.modifiers.append(.sink("listDrop", { value in
                // JSON numbers arrive as Int / Double / Bool on Linux (NSNumber on the Mac): read either.
                func number(_ v: Any) -> Double? {
                    if let d = v as? Double { return d }
                    if let i = v as? Int { return Double(i) }
                    if let b = v as? Bool { return b ? 1 : 0 }
                    return (v as? NSNumber)?.doubleValue
                }
                guard let values = value as? [Any], values.count == 4, let source = number(values[0]), let row = number(values[1]),
                      let fraction = number(values[2]), let copying = number(values[3]) else { return }
                action(Int(source), Int(row), fraction, copying != 0)
            }))
        }
    }
    public func compatListMaskDrop(dragIdentifiers: [String], dropTargetIdentifiers: [String],
                                   perform action: @escaping (_ source: String, _ target: String) -> Void) -> some View {
        modified {
            $0.stringParams["listMaskDragIdentifiers"] = dragIdentifiers.joined(separator: ",")
            $0.stringParams["listMaskDropIdentifiers"] = dropTargetIdentifiers.joined(separator: ",")
            $0.modifiers.append(.sink("listMaskDrop", { value in
                guard let values = value as? [Any], values.count == 2,
                      let source = values[0] as? String, let target = values[1] as? String else { return }
                action(source, target)
            }))
        }
    }
    /// Compat-only (AppKit's `keyDown(with:)` on a recording control stands in for it on the Mac): while this view is
    /// shown, the Qt shell hands it the next key pressed — `key` in ShortcutChord's form ("a", "\r", "\u{f702}", …, or ""
    /// for Esc, meaning cancel) and `modifiers` as Command 1 / Option 2 / Control 4 / Shift 8 (Ctrl, Alt, Meta, Shift).
    public func compatKeyCapture(perform action: @escaping (_ key: String, _ modifiers: Int) -> Void) -> some View {
        modified {
            $0.modifiers.append(.sink("keyCapture", { value in
                guard let values = value as? [Any], values.count == 2, let key = values[0] as? String else { return }
                let modifiers = (values[1] as? Int) ?? Int((values[1] as? Double) ?? 0)
                action(key, modifiers)
            }))
        }
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
        modified {
            $0.modifiers.append(.sink("onChange", { newValue in
                if let typed = newValue as? V { action(value, typed) }
            }))
            // Also fires when the value differs from the previous render, as in SwiftUI (ChangeTracker).
            $0.modifiers.append(.observe(ChangeObserver(value: value, equals: { ($0 as? V) == value }, initial: initial,
                                                        changed: { old in action((old as? V) ?? value, value) }, task: nil)))
        }
    }
    /// `@_disfavoredOverload`: real, load-bearing fix, not decoration. Having both this and the 2-arg overload
    /// above visible as equally-good candidates is what made Swift's constraint solver time out on
    /// `Compositor/ContentView.swift`'s `body` (11 chained `.onChange` calls, all 2-arg) — confirmed by removing
    /// this overload entirely, which made the exact same "unable to type-check in reasonable time" error vanish
    /// (25s build vs. 2+ minutes at a 1000x-raised solver threshold that still failed). `@_disfavoredOverload`
    /// tells the solver to only consider this one after every other candidate fails, so the 11 two-argument call
    /// sites resolve immediately without it in the running, while `TransformInspector.swift`'s three genuine
    /// zero-argument calls still resolve correctly (just as the last candidate tried, not the first).
    @_disfavoredOverload
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        modified {
            $0.modifiers.append(.sink("onChange", { _ in action() }))
            $0.modifiers.append(.observe(ChangeObserver(value: value, equals: { ($0 as? V) == value }, initial: initial,
                                                        changed: { _ in action() }, task: nil)))
        }
    }
    public func gesture<G>(_ gesture: G) -> some View { self }
    /// A drag: the shell reports the pointer as [x, y, translationX, translationY] in the enclosing GeometryReader's
    /// space, while it moves ("dragChanged") and when it lets go ("dragEnded").
    public func gesture(_ gesture: DragGesture) -> some View {
        func value(_ any: Any) -> DragGesture.Value? {
            guard let list = any as? [Any], list.count == 4 else { return nil }
            let n = list.map { ($0 as? Double) ?? ($0 as? Int).map(Double.init) ?? 0 }
            return DragGesture.Value(location: CGPoint(x: n[0], y: n[1]), translation: CGSize(width: n[2], height: n[3]))
        }
        return modified { node in
            let space = gesture.coordinateSpace.name ?? "local"
            node.modifiers.append(.dragGesture(minimumDistance: gesture.minimumDistance, coordinateSpace: space))
            if let changed = gesture.onChangedAction { node.modifiers.append(.sink("dragChanged", { if let v = value($0) { changed(v) } })) }
            if let ended = gesture.onEndedAction { node.modifiers.append(.sink("dragEnded", { if let v = value($0) { ended(v) } })) }
        }
    }
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> some View {
        modified {
            $0.modifiers.append(.tapGesture(count: max(1, count)))
            $0.modifiers.append(.sink("onTapGesture", { value in
                // The shell sends the click's modifier keys; they are current while the action runs (CompatInput).
                CompatInput.clickModifiers = (value as? Int) ?? Int((value as? Double) ?? 0)
                action()
                CompatInput.clickModifiers = 0
            }))
        }
    }
    public func onReceive<P: CombinePublisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some View {
        guard let timer = publisher as? Timer.TimerPublisher else { return modified { _ in } }
        return modified {
            $0.modifiers.append(.sink("onReceive", { _ in
                if let output = Date() as? P.Output { action(output) }
            }))
            $0.modifiers.append(.timer(interval: timer.interval))
        }
    }
    public func mask<V: View>(alignment: Alignment = .center, @ViewBuilder _ mask: () -> V) -> some View {
        let maskNode = ViewResolver.resolveList(mask(), path: ViewResolver.nestedPath("mask")).first ?? RenderNode(kind: "_Empty")
        return modified { base in
            var wrapper = RenderNode(kind: "Mask")
            wrapper.stringParams["alignment"] = alignment.name
            wrapper.children = [base, maskNode]
            base = wrapper
        }
    }
    public func onScrollGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (ScrollGeometry) -> T,
                                                      action: @escaping (T, T) -> Void) -> some View { self }
    public func onDrop(of types: [String], delegate: any DropDelegate) -> some View {
        modified {
            $0.stringParams["dropTypes"] = types.joined(separator: ",")
            $0.modifiers.append(.resultSink("dropEvent", { value in
                guard let (phase, info) = compatibilityDropEvent(value) else { return 0 }
                switch phase {
                case "entered":
                    guard delegate.validateDrop(info: info) else { return 0 }
                    delegate.dropEntered(info: info)
                    return 1
                case "updated":
                    if let operation = delegate.dropUpdated(info: info)?.operation {
                        switch operation {
                        case .cancel, .forbidden: return 0
                        case .move, .copy: return 1
                        }
                    }
                    return 1
                case "exited":
                    delegate.dropExited(info: info)
                    return 1
                case "perform": return delegate.performDrop(info: info) ? 1 : 0
                default: return 0
                }
            }))
        }
    }
    public func onDrop(of types: [String], isTargeted: Binding<Bool>? = nil,
                       perform action: @escaping ([NSItemProvider], CGPoint) -> Bool) -> some View {
        modified {
            $0.stringParams["dropTypes"] = types.joined(separator: ",")
            $0.modifiers.append(.resultSink("dropEvent", { value in
                guard let (phase, info) = compatibilityDropEvent(value) else { return 0 }
                switch phase {
                case "entered":
                    isTargeted?.wrappedValue = true
                    return 1
                case "updated": return 1
                case "exited":
                    isTargeted?.wrappedValue = false
                    return 1
                case "perform":
                    isTargeted?.wrappedValue = false
                    return action(info.itemProviders(for: types), info.location) ? 1 : 0
                default: return 0
                }
            }))
        }
    }
    public func animation<V: Equatable>(_ animation: StyleToken?, value: V) -> some View { self }
    public func aspectRatio(_ aspectRatio: Double? = nil, contentMode: ContentMode) -> some View { self }
    public func aspectRatio(contentMode: ContentMode) -> some View { self }
    public func popover<V: View>(isPresented: Binding<Bool>, @ViewBuilder content: () -> V) -> some View {
        let popoverNode = ViewResolver.resolveList(content(), path: ViewResolver.nestedPath("popover")).first
            ?? RenderNode(kind: "_Empty")
        return modified { base in
            var wrapper = RenderNode(kind: "Popover")
            wrapper.boolParams["isPresented"] = isPresented.wrappedValue
            wrapper.children = [base, popoverNode]
            wrapper.handlers["dismiss"] = { _ in isPresented.wrappedValue = false }
            base = wrapper
        }
    }
    /// Right/control-click menu — inert, same honesty as `.onReceive`: the Qt renderer doesn't wire up a
    /// context-menu gesture yet, so `content`'s actions are never reachable this way.
    /// A right-click menu, as SwiftUI shows one: the items (Buttons, Dividers, nested Menus) are resolved here into a
    /// menu description the Qt shell turns into a QMenu ("contextMenu": JSON items with titles, enabled state and
    /// submenus); picking one sends back its index, which runs that Button's action.
    public func contextMenu<M: View>(@ViewBuilder menuItems: () -> M) -> some View {
        var actions: [() -> Void] = []
        func title(_ node: RenderNode) -> String {
            if node.kind == "Text" { return node.stringParams["text"] ?? "" }
            for child in node.children { let t = title(child); if !t.isEmpty { return t } }
            return ""
        }
        func disabled(_ node: RenderNode) -> Bool {
            node.modifiers.contains { if case .disabled(true) = $0 { return true }; return false }
        }
        func items(_ nodes: [RenderNode], inheritedDisabled: Bool) -> [[String: Any]] {
            var result: [[String: Any]] = []
            for node in nodes {
                let off = inheritedDisabled || disabled(node)
                switch node.kind {
                case "Button":
                    if let action = node.handlers["action"] {
                        result.append(["title": title(node), "enabled": !off, "index": actions.count])
                        actions.append({ action(()) })
                    }
                case "Divider": result.append(["separator": true])
                case "Menu":
                    // First child: the label; the rest: the submenu's items.
                    let label = node.children.first.map(title) ?? ""
                    result.append(["title": label, "enabled": !off,
                                   "items": items(Array(node.children.dropFirst()), inheritedDisabled: off)])
                default: result += items(node.children, inheritedDisabled: off)
                }
            }
            return result
        }
        let described = items(ViewResolver.resolveList(menuItems()), inheritedDisabled: false)
        let json = (try? JSONSerialization.data(withJSONObject: described)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return modified {
            $0.stringParams["contextMenu"] = json
            $0.modifiers.append(.sink("contextMenu", { value in
                let index = (value as? Int) ?? Int((value as? Double) ?? -1)
                if actions.indices.contains(index) { actions[index]() }
            }))
        }
    }
    public func simultaneousGesture<G>(_ gesture: G) -> some View { self }
    public func simultaneousGesture(_ gesture: SpatialTapGesture) -> some View {
        modified { node in
            node.modifiers.append(.spatialTapGesture(count: max(1, gesture.count)))
            if let ended = gesture.onEndedAction {
                node.modifiers.append(.sink("spatialTapGesture", { value in
                    guard let coordinates = value as? [Any], coordinates.count == 2 else { return }
                    let numbers = coordinates.map { ($0 as? Double) ?? ($0 as? Int).map(Double.init) ?? 0 }
                    var tap = SpatialTapGesture.Value()
                    tap.location = CGPoint(x: numbers[0], y: numbers[1])
                    ended(tap)
                }))
            }
        }
    }
    public func clipped() -> some View { modified { $0.modifiers.append(.clipped) } }
    /// Share of an `HStack`/`VStack`'s space: children with a higher priority are sized first (used by `HostedLayout`).
    public func layoutPriority(_ value: Double) -> some View { modified { $0.modifiers.append(.layoutPriority(value)) } }
    public func scrollBounceBehavior(_ behavior: ScrollBounceBehavior, axes: Axis.Set = [.vertical]) -> some View { self }
    public func allowsHitTesting(_ enabled: Bool) -> some View {
        modified { $0.modifiers.append(.allowsHitTesting(enabled)) }
    }
    public func preferredColorScheme(_ colorScheme: ColorScheme?) -> some View { self }
    public func navigationTitle(_ title: String) -> some View { self }
    public func sharedBackgroundVisibility(_ visibility: StyleToken) -> some View { self }
    public func pointerStyle(_ style: PointerStyle) -> some View {
        modified { $0.modifiers.append(.pointerStyle(style.name)) }
    }
    /// The general form (`GeometryProxy`), distinct from `.onScrollGeometryChange` above.
    public func onGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T,
                                                action: @escaping (T) -> Void) -> some View {
        let tracker = GeometryChangeTracker<T>()
        return modified {
            $0.modifiers.append(.sink("geometryChange", { value in
                guard let payload = value as? [String: Any],
                      let size = payload["size"] as? [NSNumber], size.count == 2 else { return }
                let frames = (payload["frames"] as? [String: [NSNumber]] ?? [:]).compactMapValues { frame -> CGRect? in
                    guard frame.count == 4 else { return nil }
                    return CGRect(x: frame[0].doubleValue, y: frame[1].doubleValue,
                                  width: frame[2].doubleValue, height: frame[3].doubleValue)
                }
                let proxy = GeometryProxy(size: CGSize(width: size[0].doubleValue, height: size[1].doubleValue),
                                          namedFrames: frames)
                tracker.update(transform(proxy), action: action)
            }))
        }
    }
    public func toolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View { self }
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool = false,
                              onCompletion: @escaping (Result<[URL], any Error>) -> Void) -> some View { self }
    public func alert<A: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A) -> some View {
        alert(title, isPresented: isPresented, actions: actions) { Text("") }
    }
    public func alert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A,
                                         @ViewBuilder message: () -> M) -> some View {
        let actionNodes = ViewResolver.resolveList(actions(), path: ViewResolver.nestedPath("alertActions"))
        let messageNode = ViewResolver.resolveList(message(), path: ViewResolver.nestedPath("alertMessage")).first
        func firstText(_ node: RenderNode) -> String {
            if node.kind == "Text", let text = node.stringParams["text"] { return text }
            for child in node.children {
                let text = firstText(child)
                if !text.isEmpty { return text }
            }
            return ""
        }
        var actions: [(String, String?, (Any) -> Void)] = []
        func collectButtons(_ nodes: [RenderNode]) {
            for node in nodes {
                if node.kind == "Button", let action = node.handlers["action"] {
                    actions.append((firstText(node), node.stringParams["role"], action))
                } else {
                    collectButtons(node.children)
                }
            }
        }
        collectButtons(actionNodes)
        let describedActions = actions.enumerated().map { index, action -> [String: Any] in
            var description: [String: Any] = ["index": index, "title": action.0]
            if let role = action.1 { description["role"] = role }
            return description
        }
        let actionData = (try? JSONSerialization.data(withJSONObject: describedActions, options: [.sortedKeys])) ?? Data("[]".utf8)
        let actionJSON = String(data: actionData, encoding: .utf8) ?? "[]"
        return modified { base in
            var wrapper = RenderNode(kind: "Alert")
            wrapper.stringParams["title"] = title
            wrapper.stringParams["message"] = messageNode.map(firstText) ?? ""
            wrapper.stringParams["actions"] = actionJSON
            wrapper.boolParams["isPresented"] = isPresented.wrappedValue
            wrapper.children = [base]
            for (index, action) in actions.enumerated() {
                wrapper.handlers["alertAction\(index)"] = { value in action.2(value) }
            }
            wrapper.handlers["dismiss"] = { _ in isPresented.wrappedValue = false }
            base = wrapper
        }
    }


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
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View {
        let behavior: String
        switch children {
        case .ignore: behavior = "ignore"
        case .contain: behavior = "contain"
        case .combine: behavior = "combine"
        }
        return modified { $0.modifiers.append(.accessibilityElement(behavior)) }
    }
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
    private let providers: [NSItemProvider]
    public init(location: CGPoint = .zero, itemProviders: [NSItemProvider] = []) {
        self.location = location
        providers = itemProviders
    }
    public func hasItemsConforming(to types: [String]) -> Bool {
        providers.contains { provider in types.contains { provider.hasItemConformingToTypeIdentifier($0) } }
    }
    public func itemProviders(for types: [String]) -> [NSItemProvider] {
        providers.filter { provider in types.contains { provider.hasItemConformingToTypeIdentifier($0) } }
    }
}

private func compatibilityDropEvent(_ value: Any) -> (String, DropInfo)? {
    guard let event = value as? [String: Any], let phase = event["phase"] as? String else { return nil }
    let location = event["location"] as? [String: Any] ?? [:]
    let x = (location["x"] as? NSNumber)?.doubleValue ?? 0
    let y = (location["y"] as? NSNumber)?.doubleValue ?? 0
    let providers = (event["items"] as? [[String: Any]] ?? []).flatMap { item -> [NSItemProvider] in
        var representations: [String: Data] = [:]
        for representation in item["representations"] as? [[String: String]] ?? [] {
            guard let type = representation["type"], let encoded = representation["data"],
                  let data = Data(base64Encoded: encoded) else { continue }
            representations[type] = data
        }
        // ProjectWorkspace.layerType (upstream's layer-row drag type; the app module isn't visible from here).
        let layerType = "com.compositor.layer-row"
        if let data = representations[layerType],
           let text = String(data: data, encoding: .utf8) {
            let identifiers = text.split(whereSeparator: { $0.isNewline }).map(String.init)
            if identifiers.count > 1, identifiers.allSatisfy({ UUID(uuidString: $0) != nil }) {
                return identifiers.map { NSItemProvider(representations: [layerType: Data($0.utf8)]) }
            }
        }
        return [NSItemProvider(representations: representations)]
    }
    return (phase, DropInfo(location: CGPoint(x: CGFloat(x), y: CGFloat(y)), itemProviders: providers))
}

/// `.toolbar { }`'s content: the Qt renderer doesn't host a native toolbar yet (the panels this unblocks —
/// `ContentView.swift`'s New/zoom/tab-strip controls — render fine as ordinary tree nodes; only their placement
/// in a system toolbar bar is inert), so these resolve their content like `Group` and carry no placement of their
/// own. Structurally real, matching the rest of this file's honesty about what's live vs. what only type-checks.
public struct ToolbarItemPlacement: Sendable, Equatable {
    let name: String
    public init(_ name: String) { self.name = name }
    public static let navigation = ToolbarItemPlacement("navigation")
    public static let primaryAction = ToolbarItemPlacement("primaryAction")
    public static let automatic = ToolbarItemPlacement("automatic")
}

public struct ToolbarItem<Content: View>: View, _ViewListProviding {
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) { self.content = content() }
    public var _viewList: [any View] { [content] }
}

public struct ToolbarItemGroup<Content: View>: View, _ViewListProviding {
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) { self.content = content() }
    public var _viewList: [any View] { [content] }
}

public struct ToolbarSpacer: View, PrimitiveView {
    public enum Sizing { case fixed, flexible }
    public init(_ sizing: Sizing = .flexible, placement: ToolbarItemPlacement = .automatic) {}
    public func _makeNode(children: [RenderNode]) -> RenderNode { RenderNode(kind: "Spacer") }
}

public enum ColorScheme: Sendable { case light, dark }

public struct PointerStyle: Sendable {
    fileprivate let name: String
    private init(_ name: String) { self.name = name }
    public static let columnResize = PointerStyle("columnResize")
    public static let horizontalResize = PointerStyle("horizontalResize")
    public static let verticalResize = PointerStyle("verticalResize")
}



/// Compat-only: the modifier keys of the click being handled (a tap's action runs while it is set), as bits Command 1 /
/// Option 2 / Control 4 / Shift 8 — Linux's Ctrl / Alt / Meta / Shift. What AppKit code reads from `NSEvent.modifierFlags`.
public enum CompatInput {
    nonisolated(unsafe) public static var clickModifiers: Int = 0
}
