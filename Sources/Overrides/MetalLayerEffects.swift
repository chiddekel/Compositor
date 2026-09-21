// OVERRIDE for Compositor/Rendering/MetalLayerEffects.swift (excluded from the Linux build).
//
// Upstream treats the GPU effects renderer as optional: `MetalLayerEffects.shared` is nil without Metal and
// `LayerEffectsRenderer` then runs its CoreImage/CoreGraphics CPU path. This override reports "no accelerator" so that
// path — now backed by the CoreImage compat — runs on Linux. The Vulkan → Skia → OpenCV → C effects backend chain
// (same nine passes as the Metal kernels) plugs in here by returning a real instance from `shared`.

import Foundation
import CoreGraphics

final class MetalLayerEffects {
    /// nil until an accelerated backend is installed (Phase 5).
    nonisolated(unsafe) static var shared: MetalLayerEffects?

    /// Same signature as upstream: the layer's pixels with room around them, stroke and drop shadow composited in.
    func render(_ pixels: CGImage, effects: LayerEffects) throws -> CGImage {
        throw ExportError.render
    }
}
