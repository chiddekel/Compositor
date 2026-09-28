import Foundation
import Testing
@testable import Compositor

@MainActor
struct FontRunValidationTests {
    @Test(arguments: ["empty", "negative", "zero", "overflow", "pastEnd", "overlap", "unsorted",
                      "emptyName", "longName", "newline", "oldVersion"])
    func invalidFontRunsLeaveDocumentUnchanged(_ defect: String) throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 255, count: 16 * 16 * 4),
                                  width: 16, height: 16, name: "Original", replacing: true) == 0)
        let original = try editor.exportManifest()
        var manifest = try JSONDecoder().decode(ProjectManifest.self, from: original)
        var style = LayerTextStyle()
        style.content = "A😀BC"
        var run = LayerTextFontRun(location: 1, length: 2, fontName: "Monospace")
        switch defect {
        case "negative": run.location = -1
        case "zero": run.length = 0
        case "overflow": run.location = Int.max; run.length = 2
        case "pastEnd": run.length = 5
        case "emptyName": run.fontName = ""
        case "longName": run.fontName = String(repeating: "x", count: 201)
        case "newline": run.fontName = "A\nB"
        case "oldVersion": manifest.version = 10
        default: break
        }
        style.fontRuns = [run]
        if defect == "empty" { style.fontRuns = [] }
        if defect == "overlap" { style.fontRuns?.append(run) }
        if defect == "unsorted" {
            style.fontRuns = [LayerTextFontRun(location: 3, length: 1, fontName: "System"), run]
        }
        manifest.layers[0].text = style
        #expect(editor.importManifest(try JSONEncoder().encode(manifest)) != 0)
        #expect(try JSONDecoder().decode(ProjectManifest.self, from: editor.exportManifest()).documentID == manifest.documentID)
        #expect(try JSONSerialization.jsonObject(with: editor.exportManifest()) as? NSDictionary ==
                JSONSerialization.jsonObject(with: original) as? NSDictionary)
        #expect(throws: (any Error).self) { try LinuxProjectValidation.validate(manifest) }
    }
}
