// GroupingSelectionTests — portable port of
// CompositorTests/GroupingSelectionTests.swift (file-map test tier: "Keep
// assertions; port fixtures"). The macOS original uses Swift Testing +
// @MainActor; on Linux the EditorSession grouping/selection logic is now
// ported (EditorSession.swift: selectLayers/groupSelectedLayers/addGroup/
// canTransform/renderLayers; CanvasDocument.renderLayers), so the assertions
// run under XCTest with no AppKit/SwiftUI dependency. Assertions are kept
// verbatim; only the harness is XCTest instead of Swift Testing.

import XCTest
@testable import CompositorCore

final class GroupingSelectionTests: XCTestCase {

    /// macOS `singleLayerAndFolderAreWrappedRatherThanCreatingAChildFolder`.
    func testSingleLayerAndFolderAreWrappedRatherThanCreatingAChildFolder() throws {
        let session = EditorSession()
        try session.createDocument(width: 100, height: 100)
        try session.addBlankLayer()
        let layer = try XCTUnwrap(session.activeLayerID)
        session.groupSelectedLayers()
        let inner = try XCTUnwrap(session.activeLayerID)
        XCTAssertEqual(session.document?.layers.first(where: { $0.id == layer })?.parentID, inner)
        session.groupSelectedLayers()
        let outer = try XCTUnwrap(session.activeLayerID)
        XCTAssertEqual(session.document?.layers.first(where: { $0.id == inner })?.parentID, outer)
        XCTAssertEqual(session.document?.layers.first(where: { $0.id == layer })?.parentID, inner)
        XCTAssertNil(session.activeLayer?.parentID)
        try session.undo()
        XCTAssertNil(session.document?.layers.first(where: { $0.id == inner })?.parentID)
        XCTAssertEqual(session.document?.layers.count, 2)
    }

    /// macOS `multipleSelectionPreservesOrderAndSelectedFolderDescendants`.
    func testMultipleSelectionPreservesOrderAndSelectedFolderDescendants() throws {
        let session = EditorSession()
        try session.createDocument(width: 100, height: 100)
        session.addGroup()
        let folder = try XCTUnwrap(session.activeLayerID)
        try session.addBlankLayer()
        let child = try XCTUnwrap(session.activeLayerID)
        session.selectLayer(nil)
        try session.addBlankLayer()
        let sibling = try XCTUnwrap(session.activeLayerID)
        let before = session.document
        session.selectLayers([folder, child, sibling], primary: sibling)
        XCTAssertEqual(session.selectedLayerIDs.count, 3)
        XCTAssertFalse(session.canTransform)
        session.groupSelectedLayers()
        let wrapper = try XCTUnwrap(session.activeLayerID)
        XCTAssertEqual(session.document?.layers.first(where: { $0.id == folder })?.parentID, wrapper)
        XCTAssertEqual(session.document?.layers.first(where: { $0.id == sibling })?.parentID, wrapper)
        XCTAssertEqual(session.document?.layers.first(where: { $0.id == child })?.parentID, folder)
        XCTAssertEqual(session.document?.renderLayers.map(\.id), [child, sibling])
        XCTAssertEqual(session.selectedLayerIDs, [wrapper])
        try session.undo()
        XCTAssertEqual(session.document, before)
        try session.redo()
        XCTAssertEqual(session.document?.layers.count, 4)
    }

    /// macOS `itemsFromDifferentFoldersUseCommonParentAndEmptySelectionCreatesEmptyGroup`.
    func testItemsFromDifferentFoldersUseCommonParentAndEmptySelectionCreatesEmptyGroup() throws {
        let session = EditorSession()
        try session.createDocument(width: 100, height: 100)
        session.groupSelectedLayers()
        let first = try XCTUnwrap(session.activeLayerID)
        try session.addBlankLayer()
        let a = try XCTUnwrap(session.activeLayerID)
        session.selectLayer(nil)
        session.groupSelectedLayers()
        let second = try XCTUnwrap(session.activeLayerID)
        try session.addBlankLayer()
        let b = try XCTUnwrap(session.activeLayerID)
        session.selectLayers([a, b], primary: b)
        session.groupSelectedLayers()
        let group = try XCTUnwrap(session.activeLayerID)
        XCTAssertNil(session.activeLayer?.parentID)
        XCTAssertEqual(session.document?.layers.first(where: { $0.id == a })?.parentID, group)
        XCTAssertEqual(session.document?.layers.first(where: { $0.id == b })?.parentID, group)
        XCTAssertNil(session.document?.layers.first(where: { $0.id == first })?.parentID)
        XCTAssertNil(session.document?.layers.first(where: { $0.id == second })?.parentID)
    }
}