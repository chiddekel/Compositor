// NSScrollView / NSClipView: a scroll view whose clip view (`contentView`) shows part of a `documentView` by moving
// its own `bounds.origin` — AppKit's model, so code that reads `contentView.bounds`, scrolls with
// `contentView.scroll(to:)` and listens for `NSView.boundsDidChangeNotification` works unchanged. No scrollers are
// drawn (the Qt shell renders its own chrome); geometry, hit-testing and notifications are real.

import Foundation

extension NSView {
    public static let boundsDidChangeNotification = Notification.Name("NSViewBoundsDidChangeNotification")
    public static let frameDidChangeNotification = Notification.Name("NSViewFrameDidChangeNotification")
}

public enum NSBorderType: Int, Sendable { case noBorder, lineBorder, bezelBorder, grooveBorder }

@MainActor open class NSClipView: NSView {
    /// Posts `NSView.boundsDidChangeNotification` (object: this clip view) whenever the visible origin moves.
    public var postsBoundsChangedNotifications = false
    public var drawsBackground = true
    open var documentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let documentView { addSubview(documentView) }
        }
    }
    open override var isFlipped: Bool { documentView?.isFlipped ?? false }

    /// Moves the visible area's origin to `point` (document coordinates), as `NSClipView.scroll(to:)` does.
    open func scroll(to point: CGPoint) {
        let old = bounds
        bounds = CGRect(origin: point, size: frame.size)
        if bounds.origin != old.origin, postsBoundsChangedNotifications {
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: self)
        }
    }
    open override func setFrameSize(_ size: CGSize) {
        super.setFrameSize(size)
        bounds = CGRect(origin: bounds.origin, size: size)
    }
}

@MainActor open class NSScrollView: NSView {
    public enum Elasticity: Int, Sendable { case automatic, none, allowed }

    public let contentView: NSClipView
    public var drawsBackground = true
    public var borderType: NSBorderType = .bezelBorder
    public var hasVerticalScroller = false
    public var hasHorizontalScroller = false
    public var autohidesScrollers = false
    public var verticalScrollElasticity: Elasticity = .automatic
    public var horizontalScrollElasticity: Elasticity = .automatic

    public override init(frame: CGRect) {
        contentView = NSClipView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        addSubview(contentView)
    }
    public convenience init() { self.init(frame: .zero) }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    open var documentView: NSView? {
        get { contentView.documentView }
        set { contentView.documentView = newValue }
    }
    /// The clip view always fills the scroll view (no scrollers or border take room here).
    open override func setFrameSize(_ size: CGSize) {
        super.setFrameSize(size)
        contentView.setFrameSize(size)
    }
    open override var frame: CGRect {
        didSet { if frame.size != contentView.frame.size { contentView.setFrameSize(frame.size) } }
    }
    open var documentVisibleRect: CGRect { contentView.bounds }
    /// Scrollers would be updated here; there are none to redraw.
    open func reflectScrolledClipView(_ clipView: NSClipView) {}
}
