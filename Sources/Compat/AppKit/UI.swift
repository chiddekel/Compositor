import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import UniformTypeIdentifiers

// UI types the model layer names. They are inert containers; anything interactive is an injectable hook
// so the Qt host (or a test) supplies the behaviour.

public enum NSApplication {
    public enum ModalResponse: Int { case OK = 1, cancel = 0, stop = -1000, abort = -1001, continue_ = -1002
        case alertFirstButtonReturn = 1000, alertSecondButtonReturn = 1001, alertThirdButtonReturn = 1002 }
}
public typealias NSModalResponse = NSApplication.ModalResponse

/// Model code asks questions through alerts; the host installs `handler` (Qt message box). Headless default:
/// choose the first button, like pressing Return.
@MainActor open class NSAlert {
    public enum Style: Int, Sendable { case warning, informational, critical }
    public var alertStyle: Style = .warning
    public var messageText = ""
    public var informativeText = ""
    public private(set) var buttonTitles: [String] = []
    public private(set) var buttons: [NSButton] = []
    nonisolated(unsafe) public static var handler: ((NSAlert) -> NSApplication.ModalResponse)?
    public init() {}
    @discardableResult public func addButton(withTitle title: String) -> NSButton {
        buttonTitles.append(title)
        let button = NSButton(frame: .zero)
        button.title = title
        buttons.append(button)
        return button
    }
    public func runModal() -> NSApplication.ModalResponse { Self.handler?(self) ?? .alertFirstButtonReturn }
    /// As AppKit does: a sheet attached to `window` (`attachedSheet`) holding the alert's buttons, answered when one of
    /// them is clicked. The host's `handler` (a Qt message box) takes precedence; a window never shown answers
    /// headlessly with the first button, as `runModal` does.
    public func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse {
        if Self.handler != nil || !window.isVisible { return runModal() }
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled],
                             backing: .buffered, defer: false)
        let content = NSView(frame: sheet.frame)
        sheet.contentView = content
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            var answered = false
            for (index, button) in buttons.enumerated() {
                content.addSubview(button)
                button.clickHandler = {
                    guard !answered else { return }
                    answered = true
                    continuation.resume(returning: NSApplication.ModalResponse(rawValue: 1000 + index) ?? .cancel)
                }
            }
            window.attachedSheet = sheet
            sheet.isVisible = true
        }
        window.attachedSheet = nil
        sheet.orderOut(nil)
        return response
    }
}

@MainActor open class NSSavePanel {
    public var allowedContentTypes: [UTType] = []
    public var nameFieldStringValue = ""
    public var title = ""
    public var canCreateDirectories = false
    public var isExtensionHidden = true
    public var url: URL?
    nonisolated(unsafe) public static var handler: ((NSSavePanel) -> NSApplication.ModalResponse)?
    public init() {}
    public func runModal() -> NSApplication.ModalResponse { Self.handler?(self) ?? .cancel }
    public func begin() async -> NSApplication.ModalResponse { runModal() }
    public func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse { runModal() }
}

open class NSOpenPanel: NSSavePanel {
    public var allowsMultipleSelection = false
    public var canChooseDirectories = false
    public var canChooseFiles = true
    public var treatsFilePackagesAsDirectories = false
    public var urls: [URL] = []
    nonisolated(unsafe) public static var openHandler: ((NSOpenPanel) -> NSApplication.ModalResponse)?
    public override func runModal() -> NSApplication.ModalResponse { Self.openHandler?(self) ?? .cancel }
}

/// Recent-documents bookkeeping; the Qt shell may mirror it into its own recent-files menu.
@MainActor public final class NSDocumentController {
    public static let shared = NSDocumentController()
    public private(set) var recentDocumentURLs: [URL] = []
    nonisolated(unsafe) public static var onNoteRecent: ((URL) -> Void)?
    public func noteNewRecentDocumentURL(_ url: URL) {
        recentDocumentURLs.removeAll { $0 == url }
        recentDocumentURLs.insert(url, at: 0)
        Self.onNoteRecent?(url)
    }
    public func clearRecentDocuments(_ sender: Any?) { recentDocumentURLs = [] }
}
