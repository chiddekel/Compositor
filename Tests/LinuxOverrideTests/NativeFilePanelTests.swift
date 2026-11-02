import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor private enum FilePanelRecorder {
    static var handles: [UInt64] = []
    static var options: [[String: Any]] = []
    static var paths = ["/tmp/Panel 雪\n\"image\".png"]
    static var forcedResponse: Int64?
    static let picker: SessionFilePanelFunction = { handle, descriptor, output, capacity in
        onMain {
            handles.append(handle)
            let data = Data((descriptor.map { String(cString: $0) } ?? "").utf8)
            options.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            if let forcedResponse { return forcedResponse }
            let encoded = (try? JSONEncoder().encode(paths)) ?? Data()
            guard let output, capacity >= encoded.count else { return -Int64(encoded.count) }
            encoded.copyBytes(to: output, count: encoded.count)
            return Int64(encoded.count)
        }
    }
    static func reset() {
        handles = []; options = []; paths = ["/tmp/Panel 雪\n\"image\".png"]; forcedResponse = nil
    }
}

@MainActor struct NativeFilePanelTests {
    @Test func explicitOpenAndSaveWindowsOverrideTheCallerInBothDirections() async throws {
        let savedOpen = NSOpenPanel.openHandler, savedSave = NSSavePanel.handler
        defer { NSOpenPanel.openHandler = savedOpen; NSSavePanel.handler = savedSave }
        FilePanelRecorder.reset()
        compositorSetSessionFilePanel(FilePanelRecorder.picker)
        let first = compositorSessionCreate(), second = compositorSessionCreate()
        defer { compositorSessionClose(first); compositorSessionClose(second) }
        for (owner, caller) in [(first, second), (second, first)] {
            let entry = try #require(Sessions.entries[owner])
            let window = UpstreamCanvases.canvas(owner, entry).window
            for saving in [false, true] {
                let panel: NSSavePanel = saving ? NSSavePanel() : NSOpenPanel()
                panel.title = saving ? "Save Project As" : "Open Images"
                panel.message = "Choose a destination"
                panel.allowedContentTypes = saving ? [.compositorProject] : [.png]
                panel.nameFieldStringValue = "A project.comp"
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                (panel as? NSOpenPanel)?.allowsMultipleSelection = true
                let task = ShellProjects.$requestOwner.withValue(caller) {
                    Task { @MainActor in await panel.beginSheetModal(for: window) }
                }
                #expect(await task.value == .OK)
                #expect(FilePanelRecorder.handles.last == owner)
                #expect(panel.url?.path == FilePanelRecorder.paths.first)
                #expect(panel.presentationWindow == nil)
                let options = try #require(FilePanelRecorder.options.last)
                #expect(options["save"] as? Bool == saving)
                #expect(options["title"] as? String == panel.title)
                #expect(options["message"] as? String == panel.message)
                #expect(options["name"] as? String == "A project.comp")
                #expect(options["extensions"] as? [String] == (saving ? ["comp"] : ["png"]))
                #expect(options["createDirectories"] as? Bool == true)
                #expect(options["extensionHidden"] as? Bool == false)
                if let open = panel as? NSOpenPanel {
                    #expect(open.urls.map(\.path) == FilePanelRecorder.paths)
                    #expect(options["multiple"] as? Bool == true)
                }
            }
        }
        #expect(FilePanelRecorder.handles == [first, first, second, second])
        #expect(ShellProjects.requestOwner == nil)
    }

    @Test func modalOwnersAndApplicationPanelsRemainDistinct() {
        let savedOpen = NSOpenPanel.openHandler, savedSave = NSSavePanel.handler
        defer { NSOpenPanel.openHandler = savedOpen; NSSavePanel.handler = savedSave }
        FilePanelRecorder.reset()
        compositorSetSessionFilePanel(FilePanelRecorder.picker)
        let owner = compositorSessionCreate()
        defer { compositorSessionClose(owner) }
        #expect(ShellProjects.$requestOwner.withValue(owner) { NSSavePanel().runModal() } == .OK)
        #expect(NSOpenPanel().runModal() == .OK)
        #expect(FilePanelRecorder.handles == [owner, 0])
    }

    @Test func closedOwnersCancelWithoutInvokingThePicker() async throws {
        let savedOpen = NSOpenPanel.openHandler, savedSave = NSSavePanel.handler
        defer { NSOpenPanel.openHandler = savedOpen; NSSavePanel.handler = savedSave }
        FilePanelRecorder.reset()
        compositorSetSessionFilePanel(FilePanelRecorder.picker)
        let closing = compositorSessionCreate(), survivor = compositorSessionCreate()
        defer { compositorSessionClose(closing); compositorSessionClose(survivor) }
        let entry = try #require(Sessions.entries[closing])
        let window = UpstreamCanvases.canvas(closing, entry).window
        compositorSessionClose(closing)
        for saving in [false, true] {
            let panel: NSSavePanel = saving ? NSSavePanel() : NSOpenPanel()
            let task = ShellProjects.$requestOwner.withValue(survivor) {
                Task { @MainActor in await panel.beginSheetModal(for: window) }
            }
            #expect(await task.value == .cancel)
            #expect(panel.url == nil)
        }
        #expect(ShellProjects.$requestOwner.withValue(closing) { NSSavePanel().runModal() } == .cancel)
        #expect(FilePanelRecorder.handles.isEmpty)
    }

    @Test func largeUnicodeAndNewlinePathListsRetryWithoutSplittingNames() {
        let savedOpen = NSOpenPanel.openHandler, savedSave = NSSavePanel.handler
        defer { NSOpenPanel.openHandler = savedOpen; NSSavePanel.handler = savedSave }
        FilePanelRecorder.reset()
        FilePanelRecorder.paths = (0..<500).map { "/tmp/雪/\($0)-\(String(repeating: "x", count: 180))\n.png" }
        compositorSetSessionFilePanel(FilePanelRecorder.picker)
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        #expect(panel.runModal() == .OK)
        #expect(panel.urls.map(\.path) == FilePanelRecorder.paths)
        #expect(FilePanelRecorder.handles == [0, 0])
        #expect(FilePanelRecorder.options.count == 2)
    }

    @Test func cancellationEmptySelectionsAndInvalidCapacityRepliesDoNotSucceed() {
        let savedOpen = NSOpenPanel.openHandler, savedSave = NSSavePanel.handler
        defer { NSOpenPanel.openHandler = savedOpen; NSSavePanel.handler = savedSave }
        FilePanelRecorder.reset()
        compositorSetSessionFilePanel(FilePanelRecorder.picker)
        for response: Int64 in [0, -1, Int64.min, -100_000_000] {
            FilePanelRecorder.forcedResponse = response
            let panel = NSSavePanel()
            #expect(panel.runModal() == .cancel)
            #expect(panel.url == nil)
        }
        FilePanelRecorder.forcedResponse = nil; FilePanelRecorder.paths = []
        #expect(NSOpenPanel().runModal() == .cancel)
        let disabled = NSOpenPanel(); disabled.canChooseFiles = false; disabled.canChooseDirectories = false
        let calls = FilePanelRecorder.handles.count
        #expect(disabled.runModal() == .cancel)
        #expect(FilePanelRecorder.handles.count == calls)
    }

    @Test func legacyOpenRegistrationAndClearingRemainCompatible() {
        let savedOpen = NSOpenPanel.openHandler, savedSave = NSSavePanel.handler
        defer { NSOpenPanel.openHandler = savedOpen; NSSavePanel.handler = savedSave }
        compositorSetSessionFilePanel(FilePanelRecorder.picker)
        compositorSetOpenPanel { _, _, _, _, _, output, capacity in
            let bytes = "/tmp/legacy.png".utf8CString
            guard let output, capacity >= bytes.count else { return -Int32(bytes.count) }
            bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }
            return 1
        }
        let panel = NSOpenPanel()
        #expect(panel.runModal() == .OK)
        #expect(panel.urls.map(\.path) == ["/tmp/legacy.png"])
        compositorSetSessionFilePanel(nil)
        #expect(NSOpenPanel().runModal() == .cancel)
        #expect(NSSavePanel().runModal() == .cancel)
    }
}
