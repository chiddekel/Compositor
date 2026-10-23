import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized) struct NativeMaskGeometryTests {
    private struct ExistingView: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @Test func maskHitTestingUsesTheIncomingEventInsteadOfAnOuterMiddleRelease() throws {
        let scope = "maskCurrentEvent"
        let active = NativeLowering.isActive
        let previous = NSApp.currentEvent
        let flags = NSEvent.modifierFlags
        let buttons = NSEvent.pressedMouseButtons
        try #require(StateStore.begin(scope: scope))
        NativeLowering.isActive = true
        defer {
            NSApp.currentEvent = previous
            NSEvent.modifierFlags = flags
            NSEvent.pressedMouseButtons = buttons
            StateStore.end()
            NativeLowering.discard(scope: scope)
            NativeLowering.isActive = active
        }
        let session = EditorSession()
        session.createDocument(width: 64, height: 32, emptyLayer: true)
        let coordinator = NativeLayerList.Coordinator(session: session)
        let table = LayerTableView()
        table.session = session
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = 252
        table.addTableColumn(column)
        table.delegate = coordinator; table.dataSource = coordinator
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 252, height: 100))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = scroll
        coordinator.update(table)
        session.addMask(revealing: false)
        coordinator.update(table)
        scroll.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
        func pointer(_ node: RenderNode) -> ((Any) -> Void)? {
            node.handlers["pointer"] ?? node.children.lazy.compactMap(pointer).first
        }
        let handler = try #require(pointer(ViewResolver.resolve(ExistingView(view: scroll))))
        let outer = try #require(NSEvent.mouseEvent(with: .otherMouseUp, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
        outer.buttonNumber = 2
        NSApp.currentEvent = outer
        let layerID = session.activeLayerID
        let revision = session.history.currentRevision
        handler(["type": "down", "x": 106, "y": 26, "modifiers": 8, "clicks": 1] as [String: Any])
        handler(["type": "up", "x": 106, "y": 26, "modifiers": 8, "clicks": 1] as [String: Any])
        try #require(session.activeLayer?.mask?.isEnabled == false,
                     "The previous middle-button event must not redirect a Shift-click away from the mask")
        #expect(session.activeLayerID == layerID)
        #expect(NSApp.currentEvent === outer)
        session.undo()
        #expect(session.activeLayer?.mask?.isEnabled == true)
        #expect(session.history.currentRevision == revision)
        session.redo()
        #expect(session.activeLayer?.mask?.isEnabled == false)
        withExtendedLifetime((coordinator, window, scroll, table)) {}
    }

    @Test func reusedUpstreamMaskThumbnailKeepsItsGuideGeometry() throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 32, emptyLayer: true)
        let coordinator = NativeLayerList.Coordinator(session: session)
        let table = LayerTableView()
        table.session = session
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = 252
        table.addTableColumn(column)
        table.delegate = coordinator; table.dataSource = coordinator
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 252, height: 100))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = scroll
        coordinator.update(table)
        scroll.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        session.addMask(revealing: false)
        coordinator.update(table)
        scroll.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let mask = try #require(buttons(table).first { $0.toolTip?.hasPrefix("Select layer mask;") == true })
        let point = mask.convert(CGPoint(x: mask.bounds.midX, y: mask.bounds.midY), to: table)
        #expect(point.x == 106 && point.y == 26)
        #expect(mask.frame.size == CGSize(width: 30, height: 15))
        withExtendedLifetime((coordinator, window)) {}
    }

    @Test func detachingSubtreePreservesInternalConstraintsAndRemovesExternalOnes() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let cell = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 50))
        let child = NSView()
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(cell)
        cell.addSubview(child)
        let guide = NSLayoutGuide()
        cell.addLayoutGuide(guide)
        let internalConstraints = [child.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                                   child.widthAnchor.constraint(equalToConstant: 30),
                                   guide.leadingAnchor.constraint(equalTo: child.trailingAnchor, constant: 5)]
        let externalConstraints = [cell.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                                   child.topAnchor.constraint(equalTo: parent.topAnchor),
                                   guide.topAnchor.constraint(equalTo: parent.topAnchor)]
        NSLayoutConstraint.activate(internalConstraints + externalConstraints)
        defer { NSLayoutConstraint.deactivate(internalConstraints + externalConstraints) }
        cell.removeFromSuperview()
        #expect(internalConstraints.allSatisfy { $0.isActive })
        #expect(externalConstraints.allSatisfy { !$0.isActive })
        parent.addSubview(cell)
        cell.layoutSubtreeIfNeeded()
        #expect(child.frame.minX == 10 && child.frame.width == 30)
        #expect(guide.frame.minX == 45)
    }
}
