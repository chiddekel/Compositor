import Foundation
import CoreGraphics

/// The current drawing target for AppKit-style drawing (`NSColor.setFill`, text, images). A stack, like Apple's.
public final class NSGraphicsContext: @unchecked Sendable {
    public let cgContext: CGContext
    public let isFlipped: Bool
    /// Always true for the Qt-backed canvas (never printing / PDF).
    public var isDrawingToScreen: Bool { true }

    private final class ThreadState {
        var current: NSGraphicsContext?
        var stack: [NSGraphicsContext?] = []
    }
    private static let stateKey = "org.compositor.NSGraphicsContext.threadState"
    private static var state: ThreadState {
        let dictionary = Thread.current.threadDictionary
        if let existing = dictionary[stateKey] as? ThreadState { return existing }
        let created = ThreadState()
        dictionary[stateKey] = created
        return created
    }
    public static var current: NSGraphicsContext? {
        get { state.current }
        set { state.current = newValue }
    }

    public init(cgContext: CGContext, flipped: Bool) {
        self.cgContext = cgContext
        self.isFlipped = flipped
    }

    public static func saveGraphicsState() {
        state.stack.append(current)
        current?.cgContext.saveGState()
    }

    public static func restoreGraphicsState() {
        guard let saved = state.stack.popLast() else { return }
        // Restore the context whose state was saved, even if drawing assigned a different current context.
        saved?.cgContext.restoreGState()
        current = saved
    }

    public func saveGraphicsState() { Self.saveGraphicsState() }
    public func restoreGraphicsState() { Self.restoreGraphicsState() }
}

extension NSAffineTransform {
    public func concat() {
        let t = CGAffineTransform(
            a: transformStruct.m11, b: transformStruct.m12,
            c: transformStruct.m21, d: transformStruct.m22,
            tx: transformStruct.tX, ty: transformStruct.tY
        )
        NSGraphicsContext.current?.cgContext.concatenate(t)
    }
}
