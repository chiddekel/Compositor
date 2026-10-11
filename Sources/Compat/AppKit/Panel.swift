// NSPanel/NSWindowDelegate and the handful of NSWindow members real floating-panel code needs
// (Compositor/UI/FloatingPanel.swift) beyond what View.swift's NSWindow already covers.

import Foundation

@MainActor public protocol NSWindowDelegate: AnyObject {
    func windowDidMove(_ notification: Notification)
    func windowWillClose(_ notification: Notification)
    func windowShouldClose(_ sender: NSWindow) -> Bool
}
extension NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool { true }
    public func windowDidMove(_ notification: Notification) {}
    public func windowWillClose(_ notification: Notification) {}
}

@MainActor open class NSPanel: NSWindow {
    public var isFloatingPanel = false
    public var hidesOnDeactivate = false
}

extension NSWindow {
    public enum TitleVisibility: Int, Sendable { case visible = 0, hidden = 1 }
}

extension NSWindow {
    /// Posted by `frame`'s setter on every move/resize and by `close()`, as AppKit posts them.
    public static let didResizeNotification = Notification.Name("NSWindowDidResizeNotification")
    public static let didMoveNotification = Notification.Name("NSWindowDidMoveNotification")
    public static let willCloseNotification = Notification.Name("NSWindowWillCloseNotification")
    public func setFrame(_ frameRect: CGRect, display: Bool) { frame = frameRect }
}

extension NSWindow {
    public var isReleasedWhenClosed: Bool {
        get { _isReleasedWhenClosed }
        set { _isReleasedWhenClosed = newValue }
    }
    public var delegate: (any NSWindowDelegate)? {
        get { _delegate }
        set { _delegate = newValue }
    }
    /// Screen-space top-left-origin placement; this compat has no real display, so it just records the frame.
    public func setFrameTopLeftPoint(_ point: NSPoint) {
        frame = CGRect(x: point.x, y: point.y - frame.height, width: frame.width, height: frame.height)
    }
    public func setFrameOrigin(_ point: NSPoint) {
        frame = CGRect(origin: point, size: frame.size)
    }
    public func setContentSize(_ size: CGSize) {
        contentView?.updateConstraints()
        let minimum = contentMinSize, maximum = contentMaxSize
        let bounded = CGSize(width: min(max(size.width, minimum.width), maximum.width),
                             height: min(max(size.height, minimum.height), maximum.height))
        frame = CGRect(origin: frame.origin, size: bounded)
    }
    /// Centers the window on its screen, a little above the middle as AppKit puts it.
    public func center() {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
        origin.y += (screen.height - frame.height) / 6
        setFrameOrigin(origin)
    }
    public func makeKey() { isVisible = true }
    public func convertToScreen(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: frame.minX, dy: frame.minY) }
}

// Backing storage for the two computed properties above — an associated-object-style side table would be more
// "real AppKit", but this compat's `NSWindow` isn't `@objc`, so a private extension-owned dictionary is simpler.
extension NSWindow {
    private static var releaseFlags: [ObjectIdentifier: Bool] = [:]
    /// AppKit's window delegate is a weak reference; a strong side table kept closed panels (and their
    /// controllers, which hold their panels) alive for the whole process, so they never left `NSApp.windows`
    /// and `first { identifier }` found a stale invisible panel instead of a freshly shown one.
    private final class WeakDelegate {
        init(_ value: (any NSWindowDelegate)?) { self.value = value }
        weak var value: (any NSWindowDelegate)?
    }
    private static var delegates: [ObjectIdentifier: WeakDelegate] = [:]
    fileprivate var _isReleasedWhenClosed: Bool {
        get { Self.releaseFlags[ObjectIdentifier(self)] ?? true }
        set { Self.releaseFlags[ObjectIdentifier(self)] = newValue }
    }
    fileprivate var _delegate: (any NSWindowDelegate)? {
        get {
            guard let box = Self.delegates[ObjectIdentifier(self)], let value = box.value else {
                Self.delegates[ObjectIdentifier(self)] = nil
                return nil
            }
            return value
        }
        set { Self.delegates[ObjectIdentifier(self)] = newValue.map(WeakDelegate.init) }
    }
}
