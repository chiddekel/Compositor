import AppKit
import SwiftUI
import CoreGraphics
import Testing

/// The host reports its viewport together with the native offset it was last given (`basisX`/`basisY`). An unchanged
/// host offset must not undo a native scroll made after that (a Home key, a reveal), while a host scroll still wins.
@MainActor
@Suite(.serialized) struct NativeScrollBasisTests {
    private final class Document: NSView {
        var flipped = true
        override var isFlipped: Bool { flipped }
    }
    private final class Probe { var scroll: NSScrollView? }
    private struct Scroll: @preconcurrency NSViewRepresentable {
        var probe: Probe
        var flipped = true
        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
            let document = Document(frame: CGRect(x: 0, y: 0, width: 200, height: 600))
            document.flipped = flipped
            scroll.documentView = document
            scroll.hasVerticalScroller = true
            probe.scroll = scroll
            return scroll
        }
        func updateNSView(_ view: NSScrollView, context: Context) {}
    }
    private func withLowering(_ scope: String, body: () throws -> Void) throws {
        let previous = NativeLowering.isActive
        try #require(StateStore.begin(scope: scope))
        NativeLowering.isActive = true
        defer { StateStore.end(); NativeLowering.discard(scope: scope); NativeLowering.isActive = previous }
        try body()
    }
    /// Scrolls natively the way a key does: top-left host coordinates converted for the document's orientation.
    private func scrollNatively(_ scroll: NSScrollView, toHostY y: CGFloat) {
        let document = scroll.documentView!
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? y : document.frame.maxY - scroll.contentView.bounds.height - y))
    }
    private func report(_ handler: (Any) -> Void, y: Double, basis: Double?, height: Double = 120) {
        var payload: [String: Any] = ["width": 200.0, "height": height, "documentWidth": 200.0, "documentHeight": 600.0,
                                      "x": 0.0, "y": y]
        if let basis { payload["basisX"] = 0.0; payload["basisY"] = basis }
        handler(payload)
    }

    @Test(arguments: [true, false]) func anUnchangedHostOffsetDoesNotUndoALaterNativeScroll(flipped: Bool) throws {
        try withLowering("nativeScrollBasisStale\(flipped)") {
            let probe = Probe()
            let source = Scroll(probe: probe, flipped: flipped)
            _ = ViewResolver.resolve(source)
            let scroll = try #require(probe.scroll)
            scrollNatively(scroll, toHostY: 240)
            let shown = ViewResolver.resolve(source)
            #expect(shown.doubleParams["scrollY"] == 240)
            let handler = try #require(shown.handlers["scrollGeometry"])
            scrollNatively(scroll, toHostY: 0)
            report(handler, y: 240, basis: 240)
            #expect(ViewResolver.resolve(source).doubleParams["scrollY"] == 0)
        }
    }

    @Test(arguments: [true, false]) func aHostScrollStillMovesTheNativeViewport(flipped: Bool) throws {
        try withLowering("nativeScrollBasisUser\(flipped)") {
            let probe = Probe()
            let source = Scroll(probe: probe, flipped: flipped)
            _ = ViewResolver.resolve(source)
            let scroll = try #require(probe.scroll)
            scrollNatively(scroll, toHostY: 240)
            let handler = try #require(ViewResolver.resolve(source).handlers["scrollGeometry"])
            report(handler, y: 100, basis: 240)
            #expect(ViewResolver.resolve(source).doubleParams["scrollY"] == 100)
            // A host scroll made while the native offset also moved is the user's latest choice.
            scrollNatively(scroll, toHostY: 0)
            report(handler, y: 180, basis: 100)
            #expect(ViewResolver.resolve(source).doubleParams["scrollY"] == 180)
        }
    }

    @Test func aStaleOffsetStillUpdatesTheViewportSize() throws {
        try withLowering("nativeScrollBasisSize") {
            let probe = Probe()
            let source = Scroll(probe: probe)
            _ = ViewResolver.resolve(source)
            let scroll = try #require(probe.scroll)
            scrollNatively(scroll, toHostY: 240)
            let handler = try #require(ViewResolver.resolve(source).handlers["scrollGeometry"])
            scrollNatively(scroll, toHostY: 30)
            report(handler, y: 240, basis: 240, height: 100)
            #expect(scroll.frame.size == CGSize(width: 200, height: 100))
            #expect(scroll.contentView.bounds == CGRect(x: 0, y: 30, width: 200, height: 100))
        }
    }

    @Test func reportsWithoutABasisKeepTheirOffset() throws {
        try withLowering("nativeScrollBasisAbsent") {
            let probe = Probe()
            let source = Scroll(probe: probe)
            _ = ViewResolver.resolve(source)
            let scroll = try #require(probe.scroll)
            let handler = try #require(ViewResolver.resolve(source).handlers["scrollGeometry"])
            scrollNatively(scroll, toHostY: 30)
            report(handler, y: 260, basis: nil)
            #expect(ViewResolver.resolve(source).doubleParams["scrollY"] == 260)
        }
    }
}
