import Foundation
import AppKit
import Observation

// A host that draws resolved trees itself (the Qt shell) can't place real AppKit views, so with `NativeLowering`
// active an `NSViewRepresentable` resolves to the nodes its AppKit view stands for. The representable's view is made
// once per tree position and updated on every resolve, exactly as SwiftUI drives it; what it shows is read back from
// the real controls, and what the user does goes to them (a pop-up's menu tracking and action, a button's click, a
// slider's value, a field's text), so tip's coordinators run unchanged:
//
//   NSPopUpButton  → Picker (its menu's items; open, highlight, choose and close reach the menu's delegate)
//   NSButton       → Button (title or symbol), clicking it
//   NSTextField    → Text, or TextField when editable (delegate notifications, action on Return)
//   NSImageView    → Image (its symbol, tinted)
//   NSSlider       → Slider (the cell's bar colors as the track)
//   NSStackView    → HStack / VStack of its arranged views
//   NSScrollView   → ScrollView of its document view
//   NSHostingView  → its SwiftUI root, resolved in place
//   anything else  → Canvas: the view hierarchy draws itself, and the pointer reaches it as mouse events
@MainActor public enum NativeLowering {
    /// Set by a host that draws resolved trees itself, around its resolves.
    nonisolated(unsafe) public static var isActive = false

    private struct Hosted {
        let type: ObjectIdentifier; let view: NSView; let state: AnyObject; let source: any _NativeViewSource
        @MainActor func dismantle() { source._dismantleNativeView(view, state: state); view.removeFromSuperview() }
    }
    private static var hosted: [String: Hosted] = [:]

    /// Bumped when the user acts on a lowered control: the trees that showed one resolve again (AppKit state such as a
    /// pop-up's selection isn't observable by itself).
    static let revision = Revision()
    final class Revision: Observable {
        private let registrar = ObservationRegistrar()
        private var stored = 0
        var value: Int { registrar.access(self, keyPath: \.value); return stored }
        func bump() { registrar.withMutation(of: self, keyPath: \.value) { stored &+= 1 } }
    }

    /// The node an `NSViewRepresentable` at `path` resolves to while lowering is active.
    static func node(for source: any _NativeViewSource, path: String) -> RenderNode {
        let key = "\(StateStore.currentScope ?? "")|\(path)"
        var entry = hosted[key]
        if entry?.type != source._nativeTypeID {
            entry?.dismantle()
            let made = source._makeNativeView()
            entry = Hosted(type: source._nativeTypeID, view: made.view, state: made.state, source: source)
            hosted[key] = entry
            // In a window, as SwiftUI's hosting puts it: first-responder logic (a recorder taking the keys) has one.
            window(for: StateStore.currentScope ?? "").contentView?.addSubview(made.view)
        }
        guard let entry else { return RenderNode(kind: "_Empty") }
        source._updateNativeView(entry.view, state: entry.state)
        let preferred = source._sizeThatFits(.unspecified, view: entry.view, state: entry.state)
        if let preferred, entry.view.bounds.width <= 0 || entry.view.bounds.height <= 0 { entry.view.setFrameSize(preferred) }
        _ = revision.value
        var node = lower(entry.view, path: path + "/native")
        if let minimum = source._sizeThatFits(.init(width: 0, height: nil), view: entry.view, state: entry.state) {
            node.doubleParams["nativeMinWidth"] = Double(minimum.width)
        }
        if let preferred {
            node.modifiers.append(.frame(width: nil, height: preferred.height, minWidth: nil, minHeight: nil,
                                         maxWidth: nil, maxHeight: nil, alignment: "center"))
        }
        return node
    }

    /// Forgets the views made under `scope` (a panel closed for good).
    public static func discard(scope: String) {
        for key in hosted.keys where key.hasPrefix(scope + "|") { hosted.removeValue(forKey: key)?.dismantle() }
        windows.removeValue(forKey: scope)
    }

    /// One offscreen window per tree (never shown, never key): the lowered views' `window`.
    private static var windows: [String: NSWindow] = [:]
    public static func childWindows(in scopes: Set<String>) -> [NSWindow] {
        scopes.flatMap { windows[$0]?.childWindows ?? [] }.filter(\.isVisible)
    }
    public static func childWindow(_ number: Int) -> NSWindow? {
        windows.values.flatMap(\.childWindows).first { $0.windowNumber == number && $0.isVisible }
    }
    public static func dismissChildWindow(_ number: Int) {
        guard let window = childWindow(number) else { return }
        act { window.resignKey(); window.orderOut(nil); window.parent?.removeChildWindow(window) }
    }
    public static func childWindowNode(_ number: Int) -> RenderNode? {
        guard let window = childWindow(number), let view = window.contentView else { return nil }
        func hierarchy(_ view: NSView, path: String) -> RenderNode {
            var node: RenderNode
            if type(of: view) == NSView.self || view is NSVisualEffectView {
                node = RenderNode(kind: "ZStack")
                node.stringParams["alignment"] = "topLeading"
                node.children = view.subviews.enumerated().filter { !$0.element.isHidden }.map { index, child in
                    var part = hierarchy(child, path: "\(path)/\(index)")
                    let y = view.isFlipped ? child.frame.midY : view.bounds.height - child.frame.midY
                    part.modifiers.append(.position(x: child.frame.midX, y: y))
                    return part
                }
                if view is NSVisualEffectView {
                    node.modifiers.append(.background(Color(nsColor: NSColor(white: 0.16, alpha: 1)).name))
                }
                if let layer = view.layer {
                    if let fill = layer.backgroundColor { node.modifiers.append(.background(Color(nsColor: NSColor(cgColor: fill)).name)) }
                    if let border = layer.borderColor, layer.borderWidth > 0 {
                        node.modifiers.append(.border(Color(nsColor: NSColor(cgColor: border)).name, layer.borderWidth))
                    }
                    if layer.cornerRadius > 0 { node.modifiers.append(.cornerRadius(layer.cornerRadius)) }
                }
            } else if let scroll = view as? NSScrollView {
                node = decorate(scrollNode(scroll, path: path, preservesFrame: true), for: scroll)
            } else { node = lower(view, path: path) }
            node.modifiers.append(.frame(width: view.frame.width, height: view.frame.height, minWidth: nil,
                                         minHeight: nil, maxWidth: nil, maxHeight: nil, alignment: "center"))
            return node
        }
        return hierarchy(view, path: "childWindow/\(number)")
    }
    private static func window(for scope: String) -> NSWindow {
        if let window = windows[scope] { return window }
        let window = LoweringWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [], backing: .buffered, defer: true)
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        windows[scope] = window
        return window
    }

    /// Runs a user action on a lowered control, then has the trees showing it resolve again.
    static func act(_ action: () -> Void) {
        action()
        revision.bump()
    }

    static func lower(_ view: NSView, path: String) -> RenderNode {
        let node: RenderNode
        switch view {
        case let popUp as NSPopUpButton: node = popUpNode(popUp, path: path)
        case let hosting as _AnyHostingView:
            let nodes = ViewResolver.resolveList(hosting._anyRootView, path: path + "/root")
            var hosted: RenderNode
            if nodes.count == 1 { hosted = nodes[0] } else { hosted = RenderNode(kind: "VStack"); hosted.children = nodes }
            let bounds = hosting._anySizingBounds
            func finite(_ value: CGFloat?) -> Double? {
                guard let value, value.isFinite, value >= 0 else { return nil }
                return Double(value)
            }
            if bounds.minimum != nil || bounds.maximum != nil {
                hosted.modifiers.append(.frame(width: nil, height: nil, minWidth: finite(bounds.minimum?.width), minHeight: finite(bounds.minimum?.height),
                    maxWidth: finite(bounds.maximum?.width), maxHeight: finite(bounds.maximum?.height), alignment: "center"))
            }
            node = hosted
        case let stack as NSStackView: node = stackNode(stack, path: path)
        case let scroll as NSScrollView: node = scrollNode(scroll, path: path)
        case let button as NSButton: node = buttonNode(button, path: path)
        case let field as NSTextField: node = textFieldNode(field, path: path)
        case let image as NSImageView: node = imageNode(image, path: path)
        case let slider as NSSlider: node = sliderNode(slider, path: path)
        default: node = appKitNode(view, path: path)
        }
        return decorate(node, for: view)
    }

    /// What every lowered view keeps from its AppKit view: hidden, disabled, tooltip, accessibility label.
    private static func decorate(_ node: RenderNode, for view: NSView) -> RenderNode {
        var node = node
        if let control = view as? NSControl, !control.isEnabled { node.modifiers.append(.disabled(true)) }
        if let tip = view.toolTip, !tip.isEmpty { node.modifiers.append(.help(tip)) }
        if let label = view.accessibilityLabel(), !label.isEmpty { node.modifiers.append(.accessibilityLabel(label)) }
        if let identifier = view.accessibilityIdentifier(), !identifier.isEmpty { node.modifiers.append(.accessibilityIdentifier(identifier)) }
        if view.isHidden { node.modifiers.append(.opacity(0)); node.modifiers.append(.allowsHitTesting(false)) }
        // The first responder gets the keys: the shell hands it the next one pressed, as a key-down event.
        if let window = view.window, window.firstResponder === view {
            node.modifiers.append(.sink("keyCapture") { value in
                guard let values = value as? [Any], values.count == 2, let key = values[0] as? String else { return }
                let bits = (values[1] as? Int) ?? Int((values[1] as? Double) ?? 0)
                var flags: NSEvent.ModifierFlags = []
                if bits & 1 != 0 { flags.insert(.command) }
                if bits & 2 != 0 { flags.insert(.option) }
                if bits & 4 != 0 { flags.insert(.control) }
                if bits & 8 != 0 { flags.insert(.shift) }
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
                act { view.keyDown(with: event) }
            })
        }
        return node
    }

    private static func resolved(_ view: some View, path: String) -> RenderNode {
        ViewResolver.resolveList(view, path: path).first ?? RenderNode(kind: "_Empty")
    }

    // MARK: Controls

    private static func popUpNode(_ popUp: NSPopUpButton, path: String) -> RenderNode {
        // The menu is read as it would be when it opens: the delegate fills it, items are validated.
        if let menu = popUp.menu, !popUp.isMenuOpen {
            menu.delegate?.menuNeedsUpdate?(menu)
            if popUp.autoenablesItems { menu.update() }
        }
        let items = popUp.itemArray
        let selection = Binding<String>(
            get: { String(popUp.indexOfSelectedItem) },
            set: { tag in
                guard let index = Int(tag), let item = popUp.item(at: index) else { return }
                act { popUp.choose(item) }
            })
        let picker = Picker(selection: selection) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if item.isSeparatorItem {
                    Divider()
                } else if let face = (item.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName,
                          item.attributedTitle?.length ?? 0 > 0 {
                    Text(item.title).font(.custom(face, size: 13)).tag(String(index))
                } else {
                    Text(item.title).tag(String(index))
                }
            }
        } label: {
            Text(popUp.accessibilityLabel() ?? "")
        }
        .labelsHidden()
        .compatPickerHighlight { tag in
            if let tag, let index = Int(tag) {
                popUp.highlight(popUp.item(at: index))
            } else if popUp.isMenuOpen {
                act { popUp.closeMenu() }
            }
        }
        var node = resolved(picker, path: path)
        if popUp is any NSCustomPopUpPresenting {
            node.boolParams["customPopup"] = true
            node.handlers["popupOpen"] = { payload in
                act {
                    if let info = payload as? [String: Any], let anchor = info["anchor"] as? [Double], anchor.count == 4,
                       let screen = info["screen"] as? [Double], screen.count == 4,
                       (anchor + screen).allSatisfy(\.isFinite), let window = popUp.window {
                        NSScreen.main = NSScreen(frame: CGRect(x: screen[0], y: screen[1], width: screen[2], height: screen[3]))
                        popUp.setFrameSize(CGSize(width: anchor[2], height: anchor[3]))
                        let local = popUp.convert(popUp.bounds, to: nil)
                        window.frame.origin = CGPoint(x: anchor[0] - local.minX, y: anchor[1] - local.minY)
                    }
                    _ = popUp.accessibilityPerformPress()
                }
            }
        }
        // A pop-up whose intrinsic width is open (a fixed-width font menu) takes the width it is given.
        if popUp.intrinsicContentSize.width < 0 {
            node.modifiers.append(.frame(width: nil, height: nil, minWidth: nil, minHeight: nil, maxWidth: .infinity,
                                         maxHeight: nil, alignment: "leading"))
        }
        return node
    }

    private static func buttonNode(_ button: NSButton, path: String) -> RenderNode {
        let symbol = button.image?.symbolName
        let tint = button.contentTintColor
        let control = Button(action: { act { button.performClick(nil) } }) {
            if let symbol, button.imagePosition == .imageOnly || button.title.isEmpty {
                if let tint { Image(systemName: symbol).foregroundStyle(Color(nsColor: tint)) } else { Image(systemName: symbol) }
            } else if let symbol {
                Label(button.title, systemImage: symbol)
            } else {
                Text(button.title)
            }
        }
        var node = resolved(control, path: path)
        if !button.isBordered { node.modifiers.append(.buttonStyle("plain")) }
        return node
    }

    private static func textFieldNode(_ field: NSTextField, path: String) -> RenderNode {
        var node: RenderNode
        if field.isEditable {
            let text = Binding<String>(
                get: { field.stringValue },
                set: { value in
                    act {
                        field.stringValue = value
                        let notification = Notification(name: NSControl.textDidChangeNotification, object: field)
                        field.delegate?.controlTextDidChange(notification)
                        NotificationCenter.default.post(notification)
                    }
                })
            node = resolved(TextField(field.placeholderString ?? "", text: text)
                .onSubmit { act {
                    if field.delegate?.control(field, textView: NSTextView(), doCommandBy: Selector("insertNewline:")) != true {
                        field.sendAction(field.action, to: field.target)
                    }
                } }, path: path)
            node.modifiers.append(.resultSink("fieldCommand", { payload in
                guard let command = payload as? String else { return 0 }
                var handled = false
                act { handled = field.delegate?.control(field, textView: NSTextView(), doCommandBy: Selector(command)) ?? false }
                return handled ? 1 : 0
            }))
        } else {
            node = resolved(Text(field.stringValue), path: path)
            if field.lineBreakMode == .byTruncatingTail || field.maximumNumberOfLines == 1 { node.modifiers.append(.lineLimit(1)) }
        }
        if let font = field.font { node.modifiers.append(.font(fontToken(font))) }
        if field.window?.editedField === field { node.boolParams["focused"] = true }
        if let color = field.textColor { node.modifiers.append(.foregroundStyle(Color(nsColor: color).name)) }
        return node
    }

    private static func imageNode(_ imageView: NSImageView, path: String) -> RenderNode {
        guard let symbol = imageView.image?.symbolName else { return appKitNode(imageView, path: path) }
        var node = resolved(Image(systemName: symbol), path: path)
        if let points = imageView.symbolConfiguration?.pointSize, points > 0 { node.modifiers.append(.font("system:\(points)")) }
        if let tint = imageView.contentTintColor { node.modifiers.append(.foregroundStyle(Color(nsColor: tint).name)) }
        return node
    }

    private static func sliderNode(_ slider: NSSlider, path: String) -> RenderNode {
        let cell = slider.cell as? NSSliderCell
        let value = Binding<Double>(
            get: { slider.doubleValue },
            set: { newValue in act { slider.doubleValue = newValue; slider.sendAction(slider.action, to: slider.target) } })
        let range = (cell?.minValue ?? 0)...max(cell?.minValue ?? 0, cell?.maxValue ?? 1)
        if slider.frame.width < 1 { slider.frame = CGRect(x: 0, y: 0, width: 200, height: 22) }
        // A double-click is AppKit's two-click press on the knob (a slider may reset there).
        let control = Slider(value: value, in: range)
            .compatSliderTrack(cell.flatMap(barColors))
            .onTapGesture(count: 2) {
                let knob = cell?.knobRect(flipped: slider.isFlipped) ?? slider.bounds
                let event = NSEvent.mouseEvent(with: .leftMouseDown, location: slider.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil),
                                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: slider.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                               clickCount: 2, pressure: 1)!
                act { slider.mouseDown(with: event) }
            }
        return resolved(control, path: path)
    }

    /// The colors a slider cell's bar draws, left to right (a custom cell paints a gradient there), or nil when it
    /// draws none of its own.
    private static func barColors(_ cell: NSSliderCell) -> [(Double, Double, Double, Double)]? {
        let width = 64, height = 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        cell.drawBar(inside: CGRect(x: 0, y: 0, width: width, height: height), flipped: false)
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = (height / 2) * width * 4
        var stops: [(Double, Double, Double, Double)] = []
        for step in 0..<8 {
            let x = min(width - 1, step * (width - 1) / 7), offset = row + x * 4
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0 else { return nil }
            stops.append((Double(pixels[offset]) / 255 / alpha, Double(pixels[offset + 1]) / 255 / alpha,
                          Double(pixels[offset + 2]) / 255 / alpha, alpha))
        }
        return stops
    }

    // MARK: Containers

    private static func stackNode(_ stack: NSStackView, path: String) -> RenderNode {
        var node = RenderNode(kind: stack.orientation == .vertical ? "VStack" : "HStack")
        node.doubleParams["spacing"] = Double(stack.spacing)
        node.stringParams["alignment"] = "center"
        node.children = stack.arrangedSubviews.enumerated().map { lower($0.element, path: "\(path).\($0.offset)") }
        let insets = stack.edgeInsets
        if insets.top != 0 || insets.left != 0 || insets.bottom != 0 || insets.right != 0 {
            node.modifiers.append(.padding(top: Double(insets.top), leading: Double(insets.left),
                                           bottom: Double(insets.bottom), trailing: Double(insets.right)))
        }
        return node
    }

    private final class ScrollGeometry {
        weak var scroll: NSScrollView?
        var documentSize: CGSize?
        init(_ scroll: NSScrollView) { self.scroll = scroll }
    }
    private static var scrollGeometry: [ObjectIdentifier: ScrollGeometry] = [:]

    private static func scrollNode(_ scroll: NSScrollView, path: String, preservesFrame: Bool = false) -> RenderNode {
        scrollGeometry = scrollGeometry.filter { $0.value.scroll != nil }
        let key = ObjectIdentifier(scroll)
        let geometry = scrollGeometry[key] ?? ScrollGeometry(scroll)
        scrollGeometry[key] = geometry
        // A hosting document can temporarily fall back while its upstream container asks for fitting bounds.
        // Its rendered dimensions remain authoritative until Qt supplies new ones.
        if let document = scroll.documentView, document is any _AnyHostingView, let size = geometry.documentSize {
            if document.frame.size != size { document.setFrameSize(size) }
        }
        var node = RenderNode(kind: "ScrollView")
        node.boolParams["appKitScroll"] = true
        // The axes it scrolls along: a scroller, or elasticity allowed, says so (a scroller-less view still scrolls).
        let horizontal = scroll.hasHorizontalScroller || scroll.horizontalScrollElasticity == .allowed
        node.boolParams["horizontal"] = horizontal
        node.boolParams["vertical"] = !(horizontal && !scroll.hasVerticalScroller && scroll.verticalScrollElasticity == .none)
        if let document = scroll.documentView { node.children = [lower(document, path: path + ".0")] }
        if scroll.contentView.frame.width > 0, scroll.contentView.frame.height > 0, let document = scroll.documentView {
            node.doubleParams["scrollX"] = max(0, scroll.contentView.bounds.minX - document.frame.minX)
            node.doubleParams["scrollY"] = max(0, document.isFlipped
                ? scroll.contentView.bounds.minY - document.frame.minY
                : document.frame.maxY - scroll.contentView.bounds.maxY)
        }
        node.handlers["scrollGeometry"] = { payload in
            guard let values = payload as? [String: Any], let document = scroll.documentView else { return }
            func number(_ name: String) -> CGFloat? {
                let value = (values[name] as? Double) ?? (values[name] as? Int).map(Double.init)
                guard let value, value.isFinite, value >= 0 else { return nil }
                return value
            }
            guard let width = number("width"), let height = number("height"), width > 0, height > 0,
                  let x = number("x"), let y = number("y") else { return }
            let pending = scroll.contentView._pendingVisibleRect
            // An absolutely positioned child keeps its outer AppKit frame. Qt reports the viewport excluding its
            // scrollers; feeding that width back into the outer frame would shrink it on every panel refresh.
            if preservesFrame { scroll.contentView.setFrameSize(CGSize(width: width, height: height)) }
            else { scroll.setFrameSize(CGSize(width: width, height: height)) }
            scroll.layoutSubtreeIfNeeded()
            if let documentWidth = number("documentWidth"), let documentHeight = number("documentHeight") {
                let size = CGSize(width: documentWidth, height: documentHeight)
                geometry.documentSize = size
                if document.frame.size != size { document.setFrameSize(size) }
            }
            // `basisX`/`basisY`: the native offset the host's view was last given. A host offset still equal to it was
            // not scrolled there by the user; when the native viewport has moved since (a key, a reveal), that offset
            // is out of date and must not undo the move. The host is sent the current offset instead.
            let currentX = scroll.contentView.bounds.minX - document.frame.minX
            let currentY = document.isFlipped ? scroll.contentView.bounds.minY - document.frame.minY
                : document.frame.maxY - scroll.contentView.bounds.maxY
            var outdated = false
            if let basisX = number("basisX"), let basisY = number("basisY"), abs(x - basisX) < 0.5, abs(y - basisY) < 0.5 {
                outdated = abs(currentX - basisX) > 0.5 || abs(currentY - basisY) > 0.5
            }
            if let pending {
                document.scrollToVisible(pending.offsetBy(dx: -document.frame.minX, dy: -document.frame.minY))
            } else if !outdated {
                scroll.contentView.scroll(to: CGPoint(x: document.frame.minX + x,
                    y: document.isFlipped ? document.frame.minY + y : document.frame.maxY - height - y))
            }
            document.needsLayout = true
            document.layoutSubtreeIfNeeded()
            if pending != nil || outdated {
                let actualY = document.isFlipped ? scroll.contentView.bounds.minY - document.frame.minY
                    : document.frame.maxY - scroll.contentView.bounds.maxY
                let actualX = scroll.contentView.bounds.minX - document.frame.minX
                if abs(actualY - y) > 0.5 || abs(actualX - x) > 0.5 { revision.bump() }
            }
        }
        if !scroll.hasVerticalScroller && !scroll.hasHorizontalScroller { node.modifiers.append(.scrollIndicators("never")) }
        return node
    }

    // MARK: Everything else draws itself

    /// A view the host shows as the pixels it draws (`draw`), handing it the pointer (`pointer`) and, while it has the
    /// focus, the keys (`key`) as AppKit events — tip's own hit testing, tracking loops, drags and menus run on them. A
    /// text field being edited in it is a real text field over it (`children`, placed by their `frame*` parameters).
    private static func appKitNode(_ view: NSView, path: String) -> RenderNode {
        var node = RenderNode(kind: "_AppKit")
        node.boolParams["tableDocument"] = view is NSTableView
        let ideal = idealSize(view)
        if ideal.width > 0 { node.doubleParams["width"] = Double(ideal.width) }
        if ideal.height > 0 { node.doubleParams["height"] = Double(ideal.height) }
        node.handlers["draw"] = { boxed in
            guard let box = boxed as? GraphicsContextBox else { return }
            place(view, size: box.size)
            if let picture = picture(of: view, size: box.size) {
                box.context.cgContext.draw(picture, in: CGRect(origin: .zero, size: box.size))
            }
        }
        let router = PointerRouter.for(view)
        let accessibility = NativeAccessibility.adapter(for: view)
        node.handlers["accessibilitySnapshot"] = { payload in
            guard let box = payload as? NativeAccessibilityBox else { return }
            box.data = accessibility.snapshot()
        }
        node.modifiers.append(.resultSink("accessibilityAction") { accessibility.perform($0) ? 1 : 0 })
        node.handlers["pointer"] = { payload in router.handle(payload) }
        node.handlers["key"] = { payload in router.key(payload) }
        node.handlers["focus"] = { payload in router.focus((payload as? Bool) ?? false) }
        if let field = view.window?.editedField, field.isDescendant(of: view) {
            node.children = [editorNode(for: field, in: view, path: path + "/editor")]
        }
        return node
    }

    /// How big the host should make a view: a table as tall as its rows (the host scrolls it), anything else its
    /// fitting size.
    private static func idealSize(_ view: NSView) -> CGSize {
        if let table = view as? NSTableView {
            let rows = table.numberOfRows
            let height = rows > 0 ? table.rect(ofRow: rows - 1).maxY + table.intercellSpacing.height : 0
            return CGSize(width: -1, height: max(height, 1))
        }
        return view.fittingSize
    }

    /// Gives the document its drawing size without replacing the enclosing scroll viewport's geometry.
    static func place(_ view: NSView, size: CGSize) {
        if view is NSTableView {
            if view.frame.width != size.width { view.frame.size.width = size.width }
        } else if view.frame.size != size {
            view.frame.size = size
        }
        view.layoutSubtreeIfNeeded()
    }

    /// The text field over a field being edited: the field editor's text, Return ending the edit as AppKit's does,
    /// Escape asking the delegate to cancel, and leaving it ending the edit.
    private static func editorNode(for field: NSTextField, in root: NSView, path: String) -> RenderNode {
        let text = Binding<String>(
            get: { field.currentEditor()?.string ?? field.stringValue },
            set: { value in
                guard let editor = field.currentEditor(), editor.string != value else { return }
                editor.string = value
                field.delegate?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            })
        let end = { act { field.window?.makeFirstResponder(root.acceptsFirstResponder ? root : nil) } }
        var node = resolved(TextField("", text: text)
            .onSubmit {
                act {
                    field.sendAction(field.action, to: field.target)
                    field.window?.makeFirstResponder(root.acceptsFirstResponder ? root : nil)
                }
            }
            .onExitCommand {
                act {
                    guard let editor = field.currentEditor() as? NSTextView,
                          field.delegate?.control(field, textView: editor, doCommandBy: Selector("cancelOperation:")) == true
                    else { field.window?.makeFirstResponder(root.acceptsFirstResponder ? root : nil); return }
                }
            }, path: path)
        let frame = field.convert(field.bounds, to: root)
        let top = root.isFlipped ? frame.minY : root.bounds.height - frame.maxY
        node.doubleParams["frameX"] = Double(frame.minX)
        node.doubleParams["frameY"] = Double(top)
        node.doubleParams["frameW"] = Double(frame.width)
        node.doubleParams["frameH"] = Double(frame.height)
        node.boolParams["focused"] = true
        node.modifiers.append(.sink("focused") { value in if (value as? Bool) == false { end() } })
        if let font = field.font { node.modifiers.append(.font(fontToken(font))) }
        return node
    }

    /// `view` drawn at `size` (laid out already). Into an AppKit-style bitmap context (y up, flipped to the top-left
    /// space `drawHierarchy` works in), so drawing code written for the Mac's bitmaps — text, images, symbols — comes out
    /// upright; the picture then goes into the host's context.
    public static func picture(of view: NSView, size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width.rounded(.up))), height = max(1, Int(size.height.rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        drawHierarchy(view, in: context, height: CGFloat(height))
        return context.makeImage()
    }

    /// Draws `view` and its subviews into `context` (top-left based, `height` tall), each in its own coordinates, with
    /// what its layer adds (background, rounded corners, border) and its alpha.
    public static func drawHierarchy(_ view: NSView, in context: CGContext, height: CGFloat, alpha: CGFloat = 1) {
        let alpha = alpha * view.alphaValue
        guard alpha > 0 else { return }
        let box = CGRect(origin: .zero, size: view.bounds.size)
        let layer = view.wantsLayer ? view.layer : nil
        func rounded(_ rect: CGRect) -> CGPath {
            let radius = min(layer?.cornerRadius ?? 0, rect.width / 2, rect.height / 2)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        context.saveGState()
        context.setAlpha(alpha)
        if let background = layer?.backgroundColor, background.alpha > 0 {
            context.addPath(rounded(box))
            context.setFillColor(background)
            context.fillPath()
        }
        if layer?.masksToBounds == true { context.addPath(rounded(box)); context.clip() }
        context.saveGState()
        if !view.isFlipped { context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: view.isFlipped)
        view.viewWillDraw()
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        for child in view.subviews where !child.isHidden {
            context.saveGState()
            // The child's top-left corner, in the parent's top-left based space.
            let top = view.isFlipped ? child.frame.minY : view.bounds.height - child.frame.maxY
            context.translateBy(x: child.frame.minX, y: top)
            context.clip(to: CGRect(origin: .zero, size: child.frame.size))
            drawHierarchy(child, in: context, height: child.frame.height, alpha: alpha)
            context.restoreGState()
        }
        if let layer, let border = layer.borderColor, layer.borderWidth > 0 {
            let inset = layer.borderWidth / 2
            context.addPath(rounded(box.insetBy(dx: inset, dy: inset)))
            context.setStrokeColor(border)
            context.setLineWidth(layer.borderWidth)
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func fontToken(_ font: NSFont) -> String {
        if font._systemWeightName == nil { return "native:\(Double(font.pointSize)):\(font.fontName)" }
        var token = "system:\(Double(font.pointSize))"
        if let weight = font._systemWeightName { token += "+weight:\(weight)" }
        if font._isMonospaced { token += "+design:monospaced" }
        if font._usesMonospacedDigits { token += "+monospacedDigit" }
        return token
    }
}

/// An `NSHostingView`, whatever its root type.
@MainActor protocol _AnyHostingView: AnyObject {
    var _anyRootView: any View { get }
    var _anySizingBounds: (minimum: CGSize?, maximum: CGSize?) { get }
}
extension NSHostingView: _AnyHostingView {
    var _anyRootView: any View { rootView }
    var _anySizingBounds: (minimum: CGSize?, maximum: CGSize?) { _nativeSizingBounds }
}

/// The window lowered views live in: the pointer is wherever the host last reported it over them.
@MainActor final class LoweringWindow: NSWindow {
    var pointer = CGPoint.zero
    override var mouseLocationOutsideOfEventStream: CGPoint { pointer }
    /// What has the keys shows (a table's selection color, a field being edited): the trees showing it resolve again.
    @discardableResult override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        NativeLowering.revision.bump()
        return made
    }
}

/// Turns what the host reports over a pixel-drawn view (`NativeLowering`'s `_AppKit` node) into AppKit events: a press
/// goes to the view hit-tested under it, which may track it (`NSWindow.nextEvent`, fed from here while it waits) or
/// start a drag session, whose drops this routes to the table under the pointer; hovering reaches tracking areas;
/// a right-click opens the menu `menu(for:)` gives; keys go to the first responder.
@MainActor final class PointerRouter {
    private static var routers: [ObjectIdentifier: PointerRouter] = [:]
    static func `for`(_ view: NSView) -> PointerRouter {
        if let router = routers[ObjectIdentifier(view)], router.root === view { return router }
        let router = PointerRouter(view)
        routers[ObjectIdentifier(view)] = router
        return router
    }

    private weak var root: NSView?
    private var pressed: NSView?
    private weak var middlePressed: NSView?
    private var session: NSDraggingSession?
    private var dropTarget: NSTableView?
    private var dropOperation: NSDragOperation = []
    private var inside: [ObjectIdentifier: NSTrackingArea] = [:]
    private init(_ root: NSView) { self.root = root }

    /// The pointer payload: {type: down|drag|up|move|exit|rightDown, x, y (top-left based), clicks, modifiers}.
    func handle(_ payload: Any) {
        guard let root, let dict = payload as? [String: Any], let type = dict["type"] as? String else { return }
        func number(_ key: String) -> Double { (dict[key] as? Double) ?? (dict[key] as? Int).map(Double.init) ?? 0 }
        let local = CGPoint(x: number("x"), y: root.isFlipped ? number("y") : root.bounds.height - number("y"))
        let windowPoint = root.convert(local, to: nil)
        let flags = Self.flags(Int(number("modifiers")))
        let clicks = max(1, Int(number("clicks")))
        (root.window as? LoweringWindow)?.pointer = windowPoint
        NSEvent.modifierFlags = flags
        func event(_ type: NSEvent.EventType) -> NSEvent {
            let value = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: root.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            if [.otherMouseDown, .otherMouseDragged, .otherMouseUp].contains(type) { value.buttonNumber = 2 }
            return value
        }
        // A view tracking the press (waiting in nextEvent) gets the rest of it from its queue.
        if let window = root.window, window.isTrackingEvents, type == "drag" || type == "up" {
            window.postEvent(event(type == "up" ? .leftMouseUp : .leftMouseDragged), atStart: false)
            if type == "up" { NSEvent.pressedMouseButtons &= ~1 }
            return
        }
        NativeLowering.act {
            switch type {
            case "down": down(event(.leftMouseDown), at: local, in: root)
            case "drag": drag(event(.leftMouseDragged), at: local, in: root)
            case "up": up(event(.leftMouseUp), at: local, in: root,
                          externalOperation: dict["externalLayerCopy"] as? Bool == true ? .copy : [])
            case "rightDown": rightDown(event(.rightMouseDown), at: local, in: root)
            case "middleDown":
                let value = event(.otherMouseDown)
                dispatch(value) {
                    NSEvent.pressedMouseButtons |= 4
                    middlePressed = target(at: local, in: root)
                    middlePressed?.otherMouseDown(with: value)
                }
            case "middleDrag":
                let value = event(.otherMouseDragged)
                dispatch(value) { middlePressed?.otherMouseDragged(with: value) }
            case "middleUp":
                let value = event(.otherMouseUp)
                NSEvent.pressedMouseButtons &= ~4
                dispatch(value) { middlePressed?.otherMouseUp(with: value) }
                middlePressed = nil
            case "move": hover(event(.mouseMoved), at: local, in: root, exited: false)
            case "exit": hover(event(.mouseMoved), at: local, in: root, exited: true)
            default: break
            }
        }
    }

    private func dispatch(_ event: NSEvent, _ body: () -> Void) {
        let previous = NSApp.currentEvent
        NSApp.currentEvent = event
        body()
        NSApp.currentEvent = previous
    }

    private func target(at local: CGPoint, in root: NSView) -> NSView {
        root.hitTest(root.superview.map { root.convert(local, to: $0) } ?? local) ?? root
    }

    private func down(_ event: NSEvent, at local: CGPoint, in root: NSView) {
        let before = NSDraggingSession.current
        dispatch(event) {
            // Hit testing can inspect currentEvent to distinguish mask clicks from middle-button scrolling.
            NSEvent.pressedMouseButtons |= 1
            let view = target(at: local, in: root)
            pressed = view
            if view.acceptsFirstResponder, view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
            view.mouseDown(with: event)
        }
        // The press started a drag (a row, an effect, a mask): the rest of it is the drag's. A tracking loop that took
        // the release itself has finished the press.
        if let current = NSDraggingSession.current, current !== before { session = current; pressed = nil }
        else if NSEvent.pressedMouseButtons & 1 == 0 { pressed = nil }
        // What the tracking loop left queued: the drag it started takes it, as AppKit's drag session takes the events
        // after the one that began it; with no drag, the press is over and it goes.
        guard let window = root.window else { return }
        while let next = window.dequeueEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard session != nil else { continue }
            let local = root.convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp { up(next, at: local, in: root) } else { drag(next, at: local, in: root) }
        }
    }

    private func drag(_ event: NSEvent, at local: CGPoint, in root: NSView) {
        if let session {
            session.draggingLocation = event.locationInWindow
            let table = tableAccepting(session, at: local, in: root)
            if dropTarget !== table { dropTarget?.showsDropIndicator = false; dropTarget?.setDropRow(-1, dropOperation: .above) }
            dropTarget = table
            guard let table else { dropOperation = []; return }
            _ = table.autoscroll(with: event)
            let info = CompatDraggingInfo(session: session, location: event.locationInWindow, window: root.window)
            info.draggingSourceOperationMask = session.sourceOperationMask.intersection(event.modifierFlags.contains(.option) ? .copy : .every)
            dropOperation = table.validateDrop(info, at: table.convert(event.locationInWindow, from: nil)).operation
            table.showsDropIndicator = !dropOperation.isEmpty
            return
        }
        guard let pressed else { return }
        dispatch(event) { pressed.mouseDragged(with: event) }
    }

    private func up(_ event: NSEvent, at local: CGPoint, in root: NSView, externalOperation: NSDragOperation = []) {
        NSEvent.pressedMouseButtons &= ~1
        if let session {
            self.session = nil
            var operation = externalOperation
            if let table = dropTarget, !dropOperation.isEmpty {
                let info = CompatDraggingInfo(session: session, location: event.locationInWindow, window: root.window)
                info.draggingSourceOperationMask = session.sourceOperationMask.intersection(event.modifierFlags.contains(.option) ? .copy : .every)
                // The drop lands where the last validation put it (as AppKit's: no new proposal on release).
                if table.acceptDrop(info) { operation = dropOperation }
            }
            dropTarget?.showsDropIndicator = false
            dropTarget?.setDropRow(-1, dropOperation: .above)
            dropTarget = nil
            dropOperation = []
            session.end(at: event.locationInWindow, operation: operation)
            return
        }
        guard let pressed else { return }
        self.pressed = nil
        dispatch(event) { pressed.mouseUp(with: event) }
    }

    /// The table under the pointer that takes what `session` carries (its registered types).
    private func tableAccepting(_ session: NSDraggingSession, at local: CGPoint, in root: NSView) -> NSTableView? {
        let carried = Set(session.draggingPasteboard.types ?? [])
        var view: NSView? = target(at: local, in: root)
        while let current = view {
            if let table = current as? NSTableView, !carried.isDisjoint(with: table.registeredDraggedTypes) { return table }
            view = current === root ? nil : current.superview
        }
        if let table = root as? NSTableView, !carried.isDisjoint(with: table.registeredDraggedTypes) { return table }
        return nil
    }

    private func rightDown(_ event: NSEvent, at local: CGPoint, in root: NSView) {
        dispatch(event) {
            var view: NSView? = target(at: local, in: root)
            // As AppKit's: the view under the pointer, or the nearest one above it, gives the menu.
            while let current = view {
                if let menu = current.menu(for: event) {
                    menu.popUp(positioning: nil, at: current.convert(event.locationInWindow, from: nil), in: current)
                    return
                }
                view = current === root ? nil : current.superview
            }
        }
    }

    /// Tracking areas: entered, moved and exited as the pointer crosses them, and the cursor they ask for.
    private func hover(_ event: NSEvent, at local: CGPoint, in root: NSView, exited: Bool) {
        var now: [ObjectIdentifier: NSTrackingArea] = [:]
        var areas: [(NSView, NSTrackingArea)] = []
        func collect(_ view: NSView) {
            for area in view.trackingAreas { areas.append((view, area)) }
            view.subviews.filter { !$0.isHidden }.forEach(collect)
        }
        collect(root)
        dispatch(event) {
            for (view, area) in areas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                let point = view.convert(event.locationInWindow, from: nil)
                let id = ObjectIdentifier(area)
                guard !exited, rect.contains(point) else {
                    if inside[id] != nil, area.options.contains(.mouseEnteredAndExited) { (area.owner as? NSResponder)?.mouseExited(with: event) }
                    continue
                }
                now[id] = area
                let owner = area.owner as? NSResponder
                if inside[id] == nil, area.options.contains(.mouseEnteredAndExited) { owner?.mouseEntered(with: event) }
                if area.options.contains(.mouseMoved) { owner?.mouseMoved(with: event) }
                if area.options.contains(.cursorUpdate) { owner?.cursorUpdate(with: event) }
            }
        }
        inside = now
    }

    /// A key while the host's view has the focus: {characters, keyCode, modifiers, repeat}, to the first responder.
    func key(_ payload: Any) {
        guard let root, let window = root.window, let dict = payload as? [String: Any] else { return }
        let characters = dict["characters"] as? String ?? ""
        let keyCode = UInt16((dict["keyCode"] as? Int) ?? Int((dict["keyCode"] as? Double) ?? 0))
        let bits = (dict["modifiers"] as? Int) ?? Int((dict["modifiers"] as? Double) ?? 0)
        let flags = Self.flags(bits)
        let event = NSEvent.keyEvent(with: .keyDown, location: window.mouseLocationOutsideOfEventStream, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(),
                                     isARepeat: (dict["repeat"] as? Bool) ?? false, keyCode: keyCode)!
        NativeLowering.act {
            let responder = ownsFirstResponder(in: window, root: root) ? window.firstResponder : root
            dispatch(event) { responder?.keyDown(with: event) }
        }
    }

    /// The host's view gained or lost the focus: losing it, nothing in it is first responder any more (a table's
    /// selection turns gray, as an inactive list's does).
    func focus(_ focused: Bool) {
        guard let root, let window = root.window else { return }
        if focused {
            if !ownsFirstResponder(in: window, root: root), root.acceptsFirstResponder {
                NativeLowering.act { window.makeFirstResponder(root) }
            }
        } else if ownsFirstResponder(in: window, root: root) {
            NativeLowering.act { window.makeFirstResponder(nil) }
        }
    }

    private func ownsFirstResponder(in window: NSWindow, root: NSView) -> Bool {
        let owner = window.editedField ?? (window.firstResponder as? NSView)
        guard let owner else { return false }
        return owner === root || owner.isDescendant(of: root)
    }

    /// The host's modifier bits (1 Ctrl, 2 Alt, 4 Meta, 8 Shift) as the Mac's: Ctrl is Command, Alt Option, Meta Control.
    static func flags(_ bits: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if bits & 1 != 0 { flags.insert(.command) }
        if bits & 2 != 0 { flags.insert(.option) }
        if bits & 4 != 0 { flags.insert(.control) }
        if bits & 8 != 0 { flags.insert(.shift) }
        return flags
    }
}
