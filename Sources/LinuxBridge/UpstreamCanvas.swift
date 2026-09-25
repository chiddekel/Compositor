import Foundation
import AppKit

/// Upstream's own canvas view (EditorCanvas.swift's CanvasView), hosted headlessly for each session: the Qt canvas
/// forwards its pointer events here, so every tool behaves as the Mac's does, and paints the view's overlay
/// (TransformOverlay: handles, marching ants, crop, gradient line, lasso draft, guides, grid, snap lines) over the
/// document. Coordinates are the Qt canvas's: points, top-left origin.
@MainActor final class UpstreamCanvas {
    let view: CanvasView
    let window: NSWindow
    init(session: EditorSession) {
        view = CanvasView(session: session)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.contentView = view
    }
    func resize(width: Double, height: Double, scale: Double) {
        let size = CGSize(width: max(1, width), height: max(1, height))
        guard view.frame.size != size || window.backingScaleFactor != CGFloat(scale) else { return }
        window.setContentSize(size)
        view.frame = CGRect(origin: .zero, size: size)
        view.layout()
    }
    /// A pointer event (returns the cursor code, see cursorCode): `kind` 0 press, 1 drag, 2 release, 3 move (no button), 4 double press; `modifiers` in
    /// ShortcutChord bits as the shell sends them (Ctrl 1 → ⌘, Alt 2 → ⌥, Meta 4 → ⌃, Shift 8).
    func mouse(kind: Int, x: Double, y: Double, modifiers: Int, clickCount: Int) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { flags.insert(.command) }
        if modifiers & 2 != 0 { flags.insert(.option) }
        if modifiers & 4 != 0 { flags.insert(.control) }
        if modifiers & 8 != 0 { flags.insert(.shift) }
        let type: NSEvent.EventType = [0: .leftMouseDown, 1: .leftMouseDragged, 2: .leftMouseUp, 3: .mouseMoved][kind] ?? .leftMouseDown
        // The window's space is bottom-left; the view is flipped.
        let location = CGPoint(x: x, y: view.bounds.height - y)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: max(1, clickCount), pressure: 1) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: view.mouseMoved(with: event)
        }
        // Hovering: the cursor rects decide (as AppKit does); pressing and dragging: whatever the view set.
        if type == .mouseMoved || type == .leftMouseUp, let cursor = view.cursorForPoint(view.convert(event.locationInWindow, from: nil)) {
            NSCursor.current = cursor
        }
    }

    /// The cursor as a code the shell maps: 0 arrow, 1 I-beam, 2 crosshair, 3 open hand, 4 closed hand, 5 pointing hand,
    /// 6 left-right, 7 up-down, 8 diagonal ↖↘, 9 diagonal ↗↙, 10 a picture of the app's own (not yet mapped).
    static func cursorCode(_ cursor: NSCursor) -> Int32 {
        switch cursor.shape {
        case .arrow: return 0
        case .iBeam: return 1
        case .crosshair: return 2
        case .openHand: return 3
        case .closedHand: return 4
        case .pointingHand: return 5
        case .resizeLeftRight: return 6
        case .resizeUpDown: return 7
        case .frameResize(let position, _):
            switch position.rawValue {
            case 0, 2: return 7
            case 1, 3: return 6
            case 4, 7: return 8
            default: return 9
            }
        case .custom: return 10
        }
    }
    /// A key press for the canvas: `keyCode` a Mac virtual key code, `characters` what it types.
    func key(keyCode: Int, characters: String, modifiers: Int, isRepeat: Bool) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { flags.insert(.command) }
        if modifiers & 2 != 0 { flags.insert(.option) }
        if modifiers & 4 != 0 { flags.insert(.control) }
        if modifiers & 8 != 0 { flags.insert(.shift) }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: isRepeat, keyCode: UInt16(keyCode)) else { return }
        view.keyDown(with: event)
    }
    /// TransformOverlay's drawing at the canvas's size, premultiplied RGBA8, top row first.
    func overlay(width: Int, height: Int) -> [UInt8] {
        let context = CGContext(width: width, height: height)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        for subview in view.subviews where subview is TransformOverlay {
            subview.frame = view.bounds
            subview.draw(view.bounds)
        }
        return context.buffer.bytes
    }
}

@MainActor enum UpstreamCanvases {
    static var canvases: [UInt64: UpstreamCanvas] = [:]
    static func canvas(_ handle: UInt64, _ entry: Entry) -> UpstreamCanvas {
        if let canvas = canvases[handle] { return canvas }
        let canvas = UpstreamCanvas(session: entry.editor.session)
        canvases[handle] = canvas
        return canvas
    }
}

@_cdecl("compositor_canvas_resize")
nonisolated public func compositorCanvasResize(_ handle: UInt64, _ width: Double, _ height: Double, _ scale: Double) -> Int32 {
    Int32(withEntry(handle) { entry in
        UpstreamCanvases.canvas(handle, entry).resize(width: width, height: height, scale: scale)
        return 0
    })
}

@_cdecl("compositor_canvas_mouse")
nonisolated public func compositorCanvasMouse(_ handle: UInt64, _ kind: Int32, _ x: Double, _ y: Double, _ modifiers: Int32, _ clickCount: Int32) -> Int32 {
    Int32(withEntry(handle) { entry in
        UpstreamCanvases.canvas(handle, entry).mouse(kind: Int(kind), x: x, y: y, modifiers: Int(modifiers), clickCount: Int(clickCount))
        return Int64(UpstreamCanvas.cursorCode(NSCursor.current))
    })
}

@_cdecl("compositor_canvas_key")
nonisolated public func compositorCanvasKey(_ handle: UInt64, _ keyCode: Int32, _ characters: UnsafePointer<CChar>?, _ modifiers: Int32, _ isRepeat: Int32) -> Int32 {
    let typed = characters.map { String(cString: $0) } ?? ""
    return Int32(withEntry(handle) { entry in
        UpstreamCanvases.canvas(handle, entry).key(keyCode: Int(keyCode), characters: typed, modifiers: Int(modifiers), isRepeat: isRepeat != 0)
        return 0
    })
}

/// The overlay's pixels (width × height × 4); returns the byte count, -1 if `capacity` is too small.
@_cdecl("compositor_canvas_overlay")
nonisolated public func compositorCanvasOverlay(_ handle: UInt64, _ width: Int32, _ height: Int32,
                                                _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard width > 0, height > 0, Int(width) * Int(height) <= 50_000_000 else { return -1 }
    return withEntry(handle) { entry in
        let bytes = UpstreamCanvases.canvas(handle, entry).overlay(width: Int(width), height: Int(height))
        guard let output, capacity >= bytes.count else { return Int64(bytes.count) }
        bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: bytes.count) }
        return Int64(bytes.count)
    }
}
