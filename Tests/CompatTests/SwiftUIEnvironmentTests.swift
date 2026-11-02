// Tip Layers footer FooterIcon uses @Environment(\.isEnabled) under .disabled — verify resolve pushes it.

import SwiftUI
import XCTest

final class SwiftUIEnvironmentTests: XCTestCase {
    private struct Probe: View {
        @Environment(\.isEnabled) var isEnabled
        var body: some View {
            Text(isEnabled ? "on" : "off")
        }
    }

    func testDisabledPushesIsEnabledFalse() {
        EnvironmentValues.current.isEnabled = true
        let enabled = ViewResolver.resolve(Probe())
        XCTAssertEqual(Self.text(in: enabled), "on")

        let disabled = ViewResolver.resolve(Probe().disabled(true))
        XCTAssertEqual(Self.text(in: disabled), "off")
        // Outer environment restored after resolve.
        XCTAssertTrue(EnvironmentValues.current.isEnabled)
    }

    private static func text(in node: RenderNode) -> String? {
        if node.kind == "Text" { return node.stringParams["text"] }
        for child in node.children {
            if let t = text(in: child) { return t }
        }
        return nil
    }
}
