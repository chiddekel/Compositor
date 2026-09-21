import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import UniformTypeIdentifiers

// UI types the model layer names. They are inert containers; anything interactive is an injectable hook
// so the Qt host (or a test) supplies the behaviour.

@MainActor open class NSResponder {}

/// Hosts a view tree in a window. On Linux it only carries the root view; the Qt shell renders sheets itself.
@MainActor open class NSViewController: NSResponder {
    open var representedRootView: Any?
    public override init() {}
}

/// Something a sheet's root view can implement so a window with no host can settle it (headless: cancel).
@MainActor public protocol SheetAutoResolving { func resolveWithoutHost() }
open class NSView: NSResponder, @unchecked Sendable {
    public var frame: CGRect
    public var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }
    public var needsDisplay = false
    public init(frame: CGRect) { self.frame = frame }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    open var isFlipped: Bool { false }
    open func hitTest(_ point: CGPoint) -> NSView? { nil }
    open func draw(_ dirtyRect: CGRect) {}
    open func setAccessibilityElement(_ isElement: Bool) {}
    open func removeFromSuperview() {}
}

open class NSWindow: NSResponder {
    public struct StyleMask: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let titled = StyleMask(rawValue: 1 << 0), closable = StyleMask(rawValue: 1 << 1)
        public static let miniaturizable = StyleMask(rawValue: 1 << 2), resizable = StyleMask(rawValue: 1 << 3)
        public static let fullSizeContentView = StyleMask(rawValue: 1 << 15)
    }
    public var title = ""
    public var isDocumentEdited = false
    public var representedURL: URL?
    public var styleMask: StyleMask = []
    public var contentViewController: NSViewController?
    public override init() {}
    open func close() {}
    open func orderOut(_ sender: Any?) {}

    /// The Qt shell installs this to show a sheet; without a host the sheet's root view settles itself.
    nonisolated(unsafe) public static var sheetPresenter: ((_ parent: NSWindow, _ sheet: NSWindow) -> Void)?
    open func beginSheet(_ sheet: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let present = NSWindow.sheetPresenter { present(self, sheet); return }
        (sheet.contentViewController?.representedRootView as? SheetAutoResolving)?.resolveWithoutHost()
    }
    open func endSheet(_ sheet: NSWindow) {}
}

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
    nonisolated(unsafe) public static var handler: ((NSAlert) -> NSApplication.ModalResponse)?
    public init() {}
    @discardableResult public func addButton(withTitle title: String) -> AnyObject? { buttonTitles.append(title); return nil }
    public func runModal() -> NSApplication.ModalResponse { Self.handler?(self) ?? .alertFirstButtonReturn }
    public func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse { runModal() }
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
