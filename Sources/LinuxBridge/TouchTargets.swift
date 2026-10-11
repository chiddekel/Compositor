// Finger-sized hit areas while a touchscreen drives the app (TODOS: finger-touch large-target mode). The shell turns it
// on with a touch and off with a mouse or pen press (compositor_set_touch_targets); what it widens reads `large`.

import Foundation

enum TouchTargets {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedLarge = false
    /// A touchscreen made the last press: targets take the pointer from further away.
    static var large: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedLarge }
        set { lock.lock(); defer { lock.unlock() }; storedLarge = newValue }
    }
}

@_cdecl("compositor_set_touch_targets")
nonisolated public func compositorSetTouchTargets(_ on: Int32) {
    TouchTargets.large = on != 0
}
