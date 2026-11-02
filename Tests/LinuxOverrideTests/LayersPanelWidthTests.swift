import Foundation
import FoundationCompat
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized) struct LayersPanelWidthTests {
    private func withSavedWidth(_ width: Double, body: (Entry) throws -> Void) rethrows {
        let old = SQLiteUserDefaults.standard.object(forKey: "layersPanelWidth")
        SQLiteUserDefaults.standard.set(width, forKey: "layersPanelWidth")
        let entry = Entry()
        defer {
            SQLiteUserDefaults.standard.set(old, forKey: "layersPanelWidth")
        }
        try body(entry)
    }
    private func tree(_ entry: Entry) throws -> [String: Any] {
        let wire = try #require(resolvePanel("LayersPanel", entry: entry))
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
    }
    private func frameWidth(_ tree: [String: Any]) -> Double? {
        (tree["modifiers"] as? [[String: Any]])?.first(where: { $0["kind"] as? String == "frame" })
            .flatMap { ($0["doubleParams"] as? [String: Any])?["width"] as? Double }
    }
    private func dirty(_ entry: Entry) -> String {
        DirtyPanels.take(entry).joined(separator: "\n")
    }

    @Test func oldSavedWidthsClampBeforeRendering() throws {
        try withSavedWidth(202) { entry in
            #expect(updateLayersPanelWidth(0, entry: entry) == 222)
            let resolved = try tree(entry)
            #expect(frameWidth(resolved) == 222)
        }
    }
    @Test func resizingUpdatesOnlyTheLayersTreeAndPersistsWidth() throws {
        try withSavedWidth(252) { entry in
            _ = try tree(entry)
            #expect(updateLayersPanelWidth(300, entry: entry) == 300)
            #expect(dirty(entry) == "LayersPanel")
            let resolved = try tree(entry)
            #expect(frameWidth(resolved) == 300)
            #expect(SQLiteUserDefaults.standard.double(forKey: "layersPanelWidth") == 300)
            #expect(updateLayersPanelWidth(300, entry: entry) == 300)
            #expect(dirty(entry).isEmpty)
        }
    }
    @Test func boundsAndInvalidOffersDoNotProduceInvalidFrames() throws {
        try withSavedWidth(252) { entry in
            #expect(updateLayersPanelWidth(10, entry: entry) == 222)
            #expect(updateLayersPanelWidth(500, entry: entry) == 352)
            #expect(updateLayersPanelWidth(.nan, entry: entry) == 352)
            #expect(updateLayersPanelWidth(.infinity, entry: entry) == 352)
            let resolved = try tree(entry)
            #expect(frameWidth(resolved) == 352)
        }
    }
}
