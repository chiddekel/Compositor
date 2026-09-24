// The leaf controls. Each is a thin value type carrying exactly what real SwiftUI's initializer takes; the Qt
// renderer turns each into one widget (QLabel, QPushButton, QSlider, ...) — see the architecture plan for the
// kind→widget mapping.

public struct Text: View, PrimitiveView, ExpressibleByStringInterpolation {
    let content: String
    public init(_ content: String) { self.content = content }
    public init(stringLiteral value: String) { content = value }
    public init(verbatim content: String) { self.content = content }
    public init<V: BinaryFloatingPoint>(_ value: V, format: FloatingPointFormatStyle<V>) {
        let pct = Double(value) * 100.0
        let str = String(format: "%.1f%%", pct).replacingOccurrences(of: ".0%", with: "%")
        self.init(str)
    }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Text")
        node.stringParams["text"] = content
        return node
    }
}

public struct FloatingPointFormatStyle<Value: BinaryFloatingPoint>: Sendable {
    public static var percent: FloatingPointFormatStyle<Value> { FloatingPointFormatStyle() }
    public func precision(_ p: Precision) -> FloatingPointFormatStyle<Value> { self }
    public struct Precision: Sendable {
        public static func fractionLength(_ range: ClosedRange<Int>) -> Precision { Precision() }
    }
}


public struct Label<Title: View, Icon: View>: View, PrimitiveView {
    let title: Title, icon: Icon
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) { self.title = title(); self.icon = icon() }
    public var _childViews: [any View] { [title, icon] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Label")
        node.children = children
        return node
    }
}
extension Label where Title == Text, Icon == Image {
    public init(_ title: String, systemImage: String) {
        self.init(title: { Text(title) }, icon: { Image(systemName: systemImage) })
    }
}

/// Bitmaps a resolved tree shows (`Image(nsImage:)`, `Image(decorative:scale:)`), handed to the shell by token: the tree
/// carries `pixels:<token>`, the shell fetches the pixels (`compositor_swiftui_image`). One token per image object, so
/// a changed picture changes the tree and an unchanged one doesn't. The most recent images are kept, oldest dropped.
public enum ImageRegistry {
    nonisolated(unsafe) private static var tokens: [ObjectIdentifier: String] = [:]
    nonisolated(unsafe) private static var images: [String: CGImage] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    nonisolated(unsafe) private static var next = 1
    private static let lock = NSLock()
    private static let capacity = 2048

    public static func token(for image: CGImage) -> String {
        lock.lock(); defer { lock.unlock() }
        if let token = tokens[ObjectIdentifier(image)], images[token] === image { return token }
        let token = String(next); next += 1
        tokens[ObjectIdentifier(image)] = token
        images[token] = image
        order.append(token)
        if order.count > capacity {
            let dropped = order.removeFirst()
            if let image = images.removeValue(forKey: dropped) { tokens.removeValue(forKey: ObjectIdentifier(image)) }
        }
        return token
    }
    public static func image(for token: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return images[token]
    }
}

public struct Image: View, PrimitiveView {
    let source: String
    /// `.resizable()`: drawn to fill its slot (keeping its aspect with `.aspectRatio(contentMode: .fit)`, the default
    /// here) rather than at its own size.
    var isResizable = false
    public init(systemName: String) { source = "system:\(systemName)" }
    public init(_ name: String) { source = "named:\(name)" }
    public init(decorative cgImage: CGImage, scale: Double) { source = "pixels:" + ImageRegistry.token(for: cgImage) }
    public init(nsImage: NSImage) {
        if let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            source = "pixels:" + ImageRegistry.token(for: image)
        } else {
            source = "pixels:"
        }
    }
    public func resizable() -> Image { var copy = self; copy.isResizable = true; return copy }
    public func scaledToFit() -> some View { self }
    public func scaledToFill() -> some View { self }
    public func aspectRatio(_ aspectRatio: Double? = nil, contentMode: ContentMode) -> some View { self }
    public func aspectRatio(contentMode: ContentMode) -> some View { self }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Image")
        node.stringParams["source"] = source
        if isResizable { node.boolParams["resizable"] = true }
        return node
    }
}

public struct Button<Label: View>: View, PrimitiveView {
    let label: Label
    let action: () -> Void
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) { self.action = action; self.label = label() }
    public var _childViews: [any View] { [label] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Button")
        node.handlers["action"] = { _ in action() }
        node.children = children
        return node
    }
}
extension Button where Label == Text {
    public init(_ title: String, action: @escaping () -> Void) { self.init(action: action) { Text(title) } }
    /// `role:` doesn't change the render tree's shape (no destructive-red styling here yet); it exists so upstream's
    /// `Button("OK", role: .cancel) { ... }` calls compile.
    public init(_ title: String, role: ButtonRole, action: @escaping () -> Void) { self.init(action: action) { Text(title) } }
}
extension Button {
    public init(role: ButtonRole, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.init(action: action, label: label)
    }
}
public enum ButtonRole: Sendable { case destructive, cancel }

public struct Toggle<Label: View>: View, PrimitiveView {
    let label: Label
    let isOn: Binding<Bool>
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) { self.isOn = isOn; self.label = label() }
    public var _childViews: [any View] { [label] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Toggle")
        node.boolParams["isOn"] = isOn.wrappedValue
        node.handlers["isOn"] = { newValue in if let bool = newValue as? Bool { isOn.wrappedValue = bool } }
        node.children = children
        return node
    }
}
extension Toggle where Label == Text {
    public init(_ title: String, isOn: Binding<Bool>) { self.init(isOn: isOn) { Text(title) } }
}

public struct Slider<Value: BinaryFloatingPoint>: View, PrimitiveView {
    let value: Binding<Value>
    let bounds: ClosedRange<Value>
    public init(value: Binding<Value>, in bounds: ClosedRange<Value> = 0...1,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.value = value; self.bounds = bounds
    }
    public init(value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.value = value; self.bounds = bounds
    }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Slider")
        node.doubleParams["value"] = Double(value.wrappedValue)
        node.doubleParams["lowerBound"] = Double(bounds.lowerBound)
        node.doubleParams["upperBound"] = Double(bounds.upperBound)
        node.handlers["value"] = { newValue in if let double = newValue as? Double { value.wrappedValue = Value(double) } }
        return node
    }
}

public struct ProgressView: View, PrimitiveView {
    let fraction: Double?
    public init() { fraction = nil }
    public init(value: Double?, total: Double = 1) { fraction = value.map { $0 / total } }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "ProgressView")
        if let fraction { node.doubleParams["fraction"] = fraction }
        return node
    }
}

/// `format:`/`text:` text-entry field. Numeric fields (`value:`) round-trip through `Double`; upstream's own
/// `Binding<Double>` closures handle any further unit conversion, matching real SwiftUI's contract.
public struct TextField<Label: View>: View, PrimitiveView {
    let label: Label
    let text: Binding<String>?
    let value: Binding<Double>?
    let prompt: Text?
    public init(_ titleKey: String, text: Binding<String>, prompt: Text? = nil) where Label == Text {
        label = Text(titleKey); self.text = text; value = nil; self.prompt = prompt
    }
    public init(_ titleKey: String, value: Binding<Double>, format: NumberFormat = .number, prompt: Text? = nil) where Label == Text {
        label = Text(titleKey); self.value = value; text = nil; self.prompt = prompt
    }
    /// An integer-valued field: real SwiftUI's `TextField(_:value:format:)` is generic over the format's value
    /// type, so upstream binds it straight to `Int` properties too. Rounds through `Double` internally.
    public init(_ titleKey: String, value intValue: Binding<Int>, format: NumberFormat = .number, prompt: Text? = nil) where Label == Text {
        label = Text(titleKey); text = nil
        value = Binding(get: { Double(intValue.wrappedValue) }, set: { intValue.wrappedValue = Int($0.rounded()) })
        self.prompt = prompt
    }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "TextField")
        if let text {
            node.stringParams["text"] = text.wrappedValue
            node.handlers["text"] = { newValue in if let string = newValue as? String { text.wrappedValue = string } }
        }
        if let value {
            node.doubleParams["value"] = value.wrappedValue
            node.handlers["value"] = { newValue in if let double = newValue as? Double { value.wrappedValue = double } }
        }
        return node
    }
}

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View, PrimitiveView {
    let label: Label
    let selection: Binding<SelectionValue>
    let content: Content
    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.selection = selection; self.content = content(); self.label = label()
    }
    public var _childViews: [any View] { [label, content] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Picker")
        if let raw = (selection.wrappedValue as? any RawRepresentable)?.rawValue {
            node.stringParams["selection"] = "\(raw)"
        } else {
            node.stringParams["selection"] = "\(selection.wrappedValue)"
        }
        let sel = selection
        node.handlers["selection"] = { payload in
            let str: String
            if let s = payload as? String {
                str = s
            } else {
                str = "\(payload)"
            }
            if let all = (SelectionValue.self as? any CaseIterable.Type)?.allCases {
                for c in all {
                    if let v = c as? SelectionValue {
                        if "\(v)".compare(str, options: .caseInsensitive) == .orderedSame {
                            sel.wrappedValue = v
                            return
                        }
                        if let raw = (v as? any RawRepresentable)?.rawValue, "\(raw)".compare(str, options: .caseInsensitive) == .orderedSame {
                            sel.wrappedValue = v
                            return
                        }
                    }
                }
            }
            if let stringVal = str as? SelectionValue {
                sel.wrappedValue = stringVal
                return
            }
            if let intVal = Int(str), let iv = intVal as? SelectionValue {
                sel.wrappedValue = iv
                return
            }
        }
        node.children = children
        return node
    }
}
extension Picker where Label == Text {
    public init(_ titleKey: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(titleKey) }
    }
}

public struct ColorPicker<Label: View>: View, PrimitiveView {
    let label: Label
    let selection: Binding<Color>
    let supportsOpacity: Bool
    public init(selection: Binding<Color>, supportsOpacity: Bool = true, @ViewBuilder label: () -> Label) {
        self.selection = selection; self.supportsOpacity = supportsOpacity; self.label = label()
    }
    public var _childViews: [any View] { [label] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "ColorPicker")
        node.stringParams["selection"] = selection.wrappedValue.name
        node.boolParams["supportsOpacity"] = supportsOpacity
        node.children = children
        return node
    }
}
extension ColorPicker where Label == Text {
    public init(_ titleKey: String, selection: Binding<Color>, supportsOpacity: Bool = true) {
        self.init(selection: selection, supportsOpacity: supportsOpacity) { Text(titleKey) }
    }
}

public struct Menu<Label: View, Content: View>: View, PrimitiveView {
    let label: Label
    let content: Content
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content(); self.label = label()
    }
    public var _childViews: [any View] { [label, content] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Menu")
        node.children = children
        return node
    }
}
extension Menu where Label == Text {
    public init(_ titleKey: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(titleKey) }
    }
}

public struct Link<Label: View>: View, PrimitiveView {
    let label: Label
    let destination: URL
    public init(destination: URL, @ViewBuilder label: () -> Label) { self.destination = destination; self.label = label() }
    public var _childViews: [any View] { [label] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Link")
        node.stringParams["destination"] = destination.absoluteString
        node.children = children
        return node
    }
}

/// Immediate-mode drawing surface. The Qt renderer gives it a widget whose `paintEvent` hands upstream's closure a
/// real `GraphicsContext` wrapping the existing `CGContext`→Skia bridge (Sources/Compat/CoreGraphics), so drawing
/// code (histograms, curve graphs, rulers) needs no Linux-specific rewrite.
public struct Canvas: View, PrimitiveView {
    let renderer: (inout GraphicsContext, CGSize) -> Void
    public init(renderersOnly: Bool = false, opaque: Bool = false,
                rendersAsynchronously: Bool = false,
                renderer: @escaping (inout GraphicsContext, CGSize) -> Void) {
        self.renderer = renderer
    }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "Canvas")
        node.handlers["draw"] = { boxed in
            guard var box = boxed as? GraphicsContextBox else { return }
            renderer(&box.context, box.size)
        }
        return node
    }
}

/// The boxed pair `Canvas`'s draw handler receives from the Qt side (an `Any` payload, since `RenderNode.handlers`
/// is untyped) — a real `GraphicsContext`/size the CoreGraphics compat bridge already knows how to fill from Skia.
public struct GraphicsContextBox {
    public var context: GraphicsContext
    public var size: CGSize
    public init(context: GraphicsContext, size: CGSize) { self.context = context; self.size = size }
}

public struct LinearGradient: View, PrimitiveView {
    let colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint
    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.colors = colors; self.startPoint = startPoint; self.endPoint = endPoint
    }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "LinearGradient")
        node.stringParams["colors"] = colors.map(\.name).joined(separator: ",")
        node.stringParams["startPoint"] = startPoint.name
        node.stringParams["endPoint"] = endPoint.name
        return node
    }
}

public struct UnitPoint: Sendable, Equatable {
    let name: String
    public static let top = UnitPoint(name: "top"), bottom = UnitPoint(name: "bottom")
    public static let leading = UnitPoint(name: "leading"), trailing = UnitPoint(name: "trailing")
    public static let center = UnitPoint(name: "center")
    public static let topLeading = UnitPoint(name: "topLeading"), topTrailing = UnitPoint(name: "topTrailing")
    public static let bottomLeading = UnitPoint(name: "bottomLeading"), bottomTrailing = UnitPoint(name: "bottomTrailing")
}

