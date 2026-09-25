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
    /// The overlay views, in their stacking order (TransformOverlay, the brush circle, the sample ring).
    private var overlayViews: [NSView] {
        view.subviews.filter { $0 is TransformOverlay || $0 is BrushCursorOverlay || $0 is SampleRingOverlay }
    }
    /// What the overlay was last drawn from besides the views' own invalid rects: the canvas size, and which overlay
    /// views showed where (moving or hiding a view invalidates what it covered, as AppKit does).
    private var drawnLayout: [CGRect] = []
    private var currentLayout: [CGRect] {
        [view.bounds] + overlayViews.map { $0.isHidden ? .null : $0.frame }
    }
    /// What changed in the overlay since it was last drawn, in canvas coordinates (top-left): nil nothing, else the
    /// union of the overlay views' invalid rects (`setNeedsDisplay`) — the whole canvas when the layout moved.
    func overlayInvalidRect() -> CGRect? {
        if currentLayout != drawnLayout { return view.bounds }
        var dirty: CGRect?
        func add(_ rect: CGRect) { dirty = dirty.map { $0.union(rect) } ?? rect }
        for subview in overlayViews where !subview.isHidden {
            guard var rect = subview.invalidRect else { continue }
            if !subview.isFlipped { rect.origin.y = subview.bounds.height - rect.maxY }
            add(rect.offsetBy(dx: subview.frame.minX, dy: subview.frame.minY))
        }
        // The Type tool's box being dragged out is drawn by the canvas itself.
        if let rect = view.invalidRect { add(rect) }
        return dirty.map { $0.intersection(view.bounds) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    /// TransformOverlay's drawing for `region` of the canvas (points, top-left), premultiplied RGBA8 at the region's
    /// size, top row first; the overlay views' invalid rects are cleared, as a display does.
    func overlay(region: CGRect) -> [UInt8] {
        let context = CGContext(width: Int(region.width), height: Int(region.height))
        context.translateBy(x: -region.minX, y: -region.minY)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        // Each overlay view in its own frame; an unflipped one draws y-up.
        for subview in overlayViews {
            if subview is TransformOverlay { subview.frame = view.bounds }
            subview.needsDisplay = false
            guard !subview.isHidden else { continue }
            let frame = subview.frame
            guard frame.width > 0, frame.height > 0, frame.intersects(region) else { continue }
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            if !subview.isFlipped { context.translateBy(x: 0, y: frame.height); context.scaleBy(x: 1, y: -1) }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: subview.isFlipped)
            subview.draw(CGRect(origin: .zero, size: frame.size))
            context.restoreGState()
        }
        // The Type tool's box being dragged out (CanvasView.draw ends with it).
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.drawTextBoxDraft()
        view.needsDisplay = false
        drawnLayout = currentLayout
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
    compositorCanvasOverlayRegion(handle, 0, 0, width, height, output, capacity)
}

/// The overlay for the canvas rect (x, y, width, height) in points, premultiplied RGBA8 at that size.
@_cdecl("compositor_canvas_overlay_region")
nonisolated public func compositorCanvasOverlayRegion(_ handle: UInt64, _ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32,
                                                      _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard width > 0, height > 0, Int(width) * Int(height) <= 50_000_000 else { return -1 }
    let count = Int(width) * Int(height) * 4
    guard let output, capacity >= count else { return Int64(count) }
    return withEntry(handle) { entry in
        let bytes = UpstreamCanvases.canvas(handle, entry).overlay(region: CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)))
        bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: min(count, bytes.count)) }
        return Int64(bytes.count)
    }
}

/// Whether the overlay changed since it was last drawn: 0 no, 1 yes — `rect` (x, y, width, height, points, top-left)
/// then holds the part that did.
@_cdecl("compositor_canvas_overlay_invalid")
nonisolated public func compositorCanvasOverlayInvalid(_ handle: UInt64, _ rect: UnsafeMutablePointer<Double>?) -> Int32 {
    Int32(withEntry(handle) { entry in
        guard let dirty = UpstreamCanvases.canvas(handle, entry).overlayInvalidRect() else { return 0 }
        if let rect { rect[0] = dirty.minX; rect[1] = dirty.minY; rect[2] = dirty.width; rect[3] = dirty.height }
        return 1
    })
}

/// The shell's SF Symbol renderer: (name, width, height, r, g, b, a, output) → 0 when it drew the symbol into `output`
/// (width × height premultiplied RGBA8).
public typealias SymbolRenderFunction = @convention(c) (UnsafePointer<CChar>?, Int32, Int32, Double, Double, Double, Double,
                                                        UnsafeMutablePointer<UInt8>?) -> Int32

@_cdecl("compositor_set_symbol_renderer")
nonisolated public func compositorSetSymbolRenderer(_ render: SymbolRenderFunction?) {
    guard let render else { NSImage.symbolRenderer = nil; return }
    NSImage.symbolRenderer = { name, width, height, color in
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let status = name.withCString { symbol in
            bytes.withUnsafeMutableBufferPointer { render(symbol, Int32(width), Int32(height), color.0, color.1, color.2, color.3, $0.baseAddress) }
        }
        guard status == 0 else { return nil }
        return CGImage(PortableImage(PixelBuffer(width: width, height: height, bytes: bytes)))
    }
}

/// The cursor upstream's code last set (NSCursor.set()), as UpstreamCanvas.cursorCode maps it — for views outside the
/// canvas that set it themselves (NumericScrub's resize arrows while hovering a label).
@_cdecl("compositor_current_cursor")
nonisolated public func compositorCurrentCursor() -> Int32 {
    onMain { UpstreamCanvas.cursorCode(NSCursor.current) }
}

/// The current cursor's picture (a custom cursor: upstream draws it), premultiplied RGBA8, with its size and hot spot.
/// Returns the byte count (call with a nil output to size it), -1 when the cursor has no picture.
@_cdecl("compositor_canvas_cursor_image")
nonisolated public func compositorCanvasCursorImage(_ width: UnsafeMutablePointer<Int32>?, _ height: UnsafeMutablePointer<Int32>?,
                                                    _ hotX: UnsafeMutablePointer<Double>?, _ hotY: UnsafeMutablePointer<Double>?,
                                                    _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    onMain {
        let cursor = NSCursor.current
        guard let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let raster = image.portableImage
        guard raster.kind == .rgba else { return -1 }
        width?.pointee = Int32(raster.width); height?.pointee = Int32(raster.height)
        hotX?.pointee = Double(cursor.hotSpot.x); hotY?.pointee = Double(cursor.hotSpot.y)
        let bytes = raster.bytes
        if let output, capacity >= bytes.count { bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: bytes.count) } }
        return Int64(bytes.count)
    }
}
