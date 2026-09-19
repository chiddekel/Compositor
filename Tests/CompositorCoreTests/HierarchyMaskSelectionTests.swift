// Tests for the portable layer-hierarchy, live-mask graph, floating-selection
// transform, and selection copy-region logic. Pin the unchanged macOS logic on
// Linux. Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class HierarchyMaskSelectionTests: XCTestCase {

    // MARK: LayerHierarchy.entries

    func testHierarchyEntriesDepthAndOrder() {
        let root = UUID(), child = UUID(), grandchild = UUID()
        let layers = [
            ProjectLayerRecord(id: root, name: "Root", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
                               imageFile: nil, isGroup: true),
            ProjectLayerRecord(id: child, name: "Child", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
                               imageFile: nil, parentID: root, isGroup: true),
            ProjectLayerRecord(id: grandchild, name: "Grand", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
                               imageFile: "grand.png", parentID: child)
        ]
        let entries = LayerHierarchy.entries(layers)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].layer.id, root); XCTAssertEqual(entries[0].depth, 0); XCTAssertTrue(entries[0].visible)
        XCTAssertEqual(entries[1].layer.id, child); XCTAssertEqual(entries[1].depth, 1)
        XCTAssertEqual(entries[2].layer.id, grandchild); XCTAssertEqual(entries[2].depth, 2)
    }

    func testHierarchyEntriesTopFirstReversesSiblings() {
        let root = UUID()
        let a = UUID(), b = UUID()
        let layers = [
            ProjectLayerRecord(id: root, name: "R", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: nil, isGroup: true),
            ProjectLayerRecord(id: a, name: "A", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "a.png", parentID: root),
            ProjectLayerRecord(id: b, name: "B", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "b.png", parentID: root)
        ]
        let bottomUp = LayerHierarchy.entries(layers).map(\.layer.id)
        XCTAssertEqual(bottomUp, [root, a, b])
        let topFirst = LayerHierarchy.entries(layers, topFirst: true).map(\.layer.id)
        XCTAssertEqual(topFirst, [root, b, a])
    }

    func testHierarchyEntriesCollapsedSkipsSubtree() {
        let root = UUID(), child = UUID()
        let layers = [
            ProjectLayerRecord(id: root, name: "R", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: nil, isGroup: true),
            ProjectLayerRecord(id: child, name: "C", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "c.png", parentID: root)
        ]
        let entries = LayerHierarchy.entries(layers, collapsed: [root])
        XCTAssertEqual(entries.map(\.layer.id), [root])
    }

    func testHierarchyEntriesHiddenParentHidesChildren() {
        let root = UUID(), child = UUID()
        let layers = [
            ProjectLayerRecord(id: root, name: "R", isVisible: false,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: nil, isGroup: true),
            ProjectLayerRecord(id: child, name: "C", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "c.png", parentID: root)
        ]
        let entries = LayerHierarchy.entries(layers)
        XCTAssertFalse(entries[0].visible)
        XCTAssertFalse(entries[1].visible) // inherits hidden from parent
    }

    // MARK: LayerHierarchy.visibleLayers

    func testHierarchyVisibleLayersExcludesGroupsAndHidden() {
        let root = UUID(), a = UUID(), b = UUID()
        let layers = [
            ProjectLayerRecord(id: root, name: "R", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: nil, isGroup: true),
            ProjectLayerRecord(id: a, name: "A", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "a.png", parentID: root),
            ProjectLayerRecord(id: b, name: "B", isVisible: false,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "b.png", parentID: root)
        ]
        let visible = LayerHierarchy.visibleLayers(layers).map(\.id)
        XCTAssertEqual(visible, [a])
    }

    // MARK: LayerHierarchy.validate

    func testHierarchyValidateDuplicateIDThrows() {
        let id = UUID()
        let layers = [
            ProjectLayerRecord(id: id, name: "A", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: "a.png"),
            ProjectLayerRecord(id: id, name: "A2", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: "a2.png")
        ]
        XCTAssertThrowsError(try LayerHierarchy.validate(layers))
    }

    func testHierarchyValidateGroupWithImageThrows() {
        let id = UUID()
        let layers = [
            ProjectLayerRecord(id: id, name: "G", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "has-image.png", isGroup: true)
        ]
        XCTAssertThrowsError(try LayerHierarchy.validate(layers))
    }

    func testHierarchyValidateCycleThrows() {
        let a = UUID(), b = UUID()
        let layers = [
            ProjectLayerRecord(id: a, name: "A", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: nil, parentID: b, isGroup: true),
            ProjectLayerRecord(id: b, name: "B", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: nil, parentID: a, isGroup: true)
        ]
        XCTAssertThrowsError(try LayerHierarchy.validate(layers))
    }

    func testHierarchyValidateParentNotGroupThrows() {
        let parent = UUID(), child = UUID()
        let layers = [
            ProjectLayerRecord(id: parent, name: "P", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: "p.png"),
            ProjectLayerRecord(id: child, name: "C", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "c.png", parentID: parent)
        ]
        XCTAssertThrowsError(try LayerHierarchy.validate(layers))
    }

    // MARK: ImageLayer.hierarchyRecord

    func testHierarchyRecordProjection() {
        var layer = ImageLayer(name: "L", blankSize: CGSize(width: 4, height: 4))
        layer.isGroup = false
        let record = layer.hierarchyRecord
        XCTAssertEqual(record.id, layer.id)
        XCTAssertEqual(record.name, "L")
        XCTAssertTrue(record.isVisible)
        XCTAssertNil(record.imageFile) // blank layer has no asset
        XCTAssertNil(record.maskFile)
        XCTAssertEqual(record.isGroup, false) // a non-group layer records an explicit false
    }

    // MARK: LiveMaskGraph.validate

    func testLiveMaskValidateCycleThrows() {
        let a = UUID(), b = UUID()
        let layers = [
            ProjectLayerRecord(id: a, name: "A", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "a.png", maskSourceID: b),
            ProjectLayerRecord(id: b, name: "B", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "b.png", maskSourceID: a)
        ]
        XCTAssertThrowsError(try LiveMaskGraph.validate(layers))
    }

    func testLiveMaskValidateGroupWithMaskSourceThrows() {
        let base = UUID(), group = UUID()
        let layers = [
            ProjectLayerRecord(id: base, name: "Base", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: "base.png"),
            ProjectLayerRecord(id: group, name: "G", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: nil, isGroup: true, maskSourceID: base)
        ]
        XCTAssertThrowsError(try LiveMaskGraph.validate(layers))
    }

    func testLiveMaskValidateMissingSourceThrows() {
        let missing = UUID()
        let layer = ProjectLayerRecord(id: UUID(), name: "L", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
            imageFile: "l.png", maskSourceID: missing)
        XCTAssertThrowsError(try LiveMaskGraph.validate([layer]))
    }

    func testLiveMaskValidateAdjustmentSourceThrows() {
        let source = UUID()
        let base = ProjectLayerRecord(id: source, name: "S", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: "s.png",
            adjustment: LayerAdjustment(kind: .levels))
        let clipped = ProjectLayerRecord(id: UUID(), name: "C", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
            imageFile: "c.png", maskSourceID: source)
        XCTAssertThrowsError(try LiveMaskGraph.validate([base, clipped]))
    }

    func testLiveMaskValidateValidChain() {
        let base = UUID(), clipped = UUID()
        let layers = [
            ProjectLayerRecord(id: base, name: "B", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: "b.png"),
            ProjectLayerRecord(id: clipped, name: "C", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                               imageFile: "c.png", maskSourceID: base)
        ]
        XCTAssertNoThrow(try LiveMaskGraph.validate(layers))
    }

    // MARK: LiveMaskGraph.adoptClipping

    func testAdoptClippingJoinsMidStack() {
        let base = UUID(), middle = UUID(), clipped = UUID()
        var layers = [
            ImageLayer(id: base, asset: nil, name: "Base", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1))),
            ImageLayer(id: middle, asset: nil, name: "Mid", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1))),
            ImageLayer(id: clipped, asset: nil, name: "Clipped", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                       maskSourceID: base)
        ]
        LiveMaskGraph.adoptClipping(middle, in: &layers)
        XCTAssertEqual(layers.first(where: { $0.id == middle })?.maskSourceID, base)
    }

    func testAdoptClippingNoOpAtBottom() {
        let base = UUID(), clipped = UUID()
        var layers = [
            ImageLayer(id: base, asset: nil, name: "Base", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1))),
            ImageLayer(id: clipped, asset: nil, name: "Clipped", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                       maskSourceID: base)
        ]
        LiveMaskGraph.adoptClipping(base, in: &layers)
        XCTAssertNil(layers.first(where: { $0.id == base })?.maskSourceID)
    }

    // MARK: LiveMaskGraph.releaseDetachedClipping

    func testReleaseDetachedClippingClearsBrokenChain() {
        let base = UUID(), clipped = UUID(), moved = UUID()
        // Same parent; `moved` claims `base` as its mask source but sits below the
        // real base, breaking the contiguous stack.
        var layers = [
            ImageLayer(id: moved, asset: nil, name: "Moved", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                       maskSourceID: base),
            ImageLayer(id: base, asset: nil, name: "Base", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1))),
            ImageLayer(id: clipped, asset: nil, name: "Clipped", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                       maskSourceID: base)
        ]
        LiveMaskGraph.releaseDetachedClipping(in: &layers)
        XCTAssertNil(layers.first(where: { $0.id == moved })?.maskSourceID,
                     "the moved layer no longer sits above its base, so it is released")
        XCTAssertEqual(layers.first(where: { $0.id == clipped })?.maskSourceID, base,
                       "the real contiguous clip is kept")
    }

    func testReleaseDetachedClippingKeepsContiguousStack() {
        let base = UUID(), clipped = UUID()
        var layers = [
            ImageLayer(id: base, asset: nil, name: "Base", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1))),
            ImageLayer(id: clipped, asset: nil, name: "Clipped", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                       maskSourceID: base)
        ]
        LiveMaskGraph.releaseDetachedClipping(in: &layers)
        XCTAssertEqual(layers.first(where: { $0.id == clipped })?.maskSourceID, base)
    }

    // MARK: floatingSelectionTransform

    func testFloatingSelectionTransformNilWithoutFloating() {
        let edit = TransformEdit(layerID: UUID(),
            draft: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
            persistent: true)
        XCTAssertNil(edit.floatingSelectionTransform())
    }

    func testFloatingSelectionTransformIdentityWhenDraftEqualsOriginal() {
        let original = LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10))
        let floating = FloatingTransform(sourceID: UUID(),
            before: CanvasDocument(width: 100, height: 100), beforeActive: nil,
            original: original, pixelSize: CGSize(width: 10, height: 10))
        let edit = TransformEdit(layerID: UUID(), draft: original, persistent: true, floating: floating)
        guard let t = edit.floatingSelectionTransform() else { return XCTFail("expected a transform") }
        // original.inverted ∘ draft, with draft == original, is the identity.
        let p = CGPoint(x: 3, y: 4)
        let q = p.applying(t)
        XCTAssertEqual(q.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(q.y, p.y, accuracy: 1e-6)
    }

    // MARK: selectionCopyRegion

    func testSelectionCopyRegionNilSelectionReturnsWholeCanvas() {
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(selectionCopyRegion(selection: nil, canvas: canvas), canvas)
    }

    func testSelectionCopyRegionFloorsAndCeilsWithTolerance() {
        // Float noise like 60.0000001 should round to 60, not 60 + an extra pixel.
        let path = PortablePath.rectangle(CGRect(x: 10, y: 20, width: 50.0000001, height: 30.0000001))
        let selection = DocumentSelection(path: path)
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
        let region = selectionCopyRegion(selection: selection, canvas: canvas)
        XCTAssertEqual(region?.minX, 10)
        XCTAssertEqual(region?.minY, 20)
        XCTAssertEqual(region?.width, 50)
        XCTAssertEqual(region?.height, 30)
    }

    func testSelectionCopyRegionOutsideCanvasReturnsNil() {
        // A selection entirely outside the canvas intersects to nothing.
        let path = PortablePath.rectangle(CGRect(x: 200, y: 200, width: 10, height: 10))
        let selection = DocumentSelection(path: path)
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(selectionCopyRegion(selection: selection, canvas: canvas))
    }

    func testSelectionCopyRegionIntersectsCanvas() {
        // A selection extending past the canvas is clipped to the canvas.
        let path = PortablePath.rectangle(CGRect(x: -10, y: -10, width: 50, height: 50))
        let selection = DocumentSelection(path: path)
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
        let region = selectionCopyRegion(selection: selection, canvas: canvas)
        XCTAssertEqual(region?.minX, 0)
        XCTAssertEqual(region?.minY, 0)
    }
}