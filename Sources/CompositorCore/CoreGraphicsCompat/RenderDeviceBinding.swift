// CoreGraphicsCompat/RenderDeviceBinding.swift — Swift side of the render
// device injection. The C++ SkiaBridge wraps `compositor_render_rgba` in a
// Swift closure and registers it here via the `@_cdecl` entry
// `compositor_compat_set_render_fn`. Once registered, `CGContextCompat`
// draws route through Skia; before registration (or after a device-lost
// reset), draws fall back to the pure-Swift `LayerRenderer` (plan §6).
//
// This keeps the SwiftPM host build Skia-free: no Skia header is imported,
// no link-time Skia dependency. The Flatpak build links SkiaBridge.cpp and
// calls the registration at host startup.

import Foundation

/// Registered render closure (set by the C++ host via @_cdecl). Nil means
/// "use the Swift fallback" — the default before the host registers a device.
nonisolated(unsafe) private var _compatRenderFn: CompRenderFn?

@_cdecl("compositor_compat_set_render_fn")
public func compositor_compat_set_render_fn(_ fn: CompRenderFn?) {
    _compatRenderFn = fn
}

/// Internal accessor for `CGContextCompat` to pick up the registered device.
func compositor_compat_current_render_fn() -> CompRenderFn? {
    _compatRenderFn
}