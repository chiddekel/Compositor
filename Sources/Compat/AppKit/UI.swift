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
extension NSApplication {
    /// Posted when the app comes to the front (the host posts it on window activation).
    public static let didBecomeActiveNotification = Notification.Name("NSApplicationDidBecomeActiveNotification")
    public static let didResignActiveNotification = Notification.Name("NSApplicationDidResignActiveNotification")
}

/// Menu tracking notifications HeldModifiers observes (a key released while a menu is open never reaches the app).
public enum NSMenu {
    public static let didEndTrackingNotification = Notification.Name("NSMenuDidEndTrackingNotification")
}

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
    /// Most recent first, kept across launches (macOS keeps the list per app; here in the app's defaults), at most
    /// `maximumRecentDocumentCount`.
    public private(set) var recentDocumentURLs: [URL]
    public var maximumRecentDocumentCount = 10
    nonisolated(unsafe) public static var onNoteRecent: ((URL) -> Void)?
    private static let defaultsKey = "NSRecentDocumentURLs"
    init() {
        recentDocumentURLs = (UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }
    public func noteNewRecentDocumentURL(_ url: URL) {
        recentDocumentURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentDocumentURLs.insert(url, at: 0)
        if recentDocumentURLs.count > maximumRecentDocumentCount { recentDocumentURLs.removeLast(recentDocumentURLs.count - maximumRecentDocumentCount) }
        save()
        Self.mirrorFreedesktopRecent(url)
        Self.onNoteRecent?(url)
    }
    public func clearRecentDocuments(_ sender: Any?) { recentDocumentURLs = []; save() }
    private func save() {
        UserDefaults.standard.set(recentDocumentURLs.map(\.path), forKey: Self.defaultsKey)
        UserDefaults.standard.synchronize()   // written now, not at some later flush a quit can beat
    }

    /// Freedesktop recently-used.xbel so file managers / Open dialogs see projects opened in Compositor
    /// (macOS uses Launch Services; Flatpak sandboxes may still ignore host xbel).
    private static func mirrorFreedesktopRecent(_ url: URL) {
        let fileURL = url.standardizedFileURL
        guard fileURL.isFileURL else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let xbel = dir.appendingPathComponent("recently-used.xbel")
        let href = fileURL.absoluteString
        let stamp = ISO8601DateFormatter().string(from: Date())
        let epoch = String(Int(Date().timeIntervalSince1970))
        var existing = (try? String(contentsOf: xbel, encoding: .utf8)) ?? ""
        if existing.isEmpty {
            existing = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xbel version="1.0"
                  xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks"
                  xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info">
            </xbel>
            """
        }
        // Drop a prior bookmark for the same file, then insert this one at the top.
        let marker = "<bookmark href=\"\(href)\""
        if let start = existing.range(of: marker) {
            if let end = existing.range(of: "</bookmark>", range: start.lowerBound..<existing.endIndex) {
                existing.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        let mime = fileURL.pathExtension.lowercased() == "comp" || fileURL.pathExtension.lowercased() == "compositor"
            ? "application/x-compositor-project" : "application/octet-stream"
        let bookmark = """
          <bookmark href="\(href)" added="\(stamp)" modified="\(stamp)" visited="\(stamp)">
            <info>
              <metadata owner="http://freedesktop.org">
                <mime:mime-type type="\(mime)"/>
                <bookmark:applications>
                  <bookmark:application name="Compositor" exec="compositor %u" count="1" timestamp="\(epoch)"/>
                </bookmark:applications>
              </metadata>
            </info>
          </bookmark>
        """
        if let insert = existing.range(of: "<xbel") {
            // After the opening <xbel ...> tag
            if let close = existing[insert.lowerBound...].range(of: ">") {
                existing.insert(contentsOf: "\n" + bookmark, at: close.upperBound)
            }
        }
        try? existing.write(to: xbel, atomically: true, encoding: .utf8)
    }
}
