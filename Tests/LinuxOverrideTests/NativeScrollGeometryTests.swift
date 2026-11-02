import AppKit
import SwiftUI
import CoreGraphics
import Testing

@MainActor
@Suite(.serialized) struct NativeScrollGeometryTests {
    private final class Document: NSView {
        var flipped = true
        override var isFlipped: Bool { flipped }
    }
    private final class Probe { var scroll: NSScrollView? }
    private func drag(at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test(arguments: [true, false]) func dragAutoscrollUsesTheViewportAndClampsAtDocumentEdges(flipped: Bool) throws {
        let scroll = NSScrollView(frame: CGRect(x: 40, y: 30, width: 200, height: 120))
        let document = Document(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        document.flipped = flipped
        scroll.documentView = document
        scroll.contentView.scroll(to: CGPoint(x: 70, y: 180))
        let child = NSView(frame: CGRect(x: 10, y: 200, width: 20, height: 20))
        document.addSubview(child)
        func event(_ point: CGPoint) -> NSEvent {
            drag(at: scroll.contentView.convert(point, to: nil))
        }
        #expect(!child.autoscroll(with: event(CGPoint(x: 100, y: 200))))
        #expect(scroll.contentView.bounds.origin == CGPoint(x: 70, y: 180))
        #expect(child.autoscroll(with: event(CGPoint(x: 280, y: 310))))
        #expect(scroll.contentView.bounds.origin == CGPoint(x: 80, y: 190))
        #expect(child.autoscroll(with: event(CGPoint(x: 60, y: 170))))
        #expect(scroll.contentView.bounds.origin == CGPoint(x: 60, y: 170))
        scroll.contentView.scroll(to: CGPoint(x: 200, y: 480))
        #expect(!child.autoscroll(with: event(CGPoint(x: 500, y: 700))))
        scroll.contentView.scroll(to: .zero)
        #expect(!child.autoscroll(with: event(CGPoint(x: -100, y: -100))))
        #expect(!NSView().autoscroll(with: drag(at: .zero)))
    }

    @Test func dragAutoscrollPublishesTheNewOriginForNativeRendering() throws {
        try withLowering("nativeDragAutoscroll") {
            let probe = Probe()
            let source = Scroll(probe: probe)
            _ = ViewResolver.resolve(source)
            let scroll = try #require(probe.scroll)
            let document = try #require(scroll.documentView)
            let point = scroll.contentView.convert(CGPoint(x: 100, y: 130), to: nil)
            #expect(document.autoscroll(with: drag(at: point)))
            #expect(ViewResolver.resolve(source).doubleParams["scrollY"] == 10)
        }
    }
    private struct Scroll: @preconcurrency NSViewRepresentable {
        var probe: Probe
        var flipped = true
        var viewport = CGSize(width: 200, height: 120)
        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView(frame: CGRect(origin: .zero, size: viewport))
            let document = Document(frame: CGRect(x: 0, y: 0, width: 200, height: 600))
            document.flipped = flipped
            scroll.documentView = document
            scroll.hasVerticalScroller = true
            probe.scroll = scroll
            return scroll
        }
        func updateNSView(_ view: NSScrollView, context: Context) {}
    }
    @Test(arguments: [true, false]) func liveOffsetQueryReadsCurrentDocumentWithoutResolving(flipped: Bool) throws {
        try withLowering("nativeLiveOffset") {
            let probe = Probe()
            let node = ViewResolver.resolve(Scroll(probe: probe, flipped: flipped))
            let query = try #require(node.handlers["scrollOffset"])
            let scroll = try #require(probe.scroll)
            let document = try #require(scroll.documentView)
            document.frame = CGRect(x: 30, y: 40, width: 500, height: 800)
            scroll.contentView.scroll(to: CGPoint(x: 100, y: 220))
            let first = NativeScrollOffsetBox(); query(first)
            #expect(first.offset == CGPoint(x: 70, y: flipped ? 180 : 500))
            document.setFrameSize(CGSize(width: 500, height: 1000))
            scroll.contentView.scroll(to: CGPoint(x: 130, y: 300))
            let second = NativeScrollOffsetBox(); query(second)
            #expect(second.offset == CGPoint(x: 100, y: flipped ? 260 : 620))
            scroll.documentView = nil
            let removed = NativeScrollOffsetBox(); query(removed)
            #expect(removed.offset == nil)
        }
    }
    private struct HostedScroll: @preconcurrency NSViewRepresentable {
        var probe: Probe
        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
            scroll.documentView = NSHostingView(rootView: VStack(spacing: 8) {
                Text("First").frame(width: 200, height: 300)
                Spacer(minLength: 0)
                Text("Last").frame(width: 200, height: 300)
            })
            probe.scroll = scroll
            return scroll
        }
        func updateNSView(_ view: NSScrollView, context: Context) {
            view.documentView?.setFrameSize(CGSize(width: 200, height: 240))
        }
    }
    private func withLowering(_ scope: String, body: () throws -> Void) throws {
        let previous = NativeLowering.isActive
        try #require(StateStore.begin(scope: scope))
        NativeLowering.isActive = true
        defer { StateStore.end(); NativeLowering.discard(scope: scope); NativeLowering.isActive = previous }
        try body()
    }

    @Test func programmaticScrollPositionReachesTheRenderedNode() throws {
        try withLowering("nativeScrollPosition") {
            let probe = Probe()
            let view = Scroll(probe: probe)
            _ = ViewResolver.resolve(view)
            let scroll = try #require(probe.scroll)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 240))
            let node = ViewResolver.resolve(view)
            #expect(node.doubleParams["scrollX"] == 0)
            #expect(node.doubleParams["scrollY"] == 240)
        }
    }

    @Test func hostGeometryUpdatesViewportAndManualScrollPosition() throws {
        try withLowering("nativeScrollGeometry") {
            let probe = Probe()
            let source = Scroll(probe: probe)
            let node = ViewResolver.resolve(source)
            let geometry = try #require(node.handlers["scrollGeometry"])
            geometry(["width": 180.0, "height": 100.0, "documentWidth": 200.0, "documentHeight": 600.0,
                      "x": 0.0, "y": 260.0])
            let scroll = try #require(probe.scroll)
            #expect(scroll.frame.size == CGSize(width: 180, height: 100))
            #expect(scroll.contentView.bounds == CGRect(x: 0, y: 260, width: 180, height: 100))
            #expect(ViewResolver.resolve(source).doubleParams["scrollY"] == 260)
        }
    }

    @Test func drawingTheDocumentDoesNotExpandOrResetItsViewport() throws {
        try withLowering("nativeScrollDrawing") {
            let probe = Probe()
            let node = ViewResolver.resolve(Scroll(probe: probe))
            let scroll = try #require(probe.scroll)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 240))
            let document = try #require(node.children.first)
            let draw = try #require(document.handlers["draw"])
            let context = try #require(CGContext(data: nil, width: 200, height: 600, bitsPerComponent: 8,
                bytesPerRow: 800, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            draw(GraphicsContextBox(context: GraphicsContext(cgContext: context), size: CGSize(width: 200, height: 600)))
            #expect(scroll.frame.size == CGSize(width: 200, height: 120))
            #expect(scroll.contentView.bounds == CGRect(x: 0, y: 240, width: 200, height: 120))
        }
    }

    @Test func hostTopLeftScrollCoordinatesConvertForAnUnflippedDocument() throws {
        try withLowering("nativeScrollUnflipped") {
            let probe = Probe()
            let source = Scroll(probe: probe, flipped: false)
            let node = ViewResolver.resolve(source)
            let geometry = try #require(node.handlers["scrollGeometry"])
            geometry(["width": 200.0, "height": 120.0, "documentWidth": 200.0, "documentHeight": 600.0,
                      "x": 0.0, "y": 90.0])
            let scroll = try #require(probe.scroll)
            #expect(scroll.contentView.bounds.minY == 390)
            #expect(ViewResolver.resolve(source).doubleParams["scrollY"] == 90)
        }
    }

    @Test func aRevealBeforeTheFirstViewportIsPreserved() throws {
        try withLowering("nativeScrollDeferredReveal") {
            let probe = Probe()
            let source = Scroll(probe: probe, viewport: .zero)
            let node = ViewResolver.resolve(source)
            let scroll = try #require(probe.scroll)
            scroll.documentView?.scrollToVisible(CGRect(x: 0, y: 500, width: 100, height: 54))
            let geometry = try #require(node.handlers["scrollGeometry"])
            geometry(["width": 200.0, "height": 120.0, "documentWidth": 200.0, "documentHeight": 600.0,
                      "x": 0.0, "y": 0.0])
            #expect(scroll.contentView.bounds.minY == 434)
            #expect(ViewResolver.resolve(source).doubleParams["scrollY"] == 434)
        }
    }

    @Test func renderedHostingDocumentSizeSurvivesAnUpstreamFittingFallback() throws {
        try withLowering("nativeScrollHostedDocument") {
            let probe = Probe()
            let source = HostedScroll(probe: probe)
            let node = ViewResolver.resolve(source)
            let geometry = try #require(node.handlers["scrollGeometry"])
            geometry(["width": 200.0, "height": 120.0, "documentWidth": 200.0, "documentHeight": 616.0,
                      "x": 0.0, "y": 90.0])
            let updated = ViewResolver.resolve(source)
            #expect(probe.scroll?.documentView?.frame.height == 616)
            #expect(updated.doubleParams["scrollY"] == 90)
        }
    }
}
