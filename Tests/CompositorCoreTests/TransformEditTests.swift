// Port of Compositor/Document/EditorSession.swift's transform-editing state
// machine (TransformEditLinux extension): begin/preview/commit/cancel, the
// single-layer, group, and mask-alone cases, and the one-undo-step commit.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class TransformEditTests: XCTestCase {

    private func makeSession() throws -> EditorSession {
        let session = EditorSession()
        // Layer must have real pixels for `canTransform`.
        var doc = CanvasDocument(width: 60, height: 50)
        let layer = ImageLayer(asset: filledImage(), origin: .zero)
        doc.layers = [layer]
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(layer.id)
        return session
    }

    private func filledImage() -> ImportedImage {
        var p = PixelBuffer(width: 20, height: 10)
        for y in 0..<10 { for x in 0..<20 { p[x, y] = (200, 100, 50, 255) } }
        let portable = PortableImage(p)
        return ImportedImage(image: RasterImage(portable), thumbnail: RasterImage(portable), name: "Filled")
    }

    private func place(_ session: EditorSession, id: UUID, x: CGFloat, y: CGFloat) {
        var doc = session.document!
        guard let index = doc.layers.firstIndex(where: { $0.id == id }) else { return }
        doc.layers[index].transform.origin = CGPoint(x: x, y: y)
        session.replaceCurrentDocument(doc)
    }

    private func addPixelLayer(_ session: EditorSession, at x: CGFloat, y: CGFloat) -> UUID {
        var doc = session.document!
        var layer = ImageLayer(asset: filledImage(), origin: .zero)
        layer.transform.origin = CGPoint(x: x, y: y)
        doc.layers.append(layer)
        session.replaceCurrentDocument(doc)
        return layer.id
    }

    // MARK: Single layer

    func testBeginTransformCapturesDraftThenPreviewUpdatesIt() throws {
        let session = try makeSession()
        let id = try XCTUnwrap(session.activeLayerID)
        place(session, id: id, x: 5, y: 6)
        session.beginTransform()
        let edit = try XCTUnwrap(session.transformEdit)
        XCTAssertEqual(edit.draft, session.activeLayer?.transform)
        var target = edit.draft
        target.origin = CGPoint(x: 50, y: 40)
        session.previewTransform(target)
        XCTAssertEqual(session.transformEdit?.draft, target)
        // The model is untouched while dragging.
        XCTAssertEqual(session.activeLayer?.transform.origin.x ?? -1, 5)
        // Draft is shown to the render layer surface via displayedTransform.
        XCTAssertEqual(session.displayedTransform(for: session.activeLayer!), target)
    }

    func testBeginTransformRequiresVisiblePixelLayer() throws {
        let session = try makeSession()
        let id = try XCTUnwrap(session.activeLayerID)
        try session.updateLayer(visible: false)
        session.beginTransform()
        XCTAssertNil(session.transformEdit)
        _ = id
    }

    func testCommitWritesDraftInOneUndoStep() throws {
        let session = try makeSession()
        let id = try XCTUnwrap(session.activeLayerID)
        let before = session.document!
        session.beginTransform()
        var target = try XCTUnwrap(session.transformEdit).draft
        target.origin = CGPoint(x: 12, y: 14)
        session.previewTransform(target)
        session.commitTransform()
        XCTAssertNil(session.transformEdit)
        let after = session.document!
        XCTAssertEqual(after.layers[0].transform.origin.x, 12)
        XCTAssertTrue(session.history.canUndo)
        try session.undo()
        XCTAssertEqual(session.document?.layers[0].transform, before.layers[0].transform)
    }

    func testCancelDiscardsDraft() throws {
        let session = try makeSession()
        let id = try XCTUnwrap(session.activeLayerID)
        session.beginTransform()
        var target = try XCTUnwrap(session.transformEdit).draft
        target.origin = CGPoint(x: 99, y: 98)
        session.previewTransform(target)
        session.cancelTransform()
        XCTAssertNil(session.transformEdit)
        XCTAssertEqual(session.document?.layers[0].transform.origin.x ?? -1, 0)
        XCTAssertFalse(session.history.canUndo, "cancel is not an undoable step")
        _ = id
    }

    func testCommitWithoutEditDoesNothing() throws {
        let session = try makeSession()
        session.commitTransform()
        XCTAssertNil(session.transformEdit)
    }

    func testSelectLayerCommitsPendingTransform() throws {
        let session = try makeSession()
        let first = try XCTUnwrap(session.activeLayerID)
        let second = addPixelLayer(session, at: 0, y: 0)
        session.selectLayer(first)
        session.beginTransform()
        var target = try XCTUnwrap(session.transformEdit).draft
        target.origin = CGPoint(x: 30, y: 20)
        session.previewTransform(target)
        session.selectLayer(second)
        XCTAssertNil(session.transformEdit)
        XCTAssertEqual(session.activeLayerID, second)
        let doc = session.document!
        let moved = doc.layers.first { $0.id == first }
        XCTAssertEqual(moved?.transform.origin.x ?? -1, 30, "selecting another layer commits the pending edit")
    }

    func testBeginTransformWhileBusyIsRejected() throws {
        let session = try makeSession()
        try session.beginBrush(at: CGPoint(x: 5, y: 5), settings: BrushSettings(), mask: false)
        session.beginTransform()
        XCTAssertNil(session.transformEdit)
    }

    // MARK: Group

    func testGroupTransformMovesAllMembersFollowingTheBox() throws {
        let session = try makeSession()
        let first = try XCTUnwrap(session.activeLayerID)
        let second = addPixelLayer(session, at: 0, y: 0)
        place(session, id: first, x: 0, y: 0)
        place(session, id: second, x: 40, y: 0)
        session.selectLayers([first, second], primary: first)
        session.beginTransform()
        let box = try XCTUnwrap(session.transformEdit?.draft)
        // Box spans both layers' upright bounds.
        XCTAssertEqual(box.origin.x, 0)
        XCTAssertEqual(box.size.width, 60, accuracy: 0.001)
        var moved = box
        moved.origin = CGPoint(x: 5, y: 5)
        session.previewTransform(moved)
        session.commitTransform()
        let doc = session.document!
        let a = doc.layers.first { $0.id == first }!.transform
        let b = doc.layers.first { $0.id == second }!.transform
        XCTAssertEqual(a.origin.x, 5, accuracy: 0.001)
        XCTAssertEqual(b.origin.x, 45, accuracy: 0.001)
        XCTAssertEqual(a.origin.y, 5, accuracy: 0.001)
    }

    // MARK: Mask-alone

    func testUnlinkedMaskTransformsOnItsOwn() throws {
        let session = try makeSession()
        let id = try XCTUnwrap(session.activeLayerID)
        var doc = session.document!
        doc.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: PortableImage(MaskBuffer(width: 10, height: 10, fill: 255))),
                                       isEnabled: true, placement: .init(origin: .zero, size: CGSize(width: 20, height: 10)), isLinked: false)
        session.replaceCurrentDocument(doc)
        session.isMaskSelected = true
        session.beginTransform()
        let edit = try XCTUnwrap(session.transformEdit)
        XCTAssertTrue(edit.mask)
        XCTAssertEqual(edit.draft, session.activeLayer?.maskTransform)
        var target = edit.draft
        target.origin = CGPoint(x: 25, y: 25)
        session.previewTransform(target)
        session.commitTransform()
        XCTAssertNil(session.transformEdit)
        XCTAssertEqual(session.document?.layers[0].mask?.placement?.origin.x ?? -1, 25)
        // Layer pixels untouched.
        XCTAssertEqual(session.document?.layers[0].transform.origin.x ?? -1, 0)
        // transformTargetsMask stays live for the not-yet-editing lookup.
        session.isMaskSelected = true
        XCTAssertTrue(session.transformTargetsMask)
    }

    func testLinkedMaskMovesWithLayer() throws {
        let session = try makeSession()
        let id = try XCTUnwrap(session.activeLayerID)
        var doc = session.document!
        doc.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: PortableImage(MaskBuffer(width: 10, height: 10, fill: 255))),
                                       isEnabled: true, placement: nil, isLinked: true)
        session.replaceCurrentDocument(doc)
        session.beginTransform()
        let edit = try XCTUnwrap(session.transformEdit)
        XCTAssertFalse(edit.mask)
        var target = edit.draft
        target.origin = CGPoint(x: 10, y: 10)
        session.previewTransform(target)
        session.commitTransform()
        XCTAssertEqual(session.document?.layers[0].mask?.placement, target.samePlacement(as: target) ? nil : target)
    }

    // MARK: Bridge flow

    func testBridgeTransformFlow() throws {
        _ = setenv("COMPOSITOR_FORCE_CPU", "1", 1)
        let handle = compositorSessionCreate()
        defer { compositorSessionClose(handle) }
        var command = Bridge(version: 1, action: "new", width: 30, height: 20)
        XCTAssertEqual(command.run(handle), 0)
        command = Bridge(version: 1, action: "addShape", width: 8, height: 6, kind: "Rectangle", x: 2, y: 3)
        XCTAssertEqual(command.run(handle), 0)
        command = Bridge(version: 1, action: "transformBegin")
        XCTAssertEqual(command.run(handle), 0)
        XCTAssertEqual(Bridge.stateBusy(handle), true, "a pending interactive transform is busy")
        command = Bridge(version: 1, action: "transformPreview", width: 8, height: 6, x: 12, y: 10)
        XCTAssertEqual(command.run(handle), 0)
        command = Bridge(version: 1, action: "transformCancel")
        XCTAssertEqual(command.run(handle), 0)
        XCTAssertEqual(Bridge.stateBusy(handle), false)
        let stateJSON = Bridge.state(handle)
        XCTAssertEqual(stateJSON.transformOriginX ?? -1, 2, "cancel discarded the preview; the layer stayed put")
    }

    // MARK: Busy / cache-coherent helpers

    // (undo verification goes through session.history / session.undo())
}

/// Minimal bridge-driver helpers so the C-ABI transform test stays in Swift.
private struct Bridge {
    let version: Int
    let action: String
    var width: Int?
    var height: Int?
    var kind: String?
    var x: Double?
    var y: Double?

    init(version: Int, action: String, width: Int? = nil, height: Int? = nil, kind: String? = nil, x: Double? = nil, y: Double? = nil) {
        self.version = version
        self.action = action
        self.width = width
        self.height = height
        self.kind = kind
        self.x = x
        self.y = y
    }

    func run(_ handle: UInt64) -> Int32 {
        var payload: [String: Any] = ["version": version, "action": action]
        if let width { payload["width"] = width }
        if let height { payload["height"] = height }
        if let kind { payload["kind"] = kind }
        if let x { payload["x"] = x }
        if let y { payload["y"] = y }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return data.withUnsafeBytes { compositorSessionCommand(handle, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count) }
    }

    static func state(_ handle: UInt64) -> [String: Any] {
        let len = compositorSessionState(handle, nil, 0)
        guard len > 0 else { return [:] }
        var bytes = [UInt8](repeating: 0, count: Int(len))
        _ = compositorSessionState(handle, &bytes, bytes.count)
        return (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] ?? [:]
    }

    static func stateBusy(_ handle: UInt64) -> Bool {
        state(handle)["busy"] as? Bool ?? false
    }
}

private extension Dictionary where Key == String {
    var transformOriginX: Double? {
        let layers = self["layers"] as? [[String: Any]] ?? []
        let names = layers.map { $0["name"] }
        guard let layerIndex = names.firstIndex(where: { ($0 as? String)?.hasPrefix("Rectangle") == true }) else { return nil }
        guard let transform = layers[layerIndex]["transform"] as? [String: Any],
              let origin = transform["origin"] as? [Double] else { return nil }
        return origin.first
    }
}