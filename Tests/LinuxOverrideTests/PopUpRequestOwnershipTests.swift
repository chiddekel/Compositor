import AppKit
import Testing
@testable import Compositor

@MainActor
struct PopUpRequestOwnershipTests {
    private final class Target: NSSelectorDispatching, NSMenuItemValidation {
        var perform: () -> Void = {}
        var validate: () -> Bool = { true }
        func compatResponds(to selector: Selector) -> Bool { true }
        func compatPerform(_ selector: Selector, with argument: Any?) -> Bool { perform(); return true }
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate() }
    }
    private final class Delegate: NSMenuDelegate {
        var close: () -> Void = {}
        func menuDidClose(_ menu: NSMenu) { close() }
    }

    @Test func delayedChoiceAndCompletionKeepThePresentationOwner() async throws {
        let saved = ShellProjects.pending, presentation = PopUpMenus.current, presenter = NSMenu.presenter
        defer { ShellProjects.pending = saved; PopUpMenus.current = presentation; NSMenu.presenter = presenter }
        ShellProjects.pending = []
        let first = await Task.detached { compositorSessionCreate() }.value
        let second = await Task.detached { compositorSessionCreate() }.value
        let target = Target(), menu = NSMenu(title: "Owned menu"), delegate = Delegate()
        defer { withExtendedLifetime((target, delegate)) {} }
        menu.delegate = delegate
        let item = NSMenuItem(title: "Choose", action: Selector("choose:"), keyEquivalent: "")
        item.target = target; menu.addItem(item)
        var owners: [UInt64?] = []
        var validationOwners: [UInt64?] = []
        var deferred: Task<Void, Never>?
        target.validate = { validationOwners.append(ShellProjects.requestOwner); return true }
        target.perform = {
            owners.append(ShellProjects.requestOwner)
            ShellProjects.enqueue("commandPalette")
            deferred = Task { @MainActor in ShellProjects.enqueue("save") }
        }
        delegate.close = {
            owners.append(ShellProjects.requestOwner)
            ShellProjects.enqueue("showEditor")
        }
        PopUpMenus.install()
        ShellProjects.$requestOwner.withValue(first) {
            _ = menu.popUp(positioning: nil, at: .zero, in: nil)
        }
        let id = try #require(ShellProjects.$requestOwner.withValue(second) { PopUpMenus.items().first?.id })
        let restored = await Task.detached {
            onMain {
                ShellProjects.$requestOwner.withValue(second) {
                    compositorPopUpMenuChoose(Int32(id))
                    return ShellProjects.requestOwner
                }
            }
        }.value
        await deferred?.value
        #expect(owners == [first, first])
        #expect(validationOwners == [first, first])
        #expect(ShellProjects.pending.map(\.name) == ["popUpMenu", "commandPalette", "showEditor", "save"])
        #expect(ShellProjects.pending.map(\.handle) == [first, first, first, first])
        #expect(restored == second && PopUpMenus.current == nil)
        await Task.detached { compositorSessionClose(first); compositorSessionClose(second) }.value
    }

    @Test func closingTheOwnerCancelsItsPopupBeforeAnyLaterChoice() async throws {
        let saved = ShellProjects.pending, presentation = PopUpMenus.current, presenter = NSMenu.presenter
        defer { ShellProjects.pending = saved; PopUpMenus.current = presentation; NSMenu.presenter = presenter }
        ShellProjects.pending = []
        let handle = await Task.detached { compositorSessionCreate() }.value
        let target = Target(), menu = NSMenu(title: "Closing menu"), delegate = Delegate()
        defer { withExtendedLifetime((target, delegate)) {} }
        menu.delegate = delegate
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Choose", action: Selector("choose:"), keyEquivalent: "")
        item.target = target; menu.addItem(item)
        var calls = 0, finishes = 0
        var finishOwner: UInt64?
        target.perform = { calls += 1 }
        delegate.close = { finishes += 1; finishOwner = ShellProjects.requestOwner }
        PopUpMenus.install()
        ShellProjects.$requestOwner.withValue(handle) {
            _ = menu.popUp(positioning: nil, at: .zero, in: nil)
        }
        let id = try #require(PopUpMenus.items().first?.id)
        await Task.detached { compositorSessionClose(handle) }.value
        #expect(PopUpMenus.current == nil && finishes == 1 && finishOwner == handle)
        #expect(ShellProjects.pending.isEmpty)
        await Task.detached { compositorPopUpMenuChoose(Int32(id)) }.value
        #expect(calls == 0 && finishes == 1)
    }

    @Test func replacementAndDismissalFinishUnderEachPresentationOwner() async {
        let saved = ShellProjects.pending, presentation = PopUpMenus.current, presenter = NSMenu.presenter
        defer { ShellProjects.pending = saved; PopUpMenus.current = presentation; NSMenu.presenter = presenter }
        ShellProjects.pending = []
        let first = await Task.detached { compositorSessionCreate() }.value
        let second = await Task.detached { compositorSessionCreate() }.value
        var owners: [UInt64?] = []
        let firstMenu = NSMenu(title: "First"), secondMenu = NSMenu(title: "Second")
        let firstDelegate = Delegate(), secondDelegate = Delegate()
        defer { withExtendedLifetime((firstDelegate, secondDelegate)) {} }
        firstDelegate.close = { owners.append(ShellProjects.requestOwner) }
        secondDelegate.close = { owners.append(ShellProjects.requestOwner) }
        firstMenu.delegate = firstDelegate; secondMenu.delegate = secondDelegate
        PopUpMenus.install()
        ShellProjects.$requestOwner.withValue(first) {
            _ = firstMenu.popUp(positioning: nil, at: .zero, in: nil)
        }
        ShellProjects.$requestOwner.withValue(second) {
            _ = secondMenu.popUp(positioning: nil, at: .zero, in: nil)
        }
        #expect(owners == [first])
        await Task.detached { compositorPopUpMenuChoose(-1) }.value
        #expect(owners == [first, second] && PopUpMenus.current == nil)
        await Task.detached { compositorSessionClose(first); compositorSessionClose(second) }.value
    }
}
