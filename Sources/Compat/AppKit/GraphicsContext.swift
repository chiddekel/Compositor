import Foundation
import CoreGraphics

/// The current drawing target for AppKit-style drawing (`NSColor.setFill`, text, images). A stack, like Apple's.
public final class NSGraphicsContext: @unchecked Sendable {
    public let cgContext: CGContext
    public let isFlipped: Bool

    nonisolated(unsafe) private static var stack: [NSGraphicsContext?] = []
    nonisolated(unsafe) public static var current: NSGraphicsContext?

    public init(cgContext: CGContext, flipped: Bool) {
        self.cgContext = cgContext
        self.isFlipped = flipped
    }

    public static func saveGraphicsState() {
        stack.append(current)
        current?.cgContext.saveGState()
    }

    public static func restoreGraphicsState() {
        current?.cgContext.restoreGState()
        current = stack.popLast() ?? nil
    }
}
