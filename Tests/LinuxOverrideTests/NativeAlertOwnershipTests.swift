import AppKit
import Foundation
import Testing
@testable import Compositor

@MainActor private enum AlertOwnershipRecorder {
    static var handles: [UInt64] = []
    static var titles: [String] = []
    static var choices: [String] = []
    static let presenter: NativeSessionAlertPresenter = { handle, title, _, buttons in
        onMain {
            handles.append(handle)
            titles.append(title.map { String(cString: $0) } ?? "")
            choices = buttons.flatMap { try? JSONDecoder().decode([String].self, from: Data(String(cString: $0).utf8)) } ?? []
            return 1
        }
    }
}

@MainActor struct NativeAlertOwnershipTests {
    private func alert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Owned project alert"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    @Test func explicitSheetWindowOverridesTheOtherCallerInBothDirections() async throws {
        let saved = NSAlert.handler
        defer { NSAlert.handler = saved }
        AlertOwnershipRecorder.handles = []
        compositorSetSessionAlertPresenter(AlertOwnershipRecorder.presenter)
        let first = compositorSessionCreate(), second = compositorSessionCreate()
        defer { compositorSessionClose(first); compositorSessionClose(second) }
        for (owner, caller) in [(first, second), (second, first)] {
            let entry = try #require(Sessions.entries[owner])
            let window = UpstreamCanvases.canvas(owner, entry).window
            let alert = alert()
            let task = ShellProjects.$requestOwner.withValue(caller) {
                Task { @MainActor in await alert.beginSheetModal(for: window) }
            }
            #expect(await task.value == .alertSecondButtonReturn)
            #expect(AlertOwnershipRecorder.handles.last == owner)
            #expect(alert.presentationWindow == nil)
        }
        #expect(AlertOwnershipRecorder.handles == [first, second])
        #expect(AlertOwnershipRecorder.titles.suffix(2) == ["Owned project alert", "Owned project alert"])
        #expect(AlertOwnershipRecorder.choices == ["Continue", "Cancel"])
        #expect(ShellProjects.requestOwner == nil)
    }

    @Test func modalAlertsUseTheirRequestOwnerAndUnownedAlertsRemainApplicationLevel() {
        let saved = NSAlert.handler
        defer { NSAlert.handler = saved }
        AlertOwnershipRecorder.handles = []
        compositorSetSessionAlertPresenter(AlertOwnershipRecorder.presenter)
        let handle = compositorSessionCreate()
        defer { compositorSessionClose(handle) }
        #expect(ShellProjects.$requestOwner.withValue(handle) { alert().runModal() } == .alertSecondButtonReturn)
        #expect(alert().runModal() == .alertSecondButtonReturn)
        #expect(AlertOwnershipRecorder.handles == [handle, 0])
    }

    @Test func closedSheetAndRequestOwnersNeverFallBackToTheSurvivor() async throws {
        let saved = NSAlert.handler
        defer { NSAlert.handler = saved }
        AlertOwnershipRecorder.handles = []
        compositorSetSessionAlertPresenter(AlertOwnershipRecorder.presenter)
        let closing = compositorSessionCreate(), survivor = compositorSessionCreate()
        defer { compositorSessionClose(closing); compositorSessionClose(survivor) }
        let entry = try #require(Sessions.entries[closing])
        let window = UpstreamCanvases.canvas(closing, entry).window
        compositorSessionClose(closing)
        let task = ShellProjects.$requestOwner.withValue(survivor) {
            Task { @MainActor in await alert().beginSheetModal(for: window) }
        }
        #expect(await task.value == .cancel)
        #expect(ShellProjects.$requestOwner.withValue(closing) { alert().runModal() } == .cancel)
        #expect(AlertOwnershipRecorder.handles.isEmpty)
        #expect(Sessions.entries[survivor] != nil)
    }

    @Test func legacyPresenterAndClearingRemainCompatible() {
        let saved = NSAlert.handler
        defer { NSAlert.handler = saved }
        compositorSetAlertPresenter { _, _, _ in 1 }
        #expect(alert().runModal() == .alertSecondButtonReturn)
        compositorSetSessionAlertPresenter(nil)
        #expect(alert().runModal() == .alertFirstButtonReturn)
    }
}
