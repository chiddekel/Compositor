// On the Mac, upstream's tests run inside Compositor itself (its test host), so the app's document window is open the
// whole time and code that looks for "the main window" finds it (FloatingPanel's docked placement, for one). `swift
// test` on Linux has no app around the tests; this opens one document window for the test process, as the app's launch
// would, and keeps it. Linked only into the test targets. Not called from a C constructor — the Swift runtime is not
// guaranteed up that early; compat AppKit's `NSApp.windows` looks it up by name (dlsym) on the first enumeration and
// calls it there, on the main thread with the runtime fully initialized.
import AppKit
import CoreGraphics

@MainActor private var hostWindow: NSWindow?

@_cdecl("compositor_open_test_host_window")
public func compositorOpenTestHostWindow() {
    MainActor.assumeIsolated {
        guard hostWindow == nil else { return }
        let frame = CGRect(x: 120, y: 80, width: 1200, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Untitled"
        window.contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        window.makeKeyAndOrderFront(nil)
        NSApp.mainWindow = window
        hostWindow = window
    }
}
