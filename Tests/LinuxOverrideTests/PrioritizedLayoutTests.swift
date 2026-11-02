import AppKit
import Testing

@MainActor @Suite(.serialized) struct PrioritizedLayoutTests {
    private final class NaturalView: NSView {
        var natural = CGSize(width: 100, height: 20)
        override var intrinsicContentSize: CGSize { natural }
    }
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
    private func child(in parent: NSView, width: CGFloat = 100) -> NaturalView {
        let view = NaturalView(frame: .zero)
        view.natural.width = width
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        return view
    }
    private func solve(_ parent: NSView, constraints: [NSLayoutConstraint], check: () -> Void) {
        NSLayoutConstraint.activate(constraints)
        defer { NSLayoutConstraint.deactivate(constraints) }
        parent.layoutSubtreeIfNeeded()
        check()
    }

    @Test func positionalBoundsCompressTheSizeBeforeTheDepthTag() {
        let parent = FlippedView(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        let size = child(in: parent, width: 140), tag = child(in: parent, width: 30)
        size.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        solve(parent, constraints: [
            size.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            size.topAnchor.constraint(equalTo: parent.topAnchor),
            size.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor),
            tag.leadingAnchor.constraint(equalTo: size.trailingAnchor, constant: 5),
            tag.topAnchor.constraint(equalTo: parent.topAnchor),
            tag.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor)
        ]) {
            #expect(size.frame == CGRect(x: 0, y: 0, width: 85, height: 20))
            #expect(tag.frame == CGRect(x: 90, y: 0, width: 30, height: 20))
        }
    }

    @Test func higherPriorityPreferencesWinWithoutBreakingRequiredBounds() {
        let parent = FlippedView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let view = child(in: parent)
        let high = view.widthAnchor.constraint(equalToConstant: 70); high.priority = NSLayoutConstraint.Priority(900)
        let low = view.widthAnchor.constraint(equalToConstant: 150); low.priority = .defaultLow
        solve(parent, constraints: [view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor), view.widthAnchor.constraint(greaterThanOrEqualToConstant: 60), high, low]) {
            #expect(view.frame.width == 70)
        }
        let required = view.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
        solve(parent, constraints: [required, high, low]) {
            #expect(view.frame.width == 90)
        }
    }

    @Test func dimensionPrioritiesChangeWhichSiblingGrows() {
        let parent = FlippedView(frame: CGRect(x: 0, y: 0, width: 150, height: 30))
        let first = child(in: parent, width: 50), second = child(in: parent, width: 50)
        first.setContentHuggingPriority(NSLayoutConstraint.Priority(251), for: .horizontal)
        second.setContentHuggingPriority(.defaultLow, for: .horizontal)
        solve(parent, constraints: [first.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            second.leadingAnchor.constraint(equalTo: first.trailingAnchor), second.trailingAnchor.constraint(equalTo: parent.trailingAnchor)]) {
            #expect(first.frame.width == 50)
            #expect(second.frame.width == 100)
        }
        first.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        solve(parent, constraints: [first.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            second.leadingAnchor.constraint(equalTo: first.trailingAnchor), second.trailingAnchor.constraint(equalTo: parent.trailingAnchor)]) {
            #expect(first.frame.width == 100)
            #expect(second.frame.width == 50)
        }
    }

    @Test func negativePositionsAndUnflippedCoordinatesRemainValid() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = child(in: parent, width: 25)
        let preferred = view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: -15)
        preferred.priority = NSLayoutConstraint.Priority(900)
        solve(parent, constraints: [preferred, view.topAnchor.constraint(equalTo: parent.topAnchor, constant: 12),
            view.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor)]) {
            #expect(view.frame == CGRect(x: -15, y: 68, width: 25, height: 20))
        }
    }

    @Test func multipliersAndFractionalConstantsArePreserved() {
        let parent = FlippedView(frame: CGRect(x: 0, y: 0, width: 101, height: 50))
        let view = child(in: parent)
        let width = view.widthAnchor.constraint(equalTo: parent.widthAnchor, multiplier: 0.5, constant: 0.25)
        width.priority = NSLayoutConstraint.Priority(900)
        solve(parent, constraints: [view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), width]) {
            #expect(abs(view.frame.width - 50.75) < 0.00001)
        }
    }

    @Test func prioritySettersRetainEachAxisAndInvalidateTheParent() {
        let parent = NSView(), view = child(in: parent)
        parent.needsLayout = false
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(300), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(800), for: .vertical)
        #expect(parent.needsLayout)
        #expect(view.contentHuggingPriority(for: .horizontal).rawValue == 300)
        #expect(view.contentHuggingPriority(for: .vertical) == .defaultLow)
        #expect(view.contentCompressionResistancePriority(for: .horizontal) == .defaultHigh)
        #expect(view.contentCompressionResistancePriority(for: .vertical).rawValue == 800)
    }
}
