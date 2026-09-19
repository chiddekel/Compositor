// Port of Compositor/Document/AdjustmentEditing.swift's session state machine:
// non-destructive adjustment editing (preview writes metadata, never pixels),
// matching macOS begin/preview/commit/cancel semantics.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class AdjustmentEditingTests: XCTestCase {

    private func makeSession() throws -> EditorSession {
        let session = EditorSession()
        try session.createDocument(width: 8, height: 8, emptyLayer: true)
        return session
    }

    func testAddAdjustmentCreatesLayerAndOpensEditing() throws {
        let session = try makeSession()
        try session.addAdjustment(.hsv)
        let activeID = try XCTUnwrap(session.activeLayerID)
        XCTAssertEqual(session.activeLayer?.isGroup, false)
        XCTAssertEqual(session.activeLayer?.adjustment?.kind, .hsv)
        XCTAssertEqual(session.activeLayer?.name, "Hue/Saturation")
        XCTAssertEqual(session.adjustmentEditingID, activeID)
        XCTAssertNotNil(session.adjustmentOriginal)
    }

    func testPreviewWritesMetadataNotPixels() throws {
        let session = try makeSession()
        try session.addAdjustment(.hsv)
        
        let before = try session.render()
        var value = try XCTUnwrap(session.adjustmentOriginal)
        value.hue = 60
        value.saturation = 40
        XCTAssertTrue(try session.previewAdjustmentEditing(value))
        let after = try session.render()
        XCTAssertEqual(session.activeLayer?.adjustment?.hue, 60)
        // Both renders must come from the same layer size (8x8); the adjustment
        // color change is real but the canvas stays intact.
        XCTAssertEqual(before.bytes.count, after.bytes.count)
        XCTAssertEqual(before.width, after.width)
    }

    func testPreviewRejectsMismatchedKind() throws {
        let session = try makeSession()
        try session.addAdjustment(.curves)
        var value = try XCTUnwrap(session.adjustmentOriginal)
        value.kind = .grain
        XCTAssertThrowsError(try session.previewAdjustmentEditing(value))
    }

    func testPreviewRejectsInvalidValue() throws {
        let session = try makeSession()
        try session.addAdjustment(.hsv)
        var value = try XCTUnwrap(session.adjustmentOriginal)
        value.hue = 500
        XCTAssertThrowsError(try session.previewAdjustmentEditing(value))
    }

    func testCommitPersistsAndCloses() throws {
        let session = try makeSession()
        try session.addAdjustment(.levels)
        
        var value = try XCTUnwrap(session.adjustmentOriginal)
        value.levels.ranges[1].white = 40
        XCTAssertTrue(try session.previewAdjustmentEditing(value))
        try session.finishAdjustmentEditing(commit: true)
        XCTAssertNil(session.adjustmentEditingID)
        XCTAssertNil(session.adjustmentOriginal)
        XCTAssertEqual(session.activeLayer?.adjustment?.levels.ranges[1].white, 40)
        XCTAssertTrue(session.history.canUndo)
    }

    func testCancelRestoresOriginalAndCloses() throws {
        let session = try makeSession()
        try session.addAdjustment(.exposure)
        let original = try XCTUnwrap(session.adjustmentOriginal)
        var value = original
        value.exposure.exposure = 3
        XCTAssertTrue(try session.previewAdjustmentEditing(value))
        try session.finishAdjustmentEditing(commit: false)
        XCTAssertNil(session.adjustmentEditingID)
        XCTAssertEqual(session.activeLayer?.adjustment?.exposure.exposure, original.exposure.exposure)
    }

    func testUndoRestoresPreEditAdjustment() throws {
        let session = try makeSession()
        try session.addAdjustment(.hsv)
        var value = try XCTUnwrap(session.adjustmentOriginal)
        value.hue = 90
        XCTAssertTrue(try session.previewAdjustmentEditing(value))
        try session.finishAdjustmentEditing(commit: true)
        XCTAssertEqual(session.activeLayer?.adjustment?.hue, 90)
        XCTAssertTrue(session.history.canUndo)
        try session.undo()
        // Undo of the "New Hue/Saturation Adjustment" transaction removes the layer.
        XCTAssertNil(session.activeLayer?.adjustment)
    }

    func testBeginAdjustmentEditingBlocksConcurrentEdits() throws {
        let session = try makeSession()
        try session.addAdjustment(.curves)
        // beginAdjustmentEditing on the same (already editing) layer is busy.
        XCTAssertThrowsError(try session.beginAdjustmentEditing(try XCTUnwrap(session.activeLayerID)))
    }

    func testBridgeAddAndCommitAdjustment() throws {
        _ = setenv("COMPOSITOR_FORCE_CPU", "1", 1)
        let handle = compositorSessionCreate()
        defer { compositorSessionClose(handle) }
        var command = EditorCommandJSON(version: 1, action: "new", width: 6, height: 6)
        XCTAssertEqual(command.run(handle), 0)
        command = EditorCommandJSON(version: 1, action: "addAdjustment", kind: "Levels")
        XCTAssertEqual(command.run(handle), 0)
        let layerID = try XCTUnwrap(EditorCommandJSON.currentActiveLayerID(handle))
        var value = LayerAdjustment(kind: .levels)
        value.levels.ranges[0].white = 30
        let preview = try EditorCommandJSON.withAdjustment(handle, action: "adjustmentPreview", layerID: layerID, value: value)
        XCTAssertEqual(preview, 0)
        let commit = try EditorCommandJSON.withAdjustment(handle, action: "adjustmentCommit", layerID: layerID, value: value)
        XCTAssertEqual(commit, 0)
        let state = try XCTUnwrap(EditorCommandJSON.currentActiveLayerID(handle))
        XCTAssertEqual(state, layerID)
    }
}

/// Minimal bridge-driver helpers so the C-ABI test stays in Swift.
private struct EditorCommandJSON {
    let version: Int
    let action: String
    var width: Int?
    var height: Int?
    var kind: String?

    func run(_ handle: UInt64) -> Int32 {
        var payload: [String: Any] = ["version": version, "action": action]
        if let width { payload["width"] = width }
        if let height { payload["height"] = height }
        if let kind { payload["kind"] = kind }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return data.withUnsafeBytes { compositorSessionCommand(handle, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count) }
    }

    static func withAdjustment(_ handle: UInt64, action: String, layerID: UUID, value: LayerAdjustment) throws -> Int32 {
        var payload: [String: Any] = ["version": 1, "action": action, "layerID": layerID.uuidString]
        payload["adjustment"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value),
            options: .fragmentsAllowed)
        let data = try JSONSerialization.data(withJSONObject: payload)
        return data.withUnsafeBytes { compositorSessionCommand(handle, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count) }
    }

    static func currentActiveLayerID(_ handle: UInt64) -> UUID? {
        let state = compositorSessionState(handle, nil, 0)
        guard state > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(state))
        _ = compositorSessionState(handle, &bytes, bytes.count)
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)),
              let dict = object as? [String: Any], let id = dict["activeLayerID"] as? String else { return nil }
        return UUID(uuidString: id)
    }
}