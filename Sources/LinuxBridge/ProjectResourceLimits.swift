import Foundation

/// The package ABI uses the document model's limits, including separate image and
/// mask totals, as ProjectStore does. A decoded asset must also fit one surface.
@_cdecl("compositor_project_max_surface_pixels")
nonisolated public func compositorProjectMaxSurfacePixels() -> Int {
    DocumentLimits.maxSurfacePixels
}

@_cdecl("compositor_project_pixel_budget")
nonisolated public func compositorProjectPixelBudget() -> Int {
    DocumentLimits.documentPixelBudget
}

/// Returns the new total, or -1. Validate dimensions before multiplying and the
/// existing total before subtracting so even hostile ABI inputs cannot overflow.
@_cdecl("compositor_project_account_asset")
nonisolated public func compositorProjectAccountAsset(_ width: Int, _ height: Int, _ used: Int) -> Int64 {
    guard (1...DocumentLimits.maxSide).contains(width),
          (1...DocumentLimits.maxSide).contains(height),
          (0...DocumentLimits.documentPixelBudget).contains(used) else { return -1 }
    let pixels = width * height
    guard pixels <= DocumentLimits.maxSurfacePixels,
          pixels <= DocumentLimits.documentPixelBudget - used else { return -1 }
    return Int64(used + pixels)
}
