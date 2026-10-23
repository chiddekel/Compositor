import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized) struct HostingMeasurementTests {
    private final class NaturalView: NSView {
        var naturalSize = CGSize.zero
        override var intrinsicContentSize: CGSize { naturalSize }
    }
    private struct Native: @preconcurrency NSViewRepresentable {
        var size: CGSize
        func makeNSView(context: Context) -> NaturalView { NaturalView(frame: .zero) }
        func updateNSView(_ view: NaturalView, context: Context) { view.naturalSize = size }
    }
    private final class SizingProbe {
        var makes = 0
        weak var view: NaturalView?
        var proposals: [ProposedViewSize] = []
        var coordinators: [ObjectIdentifier] = []
    }
    private struct MeasuredNative: @preconcurrency NSViewRepresentable {
        var value: CGFloat
        var probe: SizingProbe
        func makeCoordinator() -> SizingProbe { probe }
        func makeNSView(context: Context) -> NaturalView {
            probe.makes += 1
            let view = NaturalView(frame: .zero)
            probe.view = view
            return view
        }
        func updateNSView(_ view: NaturalView, context: Context) {
            view.naturalSize = CGSize(width: value, height: 10)
        }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NaturalView, context: Context) -> CGSize? {
            probe.proposals.append(proposal)
            probe.coordinators.append(ObjectIdentifier(context.coordinator))
            let width = proposal.width ?? nsView.naturalSize.width
            return CGSize(width: width, height: width / 2)
        }
    }
    private struct HeightMeasuredNative: @preconcurrency NSViewRepresentable {
        var probe: SizingProbe
        func makeNSView(context: Context) -> NaturalView { NaturalView(frame: .zero) }
        func updateNSView(_ view: NaturalView, context: Context) { view.naturalSize = CGSize(width: 80, height: 160) }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NaturalView, context: Context) -> CGSize? {
            probe.proposals.append(proposal)
            let height = proposal.height ?? nsView.naturalSize.height
            return CGSize(width: height / 2, height: height)
        }
    }
    private struct InvalidNative: @preconcurrency NSViewRepresentable {
        var response: CGSize
        func makeNSView(context: Context) -> NaturalView { NaturalView(frame: .zero) }
        func updateNSView(_ view: NaturalView, context: Context) { view.naturalSize = CGSize(width: 78, height: 29) }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NaturalView, context: Context) -> CGSize? { response }
    }
    private struct LoweredHosting: @preconcurrency NSViewRepresentable {
        var minimum: CGFloat
        var maximum: CGFloat
        var options: NSHostingSizingOptions
        func makeNSView(context: Context) -> NSHostingView<AnyView> { NSHostingView(rootView: AnyView(EmptyView())) }
        func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
            view.rootView = AnyView(Text("Bounds").frame(minWidth: minimum, maxWidth: maximum))
            view.sizingOptions = options
        }
    }

    @Test func nativeLoweringForwardsEnabledHostingBoundsAndRootChanges() throws {
        let scope = "loweredHostingBounds"
        let active = NativeLowering.isActive
        try #require(StateStore.begin(scope: scope))
        NativeLowering.isActive = true
        defer { StateStore.end(); NativeLowering.discard(scope: scope); NativeLowering.isActive = active }
        func frames(_ node: RenderNode) -> [(Double?, Double?, Double?, Double?)] {
            node.modifiers.compactMap { modifier in
                if case let .frame(_, _, minWidth, minHeight, maxWidth, maxHeight, _) = modifier {
                    return (minWidth, minHeight, maxWidth, maxHeight)
                }
                return nil
            }
        }
        let source = LoweredHosting(minimum: 80, maximum: 200, options: [.minSize, .maxSize])
        let initial = frames(ViewResolver.resolve(source))
        #expect(initial.count == 2)
        let bounds = try #require(initial.last)
        #expect(bounds.0 == 80 && bounds.2 == 200)
        let changed = frames(ViewResolver.resolve(LoweredHosting(minimum: 120, maximum: .infinity, options: .minSize)))
        let minimum = try #require(changed.last)
        #expect(minimum.0 == 120 && minimum.2 == nil)
        let disabled = frames(ViewResolver.resolve(LoweredHosting(minimum: 120, maximum: .infinity, options: [])))
        #expect(disabled.count == 1)
    }

    @Test func sizingOptionsControlIntrinsicSizeWithoutChangingFittingSize() {
        #expect(NSHostingSizingOptions.standardBounds == [.minSize, .intrinsicContentSize, .maxSize])
        let host = NSHostingView(rootView: Text("Panel").frame(width: 80, height: 24).padding(4))
        #expect(host.intrinsicContentSize == CGSize(width: 88, height: 32))
        host.sizingOptions = []
        #expect(host.intrinsicContentSize == CGSize(width: -1, height: -1))
        #expect(host.fittingSize == CGSize(width: 88, height: 32))
        host.sizingOptions = .intrinsicContentSize
        #expect(host.intrinsicContentSize == CGSize(width: 88, height: 32))
    }

    @Test func intrinsicSizingPreservesAnUnknownAxisAndIgnoresTheHostFrame() {
        let host = NSHostingView(rootView: Text("Headless label").frame(width: 210))
        #expect(host.intrinsicContentSize == CGSize(width: 210, height: -1))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        #expect(host.intrinsicContentSize == CGSize(width: 210, height: -1))
        #expect(host.fittingSize == CGSize(width: 320, height: 240))
    }

    @Test func rootUpdatesInvalidateTheContainingAutoLayout() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let host = NSHostingView(rootView: Text("Panel").frame(width: 80, height: 24))
        host.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(host)
        let constraints = [host.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                           host.topAnchor.constraint(equalTo: parent.topAnchor)]
        NSLayoutConstraint.activate(constraints)
        defer { NSLayoutConstraint.deactivate(constraints) }
        parent.layoutSubtreeIfNeeded()
        #expect(host.frame.size == CGSize(width: 80, height: 24))
        host.rootView = Text("Updated").frame(width: 140, height: 48)
        #expect(parent.needsLayout)
        parent.layoutSubtreeIfNeeded()
        #expect(host.frame.size == CGSize(width: 140, height: 48))
    }

    @Test func intrinsicInvalidationRecalculatesNativeChildBounds() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let child = NaturalView()
        child.translatesAutoresizingMaskIntoConstraints = false
        child.naturalSize = CGSize(width: 80, height: 24)
        parent.addSubview(child)
        let constraints = [child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                           child.topAnchor.constraint(equalTo: parent.topAnchor)]
        NSLayoutConstraint.activate(constraints)
        defer { NSLayoutConstraint.deactivate(constraints) }
        parent.layoutSubtreeIfNeeded()
        #expect(child.frame.size == CGSize(width: 80, height: 24))
        child.naturalSize = CGSize(width: 140, height: 48)
        child.invalidateIntrinsicContentSize()
        #expect(parent.needsLayout)
        parent.layoutSubtreeIfNeeded()
        #expect(child.frame.size == CGSize(width: 140, height: 48))
    }

    @Test func hostingOptionsGenerateAndRemoveRequiredSizeBounds() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let probe = SizingProbe()
        let host = NSHostingView(rootView: MeasuredNative(value: 150, probe: probe)
            .frame(minWidth: 80, maxWidth: 200, minHeight: 10, maxHeight: 120))
        host.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(host)
        let placement = [host.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                         host.topAnchor.constraint(equalTo: parent.topAnchor)]
        NSLayoutConstraint.activate(placement)
        defer { NSLayoutConstraint.deactivate(placement + host.constraints.filter { $0.identifier?.hasPrefix("compositor.hosting.") == true }) }
        func limits() -> [String: CGFloat] {
            Dictionary(uniqueKeysWithValues: host.constraints.compactMap { constraint in
                guard let id = constraint.identifier, id.hasPrefix("compositor.hosting.") else { return nil }
                return (id, constraint.constant)
            })
        }
        parent.layoutSubtreeIfNeeded()
        #expect(limits() == ["compositor.hosting.min.width": 80, "compositor.hosting.max.width": 200,
                             "compositor.hosting.min.height": 10, "compositor.hosting.max.height": 120])
        #expect(host.frame.size == CGSize(width: 150, height: 75))
        host.sizingOptions = .minSize
        parent.layoutSubtreeIfNeeded()
        #expect(limits() == ["compositor.hosting.min.width": 80, "compositor.hosting.min.height": 10])
        host.sizingOptions = []
        parent.layoutSubtreeIfNeeded()
        #expect(limits().isEmpty)
        #expect(probe.makes == 1)
    }

    @Test func generatedBoundsFollowRootUpdatesAndDoNotBoundAnUnboundedAxis() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let host = NSHostingView(rootView: Text("Headless label").frame(minWidth: 80, maxWidth: 200))
        host.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(host)
        let placement = [host.leadingAnchor.constraint(equalTo: parent.leadingAnchor)]
        NSLayoutConstraint.activate(placement)
        defer { NSLayoutConstraint.deactivate(placement + host.constraints.filter { $0.identifier?.hasPrefix("compositor.hosting.") == true }) }
        parent.layoutSubtreeIfNeeded()
        #expect(host.constraints.first { $0.identifier == "compositor.hosting.min.width" }?.constant == 80)
        #expect(host.constraints.first { $0.identifier == "compositor.hosting.max.width" }?.constant == 200)
        #expect(host.frame.width == 80)
        host.rootView = Text("Updated").frame(minWidth: 120, maxWidth: .infinity)
        parent.layoutSubtreeIfNeeded()
        #expect(host.constraints.first { $0.identifier == "compositor.hosting.min.width" }?.constant == 120)
        #expect(!host.constraints.contains { $0.identifier == "compositor.hosting.max.width" })
        #expect(host.frame.width == 120)
        host.translatesAutoresizingMaskIntoConstraints = true
        parent.layoutSubtreeIfNeeded()
        #expect(!host.constraints.contains { $0.identifier?.hasPrefix("compositor.hosting.") == true })
    }

    @Test func infiniteMaximumResponseDoesNotCapAFlexibleRepresentableAtItsIdealSize() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let probe = SizingProbe()
        let host = NSHostingView(rootView: MeasuredNative(value: 150, probe: probe))
        host.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(host)
        let placement = [host.leadingAnchor.constraint(equalTo: parent.leadingAnchor)]
        NSLayoutConstraint.activate(placement)
        defer { NSLayoutConstraint.deactivate(placement + host.constraints.filter { $0.identifier?.hasPrefix("compositor.hosting.") == true }) }
        parent.layoutSubtreeIfNeeded()
        #expect(!host.constraints.contains { $0.identifier?.hasPrefix("compositor.hosting.max.") == true })
        #expect(host.intrinsicContentSize == CGSize(width: 150, height: 75))
        #expect(probe.proposals.contains(.infinity))
        #expect(probe.makes == 1)
    }

    @Test func windowContentSizesFollowHostingBoundsAndRootUpdates() {
        let host = NSHostingView(rootView: Text("Window").frame(minWidth: 80, maxWidth: 200, minHeight: 30, maxHeight: 100))
        let window = NSWindow(contentRect: CGRect(x: 10, y: 20, width: 150, height: 60),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(CGSize(width: 500, height: 200))
        #expect(window.frame.size == CGSize(width: 200, height: 100))
        #expect(host.frame.size == window.frame.size)
        host.rootView = Text("Updated").frame(minWidth: 120, maxWidth: 240, minHeight: 40, maxHeight: 120)
        window.setContentSize(CGSize(width: 20, height: 10))
        #expect(window.frame.size == CGSize(width: 120, height: 40))
        #expect(window.frame.origin == CGPoint(x: 10, y: 20))
        #expect(host.frame.size == window.frame.size)
    }

    @Test func emptyWindowHostingOptionsLeaveExplicitSizingAvailable() {
        let host = NSHostingView(rootView: Text("Window").frame(width: 80, height: 24))
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(CGSize(width: 300, height: 200))
        #expect(window.frame.size == CGSize(width: 80, height: 24))
        host.sizingOptions = []
        window.setContentSize(CGSize(width: 300, height: 200))
        #expect(window.frame.size == CGSize(width: 300, height: 200))
        #expect(host.fittingSize == CGSize(width: 80, height: 24))
    }

    @Test func replacingOrMovingWindowContentClearsTheOldWindowAndItsBounds() {
        let first = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Text("Window").frame(width: 80, height: 24))
        first.contentView = host
        second.contentView = host
        #expect(first.contentView == nil)
        #expect(host.window === second)
        first.setContentSize(CGSize(width: 300, height: 200))
        #expect(first.frame.size == CGSize(width: 300, height: 200))
        second.setContentSize(CGSize(width: 300, height: 200))
        #expect(second.frame.size == CGSize(width: 80, height: 24))
        second.contentView = NSView()
        #expect(host.window == nil)
        second.setContentSize(CGSize(width: 300, height: 200))
        #expect(second.frame.size == CGSize(width: 300, height: 200))
    }

    @Test func explicitWindowFrameBypassesContentLimitsAndStillFillsTheContentView() {
        let host = NSHostingView(rootView: Text("Window").frame(width: 80, height: 24))
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrame(CGRect(x: 10, y: 20, width: 300, height: 200), display: false)
        #expect(window.frame.size == CGSize(width: 300, height: 200))
        #expect(host.frame.size == window.frame.size)
    }

    @Test func windowHostingPreservesUnknownAxesAndRestoresExplicitLimits() {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.contentMinSize = CGSize(width: 100, height: 40)
        window.contentMaxSize = CGSize(width: 500, height: 300)
        let host = NSHostingView(rootView: Text("Headless label").frame(minWidth: 80, maxWidth: 200))
        window.contentView = host
        #expect(window.contentMinSize == CGSize(width: 80, height: 40))
        #expect(window.contentMaxSize == CGSize(width: 200, height: 300))
        host.rootView = Text("Updated").frame(minWidth: 120, maxWidth: .infinity)
        #expect(window.contentMinSize == CGSize(width: 120, height: 40))
        #expect(window.contentMaxSize.width > 1_000_000 && window.contentMaxSize.height == 300)
        host.sizingOptions = []
        #expect(window.contentMinSize == CGSize(width: 100, height: 40))
        #expect(window.contentMaxSize == CGSize(width: 500, height: 300))
        window.setContentSize(CGSize(width: 900, height: 500))
        #expect(window.frame.size == CGSize(width: 500, height: 300))
    }

    @Test func explicitFramesAndPaddingDeterminePanelBounds() {
        let host = NSHostingView(rootView: Text("Panel").frame(width: 280, height: 140).padding(12))
        #expect(host.fittingSize == CGSize(width: 304, height: 164))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(host.fittingSize == CGSize(width: 304, height: 164))
    }

    @Test func nativeSizesFollowRootUpdatesWithoutRemakingTheView() {
        let host = NSHostingView(rootView: Native(size: CGSize(width: 92, height: 26)).padding(4))
        #expect(host.fittingSize == CGSize(width: 100, height: 34))
        let original = host.subviews.first
        host.rootView = Native(size: CGSize(width: 136, height: 38)).padding(4)
        #expect(host.fittingSize == CGSize(width: 144, height: 46))
        #expect(host.subviews.first === original)
    }

    @Test func stacksIncludeSpacingAndNativeContent() {
        let host = NSHostingView(rootView: VStack(spacing: 7) {
            Native(size: CGSize(width: 90, height: 24))
            Native(size: CGSize(width: 130, height: 32))
        }.padding(10))
        #expect(host.fittingSize == CGSize(width: 150, height: 83))
    }

    @Test func constrainedHorizontalStackSharesWidthBeforeMeasuringHeight() {
        let left = SizingProbe(), right = SizingProbe()
        let host = NSHostingView(rootView: HStack(spacing: 12) {
            MeasuredNative(value: 160, probe: left)
            MeasuredNative(value: 160, probe: right)
        }.frame(width: 300))
        #expect(host.fittingSize == CGSize(width: 300, height: 72))
        #expect(left.proposals.last == ProposedViewSize(width: 144, height: nil))
        #expect(right.proposals.last == ProposedViewSize(width: 144, height: nil))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 72)
        #expect(host.subviews.count == 2)
        #expect(host.subviews.allSatisfy { $0.frame.size == CGSize(width: 144, height: 72) })
        #expect(left.makes == 1 && right.makes == 1)
    }

    @Test func constrainedStackReservesFixedChildrenAndHonorsPriority() {
        let high = SizingProbe(), low = SizingProbe()
        let host = NSHostingView(rootView: HStack(spacing: 10) {
            Native(size: CGSize(width: 60, height: 20)).frame(width: 60)
            MeasuredNative(value: 160, probe: high).layoutPriority(1)
            MeasuredNative(value: 160, probe: low)
        }.frame(width: 300))
        #expect(host.fittingSize == CGSize(width: 300, height: 110))
        #expect(high.proposals.last == ProposedViewSize(width: 220, height: nil))
        #expect(low.proposals.last == ProposedViewSize(width: 0, height: nil))
    }

    @Test func constrainedStackKeepsFixedSizeChildrenAtTheirIdealWidth() {
        let fixed = SizingProbe(), flexible = SizingProbe()
        let host = NSHostingView(rootView: HStack(spacing: 12) {
            MeasuredNative(value: 160, probe: fixed).fixedSize()
            MeasuredNative(value: 160, probe: flexible)
        }.frame(width: 300).padding(6))
        #expect(host.fittingSize == CGSize(width: 312, height: 92))
        #expect(fixed.proposals.last == .unspecified)
        #expect(flexible.proposals.last == ProposedViewSize(width: 128, height: nil))
    }

    @Test func constrainedVerticalStackSharesHeightBeforeMeasuringWidth() {
        let top = SizingProbe(), bottom = SizingProbe()
        let host = NSHostingView(rootView: VStack(spacing: 12) {
            HeightMeasuredNative(probe: top)
            HeightMeasuredNative(probe: bottom)
        }.frame(height: 300))
        #expect(host.fittingSize == CGSize(width: 72, height: 300))
        #expect(top.proposals.last == ProposedViewSize(width: nil, height: 144))
        #expect(bottom.proposals.last == ProposedViewSize(width: nil, height: 144))
        host.frame = CGRect(x: 0, y: 0, width: 72, height: 300)
        #expect(host.subviews.count == 2)
        #expect(host.subviews.allSatisfy { $0.frame.size == CGSize(width: 72, height: 144) })
    }

    @Test func constrainedNestedStacksReserveTheirMeasuredMinimum() {
        let flexible = SizingProbe()
        let host = NSHostingView(rootView: HStack(spacing: 12) {
            VStack(spacing: 12) {
                Native(size: CGSize(width: 80, height: 24)).frame(width: 80, height: 24)
                Native(size: CGSize(width: 80, height: 24)).frame(width: 80, height: 24)
            }
            MeasuredNative(value: 160, probe: flexible)
        }.frame(width: 240))
        #expect(host.fittingSize == CGSize(width: 240, height: 74))
        #expect(flexible.proposals.last == ProposedViewSize(width: 148, height: nil))
    }

    @Test func constrainedStackWithUnknownLeafRetainsUnknownBounds() {
        let host = NSHostingView(rootView: HStack {
            Text("Renderer-owned label")
            Native(size: CGSize(width: 80, height: 24))
        }.frame(width: 300))
        #expect(host.fittingSize == CGSize(width: 320, height: 240))
    }

    @Test func anEmptyStackHasOnlyItsExplicitPadding() {
        let host = NSHostingView(rootView: HStack {}.padding(8))
        #expect(host.fittingSize == CGSize(width: 16, height: 16))
    }

    @Test func aFixedAxisCanSupplyMissingNativeIntrinsicSize() {
        let host = NSHostingView(rootView: Native(size: CGSize(width: NSView.noIntrinsicMetric, height: 28)).frame(width: 210))
        #expect(host.fittingSize == CGSize(width: 210, height: 28))
    }

    @Test func loweringStateIsRestoredAndSizingDoesNotDispatchActions() {
        let previous = NativeLowering.isActive
        NativeLowering.isActive = true
        defer { NativeLowering.isActive = previous }
        var clicks = 0
        let host = NSHostingView(rootView: Button("Apply") { clicks += 1 }.frame(width: 160, height: 32))
        #expect(host.fittingSize == CGSize(width: 160, height: 32))
        #expect(NativeLowering.isActive)
        #expect(clicks == 0)
    }

    @Test func unknownLeavesKeepFallbackInsteadOfCollapsingToPadding() {
        let host = NSHostingView(rootView: Text("Unmeasured").padding(12))
        #expect(host.fittingSize == CGSize(width: 320, height: 240))
    }

    @Test func controlChromeIsNotMistakenForItsLabelBounds() {
        let host = NSHostingView(rootView: Button(action: {}) {
            Text("Apply").frame(width: 100, height: 24)
        })
        #expect(host.fittingSize == CGSize(width: 320, height: 240))
    }

    @Test func upstreamFloatingPanelUsesMeasuredContentAndKeepsItsPosition() throws {
        let controller = FloatingPanelController(name: "testMeasuredHostingPanel")
        defer { controller.close() }
        controller.show(title: "Measured", content: Text("Panel").frame(width: 280, height: 140).padding(12))
        let panel = try #require(NSApp.windows.first { $0.identifier == controller.identifier })
        #expect(panel.contentView?.bounds.size == CGSize(width: 304, height: 164))
        panel.setFrameTopLeftPoint(NSPoint(x: 40, y: 500))
        let parked = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        controller.show(title: "Updated", content: Text("Panel").frame(width: 420, height: 200))
        #expect(panel.contentView?.bounds.size == CGSize(width: 420, height: 200))
        #expect(NSPoint(x: panel.frame.minX, y: panel.frame.maxY) == parked)
    }

    @Test func customSizingReceivesProposalsAndTheExistingCoordinator() {
        let probe = SizingProbe()
        let host = NSHostingView(rootView: MeasuredNative(value: 160, probe: probe).frame(width: 80))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        #expect(host.subviews.first?.frame.size == CGSize(width: 80, height: 40))
        #expect(host.fittingSize == CGSize(width: 80, height: 40))
        #expect(probe.proposals.last == ProposedViewSize(width: 80, height: nil))
        let original = host.subviews.first
        host.rootView = MeasuredNative(value: 90, probe: probe).frame(width: nil)
        #expect(host.fittingSize == CGSize(width: 90, height: 45))
        #expect(host.subviews.first === original && probe.makes == 1)
        #expect(probe.coordinators.allSatisfy { $0 == ObjectIdentifier(probe) })
    }

    @Test func fixedSizeProposesAnUnspecifiedAxisToCustomSizing() {
        let probe = SizingProbe()
        let host = NSHostingView(rootView: MeasuredNative(value: 160, probe: probe).fixedSize().frame(width: 80))
        #expect(host.fittingSize == CGSize(width: 80, height: 80))
        #expect(probe.proposals.last == .unspecified)
    }

    @Test func fixedSizeRemainsUnspecifiedThroughPaddingDuringPlacement() {
        let probe = SizingProbe()
        let host = NSHostingView(rootView: MeasuredNative(value: 160, probe: probe).padding(8).fixedSize().frame(width: 80))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 160)
        #expect(host.subviews.first?.frame.size == CGSize(width: 160, height: 80))
        #expect(host.fittingSize == CGSize(width: 80, height: 96))
        #expect(probe.proposals.last == .unspecified)
    }

    @Test func invalidCustomSizesFallBackToNativeIntrinsicBounds() {
        for size in [CGSize(width: CGFloat.infinity, height: 24), CGSize(width: 78, height: CGFloat.nan), CGSize(width: -1, height: 24)] {
            let host = NSHostingView(rootView: InvalidNative(response: size))
            #expect(host.fittingSize == CGSize(width: 78, height: 29))
            #expect(host.subviews.first?.frame.width.isFinite == true)
        }
    }

    @Test func upstreamCameraRawSizingIsUsedInHostingAndLowering() {
        var changes = 0
        let slider = CameraRawSlider(value: 0, range: -100...100, track: .temperature, help: "Temperature",
                                     onChange: { _ in changes += 1 }, onReset: { changes += 1 })
        let host = NSHostingView(rootView: slider.frame(width: 210))
        #expect(host.fittingSize == CGSize(width: 210, height: 22))
        let previous = NativeLowering.isActive
        NativeLowering.isActive = true
        defer { NativeLowering.isActive = previous }
        let node = ViewResolver.resolve(slider)
        #expect(node.modifiers.contains { modifier in
            if case let .frame(_, height, _, _, _, _, _) = modifier { return height == 22 }
            return false
        })
        #expect(changes == 0)
    }

    @Test func loweringDoesNotOverwriteAnAlreadyPlacedNativeWidth() throws {
        let previous = NativeLowering.isActive
        NativeLowering.isActive = true
        defer { NativeLowering.isActive = previous }
        let probe = SizingProbe()
        let source = MeasuredNative(value: 160, probe: probe)
        _ = ViewResolver.resolve(source)
        let view = try #require(probe.view)
        #expect(view.frame.size == CGSize(width: 160, height: 80))
        view.frame = CGRect(x: 0, y: 0, width: 240, height: 80)
        _ = ViewResolver.resolve(source)
        #expect(view.frame.width == 240 && probe.makes == 1)
    }
}
