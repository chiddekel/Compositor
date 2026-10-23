import AppKit
import Testing

@MainActor
@Suite(.serialized) struct LayoutDimensionBoundsTests {
    private final class NaturalView: NSView {
        var naturalSize = CGSize(width: 80, height: 20)
        override var intrinsicContentSize: CGSize { naturalSize }
    }

    @Test func requiredBoundsClampIntrinsicSizeAndPreserveCenterAlignment() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let child = NaturalView()
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        let constraints = [child.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
                           child.topAnchor.constraint(equalTo: parent.topAnchor),
                           child.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
                           child.widthAnchor.constraint(lessThanOrEqualToConstant: 140)]
        NSLayoutConstraint.activate(constraints)
        defer { NSLayoutConstraint.deactivate(constraints) }
        parent.layoutSubtreeIfNeeded()
        #expect(child.frame.width == 100 && child.frame.midX == 150)
        child.naturalSize.width = 200
        child.invalidateIntrinsicContentSize()
        parent.layoutSubtreeIfNeeded()
        #expect(child.frame.width == 140 && child.frame.midX == 150)
    }

    @Test func dimensionBoundsUseKnownSiblingDimensionsAndIntersectConstants() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let fixed = NSView(), child = NaturalView()
        for view in [fixed, child] { view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view) }
        child.naturalSize.width = 200
        let constraints = [fixed.widthAnchor.constraint(equalToConstant: 120),
                           child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                           child.topAnchor.constraint(equalTo: parent.topAnchor),
                           child.widthAnchor.constraint(lessThanOrEqualTo: fixed.widthAnchor),
                           child.widthAnchor.constraint(lessThanOrEqualToConstant: 140),
                           child.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
                           child.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)]
        NSLayoutConstraint.activate(constraints)
        defer { NSLayoutConstraint.deactivate(constraints) }
        parent.layoutSubtreeIfNeeded()
        #expect(child.frame.size == CGSize(width: 120, height: 30))
        #expect(child.frame.maxX == 300)
        constraints[3].constant = -20
        parent.layoutSubtreeIfNeeded()
        #expect(child.frame.width == 100 && child.frame.maxX == 300)
    }

    @Test func dimensionBoundsApplyToUnsizedLayoutGuides() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let guide = NSLayoutGuide()
        parent.addLayoutGuide(guide)
        let constraints = [guide.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 10),
                           guide.widthAnchor.constraint(greaterThanOrEqualToConstant: 50),
                           guide.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)]
        NSLayoutConstraint.activate(constraints)
        defer { NSLayoutConstraint.deactivate(constraints) }
        parent.layoutSubtreeIfNeeded()
        #expect(guide.frame.minX == 10 && guide.frame.size == CGSize(width: 50, height: 30))
    }

    @Test func multiplierBoundsWorkWithTheAdjustableDimensionOnEitherSide() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let fixed = NSView(), child = NaturalView()
        for view in [fixed, child] { view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view) }
        let constraints = [fixed.widthAnchor.constraint(equalToConstant: 120),
                           child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                           fixed.widthAnchor.constraint(lessThanOrEqualTo: child.widthAnchor, multiplier: 1.5, constant: -30),
                           child.widthAnchor.constraint(lessThanOrEqualTo: fixed.widthAnchor, multiplier: 1, constant: 10)]
        NSLayoutConstraint.activate(constraints)
        defer { NSLayoutConstraint.deactivate(constraints) }
        parent.layoutSubtreeIfNeeded()
        #expect(child.frame.width == 100 && child.frame.maxX == 300)
        child.naturalSize.width = 200
        child.invalidateIntrinsicContentSize()
        parent.layoutSubtreeIfNeeded()
        #expect(child.frame.width == 130 && child.frame.maxX == 300)
    }
}
