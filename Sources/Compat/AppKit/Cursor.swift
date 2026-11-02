import Foundation

/// Cursors are opaque tokens here: the model asks for a shape, the Qt shell maps it to a `QCursor`.
public final class NSCursor: @unchecked Sendable, Equatable {
    public enum Shape: Equatable, Sendable {
        case arrow, iBeam, crosshair, openHand, closedHand, pointingHand, resizeLeftRight, resizeUpDown
        case frameResize(FrameResizePosition, FrameResizeDirections)
        case custom(hotSpot: CGPoint)
    }
    public struct FrameResizePosition: Equatable, Sendable {
        public let rawValue: Int
        public static let top = FrameResizePosition(rawValue: 0), left = FrameResizePosition(rawValue: 1)
        public static let bottom = FrameResizePosition(rawValue: 2), right = FrameResizePosition(rawValue: 3)
        public static let topLeft = FrameResizePosition(rawValue: 4), topRight = FrameResizePosition(rawValue: 5)
        public static let bottomLeft = FrameResizePosition(rawValue: 6), bottomRight = FrameResizePosition(rawValue: 7)
    }
    public struct FrameResizeDirections: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let inward = FrameResizeDirections(rawValue: 1)
        public static let outward = FrameResizeDirections(rawValue: 2)
        public static let all: FrameResizeDirections = [.inward, .outward]
    }

    public let shape: Shape
    public let image: NSImage
    public let hotSpot: CGPoint

    public init(shape: Shape) { self.shape = shape; image = NSImage(size: CGSize(width: 16, height: 16)); hotSpot = .zero }
    init(shape: Shape, image: NSImage, hotSpot: CGPoint) { self.shape = shape; self.image = image; self.hotSpot = hotSpot }
    public init(image: NSImage, hotSpot: CGPoint) {
        shape = .custom(hotSpot: hotSpot); self.image = image; self.hotSpot = hotSpot
    }

    nonisolated(unsafe) public static var current = NSCursor.arrow
    nonisolated(unsafe) private static var stack: [NSCursor] = []
    /// Called whenever the model changes the cursor; the host maps it to a real one.
    nonisolated(unsafe) public static var onChange: ((NSCursor) -> Void)?

    public static let arrow = NSCursor(shape: .arrow)
    public static let iBeam = NSCursor(shape: .iBeam)
    /// The Mac's crosshair: thin black arms with a white edge, 24 points, the hot spot in the middle (so a selection
    /// cursor built on it has something to show).
    public static let crosshair: NSCursor = {
        let image = NSImage(size: CGSize(width: 24, height: 24), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for (color, width) in [(CGColor(red: 1, green: 1, blue: 1, alpha: 1), 3.0), (CGColor(red: 0, green: 0, blue: 0, alpha: 1), 1.0)] {
                context.setStrokeColor(color)
                context.setLineWidth(width)
                // On pixel centres, so a 1-pixel arm stays one pixel wide.
                for (a, b) in [((12.5, 2.0), (12.5, 9.0)), ((12.5, 16.0), (12.5, 23.0)), ((2.0, 12.5), (9.0, 12.5)), ((16.0, 12.5), (23.0, 12.5))] {
                    context.move(to: CGPoint(x: a.0, y: a.1)); context.addLine(to: CGPoint(x: b.0, y: b.1))
                }
                context.strokePath()
            }
            return true
        }
        return NSCursor(shape: .crosshair, image: image, hotSpot: CGPoint(x: 12, y: 12))
    }()
    public static let openHand = NSCursor(shape: .openHand)
    public static let closedHand = NSCursor(shape: .closedHand)
    /// The Mac's pointing hand: white with a black outline, the hot spot on the fingertip (the host still shows its own
    /// hand for this shape; the image is for cursors built on it, like the layer list's load-selection cursor).
    public static let pointingHand: NSCursor = {
        let image = NSImage(size: CGSize(width: 24, height: 24), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let parts = [CGRect(x: 6.5, y: 0.5, width: 4, height: 13), CGRect(x: 10, y: 7.5, width: 3.5, height: 8),
                         CGRect(x: 13, y: 8.5, width: 3.5, height: 7), CGRect(x: 16, y: 9.5, width: 3, height: 6),
                         CGRect(x: 6.5, y: 12, width: 12.5, height: 9.5)]
            let thumb = CGMutablePath()
            thumb.move(to: CGPoint(x: 8, y: 16)); thumb.addLine(to: CGPoint(x: 3.5, y: 11.5))
            context.setLineCap(.round)
            // Every part outlined first, then filled over: the outline of the whole hand stays.
            for (color, grow) in [(CGColor(red: 0, green: 0, blue: 0, alpha: 1), 1.0), (CGColor(red: 1, green: 1, blue: 1, alpha: 1), 0.0)] {
                context.setFillColor(color); context.setStrokeColor(color)
                for rect in parts {
                    let r = rect.insetBy(dx: -grow, dy: -grow)
                    context.addPath(CGPath(roundedRect: r, cornerWidth: min(r.width / 2, 3.5), cornerHeight: min(r.width / 2, 3.5), transform: nil))
                    context.fillPath()
                }
                context.setLineWidth(3.5 + 2 * grow)
                context.addPath(thumb); context.strokePath()
            }
            context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.setLineWidth(1)
            for x in [10.5, 13.5, 16.5] { context.move(to: CGPoint(x: x, y: 11)); context.addLine(to: CGPoint(x: x, y: 14.5)) }
            context.strokePath()
            return true
        }
        return NSCursor(shape: .pointingHand, image: image, hotSpot: CGPoint(x: 8, y: 1))
    }()
    public static let resizeLeftRight = NSCursor(shape: .resizeLeftRight)
    public static let resizeUpDown = NSCursor(shape: .resizeUpDown)
    public static func frameResize(position: FrameResizePosition, directions: FrameResizeDirections) -> NSCursor {
        NSCursor(shape: .frameResize(position, directions))
    }

    public func set() { NSCursor.current = self; NSCursor.onChange?(self) }
    public func push() { NSCursor.stack.append(NSCursor.current); set() }
    public func pop() { NSCursor.pop() }
    public static func pop() { (stack.popLast() ?? arrow).set() }
    public static func hide() {}
    /// AppKit hides the pointer while typing until the mouse moves; the Qt shell owns pointer visibility, so this
    /// records the request only.
    nonisolated(unsafe) public static var hiddenUntilMouseMoves = false
    public static func setHiddenUntilMouseMoves(_ flag: Bool) { hiddenUntilMouseMoves = flag }
    public static func unhide() {}

    public static func == (lhs: NSCursor, rhs: NSCursor) -> Bool { lhs === rhs }
}
