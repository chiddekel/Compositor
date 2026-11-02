import AppKit
import Testing
@testable import Compositor

@MainActor
struct PopUpMenuTests {
    private final class Target: NSSelectorDispatching {
        var calls = 0
        func compatResponds(to selector: Selector) -> Bool { true }
        func compatPerform(_ selector: Selector, with argument: Any?) -> Bool { calls += 1; return true }
    }
    @Test func nestedChoicesRetainIdentityAndRespectDisabledParents() async throws {
        let target = Target(), root = NSMenu(title: "Root"), child = NSMenu(title: "Child")
        root.autoenablesItems = false; child.autoenablesItems = false
        let hidden = NSMenuItem(title: "Hidden", action: Selector("invoke:"), keyEquivalent: "")
        hidden.isHidden = true; child.addItem(hidden)
        child.addItem(NSMenuItem.separator())
        let leaf = NSMenuItem(title: "Leaf", action: Selector("invoke:"), keyEquivalent: "")
        leaf.target = target; child.addItem(leaf)
        let parent = NSMenuItem(title: "Parent", action: nil, keyEquivalent: "")
        parent.submenu = child; root.addItem(parent)
        let previous = PopUpMenus.current
        defer { PopUpMenus.current = previous }
        for enabled in [true, false] {
            parent.isEnabled = enabled
            var finished = false
            PopUpMenus.current = PopUpMenus.Presentation(menu: root, finish: { _ in finished = true })
            let items = PopUpMenus.items()
            let nested = try #require(items.first?.children)
            #expect(nested.count == 2 && nested[0].separator)
            #expect(nested[1].title == "Leaf" && nested[1].enabled == enabled)
            let id = nested[1].id
            #expect(PopUpMenus.items().first?.children?.last?.id == id)
            await Task.detached { compositorPopUpMenuChoose(Int32(id)) }.value
            #expect(finished && PopUpMenus.current == nil)
            #expect(target.calls == 1)
        }
    }
}
