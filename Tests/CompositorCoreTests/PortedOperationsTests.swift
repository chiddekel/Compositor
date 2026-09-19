import XCTest
@testable import CompositorCore

final class PortedOperationsTests: XCTestCase {
    func testAppearanceFlipShapeAndClipboardOperations() throws {
        let session = EditorSession()
        try session.createDocument(width: 16, height: 16, emptyLayer: true)
        session.setLayerOpacity(0.5)
        XCTAssertEqual(session.activeLayer?.opacity, 0.5)
        session.setLayerBlendMode(.multiply)
        XCTAssertEqual(session.activeLayer?.blendMode, .multiply)

        try session.addShape(kind: .rectangle, rect: CGRect(x: 2, y: 3, width: 6, height: 5),
                             color: .white, cornerRadius: 1)
        XCTAssertEqual(session.activeLayer?.asset?.image.width, 6)
        session.flipLayers(horizontally: true)
        session.flipCanvas(horizontally: false)

        try session.setSelection(DocumentSelection(path: .rectangle(CGRect(x: 0, y: 0, width: 8, height: 8))))
        session.copyMergedSelection()
        XCTAssertNotNil(session.pixelClipboard)
        session.paste()
        XCTAssertGreaterThanOrEqual(session.document?.layers.count ?? 0, 3)
    }

    func testWarpStrokeCompletesAndKeepsDocumentValid() throws {
        let session = EditorSession()
        try session.createDocument(width: 16, height: 16, emptyLayer: true)
        try session.addShape(kind: .rectangle, rect: CGRect(x: 2, y: 2, width: 8, height: 8), color: .white)
        var settings = BrushSettings()
        settings.diameter = 4
        try session.beginWarp(at: CGPoint(x: 5, y: 5), mode: .smudge, settings: settings)
        try session.continueWarp(at: CGPoint(x: 7, y: 5))
        try session.finishWarp()
        XCTAssertNil(session.warpStroke)
        XCTAssertTrue(session.document?.layers.allSatisfy { $0.transform.isValid } == true)
    }
}
