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
        apply(image) { pixels, width, height, stride, extent in
            // As the Metal kernel: a pixel's frame position plus the corner, frame pixels counted from the document's.
            noise_add_at(pixels, width, height, stride, amount, gaussian ? 1 : 0, monochromatic ? 1 : 0, seed,
                         Int64(floor(-mapping.tx)) + Int64(extent.minX), Int64(floor(-mapping.ty)) + Int64(extent.minY))
        }
    }

    static func addGrain(to image: CIImage, grain: GrainSettings, scale: CGFloat, mapping: CGAffineTransform) -> CIImage? {
        guard grain.amount > 0, scale > 0 else { return image }
        // A frame pixel's center, in document pixels, is its position less the mapping's offset, over the scale.
        return apply(image) { pixels, width, height, stride, extent in
            adjust_grain(pixels, width, height, stride, grain.amount, max(grain.size, 0.01),
                         grain.roughness, grain.seed, (extent.minX - mapping.tx) / scale, (extent.minY - mapping.ty) / scale, 1 / scale)
        }
    }

    /// Runs a C kernel over the image's pixels with row `r` at the frame's y = minY + r, as the Metal kernels index the
    /// frame (`extent` is the region, in frame pixels).
    private static func apply(_ image: CIImage,
                              mutate: (UnsafeMutablePointer<UInt8>, Int, Int, Int, CGRect) -> Void) -> CIImage? {
        let extent = image.extent.integral
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1, extent.width * extent.height <= 200_000_000
        else { return nil }
        let width = Int(extent.width), height = Int(extent.height)
        // The frame's own working space (sRGB, as GPUCanvasRenderer's context), so what is under a translucent layer is
        // mixed as the frame mixes it; a linear context re-blended it and changed its colors before the noise.
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let cg = context.createCGImage(image, from: extent),
              let copy = try? BrushRaster.copy(cg), let data = copy.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: copy.bytesPerRow * height)
        // A CGImage's rows run from the top (highest y) down; turn them over for the kernel and back afterwards.
        func flip() {
            var row = [UInt8](repeating: 0, count: copy.bytesPerRow)
            for y in 0..<(height / 2) {
                let a = pixels + y * copy.bytesPerRow, b = pixels + (height - 1 - y) * copy.bytesPerRow
                row.withUnsafeMutableBufferPointer { buffer in
                    memcpy(buffer.baseAddress!, a, copy.bytesPerRow)
                    memcpy(a, b, copy.bytesPerRow)
                    memcpy(b, buffer.baseAddress!, copy.bytesPerRow)
                }
            }
        }
        flip()
        mutate(pixels, width, height, copy.bytesPerRow, extent)
        flip()
        guard let out = copy.makeImage() else { return nil }
        return CIImage(cgImage: out).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}