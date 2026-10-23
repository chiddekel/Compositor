import Foundation
import Testing
@testable import Compositor

@MainActor
struct ProjectManifestValidationTests {
    private func editor() -> UpstreamEditor {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 8 * 8 * 4),
                                  width: 8, height: 8, name: "Original", replacing: true) == 0)
        return editor
    }

    @Test(arguments: ["format", "future", "nextVersion", "zero", "colorSpace", "resolution",
                      "duplicate", "parent", "active", "transform", "name", "imagePath",
                      "maskPath", "maskEnabled", "opacity", "text", "width"])
    func rejectsInvalidMetadataWithoutReplacingDocument(_ defect: String) throws {
        let editor = editor()
        let original = try editor.exportManifest()
        let originalPixels = try editor.renderRGBA().bytes
        let originalKey = editor.renderKey()
        var manifest = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var layers = try #require(manifest["layers"] as? [[String: Any]])
        switch defect {
        case "format": manifest["format"] = "another.application"
        case "future": manifest["version"] = 999
        case "nextVersion": manifest["version"] = ProjectManifest.current + 1
        case "zero": manifest["version"] = 0
        case "colorSpace": manifest["colorSpace"] = "unsupported"
        case "resolution": manifest["resolution"] = 0
        case "duplicate": layers.append(layers[0])
        case "parent": layers[0]["parentID"] = UUID().uuidString
        case "active": manifest["activeLayerID"] = UUID().uuidString
        case "transform":
            var transform = try #require(layers[0]["transform"] as? [String: Any])
            transform["size"] = ["width": -1, "height": 8]
            layers[0]["transform"] = transform
        case "name": layers[0]["name"] = "  "
        case "imagePath": layers[0]["imageFile"] = "../outside.png"
        case "maskPath": layers[0]["maskFile"] = "../outside.mask.png"
        case "maskEnabled": layers[0]["maskEnabled"] = true
        case "opacity": layers[0]["opacity"] = 2
        case "text":
            var style = LayerTextStyle()
            style.content = "AB"
            style.colorRuns = [LayerTextColorRun(location: 1, length: 5, red: 1, green: 0, blue: 0)]
            layers[0]["text"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style))
        case "width": manifest["width"] = Int.max
        default: Issue.record("Unknown defect")
        }
        manifest["layers"] = layers
        #expect(editor.importManifest(try JSONSerialization.data(withJSONObject: manifest)) != 0)
        #expect(editor.renderKey() == originalKey)
        #expect(try editor.renderRGBA().bytes == originalPixels)
        let after = try JSONSerialization.jsonObject(with: editor.exportManifest()) as? NSDictionary
        #expect(after == (try JSONSerialization.jsonObject(with: original) as? NSDictionary))
    }

    @Test(arguments: Array(ProjectManifest.supported))
    func acceptsSupportedPlainRasterVersions(_ version: Int) async throws {
        let source = editor()
        var manifest = try JSONDecoder().decode(ProjectManifest.self, from: source.exportManifest())
        manifest.version = version
        let destination = UpstreamEditor()
        #expect(destination.importManifest(try JSONEncoder().encode(manifest)) == 0)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: package) }
        let snapshot = try #require(source.session.projectSnapshot())
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: manifest, images: snapshot.images), to: package)
        let reopened = try await ProjectStore.shared.load(from: package)
        #expect(reopened.manifest.version == version)
        #expect(destination.importManifest(try JSONEncoder().encode(reopened.manifest)) == 0)
    }

    @Test func rejectsOversizedMetadata() {
        let editor = editor()
        let key = editor.renderKey()
        #expect(editor.importManifest(Data(repeating: 32, count: 4 * 1024 * 1024 + 1)) != 0)
        #expect(editor.renderKey() == key)
    }
}
