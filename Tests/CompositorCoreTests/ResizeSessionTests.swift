import XCTest
@testable import CompositorCore

final class ResizeSessionTests: XCTestCase {
    func testResolutionOnlySharesPixelsAndUndoRestoresResolution() throws {
        let session = EditorSession()
        try session.importImage(PortableImage(PixelBuffer(width: 8, height: 6)), name: "Transparent", replacing: true)
        let original = try XCTUnwrap(session.activeLayer?.asset?.image)
        try session.resizeImage(width: 8, height: 6, resolution: 300)
        XCTAssertTrue(session.activeLayer?.asset?.image === original)
        XCTAssertEqual(session.document?.resolution, 300)
        try session.undo()
        XCTAssertEqual(session.document?.resolution, 72)
        XCTAssertTrue(session.activeLayer?.asset?.image === original)
        try session.redo()
        XCTAssertEqual(session.document?.resolution, 300)
    }

    func testInvalidResolutionDoesNotMutateDocumentOrHistory() throws {
        let session = EditorSession()
        try session.createDocument(width: 8, height: 6, emptyLayer: true)
        let before = session.document
        for resolution in [0, -1, 9601, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try session.resizeImage(width: 8, height: 6, resolution: resolution))
            XCTAssertEqual(session.document, before)
            XCTAssertFalse(session.history.canUndo)
        }
    }

    func testNonuniformResizeBakesRotatedLayerAndScalesSelection() throws {
        let session = EditorSession()
        try session.importImage(PortableImage(PixelBuffer(width: 12, height: 12, fill: 0xFFFFFFFF)),
                                name: "White", replacing: true)
        var transform = try XCTUnwrap(session.activeLayer?.transform)
        transform.rotation = 45
        try session.updateLayer(transform: transform)
        try session.setSelection(DocumentSelection(path: .rectangle(CGRect(x: 2, y: 3, width: 4, height: 5))))
        let before = session.document
        try session.resizeImage(width: 24, height: 12)
        XCTAssertEqual(session.activeLayer?.transform.rotation, 0)
        XCTAssertEqual(session.document?.selection?.path.boundingBox, CGRect(x: 4, y: 3, width: 8, height: 5))
        try session.undo()
        XCTAssertEqual(session.document, before)
    }

    func testCanvasExtensionIsSeparateLayerAndUndoRestoresSource() throws {
        let session = EditorSession()
        try session.importImage(PortableImage(PixelBuffer(width: 2, height: 2)), name: "Transparent", replacing: true)
        let original = try XCTUnwrap(session.activeLayer?.asset?.image)
        try session.resizeCanvas(width: 4, height: 4, anchor: 0,
            fill: CanvasExtensionColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(session.document?.layers.count, 2)
        XCTAssertTrue(session.activeLayer?.asset?.image === original)
        let image = try session.render()
        XCTAssertEqual(Array(image.bytes[0..<4]), [0, 0, 0, 0])
        XCTAssertEqual(Array(image.bytes[60..<64]), [255, 0, 0, 255])
        try session.undo()
        XCTAssertEqual(session.document?.width, 2)
        XCTAssertEqual(session.document?.layers.count, 1)
    }
}
