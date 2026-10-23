import Foundation
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct StagedAssetRecoveryTests {
    private func fixture(withMask: Bool = false) throws -> (source: UpstreamEditor, loader: UpstreamEditor) {
        let source = UpstreamEditor()
        #expect(source.importRGBA([UInt8](repeating: 255, count: 16 * 12 * 4), width: 16, height: 12,
                                  name: "Original", replacing: true) == 0)
        if withMask { source.session.addMask(revealing: true) }
        let loader = UpstreamEditor()
        #expect(loader.importManifest(try source.exportManifest()) == 0)
        return (source, loader)
    }

    nonisolated private static let blockers = ["project", "import", "newDocument", "importer", "conversion", "rename", "error", "adjustment"]
    private func block(_ name: String, session: EditorSession, enabled: Bool) {
        switch name {
        case "project": session.isProjectBusy = enabled
        case "import": session.isImporting = enabled
        case "newDocument": session.showsNewDocument = enabled
        case "importer": session.showsImporter = enabled
        case "conversion": session.showsConversionSheet = enabled
        case "rename": session.renamingLayerID = enabled ? session.activeLayerID : nil
        case "error": session.importError = enabled ? "Decode failed" : nil
        case "adjustment": session.adjustmentEditingID = enabled ? session.activeLayerID : nil
        default: preconditionFailure("Unknown asset blocker")
        }
    }

    @Test(arguments: blockers, [false, true])
    func busyAssetInstallPreservesStagingAndCanRetry(blocker: String, mask: Bool) throws {
        let (source, loader) = try fixture(withMask: true)
        let id = try #require(source.session.activeLayerID)
        let pixels = try #require(source.layerPixels(id: id, mask: mask))
        let revision = loader.session.history.currentRevision
        block(blocker, session: loader.session, enabled: true)
        defer { block(blocker, session: loader.session, enabled: false) }
        let originalError = loader.session.importError
        #expect(loader.installLayerAsset(pixels, id: id, mask: mask) == -3)
        #expect(loader.session.activeLayer?.asset == nil)
        #expect(loader.session.activeLayer?.mask == nil)
        #expect(loader.session.history.currentRevision == revision)
        #expect(loader.session.importError == originalError)
        block(blocker, session: loader.session, enabled: false)
        #expect(loader.installLayerAsset(pixels, id: id, mask: mask) == 0)
        #expect(loader.layerPixels(id: id, mask: mask)?.bytes == pixels.bytes)
        let remaining = try #require(source.layerPixels(id: id, mask: !mask))
        #expect(loader.installLayerAsset(remaining, id: id, mask: !mask) == 0)
        #expect(loader.error == nil)
    }

    @Test(arguments: [false, true])
    func duplicateAssetAfterLoadCannotEraseUnsavedHistory(mask: Bool) throws {
        let (source, loader) = try fixture(withMask: true)
        let id = try #require(source.session.activeLayerID)
        let pixels = try #require(source.layerPixels(id: id, mask: mask))
        #expect(loader.installLayerAsset(pixels, id: id, mask: mask) == 0)
        let remaining = try #require(source.layerPixels(id: id, mask: !mask))
        #expect(loader.installLayerAsset(remaining, id: id, mask: !mask) == 0)
        loader.session.beginEdit("Unsaved rename")
        loader.session.document?.layers[0].name = "Unsaved"
        loader.session.endEdit()
        let revision = loader.session.history.currentRevision
        let image = loader.session.activeLayer?.asset?.image
        #expect(loader.installLayerAsset(pixels, id: id, mask: mask) == -5)
        #expect(loader.session.activeLayer?.asset?.image === image)
        #expect(loader.session.activeLayer?.name == "Unsaved")
        #expect(loader.session.history.currentRevision == revision)
        #expect(loader.session.history.canUndo)
    }

    @Test
    func editedPartialLoadRefusesRemainingAssetWithoutResettingHistory() throws {
        let (source, loader) = try fixture(withMask: true)
        let id = try #require(source.session.activeLayerID)
        #expect(loader.installLayerAsset(try #require(source.layerPixels(id: id, mask: false)), id: id, mask: false) == 0)
        loader.session.beginEdit("Unsaved rename")
        loader.session.document?.layers[0].name = "Unsaved"
        loader.session.endEdit()
        let revision = loader.session.history.currentRevision
        #expect(loader.installLayerAsset(try #require(source.layerPixels(id: id, mask: true)), id: id, mask: true) == -5)
        #expect(loader.session.history.currentRevision == revision)
        #expect(loader.session.history.canUndo)
        #expect(loader.session.activeLayer?.name == "Unsaved")
        #expect(loader.session.activeLayer?.mask == nil)
    }

    @Test
    func invalidImageLeavesPendingAssetAvailableForRetry() throws {
        let (source, loader) = try fixture(withMask: true)
        let id = try #require(source.session.activeLayerID)
        let revision = loader.session.history.currentRevision
        #expect(loader.installLayerAsset(try #require(source.layerPixels(id: id, mask: true)), id: id, mask: false) == -1)
        #expect(loader.session.history.currentRevision == revision)
        #expect(loader.session.activeLayer?.asset == nil)
        #expect(loader.installLayerAsset(try #require(source.layerPixels(id: id, mask: false)), id: id, mask: false) == 0)
    }

    @Test
    func replacedDocumentCannotReceiveOldAssetsWithMatchingLayerIDs() throws {
        let (source, loader) = try fixture()
        let id = try #require(source.session.activeLayerID)
        var json = try #require(JSONSerialization.jsonObject(with: source.exportManifest()) as? [String: Any])
        json["documentID"] = UUID().uuidString
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: JSONSerialization.data(withJSONObject: json))
        loader.session.installProject(ProjectSnapshot(manifest: manifest, images: [:]), from: URL(fileURLWithPath: "/tmp/replacement.comp"))
        let documentID = loader.session.document?.id
        let revision = loader.session.history.currentRevision
        #expect(loader.installLayerAsset(try #require(source.layerPixels(id: id, mask: false)), id: id, mask: false) == -5)
        #expect(loader.session.document?.id == documentID)
        #expect(loader.session.history.currentRevision == revision)
        #expect(loader.session.activeLayer?.asset == nil)
    }

    @Test
    func stagedAssetRefusesActiveTransformAndRecoversAfterCancel() throws {
        let (source, loader) = try fixture(withMask: true)
        let id = try #require(source.session.activeLayerID)
        #expect(loader.installLayerAsset(try #require(source.layerPixels(id: id, mask: false)), id: id, mask: false) == 0)
        loader.session.beginTransform()
        let draft = try #require(loader.session.transformEdit)
        let revision = loader.session.history.currentRevision
        #expect(loader.session.canStartProjectOperation)
        let mask = try #require(source.layerPixels(id: id, mask: true))
        #expect(loader.installLayerAsset(mask, id: id, mask: true) == -3)
        #expect(loader.session.transformEdit?.draft == draft.draft)
        #expect(loader.session.activeLayer?.mask == nil)
        #expect(loader.session.history.currentRevision == revision)
        loader.session.cancelTransform()
        #expect(loader.installLayerAsset(mask, id: id, mask: true) == 0)
        #expect(loader.layerPixels(id: id, mask: true)?.bytes == mask.bytes)
    }

    @Test
    func stagedAssetPreservesUnsavedMarkerWithoutUndoEntries() throws {
        let (source, loader) = try fixture()
        let id = try #require(source.session.activeLayerID)
        loader.session.history.markSaved(UUID())
        let revision = loader.session.history.currentRevision
        #expect(loader.session.history.isModified && !loader.session.history.canUndo)
        #expect(loader.installLayerAsset(try #require(source.layerPixels(id: id, mask: false)), id: id, mask: false) == -5)
        #expect(loader.session.history.isModified)
        #expect(loader.session.history.currentRevision == revision)
        #expect(loader.session.activeLayer?.asset == nil)
    }
}
