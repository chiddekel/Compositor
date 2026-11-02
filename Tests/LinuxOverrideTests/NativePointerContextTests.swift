import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct NativePointerContextTests {
    private struct ExistingView: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private final class MenuView: NSView {
        let choice: NSMenu
        var received: NSEvent?
        init(title: String) {
            choice = NSMenu(title: title)
            super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func menu(for event: NSEvent) -> NSMenu? {
            received = event
            return choice
        }
    }

    private final class EventSensitiveView: NSView {
        let child = MenuView(title: "Thumbnail")
        let fallback = NSMenu(title: "Table")
        var hitEvent: NSEvent?
        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(child)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            hitEvent = NSApp.currentEvent
            // Layer tables also redirect middle-button hits away from their thumbnail controls.
            return NSApp.currentEvent?.type == .rightMouseDown ? child : self
        }
        override func menu(for event: NSEvent) -> NSMenu? { fallback }
    }

    private final class ButtonView: NSView {
        var buttons: [Int] = []
        var hitButtons: [Int] = []
        var types: [NSEvent.EventType] = []
        var onLeftDown: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            hitButtons.append(NSEvent.pressedMouseButtons)
            return super.hitTest(point)
        }
        private func record(_ event: NSEvent) {
            buttons.append(NSEvent.pressedMouseButtons)
            types.append(event.type)
            #expect(NSApp.currentEvent === event)
        }
        override func mouseDown(with event: NSEvent) { record(event); onLeftDown?() }
        override func mouseUp(with event: NSEvent) { record(event) }
        override func otherMouseDown(with event: NSEvent) { record(event) }
        override func otherMouseDragged(with event: NSEvent) { record(event) }
        override func otherMouseUp(with event: NSEvent) { record(event) }
    }

    @Test func trackingLoopReleasePreservesMiddleAndClearsTheLeftPress() throws {
        let scope = "trackingPointerButtons"
        let active = NativeLowering.isActive
        let previous = NSApp.currentEvent
        let flags = NSEvent.modifierFlags
        let buttons = NSEvent.pressedMouseButtons
        let pump = NSApp.eventPump
        try #require(StateStore.begin(scope: scope))
        NativeLowering.isActive = true
        NSEvent.pressedMouseButtons = 0
        defer {
            NSApp.currentEvent = previous
            NSEvent.modifierFlags = flags
            NSEvent.pressedMouseButtons = buttons
            NSApp.eventPump = pump
            StateStore.end()
            NativeLowering.discard(scope: scope)
            NativeLowering.isActive = active
        }
        let root = ButtonView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: root.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = root
        func pointer(_ node: RenderNode) -> ((Any) -> Void)? {
            node.handlers["pointer"] ?? node.children.lazy.compactMap(pointer).first
        }
        let handler = try #require(pointer(ViewResolver.resolve(ExistingView(view: root))))
        let send: (String) -> Void = { type in
            handler(["type": type, "x": 25, "y": 40, "modifiers": 0, "clicks": 1] as [String: Any])
        }
        var sentRelease = false
        var release: NSEvent?
        var buttonsOnRelease: Int?
        NSApp.eventPump = {
            guard !sentRelease else { return false }
            sentRelease = true
            send("up")
            return true
        }
        root.onLeftDown = {
            release = window.nextEvent(matching: .leftMouseUp)
            buttonsOnRelease = NSEvent.pressedMouseButtons
        }
        defer { root.onLeftDown = nil }
        send("middleDown")
        send("down")
        #expect(sentRelease && release?.type == .leftMouseUp)
        #expect(buttonsOnRelease == 4)
        #expect(NSEvent.pressedMouseButtons == 4)
        send("up")
        #expect(root.types == [.otherMouseDown, .leftMouseDown],
                "A tracking loop that consumed release must not leave a stale left-button target")
        send("middleUp")
        #expect(root.buttons == [4, 5, 0])
        #expect(NSEvent.pressedMouseButtons == 0)
        #expect(NSApp.currentEvent === previous)
        withExtendedLifetime((window, root)) {}
    }

    @Test func overlappingLeftAndMiddlePressesPreserveEachButtonsState() throws {
        let scope = "overlappingPointerButtons"
        let active = NativeLowering.isActive
        let previous = NSApp.currentEvent
        let flags = NSEvent.modifierFlags
        let buttons = NSEvent.pressedMouseButtons
        try #require(StateStore.begin(scope: scope))
        NativeLowering.isActive = true
        NSEvent.pressedMouseButtons = 0
        defer {
            NSApp.currentEvent = previous
            NSEvent.modifierFlags = flags
            NSEvent.pressedMouseButtons = buttons
            StateStore.end()
            NativeLowering.discard(scope: scope)
            NativeLowering.isActive = active
        }
        let root = ButtonView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: root.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = root
        func pointer(_ node: RenderNode) -> ((Any) -> Void)? {
            node.handlers["pointer"] ?? node.children.lazy.compactMap(pointer).first
        }
        let handler = try #require(pointer(ViewResolver.resolve(ExistingView(view: root))))
        for type in ["middleDown", "down", "up", "middleDrag", "middleUp",
                     "middleDown", "middleUp", "down", "middleDown", "middleUp", "up"] {
            handler(["type": type, "x": 25, "y": 40, "modifiers": 0, "clicks": 1] as [String: Any])
        }
        #expect(root.types == [.otherMouseDown, .leftMouseDown, .leftMouseUp, .otherMouseDragged, .otherMouseUp,
                               .otherMouseDown, .otherMouseUp, .leftMouseDown, .otherMouseDown, .otherMouseUp, .leftMouseUp])
        #expect(root.buttons == [4, 5, 4, 4, 0, 4, 0, 1, 5, 1, 0],
                "Releasing either button must preserve the other, and release callbacks must see the new state")
        #expect(root.hitButtons == [4, 5, 4, 1, 5], "Hit testing must see the incoming press, including held buttons")
        #expect(NSEvent.pressedMouseButtons == 0)
        #expect(NSApp.currentEvent === previous)
        withExtendedLifetime((window, root)) {}
    }

    @Test func rightClickHitTestingAndMenuUseTheIncomingEvent() throws {
        let scope = "rightClickContext"
        let active = NativeLowering.isActive
        let previous = NSApp.currentEvent
        let flags = NSEvent.modifierFlags
        let presenter = NSMenu.presenter
        try #require(StateStore.begin(scope: scope))
        NativeLowering.isActive = true
        defer {
            NSApp.currentEvent = previous
            NSEvent.modifierFlags = flags
            NSMenu.presenter = presenter
            StateStore.end()
            NativeLowering.discard(scope: scope)
            NativeLowering.isActive = active
        }
        let root = EventSensitiveView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: root.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = root
        func pointer(_ node: RenderNode) -> ((Any) -> Void)? {
            node.handlers["pointer"] ?? node.children.lazy.compactMap(pointer).first
        }
        let handler = try #require(pointer(ViewResolver.resolve(ExistingView(view: root))))
        let outer = try #require(NSEvent.mouseEvent(with: .otherMouseUp, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
        outer.buttonNumber = 2
        NSApp.currentEvent = outer
        var presented: NSMenu?
        var presentingEvent: NSEvent?
        NSMenu.presenter = { menu, finish in
            presented = menu
            presentingEvent = NSApp.currentEvent
            finish(nil)
        }
        handler(["type": "rightDown", "x": 25, "y": 40, "modifiers": 8, "clicks": 1] as [String: Any])
        #expect(presented === root.child.choice, "The outer middle event must not select the table's context menu")
        let incoming = try #require(root.hitEvent)
        #expect(incoming.type == .rightMouseDown)
        #expect(incoming.buttonNumber == 1)
        #expect(incoming.modifierFlags.contains(.shift))
        #expect(incoming.locationInWindow == CGPoint(x: 25, y: 60))
        #expect(root.child.received === incoming)
        #expect(presentingEvent === incoming)
        #expect(NSApp.currentEvent === outer)
        withExtendedLifetime((window, root)) {}
    }
}
