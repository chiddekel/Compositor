import Foundation
import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct NativeSymbolAccessibilityTests {
    private struct ExistingView: @preconcurrency NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @Test(arguments: [false, true])
    func symbolDescriptionsNameNativeIconButtons(configured: Bool) throws {
        let title = "Expand or collapse folder"
        let original = try #require(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: title))
        let image = configured ? try #require(original.withSymbolConfiguration(.init(paletteColors: [.white]))) : original
        #expect(image.accessibilityDescription == title)
        #expect(original.accessibilityDescription == title)
        #expect(image.symbolName == "chevron.down")
        #expect(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.accessibilityDescription == nil)

        let root = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        let button = NSButton(image: image, target: nil, action: nil)
        button.frame = CGRect(x: 8, y: 16, width: 16, height: 24)
        root.addSubview(button)
        let scope = "symbolAccessibility-\(UUID())"
        let wasActive = NativeLowering.isActive
        try #require(StateStore.begin(scope: scope))
        NativeLowering.isActive = true
        defer {
            StateStore.end()
            StateStore.discard(scope: scope)
            NativeLowering.discard(scope: scope)
            NativeLowering.isActive = wasActive
        }
        let tree = ViewResolver.resolve(ExistingView(view: root))
        func snapshot(_ node: RenderNode) -> ((Any) -> Void)? {
            node.handlers["accessibilitySnapshot"] ?? node.children.lazy.compactMap(snapshot).first
        }
        let handler = try #require(snapshot(tree))
        let box = NativeAccessibilityBox()
        handler(box)
        let value = try #require(JSONSerialization.jsonObject(with: box.data) as? [String: Any])
        let children = try #require(value["children"] as? [[String: Any]])
        let element = try #require(children.first { $0["label"] as? String == title })
        #expect(element["role"] as? String == "button")
        #expect(element["press"] as? Bool == true)
        #expect(element["enabled"] as? Bool == true)
        #expect(element["width"] as? Double == 16)
        #expect(element["height"] as? Double == 24)
    }
}
