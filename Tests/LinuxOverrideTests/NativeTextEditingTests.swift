import Foundation
import Testing
@testable import Compositor

@MainActor
struct NativeTextEditingTests {
    private func editor() -> UpstreamEditor {
        let e = UpstreamEditor()
        #expect(e.importRGBA([UInt8](repeating: 255, count: 64 * 64 * 4), width: 64, height: 64, name: "Canvas", replacing: true) == 0)
        e.session.beginText(at: .zero, newLayer: true)
        e.session.textDraft?.style.content = "A😀BCDEF"
        e.session.textDraft?.style.setColor(PaletteColor(red: 1, green: 0, blue: 0), in: NSRange(location: 3, length: 3))
        e.session.textDraft?.style.setFont("Monospace", in: NSRange(location: 3, length: 3))
        return e
    }

    private func send(_ e: UpstreamEditor, _ action: String, _ fields: [String: Any] = [:]) async throws -> Int32 {
        var command = fields
        command["version"] = 1; command["action"] = action
        return await e.commandAsync(try JSONSerialization.data(withJSONObject: command))
    }

    @Test func replacementKeepsColorsAndCommitsUndoably() async throws {
        let e = editor()
        #expect(try await send(e, "textReplace", ["location": 4, "length": 1, "name": "é🦊"]) == 0)
        let style = try #require(e.session.textDraft?.style)
        #expect(style.content == "A😀Bé🦊DEF")
        #expect(style.colorRuns == [LayerTextColorRun(location: 3, length: 5, red: 1, green: 0, blue: 0)])
        #expect(style.fontRuns == [LayerTextFontRun(location: 3, length: 5, fontName: "Monospace")])
        #expect(e.session.textDraft?.selection == NSRange(location: 7, length: 0))
        #expect(try await send(e, "textFinish") == 0)
        #expect(e.session.activeLayer?.liveText?.style == style)
        #expect(try await send(e, "undo") == 0)
        #expect(e.session.document?.layers.count == 1)
        #expect(try await send(e, "redo") == 0)
        #expect(e.session.activeLayer?.liveText?.style == style)
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: e.exportManifest())
        #expect(manifest.layers.last?.text == style)
    }

    @Test func selectionControlsColorAndIsExposedToNativeEditor() async throws {
        let e = editor()
        #expect(try await send(e, "textSelect", ["location": 1, "length": 2]) == 0)
        e.session.setDraftTextColor(PaletteColor(red: 0, green: 0, blue: 1))
        let style = try #require(e.session.textDraft?.style)
        #expect(style.color(at: 1).blue == 1 && style.color(at: 2).blue == 1)
        #expect(style.color(at: 3).red == 1)
        let state = try #require(JSONSerialization.jsonObject(with: e.stateJSON()) as? [String: Any])
        let draft = try #require(state["textDraft"] as? [String: Any])
        #expect(draft["selectionLocation"] as? Int == 1)
        #expect(draft["selectionLength"] as? Int == 2)
        #expect(draft["id"] as? String == e.session.textDraft?.id.uuidString)
        let runs = try #require(draft["fontRuns"] as? [[String: Any]])
        #expect(runs.first?["fontName"] as? String == "Monospace")
    }

    @Test func invalidEditsPreserveDraft() async throws {
        let e = editor()
        let original = try #require(e.session.textDraft)
        for (location, length) in [(-1, 1), (2, 0), (1, 1), (8, 1), (Int.max, 1), (0, Int.max)] {
            #expect(try await send(e, "textReplace", ["location": location, "length": length, "name": "x"]) == -1)
            #expect(try await send(e, "textSelect", ["location": location, "length": length]) == -1)
        }
        #expect(try await send(e, "textSetContent", ["name": String(repeating: "x", count: 100_001)]) == -1)
        #expect(e.session.textDraft?.style == original.style)
        #expect(e.session.textDraft?.selection == original.selection)
    }

    @Test func wholeStringFallbackPreservesRunsAcrossUnicodeEdits() async throws {
        let e = editor()
        #expect(try await send(e, "textSetContent", ["name": "A🦊BCDEF"]) == 0)
        #expect(e.session.textDraft?.style.colorRuns?.first?.location == 3)
        #expect(try await send(e, "textSetContent", ["name": "A🦊BDEF"]) == 0)
        #expect(e.session.textDraft?.style.colorRuns?.first?.length == 2)
        #expect(try await send(e, "textSetContent", ["name": ""]) == 0)
        #expect(e.session.textDraft?.style.colorRuns == nil)
        #expect(e.session.textDraft?.style.fontRuns == nil)
    }

    @Test(arguments: ["wholeRun", "rightBoundary", "leftBoundary"])
    func replacementsAcrossFontAndColorBoundaries(_ boundary: String) async throws {
        let e = editor()
        let location: Int, length: Int, replacement: String
        let expectedContent: String, expectedRun: LayerTextFontRun?
        switch boundary {
        case "wholeRun":
            (location, length, replacement) = (3, 3, "x")
            expectedContent = "A😀xEF"; expectedRun = nil
        case "rightBoundary":
            (location, length, replacement) = (4, 3, "🦊")
            expectedContent = "A😀B🦊F"
            expectedRun = LayerTextFontRun(location: 3, length: 3, fontName: "Monospace")
        default:
            (location, length, replacement) = (0, 4, "Hi")
            expectedContent = "HiCDEF"
            expectedRun = LayerTextFontRun(location: 2, length: 2, fontName: "Monospace")
        }
        #expect(try await send(e, "textReplace", ["location": location, "length": length, "name": replacement]) == 0)
        let style = try #require(e.session.textDraft?.style)
        #expect(style.content == expectedContent)
        #expect(style.fontRuns == expectedRun.map { [$0] })
        #expect(style.colorRuns?.map { NSRange(location: $0.location, length: $0.length) } ==
                expectedRun.map { [NSRange(location: $0.location, length: $0.length)] })
        #expect(try await send(e, "textFinish") == 0)
        #expect(try await send(e, "undo") == 0)
        #expect(try await send(e, "redo") == 0)
        #expect(e.session.activeLayer?.liveText?.style == style)
    }

    @Test func restoresDeletedTextWithItsExactAttributes() async throws {
        let e = editor()
        e.session.textDraft?.style.tracking = 3
        e.session.textDraft?.style.leading = 90
        let original = try #require(e.session.textDraft)
        #expect(try await send(e, "textReplace", ["location": 0, "length": 6, "name": "Q"]) == 0)
        #expect(e.session.textDraft?.style.fontRuns == nil)
        let style = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original.style))
        #expect(try await send(e, "textRestore", ["draftID": original.id.uuidString, "textStyle": style,
                                                "location": 3, "length": 3]) == 0)
        #expect(e.session.textDraft?.style == original.style)
        #expect(e.session.textDraft?.selection == NSRange(location: 3, length: 3))
    }

    @Test(arguments: ["staleDraft", "badFontRange", "tooLong", "splitSurrogate"])
    func rejectsInvalidNativeHistory(_ defect: String) async throws {
        let e = editor(), original = try #require(e.session.textDraft)
        var style = original.style
        var id = original.id, location = 0
        switch defect {
        case "staleDraft": id = UUID()
        case "badFontRange": style.fontRuns = [LayerTextFontRun(location: 0, length: 99, fontName: "System")]
        case "tooLong": style.content = String(repeating: "x", count: 100_001)
        default: location = 2
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style))
        #expect(try await send(e, "textRestore", ["draftID": id.uuidString, "textStyle": encoded,
                                                "location": location, "length": 0]) == -1)
        #expect(e.session.textDraft?.style == original.style)
        #expect(e.session.textDraft?.selection == original.selection)
    }

    @Test func largeRestorationUsesTheProjectMetadataBudget() async throws {
        let handle = await Task.detached { compositorSessionCreate() }.value
        defer { Sessions.entries.removeValue(forKey: handle) }
        let e = try #require(Sessions.entries[handle]?.editor)
        #expect(e.importRGBA([UInt8](repeating: 255, count: 16 * 16 * 4), width: 16, height: 16, name: "Canvas", replacing: true) == 0)
        e.session.beginText(at: .zero, newLayer: true)
        let original = try #require(e.session.textDraft)
        var style = original.style
        style.content = String(repeating: "x", count: 10_000)
        style.fontRuns = (0..<10_000).map {
            LayerTextFontRun(location: $0, length: 1, fontName: String(repeating: "f", count: 100) + String($0))
        }
        var fields: [String: Any] = ["version": 1, "action": "textRestore", "draftID": original.id.uuidString,
            "textStyle": try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)), "location": 10_000, "length": 0]
        let restoration = try JSONSerialization.data(withJSONObject: fields)
        #expect(restoration.count > 1_048_576 && restoration.count < 4 * 1_048_576)
        #expect(await e.commandAsync(restoration) == 0)
        #expect(e.session.textDraft?.style == style)
        fields["action"] = "textSetContent"
        let oversizedOrdinaryCommand = try JSONSerialization.data(withJSONObject: fields)
        #expect(await Task.detached {
            oversizedOrdinaryCommand.withUnsafeBytes { compositorSessionCommand(handle, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count) }
        }.value == -1)
        #expect(await Task.detached {
            let tooLarge = [UInt8](repeating: 32, count: 4 * 1_048_576 + 1)
            return compositorSessionCommand(handle, tooLarge, tooLarge.count)
        }.value == -1)
        #expect(e.session.textDraft?.style == style)
    }
}
