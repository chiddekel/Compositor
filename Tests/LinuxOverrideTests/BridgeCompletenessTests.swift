import Foundation
import Testing
@testable import Compositor

/// The command bridge and the Qt shell agree: every action the shell sends is one the bridge runs, and every action the
/// bridge declares supported has its own case (none falls through to "Unsupported by the upstream bridge yet", -7).
/// Read from the sources, since several actions open sheets that wait for an answer.
@MainActor
struct BridgeCompletenessTests {
    private static let checkout: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent("host").path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }()

    private func matches(_ pattern: String, in text: String, group: Int = 1) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { Range($0.range(at: group), in: text).map { String(text[$0]) } }
    }
    private func quoted(_ text: String) throws -> [String] { try matches(#""(\w+)""#, in: text) }

    /// Actions in the shell's command JSON: `{"action", "x"}` (or `cond ? "x" : "y"`), raw `"action":"x"`,
    /// `cmd["action"] = "x"`. Test fixtures that send an unknown action on purpose are listed as such.
    private func shellActions() throws -> [String: String] {
        let host = Self.checkout.appendingPathComponent("host")
        var found: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: host.path).sorted()
        where name.hasSuffix(".cpp") || name.hasSuffix(".h") {
            let text = try String(contentsOf: host.appendingPathComponent(name), encoding: .utf8)
            // A condition's own strings (`request == QLatin1String("canvasSize") ? …`) are not actions.
            var actions = try matches(#""action"\s*,\s*([^}]*?)\}"#, in: text)
                .map { $0.replacingOccurrences(of: #"QLatin1String\("\w+"\)"#, with: "", options: .regularExpression) }
                .flatMap(quoted)
            actions += try matches(#""action":"(\w+)""#, in: text)
            actions += try matches(#"\["action"\]\s*=\s*"(\w+)""#, in: text)
            for action in actions where found[action] == nil { found[action] = name }
        }
        return found
    }

    /// Deliberately unknown (DialogJourney checks the refusal) or not a bridge command (a SwiftUI button press payload).
    private let notCommands: Set<String> = ["unknownAction", "press"]

    @Test func everyActionTheShellSendsIsSupported() throws {
        let shell = try shellActions()
        #expect(shell.count > 100, "the scan found the shell's commands (\(shell.count))")
        let unsupported = shell.filter { !UpstreamEditor.supportedActions.contains($0.key) && !notCommands.contains($0.key) }
        #expect(unsupported.isEmpty, "sent by the shell, refused with -7: \(unsupported.sorted { $0.key < $1.key })")
    }

    @Test func everySupportedActionHasItsOwnCase() throws {
        let source = try String(contentsOf: Self.checkout.appendingPathComponent("Sources/LinuxBridge/UpstreamEditor.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "func commandAsync"))
        // The switch's own fall-through (the guard above it uses the same message).
        let end = try #require(source.range(of: "default:\n            return fail(-7, \"Unsupported by the upstream bridge yet",
                                            range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let cases = Set(try matches(#"^\s*case ((?:"\w+"\s*,\s*)*"\w+")\s*(?:where[^:]*)?:"#, in: body).flatMap(quoted))
        let missing = UpstreamEditor.supportedActions.subtracting(cases)
        #expect(missing.isEmpty, "declared supported but no case: \(missing.sorted())")
    }

    private func command(_ e: UpstreamEditor, _ action: String, _ fields: String = "") async -> Int32 {
        await e.commandAsync(Data(#"{"version":1,"action":"\#(action)"\#(fields.isEmpty ? "" : "," + fields)}"#.utf8))
    }

    /// View › Clear Guides was refused with -7 before it was a bridge action.
    @Test func clearGuidesRemovesEveryGuideInOneUndoStep() async throws {
        let e = UpstreamEditor()
        #expect(await command(e, "new", #""width":200,"height":100"#) == 0)
        for (axis, value) in [("vertical", 40.0), ("horizontal", 60.0)] {
            #expect(await command(e, "guideCreate", #""kind":"\#(axis)","value":\#(value)"#) == 0)
            #expect(await command(e, "guideFinish") == 0)
        }
        #expect(e.session.document?.guides.count == 2)
        #expect(await command(e, "clearGuides") == 0)
        #expect(e.session.document?.guides.isEmpty == true)
        #expect(await command(e, "undo") == 0)
        #expect(e.session.document?.guides.count == 2)
    }
}
