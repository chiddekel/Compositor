// OVERRIDE for Compositor/Rendering/MetalWarp.swift (excluded from the Linux build).
//
// Metal → Vulkan/CPU: same surface as tip's MetalWarp so WarpStroke compiles unmodified. Dabs run on a CPU working
// copy that mirrors the Metal kernels' math (weight / pick_up / smudge / push) — brush feel and look must match Mac,
// not merely compile. When Vulkan is present this path is still used for correctness; a future SPIR-V port can
// replace the dab bodies behind the same API only if pixel response stays identical.

import Foundation
import CoreGraphics
import CoreImage

@MainActor final class MetalWarp {
    let width: Int
    let height: Int
    private let pixels: UnsafeMutablePointer<UInt8>
    private let bytesPerRow: Int
    private var carried: [Float] = []
    private var carriedSide = 0
    private var scratch: [Float] = []
    private var scratchW = 0
    private var scratchH = 0
    private var scratchOrigin = SIMD2<Int32>.zero

    init?(pixels context: CGContext) {
        guard GPUCanvasRenderer.shared != nil, let data = context.data else { return nil }
        width = context.width
        height = context.height
        bytesPerRow = context.bytesPerRow
        pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    }

    var image: CIImage? {
        guard let ctx = try? BrushRaster.context(width: width, height: height, mask: false),
              let dest = ctx.data else { return nil }
        for y in 0..<height {
            memcpy(dest + y * ctx.bytesPerRow, pixels + y * bytesPerRow, width * 4)
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    func read(into context: CGContext) {
        guard let dest = context.data, context.width == width, context.height == height else { return }
        for y in 0..<height {
            memcpy(dest + y * context.bytesPerRow, pixels + y * bytesPerRow, min(width * 4, context.bytesPerRow))
        }
    }

    func commit() {}

    private func weight(_ u: Float, hardness: Float) -> Float {
        guard u < 1 else { return 0 }
        guard u > hardness else { return 1 }
        let t = (1 - u) / (1 - hardness)
        return t * t * (3 - 2 * t)
    }

    private func sample(_ x: Int, _ y: Int) -> SIMD4<Float> {
        guard x >= 0, y >= 0, x < width, y < height else { return .zero }
        let i = y * bytesPerRow + x * 4
        return SIMD4(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]), Float(pixels[i + 3]))
    }

    private func write(_ x: Int, _ y: Int, _ c: SIMD4<Float>) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = y * bytesPerRow + x * 4
        pixels[i] = UInt8(max(0, min(255, c.x.rounded())))
        pixels[i + 1] = UInt8(max(0, min(255, c.y.rounded())))
        pixels[i + 2] = UInt8(max(0, min(255, c.z.rounded())))
        pixels[i + 3] = UInt8(max(0, min(255, c.w.rounded())))
    }

    func pickUp(at center: CGPoint, radius: Int) {
        let side = 2 * radius + 1
        carriedSide = side
        carried = [Float](repeating: 0, count: side * side * 4)
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        for gy in 0..<side {
            for gx in 0..<side {
                let p = SIMD2(cx + gx - radius, cy + gy - radius)
                let c = sample(Int(p.x), Int(p.y))
                let o = (gy * side + gx) * 4
                carried[o] = c.x; carried[o + 1] = c.y; carried[o + 2] = c.z; carried[o + 3] = c.w
            }
        }
    }

    func smudge(at center: CGPoint, radius: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        guard carriedSide == 2 * radius + 1, !carried.isEmpty else { return }
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let invR = 1 / Float(diameter / 2)
        let side = carriedSide
        for gy in 0..<side {
            for gx in 0..<side {
                let ox = gx - radius, oy = gy - radius
                let px = cx + ox, py = cy + oy
                guard px >= 0, py >= 0, px < width, py < height else { continue }
                let w = weight(sqrt(Float(ox * ox + oy * oy)) * invR, hardness: Float(hardness))
                guard w > 0 else { continue }
                let under = sample(px, py)
                let o = (gy * side + gx) * 4
                let held = SIMD4(carried[o], carried[o + 1], carried[o + 2], carried[o + 3])
                let painted = under + (held - under) * w
                write(px, py, painted)
                let next = painted + (held - painted) * Float(strength)
                carried[o] = next.x; carried[o + 1] = next.y; carried[o + 2] = next.z; carried[o + 3] = next.w
            }
        }
    }

    func push(from a: CGPoint, to b: CGPoint, radius r: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        let move = SIMD2<Float>(Float(b.x - a.x), Float(b.y - a.y)) * Float(strength)
        let margin = Int(ceil(max(abs(move.x), abs(move.y)))) + 2
        let cx = Int(b.x.rounded()), cy = Int(b.y.rounded())
        let x0 = max(0, cx - r - margin), x1 = min(width - 1, cx + r + margin)
        let y0 = max(0, cy - r - margin), y1 = min(height - 1, cy + r + margin)
        guard x0 <= x1, y0 <= y1 else { return }
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        scratchW = cw; scratchH = ch
        scratchOrigin = SIMD2(Int32(x0), Int32(y0))
        scratch = [Float](repeating: 0, count: cw * ch * 4)
        for gy in 0..<ch {
            for gx in 0..<cw {
                let c = sample(x0 + gx, y0 + gy)
                let o = (gy * cw + gx) * 4
                scratch[o] = c.x; scratch[o + 1] = c.y; scratch[o + 2] = c.z; scratch[o + 3] = c.w
            }
        }
        let invR = 1 / Float(diameter / 2)
        let side = 2 * r + 1
        for gy in 0..<side {
            for gx in 0..<side {
                let ox = gx - r, oy = gy - r
                let px = cx + ox, py = cy + oy
                guard px >= x0, py >= y0, px <= x1, py <= y1 else { continue }
                let w = weight(sqrt(Float(ox * ox + oy * oy)) * invR, hardness: Float(hardness))
                guard w > 0 else { continue }
                let sx = min(Float(cw - 1), max(0, Float(px - x0) - move.x * w))
                let sy = min(Float(ch - 1), max(0, Float(py - y0) - move.y * w))
                let ix = min(cw - 2, Int(sx)), iy = min(ch - 2, Int(sy))
                guard ix >= 0, iy >= 0 else { continue }
                let fx = sx - Float(ix), fy = sy - Float(iy)
                func at(_ x: Int, _ y: Int) -> SIMD4<Float> {
                    let o = (y * cw + x) * 4
                    return SIMD4(scratch[o], scratch[o + 1], scratch[o + 2], scratch[o + 3])
                }
                let top = at(ix, iy) + (at(ix + 1, iy) - at(ix, iy)) * fx
                let bottom = at(ix, iy + 1) + (at(ix + 1, iy + 1) - at(ix, iy + 1)) * fx
                write(px, py, top + (bottom - top) * fy)
            }
        }
    }
}
