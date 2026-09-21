// SelectionModifyTests — portable port of the macOS SelectionTests
// `expandAndContractGrowAndShrinkTheOutline` and
// `expandStaysOnCanvasAndContractCanEmptyTheSelection` (same numbers), plus the
// New/Add/Subtract combine modes of the marquee. The macOS assertions probe CGPath
// bounds; here the raster expand/contract is probed through `rasterized(in:)`.

import XCTest
@testable import CompositorCore

final class SelectionModifyTests: XCTestCase {
    private func makeSession() throws -> EditorSession {
        let session = EditorSession()
        try session.createDocument(width: 100, height: 100)
        try session.addBlankLayer()
        return session
    }

    private func coverage(_ session: EditorSession, _ x: Int, _ y: Int) throws -> UInt8 {
        let selection = try XCTUnwrap(session.document?.selection)
        let region = CGRect(x: 0, y: 0, width: 100, height: 100)
        return selection.rasterized(in: region).bytes[y * 100 + x]
    }

    func testExpandAndContractGrowAndShrinkTheOutline() throws {
        let session = try makeSession()
        try session.setSelection(DocumentSelection(path: .polygon([CGPoint(x: 40, y: 40), CGPoint(x: 60, y: 40),
                                                                    CGPoint(x: 60, y: 60), CGPoint(x: 40, y: 60)])))
        try session.expandSelection(by: 5)
        XCTAssertEqual(session.history.undoName, "Expand Selection")
        let grown = try XCTUnwrap(session.document?.selection).path.boundingBox
        XCTAssertEqual(grown.minX, 35, accuracy: 0.01)
        XCTAssertEqual(grown.width, 30, accuracy: 0.01)
        XCTAssertEqual(try coverage(session, 37, 50), 255)
        XCTAssertEqual(try coverage(session, 33, 50), 0)
        try session.contractSelection(by: 8)
        let shrunk = try XCTUnwrap(session.document?.selection).path.boundingBox
        XCTAssertEqual(shrunk.minX, 43, accuracy: 0.01)
        XCTAssertEqual(shrunk.width, 14, accuracy: 0.01)
        try session.undo()
        XCTAssertEqual(try XCTUnwrap(session.document?.selection).path.boundingBox.width, 30, accuracy: 0.01)
    }

    func testExpandStaysOnCanvasAndContractCanEmptyTheSelection() throws {
        let session = try makeSession()
        try session.setSelection(DocumentSelection(path: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100))))
        try session.expandSelection(by: 10)
        XCTAssertEqual(try XCTUnwrap(session.document?.selection).path.boundingBox, CGRect(x: 0, y: 0, width: 100, height: 100))
        try session.contractSelection(by: 10) // Pulls in from the canvas edges too.
        XCTAssertEqual(try coverage(session, 5, 50), 0)
        XCTAssertEqual(try coverage(session, 50, 50), 255)
        try session.contractSelection(by: 45)
        XCTAssertTrue(try XCTUnwrap(session.document?.selection).isEmpty)
    }

    func testAddAndSubtractCombineWithTheCurrentSelection() throws {
        let session = try makeSession()
        try session.setSelection(DocumentSelection(path: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20))))
        try session.applySelection(.rectangle(CGRect(x: 60, y: 60, width: 20, height: 20)), mode: .add, antialiased: true, name: "Selection")
        XCTAssertEqual(try coverage(session, 15, 15), 255)
        XCTAssertEqual(try coverage(session, 70, 70), 255)
        XCTAssertEqual(try coverage(session, 45, 45), 0)
        try session.applySelection(.rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)), mode: .subtract, antialiased: true, name: "Selection")
        XCTAssertEqual(try coverage(session, 15, 15), 0)
        XCTAssertEqual(try coverage(session, 70, 70), 255)
    }
}
