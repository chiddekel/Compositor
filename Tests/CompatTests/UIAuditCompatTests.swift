import SwiftUI
import XCTest

/// Compat behavior behind the 2026-10-18 UI audit fixes (host/UIAuditJourney.h checks what the shell draws from it).
final class UIAuditCompatTests: XCTestCase {
    private struct Preset: Hashable { let title: String; let width: Int; let height: Int }

    private func tags(in node: RenderNode) -> [String] {
        var found: [String] = []
        for modifier in node.modifiers { if case let .tag(text) = modifier { found.append(text) } }
        return found + node.children.flatMap(tags)
    }

    /// New Canvas's presets: a Picker over `CanvasPreset?` (neither an enum nor a string) sets the value the chosen
    /// row was tagged with, and Custom (`nil`) sets nil again.
    func testStructTagsSelectTheTaggedValue() throws {
        let square = Preset(title: "Instagram Square", width: 1080, height: 1080)
        let story = Preset(title: "Instagram Story", width: 1080, height: 1920)
        var chosen: Preset? = nil
        let picker = Picker("Size", selection: Binding<Preset?>(get: { chosen }, set: { chosen = $0 })) {
            Text("Custom").tag(Preset?.none)
            ForEach([square, story], id: \.self) { Text($0.title).tag(Preset?.some($0)) }
        }
        let node = ViewResolver.resolve(picker)
        let select = try XCTUnwrap(node.handlers["selection"])
        let sent = tags(in: node)
        XCTAssertEqual(sent.count, 3)
        select(sent[2])
        XCTAssertEqual(chosen, story)
        select(sent[1])
        XCTAssertEqual(chosen, square)
        select(sent[0])
        XCTAssertNil(chosen)
    }

    /// FilterSheet's slider titles: each row puts a GeometryReader in a `.background` from one body; each reader has
    /// its own place, so the sizes the shell reports for them don't overwrite one another.
    func testBackgroundReadersInOneBodyHaveTheirOwnPlace() {
        struct Rows: View {
            var body: some View {
                // As FilterSheet's `control(...)` helper: the rows are built while this one body is evaluated.
                VStack {
                    row("Line Spacing")
                    row("Thickness")
                    row("Black Level")
                }
            }
            func row(_ title: String) -> some View { Text(title).fixedSize().background(GeometryReader { _ in Color.clear }) }
        }
        XCTAssertTrue(StateStore.begin(scope: "UIAuditCompatTests"))
        let node = ViewResolver.resolve(Rows())
        StateStore.end()
        func keys(_ node: RenderNode) -> [String] {
            (node.kind == "GeometryReader" ? [node.stringParams["geometryKey"] ?? ""] : []) + node.children.flatMap(keys)
        }
        let found = keys(node)
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(Set(found).count, 3, "readers share a size key: \(found)")
        // The same body resolved again gives each reader the same place as before.
        XCTAssertTrue(StateStore.begin(scope: "UIAuditCompatTests"))
        let again = ViewResolver.resolve(Rows())
        StateStore.end()
        XCTAssertEqual(keys(again), found)
    }
}
