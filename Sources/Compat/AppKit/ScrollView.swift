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
            _pendingVisibleRect = nil
            oldValue?.removeFromSuperview()
            if let documentView { addSubview(documentView) }
        }
    }
    open override var isFlipped: Bool { documentView?.isFlipped ?? false }
    /// A reveal requested before a host supplied a viewport waits for a meaningful visible rectangle.
    public private(set) var _pendingVisibleRect: CGRect?
    @discardableResult func reveal(_ target: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { _pendingVisibleRect = target; return false }
        let visible = bounds
        var origin = visible.origin
        if target.minY < visible.minY { origin.y = target.minY }
        else if target.maxY > visible.maxY { origin.y = target.maxY - visible.height }
        if target.minX < visible.minX { origin.x = target.minX }
        else if target.maxX > visible.maxX { origin.x = target.maxX - visible.width }
        guard origin != visible.origin else { return false }
        scroll(to: origin)
        return true
    }

    /// Moves the visible area's origin to `point` (document coordinates), as `NSClipView.scroll(to:)` does.
    open func scroll(to point: CGPoint) {
        let old = bounds
        bounds = CGRect(origin: constrainedOrigin(point), size: frame.size)
        if bounds.origin != old.origin, postsBoundsChangedNotifications {
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: self)
        }
    }
    /// Keeps the visible area over the document, as AppKit's `constrainBoundsRect` does: never scrolled past its end
    /// (or before its start), and at its start when the document is smaller than the clip view.
    func constrainedOrigin(_ point: CGPoint) -> CGPoint {
        guard let document = documentView?.frame else { return point }
        let maxX = max(document.minX, document.maxX - frame.width), maxY = max(document.minY, document.maxY - frame.height)
        return CGPoint(x: min(max(point.x, document.minX), maxX), y: min(max(point.y, document.minY), maxY))
    }
    /// Re-applies that constraint after the document or this view changed size.
    public func reconstrain() {
        let origin = constrainedOrigin(bounds.origin)
        if origin != bounds.origin { scroll(to: origin) }
    }
    open override func setFrameSize(_ size: CGSize) {
        super.setFrameSize(size)
        bounds = CGRect(origin: constrainedOrigin(bounds.origin), size: size)
        // The document (a table tiling itself to the clip's width) lays out again for the new size.
        documentView?.needsLayout = true
        if size.width > 0, size.height > 0, let pending = _pendingVisibleRect {
            _pendingVisibleRect = nil
            reveal(pending)
        }
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

extension NSView {
    /// The scroll view this view scrolls in, if any.
    public var enclosingScrollView: NSScrollView? {
        var current = superview
        while let view = current {
            if let scroll = view as? NSScrollView { return scroll }
            current = view.superview
        }
        return nil
    }
    /// Scrolls the clip view holding this view by the least that brings `rect` (this view's coordinates) into view, as
    /// AppKit's; false when there is no clip view or nothing to scroll.
    @discardableResult public func scrollToVisible(_ rect: CGRect) -> Bool {
        guard let clip = superview as? NSClipView else { return false }
        let target = CGRect(x: rect.minX + frame.minX, y: rect.minY + frame.minY, width: rect.width, height: rect.height)
        return clip.reveal(target)
    }
}
