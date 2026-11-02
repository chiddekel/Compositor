import Foundation
import AppKit
import SwiftUI
import Testing

/// SwiftUI calls `dismantleNSView` when a representable's view leaves the hierarchy; upstream's pickers end a hover
/// preview and detach their menu delegates there. Both hosting paths must call it, with the view's own coordinator.
@MainActor
@Suite(.serialized)
struct RepresentableDismantleTests {
    final class Log { var made = 0; var dismantled: [Int] = [] }
    private struct Counted: @preconcurrency NSViewRepresentable {
        let log: Log
        final class Coordinator { let serial: Int; init(_ serial: Int) { self.serial = serial } }
        func makeCoordinator() -> Coordinator { log.made += 1; return Coordinator(log.made) }
        func makeNSView(context: Context) -> NSView { NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20)) }
        func updateNSView(_ nsView: NSView, context: Context) {}
        static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { logs.last?.dismantled.append(coordinator.serial) }
        static var logs: [Log] = []
    }

    @Test func loweredViewsAreDismantledWhenTheirScopeIsDiscarded() throws {
        let log = Log(); Counted.logs = [log]
        let scope = "dismantle-\(UUID())"
        let wasActive = NativeLowering.isActive
        try #require(StateStore.begin(scope: scope))
        NativeLowering.isActive = true
        _ = ViewResolver.resolve(Counted(log: log))
        _ = ViewResolver.resolve(Counted(log: log))
        StateStore.end()
        #expect(log.made == 1 && log.dismantled.isEmpty, "a view kept across resolves must not be dismantled")
        NativeLowering.discard(scope: scope)
        StateStore.discard(scope: scope)
        NativeLowering.isActive = wasActive
        #expect(log.dismantled == [1])
    }

    @Test func hostedViewsAreDismantledWhenTheyLeaveTheTree() {
        let log = Log(); Counted.logs = [log]
        let wasActive = NativeLowering.isActive
        NativeLowering.isActive = false
        defer { NativeLowering.isActive = wasActive }
        let host = NSHostingView(rootView: AnyView(Counted(log: log)))
        host.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        host.layout()
        #expect(log.made == 1 && log.dismantled.isEmpty)
        host.rootView = AnyView(Text("Gone"))
        host.layout()
        #expect(log.dismantled == [1])
    }
}
