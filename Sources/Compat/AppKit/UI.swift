import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import UniformTypeIdentifiers

// UI types the model layer names. They are inert containers; anything interactive is an injectable hook
// so the Qt host (or a test) supplies the behaviour.

@MainActor open class NSResponder {}
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
    public var title = ""
    public var isDocumentEdited = false
    public override init() {}
    open func close() {}
}

public enum NSApplication {
    public enum ModalResponse: Int { case OK = 1, cancel = 0, stop = -1000, abort = -1001, continue_ = -1002
        case alertFirstButtonReturn = 1000, alertSecondButtonReturn = 1001, alertThirdButtonReturn = 1002 }
}
public typealias NSModalResponse = NSApplication.ModalResponse

/// Model code asks questions through alerts; the host installs `handler` (Qt message box). Headless default:
/// choose the first button, like pressing Return.
@MainActor open class NSAlert {
    public var messageText = ""
    public var informativeText = ""
    public private(set) var buttonTitles: [String] = []
    nonisolated(unsafe) public static var handler: ((NSAlert) -> NSApplication.ModalResponse)?
    public init() {}
    @discardableResult public func addButton(withTitle title: String) -> AnyObject? { buttonTitles.append(title); return nil }
    public func runModal() -> NSApplication.ModalResponse { Self.handler?(self) ?? .alertFirstButtonReturn }
}

@MainActor open class NSSavePanel {
    public var allowedContentTypes: [UTType] = []
    public var nameFieldStringValue = ""
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
