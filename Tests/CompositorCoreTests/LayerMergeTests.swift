// Tests for the portable LayerMerge planning logic. Pin the unchanged macOS
// logic on Linux. Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class LayerMergeTests: XCTestCase {

    private let tf = LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10))
    private func layer(_ id: UUID, name: String = "L", parent: UUID? = nil, isGroup: Bool = false) -> ImageLayer {
        ImageLayer(id: id, asset: nil, name: name, isVisible: true, transform: tf, parentID: parent, isGroup: isGroup)
    }

    // MARK: descendantIDs

    func testDescendantIDsWalksSubtreeExcludingRoot() {
        let group = UUID(), child = UUID(), grandchild = UUID(), other = UUID()
        let layers = [
            layer(group, isGroup: true),
            layer(child, parent: group, isGroup: true),
            layer(grandchild, parent: child),
            layer(other)
        ]
        let desc = LayerMerge.descendantIDs(of: group, in: layers)
        XCTAssertEqual(desc, [child, grandchild])
    }

    func testDescendantIDsEmptyForLeaf() {
        let leaf = UUID()
        let desc = LayerMerge.descendantIDs(of: leaf, in: [layer(leaf)])
        XCTAssertTrue(desc.isEmpty)
    }

    // MARK: mergePlan — nil cases

    func testMergePlanNilWhenActiveMissing() {
        XCTAssertNil(LayerMerge.mergePlan(layers: [layer(UUID())], activeID: UUID(), selectedIDs: []))
    }

    func testMergePlanNilWhenActiveIsBottomLayer() {
        let active = UUID(), other = UUID()
        let layers = [layer(active), layer(other)]
        XCTAssertNil(LayerMerge.mergePlan(layers: layers, activeID: active, selectedIDs: [active]))
    }

    func testMergePlanNilWhenLayerBelowIsGroup() {
        let below = UUID(), active = UUID()
        let layers = [layer(below, isGroup: true), layer(active)]
        XCTAssertNil(LayerMerge.mergePlan(layers: layers, activeID: active, selectedIDs: [active]))
    }

    // MARK: mergePlan — Merge Down

    func testMergePlanMergeDownWithSiblingBelow() {
        let below = UUID(), active = UUID()
        let layers = [layer(below, name: "Bottom"), layer(active, name: "Top")]
        let plan = LayerMerge.mergePlan(layers: layers, activeID: active, selectedIDs: [active])
        XCTAssertEqual(plan?.ids, [below, active])
        XCTAssertEqual(plan?.removed, [below, active])
        XCTAssertEqual(plan?.name, "Bottom")
        XCTAssertNil(plan?.parent)
        XCTAssertEqual(plan?.anchor, active)
        XCTAssertEqual(plan?.action, "Merge Down")
    }

    // MARK: mergePlan — Merge Group

    func testMergePlanMergeGroup() {
        let group = UUID(), child = UUID(), grandchild = UUID()
        let layers = [
            layer(group, name: "Folder", isGroup: true),
            layer(child, parent: group),
            layer(grandchild, parent: group)
        ]
        let plan = LayerMerge.mergePlan(layers: layers, activeID: group, selectedIDs: [group])
        XCTAssertEqual(plan?.ids, [group, child, grandchild])
        XCTAssertEqual(plan?.removed, [group, child, grandchild])
        XCTAssertEqual(plan?.name, "Folder")
        XCTAssertEqual(plan?.anchor, group)
        XCTAssertEqual(plan?.action, "Merge Group")
    }

    func testMergePlanMergeGroupNilWhenEmpty() {
        let group = UUID()
        let layers = [layer(group, isGroup: true)]
        XCTAssertNil(LayerMerge.mergePlan(layers: layers, activeID: group, selectedIDs: [group]))
    }

    // MARK: mergePlan — Merge Layers (multi-select)

    func testMergePlanMergeLayersMultiSelect() {
        let a = UUID(), b = UUID(), c = UUID()
        let layers = [layer(a, name: "A"), layer(b, name: "B"), layer(c, name: "C")]
        // Selecting a and c (skipping b); active is b. The topmost selected is c.
        let plan = LayerMerge.mergePlan(layers: layers, activeID: b, selectedIDs: [a, c])
        XCTAssertEqual(plan?.ids, [a, c])
        XCTAssertEqual(plan?.removed, [a, c])
        XCTAssertEqual(plan?.name, "C")
        XCTAssertEqual(plan?.anchor, c)
        XCTAssertEqual(plan?.action, "Merge Layers")
    }

    func testMergePlanMergeLayersNilWhenAllGroups() {
        let g1 = UUID(), g2 = UUID()
        let layers = [layer(g1, isGroup: true), layer(g2, isGroup: true)]
        XCTAssertNil(LayerMerge.mergePlan(layers: layers, activeID: g1, selectedIDs: [g1, g2]))
    }

    func testMergePlanMergeLayersIncludesDescendantsOfSelected() {
        // Selecting a group pulls its descendants into the merge set.
        let group = UUID(), child = UUID(), other = UUID()
        let layers = [layer(group, isGroup: true), layer(child, parent: group), layer(other)]
        let plan = LayerMerge.mergePlan(layers: layers, activeID: other, selectedIDs: [group, other])
        XCTAssertEqual(plan?.ids, [group, child, other])
        XCTAssertEqual(plan?.removed, [group, child, other])
        XCTAssertEqual(plan?.action, "Merge Layers")
    }
}