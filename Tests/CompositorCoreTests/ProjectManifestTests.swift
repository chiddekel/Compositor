// Tests for the portable ShapeKind.path outline and the ProjectStore manifest
// validation. Pin the unchanged macOS logic on Linux. Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class ProjectManifestTests: XCTestCase {

    // MARK: ShapeKind.path

    func testShapeKindPathRectangleIsRectanglePath() {
        let r = CGRect(x: 1, y: 2, width: 10, height: 20)
        XCTAssertEqual(ShapeKind.rectangle.path(in: r), .rectangle(r))
    }

    func testShapeKindPathEllipseIsEllipsePath() {
        let r = CGRect(x: 1, y: 2, width: 10, height: 20)
        XCTAssertEqual(ShapeKind.ellipse.path(in: r, cornerRadius: 5), .ellipse(r))
    }

    func testShapeKindPathRoundedRectWhenRadiusPositive() {
        let r = CGRect(x: 0, y: 0, width: 10, height: 20)
        XCTAssertEqual(ShapeKind.rectangle.path(in: r, cornerRadius: 3), .roundedRect(r, cornerRadius: 3))
    }

    func testShapeKindPathClampsRadiusToHalfShorterSide() {
        // width 10 → half is 5; a radius of 100 clamps to 5 (a pill).
        let r = CGRect(x: 0, y: 0, width: 10, height: 40)
        XCTAssertEqual(ShapeKind.rectangle.path(in: r, cornerRadius: 100), .roundedRect(r, cornerRadius: 5))
    }

    func testShapeKindPathZeroRadiusFallsBackToRectangle() {
        let r = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(ShapeKind.rectangle.path(in: r, cornerRadius: 0), .rectangle(r))
    }

    // MARK: ProjectManifest Codable

    func testProjectManifestCodableRoundTrip() throws {
        let id = UUID(), layerID = UUID()
        let manifest = ProjectManifest(documentID: id, width: 800, height: 600,
            activeLayerID: layerID,
            layers: [ProjectLayerRecord(id: layerID, name: "Layer 1", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: 800, height: 600)), imageFile: "\(layerID.uuidString).png")])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ProjectManifest.self, from: data)
        XCTAssertEqual(decoded.format, "com.compositor.project")
        XCTAssertEqual(decoded.version, 7)
        XCTAssertEqual(decoded.colorSpace, "sRGB")
        XCTAssertNil(decoded.resolution) // not set in this manifest → nil round-trips
        XCTAssertEqual(decoded.documentID, id)
        XCTAssertEqual(decoded.width, 800)
        XCTAssertEqual(decoded.height, 600)
        XCTAssertEqual(decoded.activeLayerID, layerID)
        XCTAssertEqual(decoded.layers.count, 1)
        XCTAssertEqual(decoded.layers.first?.id, layerID)
        XCTAssertEqual(decoded.layers.first?.imageFile, "\(layerID.uuidString).png")
    }

    // MARK: ProjectStore.validate

    private func manifest(width: Int = 100, height: Int = 100, activeLayerID: UUID? = nil,
                          version: Int = 7, layers: [ProjectLayerRecord] = []) -> ProjectManifest {
        ProjectManifest(format: "com.compositor.project", version: version, colorSpace: "sRGB",
                        resolution: 72, documentID: UUID(), width: width, height: height,
                        activeLayerID: activeLayerID, layers: layers)
    }

    private func validManifest(version: Int = 7, layers: [ProjectLayerRecord] = []) -> ProjectManifest {
        manifest(version: version, layers: layers)
    }

    private func layer(id: UUID, name: String = "L", isGroup: Bool? = nil, parentID: UUID? = nil,
                       imageFile: String? = "x.png", version: Int = 7) -> ProjectLayerRecord {
        ProjectLayerRecord(id: id, name: name, isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
            imageFile: imageFile == nil ? nil : "\(id.uuidString).png", parentID: parentID, isGroup: isGroup)
    }

    func testValidateAcceptsValidManifest() {
        let id = UUID()
        let m = validManifest(layers: [layer(id: id)])
        XCTAssertNoThrow(try ProjectStore.validate(m))
    }

    func testValidateRejectsWrongFormat() {
        var m = validManifest(); m.format = "something.else"
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    func testValidateRejectsOutOfRangeVersion() {
        let m = validManifest(version: 8)
        XCTAssertThrowsError(try ProjectStore.validate(m)) { error in
            guard case ProjectError.version(8)? = error as? ProjectError else { return XCTFail("expected .version(8)") }
        }
    }

    func testValidateRejectsBadColorSpace() {
        var m = validManifest(); m.colorSpace = "displayP3"
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    func testValidateRejectsBadDimensions() {
        let m = manifest(width: 0)
        XCTAssertThrowsError(try ProjectStore.validate(m)) { error in
            guard case ProjectError.tooLarge? = error as? ProjectError else { return XCTFail("expected .tooLarge") }
        }
    }

    func testValidateRejectsTooManyLayers() {
        let layers = (0..<10_001).map { _ in layer(id: UUID()) }
        let m = validManifest(layers: layers)
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    func testValidateRejectsDuplicateIDs() {
        let id = UUID()
        let m = validManifest(layers: [layer(id: id), layer(id: id)])
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    func testValidateRejectsEmptyName() {
        let m = validManifest(layers: [layer(id: UUID(), name: "   ")])
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    func testValidateRejectsMismatchedImageFile() {
        let id = UUID()
        let bad = ProjectLayerRecord(id: id, name: "L", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
            imageFile: "not-the-id.png")
        let m = validManifest(layers: [bad])
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    func testValidateRejectsUnknownActiveLayerID() {
        let m = manifest(activeLayerID: UUID(), layers: [layer(id: UUID())])
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    func testValidateRejectsMaskSourceBeforeVersion5() {
        let base = UUID(), clipped = UUID()
        let layers = [
            layer(id: base),
            ProjectLayerRecord(id: clipped, name: "C", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
                imageFile: "\(clipped.uuidString).png", maskSourceID: base)
        ]
        let m = validManifest(version: 4, layers: layers)
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    func testValidateRejectsGroupWithOpacity() {
        let id = UUID()
        let group = ProjectLayerRecord(id: id, name: "G", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
            imageFile: nil, isGroup: true, opacity: 0.5)
        let m = validManifest(layers: [group])
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    func testValidateRejectsAdjustmentOnGroup() {
        let id = UUID()
        let adj = ProjectLayerRecord(id: id, name: "A", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)),
            imageFile: nil, isGroup: true, adjustment: LayerAdjustment(kind: .levels))
        let m = validManifest(layers: [adj])
        XCTAssertThrowsError(try ProjectStore.validate(m))
    }

    // MARK: - EditorSession.importManifest Hardening

    func testImportManifestReconstructsDocumentAndLayers() throws {
        let session = EditorSession()
        let docID = UUID(), l1ID = UUID(), l2ID = UUID()
        let l1 = ProjectLayerRecord(id: l1ID, name: "Background", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 200, height: 100)),
            imageFile: "\(l1ID.uuidString).png", opacity: 0.8, blendMode: .multiply)
        let l2 = ProjectLayerRecord(id: l2ID, name: "Overlay", isVisible: false,
            transform: LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 50, height: 50)),
            imageFile: "\(l2ID.uuidString).png", opacity: 1.0, blendMode: .screen)
        let manifest = ProjectManifest(format: "com.compositor.project", version: 7, colorSpace: "sRGB",
                                       resolution: 144, documentID: docID, width: 200, height: 100,
                                       activeLayerID: l1ID, layers: [l1, l2])
        try session.importManifest(manifest)

        XCTAssertEqual(session.document?.id, docID)
        XCTAssertEqual(session.document?.width, 200)
        XCTAssertEqual(session.document?.height, 100)
        XCTAssertEqual(session.document?.resolution, 144)
        XCTAssertEqual(session.activeLayerID, l1ID)
        XCTAssertEqual(session.document?.layers.count, 2)
        XCTAssertEqual(session.document?.layers[0].name, "Background")
        XCTAssertEqual(session.document?.layers[0].opacity, 0.8)
        XCTAssertEqual(session.document?.layers[0].blendMode, .multiply)
        XCTAssertEqual(session.document?.layers[1].name, "Overlay")
        XCTAssertFalse(session.document?.layers[1].isVisible ?? true)
    }

    func testImportManifestRejectsOversizedTotalPixels() {
        let session = EditorSession()
        // 20,000 * 20,000 = 400,000,000 pixels > 100,000,000 limit
        let manifest = ProjectManifest(format: "com.compositor.project", version: 7, colorSpace: "sRGB",
                                       resolution: 72, documentID: UUID(), width: 20_000, height: 20_000,
                                       activeLayerID: nil, layers: [])
        XCTAssertThrowsError(try session.importManifest(manifest)) { error in
            guard case ProjectError.tooLarge? = error as? ProjectError else {
                return XCTFail("expected ProjectError.tooLarge, got \(error)")
            }
        }
    }

    func testImportManifestRejectsCorruptedManifest() {
        let session = EditorSession()
        var corrupted = validManifest()
        corrupted.format = "corrupted.format"
        XCTAssertThrowsError(try session.importManifest(corrupted))
    }
}