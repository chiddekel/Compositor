// OVERRIDE for Compositor/Rendering/GPUNoise.swift (excluded from the Linux build).
//
// Metal → Vulkan/CPU: tip uses Metal compute with the same hashes as NoisePixels.c. Linux applies those C kernels
// through a CIImage → bitmap → kernel → CIImage round-trip so GPUAdjustment noise/grain match export look and feel.

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum GPUNoise {
    static func addNoise(to image: CIImage, mapping: CGAffineTransform, amount: Float, gaussian: Bool, monochromatic: Bool,
                         seed: UInt32) -> CIImage? {
        apply(image) { pixels, width, height, stride in
            noise_add_at(pixels, width, height, stride, amount, gaussian ? 1 : 0, monochromatic ? 1 : 0, seed,
                         Int64(floor(-mapping.tx)), Int64(floor(-mapping.ty)))
        }
    }

    static func addGrain(to image: CIImage, grain: GrainSettings, scale: CGFloat, mapping: CGAffineTransform) -> CIImage? {
        guard grain.amount > 0, scale > 0 else { return image }
        return apply(image) { pixels, width, height, stride in
            adjust_grain(pixels, width, height, stride, grain.amount, max(grain.size, 0.01),
                         grain.roughness, grain.seed, -mapping.tx / scale, -mapping.ty / scale, 1 / scale)
        }
    }

    private static func apply(_ image: CIImage, mutate: (UnsafeMutablePointer<UInt8>, Int, Int, Int) -> Void) -> CIImage? {
        let extent = image.extent.integral
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }
        let width = Int(extent.width), height = Int(extent.height)
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(image, from: extent),
              let copy = try? BrushRaster.copy(cg), let data = copy.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: copy.bytesPerRow * height)
        mutate(pixels, width, height, copy.bytesPerRow)
        guard let out = copy.makeImage() else { return nil }
        return CIImage(cgImage: out).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}
