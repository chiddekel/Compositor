// OVERRIDE for Compositor/Rendering/MetalWarp.swift (excluded from the Linux build).
//
// Metal → Vulkan/CPU: same surface as tip's MetalWarp so WarpStroke compiles unmodified. Dabs run on a CPU working
// copy that mirrors the Metal kernels' math (weight / pick_up / smudge / push) — brush feel and look must match Mac,
// not merely compile. When Vulkan is present this path is still used for correctness; a future SPIR-V port can
// replace the dab bodies behind the same API only if pixel response stays identical.
//
// Tip 1.4.2+ Liquify keeps pixels sharp by warping source offsets against an untouched original (not resampling
// the working pixels each dab). Smudge lays down carried color at strength and then carries what it just left.
//
// As tip's textures (rgba8Unorm / rgba16Unorm / rgba16Float), the working copy is the context's own format: 8 bits, a
// 16-bit layer's 16 bits (`DeepLayer`), or an HDR layer's half floats. Values are worked on in the format's own steps
// (255, 65535) and rounded and clipped to them; half floats are kept as they come, nothing rounded or clipped at white.

import Foundation
import CoreGraphics
import CoreImage

@MainActor final class MetalWarp {
    /// Tip's compute pipelines; WarpStroke only asks whether there are any. The dab kernels here always run.
    static let pipelines: [String: Any]? = [:]

    private enum Format { case byte, short, half }
    let width: Int
    let height: Int
    private let pixels: UnsafeMutableRawPointer
    private let bytesPerRow: Int
    private let format: Format
    /// Bytes per channel, and the levels a channel has (0: half floats, kept as they come).
    private let channelBytes: Int
    private let steps: Float
    private var carried: [Float] = []
    private var carriedSide = 0
    /// Untouched layer at stroke start (RGBA bytes, width×height).
    private var original: UnsafeMutableRawPointer?
    /// Per-pixel source offset (dx, dy) from the untouched layer, in pixels.
    /// calloc so untouched pages stay lazy — Swift Array zero-fill of Full HD stalled first Liquify feedback.
    private var offsets: UnsafeMutablePointer<Float>?
    private var scratch: [Float] = []
    private var scratchW = 0
    private var scratchH = 0
    private var scratchOrigin = SIMD2<Int32>.zero

    init?(pixels context: CGContext) {
        // Linux MetalWarp is CPU-backed dab math (tip 1.4.2 sharp Liquify). Do not gate on
        // GPUCanvasRenderer.shared — that only controls the Metal/Vulkan canvas present path.
        guard let data = context.data else { return nil }
        width = context.width
        height = context.height
        bytesPerRow = context.bytesPerRow
        pixels = data
        if context.bitsPerComponent == 16 {
            format = context.bitmapInfo.contains(.floatComponents) ? .half : .short
            channelBytes = 2
            steps = format == .half ? 0 : 65535
        } else {
            format = .byte
            channelBytes = 1
            steps = 255
        }
    }

    private func load(_ base: UnsafeMutableRawPointer, _ offset: Int) -> Float {
        switch format {
        case .byte: return Float(base.load(fromByteOffset: offset, as: UInt8.self))
        case .short: return Float(base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        case .half: return Float(base.loadUnaligned(fromByteOffset: offset, as: Float16.self))
        }
    }

    private func store(_ base: UnsafeMutableRawPointer, _ offset: Int, _ value: Float) {
        switch format {
        case .byte: base.storeBytes(of: UInt8(max(0, min(255, value.rounded()))), toByteOffset: offset, as: UInt8.self)
        case .short: base.storeBytes(of: UInt16(max(0, min(65535, value.rounded()))), toByteOffset: offset, as: UInt16.self)
        case .half: base.storeBytes(of: Float16(value), toByteOffset: offset, as: Float16.self)
        }
    }

    /// Byte offset of pixel (x, y), channel `k`, in the working copy.
    private func at(_ x: Int, _ y: Int, _ k: Int = 0) -> Int { y * bytesPerRow + (x * 4 + k) * channelBytes }

    deinit {
        original?.deallocate()
        if let offsets { free(UnsafeMutableRawPointer(offsets)) }
    }

    var image: CIImage? {
        guard let ctx = try? (format == .byte ? BrushRaster.context(width: width, height: height, mask: false)
                                             : DeepLayer.context(width: width, height: height, hdr: format == .half)),
              let dest = ctx.data else { return nil }
        for y in 0..<height {
            memcpy(dest + y * ctx.bytesPerRow, pixels + y * bytesPerRow, width * 4 * channelBytes)
        }
        guard let cg = ctx.makeImage() else { return nil }
        // As tip's texture-backed image: the top row at y = 0 (the GPU canvas builds its frame with y counting down).
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
    }

    func read(into context: CGContext) {
        guard let dest = context.data, context.width == width, context.height == height else { return }
        for y in 0..<height {
            memcpy(dest + y * context.bytesPerRow, pixels + y * bytesPerRow, min(width * 4 * channelBytes, context.bytesPerRow))
        }
    }

    func commit() {}

    private func weight(_ u: Float, hardness: Float) -> Float {
        guard u < 1 else { return 0 }
        guard u > hardness else { return 1 }
        let t = (1 - u) / (1 - hardness)
        return t * t * (3 - 2 * t)
    }

    private func write(_ x: Int, _ y: Int, _ c: SIMD4<Float>) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = at(x, y)
        for k in 0..<4 { store(pixels, i + k * channelBytes, c[k]) }
    }

    private func sampleOriginal(_ x: Float, _ y: Float) -> SIMD4<Float> {
        guard let original else { return .zero }
        let sx = min(Float(width - 1), max(0, x))
        let sy = min(Float(height - 1), max(0, y))
        let ix = min(width - 2, Int(sx)), iy = min(height - 2, Int(sy))
        guard ix >= 0, iy >= 0 else { return .zero }
        let fx = sx - Float(ix), fy = sy - Float(iy)
        let rowBytes = width * 4 * channelBytes
        func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let i = y * rowBytes + x * 4 * channelBytes
            return SIMD4(load(original, i), load(original, i + channelBytes), load(original, i + 2 * channelBytes),
                         load(original, i + 3 * channelBytes))
        }
        let top = pixel(ix, iy) + (pixel(ix + 1, iy) - pixel(ix, iy)) * fx
        let bottom = pixel(ix, iy + 1) + (pixel(ix + 1, iy + 1) - pixel(ix, iy + 1)) * fx
        return top + (bottom - top) * fy
    }

    func pickUp(at center: CGPoint, radius: Int) {
        let side = 2 * radius + 1
        carriedSide = side
        let count = side * side * 4
        if carried.count != count { carried = [Float](repeating: 0, count: count) }
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        for gy in 0..<side {
            for gx in 0..<side {
                let px = cx + gx - radius, py = cy + gy - radius
                let o = (gy * side + gx) * 4
                if px >= 0, py >= 0, px < width, py < height {
                    let i = at(px, py)
                    for k in 0..<4 { carried[o + k] = load(pixels, i + k * channelBytes) }
                } else {
                    carried[o] = 0; carried[o + 1] = 0; carried[o + 2] = 0; carried[o + 3] = 0
                }
            }
        }
    }

    private var falloff: [Float] = []
    private var falloffKey: (radius: Int, diameter: CGFloat, hardness: CGFloat) = (-1, 0, 0)

    func smudge(at center: CGPoint, radius: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        guard carriedSide == 2 * radius + 1, !carried.isEmpty else { return }
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let invR = 1 / Float(diameter / 2)
        let keep = Float(strength)
        let h = Float(hardness)
        let side = carriedSide
        // The falloff by squared distance, computed once per brush (as WarpStroke's radialWeights): a square root and
        // the weight curve for every pixel of every dab stalled live smudging.
        if falloffKey.radius != radius || falloffKey.diameter != diameter || falloffKey.hardness != hardness {
            falloff = (0...(2 * radius * radius)).map { weight(Float($0).squareRoot() * invR, hardness: h) }
            falloffKey = (radius, diameter, hardness)
        }
        for gy in 0..<side {
            let oy = gy - radius
            let py = cy + oy
            guard py >= 0, py < height else { continue }
            for gx in 0..<side {
                let ox = gx - radius
                let px = cx + ox
                guard px >= 0, px < width else { continue }
                let w = falloff[ox * ox + oy * oy]
                guard w > 0 else { continue }
                let i = at(px, py)
                let o = (gy * side + gx) * 4
                let blend = w * keep
                for k in 0..<4 {
                    let under = load(pixels, i + k * channelBytes)
                    let painted = under + (carried[o + k] - under) * blend
                    store(pixels, i + k * channelBytes, painted)
                    carried[o + k] = painted
                }
            }
        }
    }

    /// Forward warp on offsets against an untouched original (tip 1.4.2+), so repeated dabs stay sharp.
    func push(from a: CGPoint, to b: CGPoint, radius r: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        let move = SIMD2<Float>(Float(b.x - a.x), Float(b.y - a.y)) * Float(strength)
        let margin = Int(ceil(max(abs(move.x), abs(move.y)))) + 2
        let cx = Int(b.x.rounded()), cy = Int(b.y.rounded())
        let x0 = max(0, cx - r - margin), x1 = min(width - 1, cx + r + margin)
        let y0 = max(0, cy - r - margin), y1 = min(height - 1, cy + r + margin)
        guard x0 <= x1, y0 <= y1 else { return }
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1

        if original == nil {
            let rowBytes = width * 4 * channelBytes
            let copy = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 8)
            for y in 0..<height {
                memcpy(copy + y * rowBytes, pixels + y * bytesPerRow, rowBytes)
            }
            original = copy
            // calloc: untouched offset pages stay lazy until a dab writes them (Full HD Array zero-fill was ~50–100 ms).
            let offsetCount = width * height * 2
            offsets = calloc(offsetCount, MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
        }
        guard let offsets, original != nil else { return }

        scratchW = cw; scratchH = ch
        scratchOrigin = SIMD2(Int32(x0), Int32(y0))
        // Scratch holds prior offsets (dx, dy) for the dab region.
        scratch = [Float](repeating: 0, count: cw * ch * 2)
        for gy in 0..<ch {
            for gx in 0..<cw {
                let i = ((y0 + gy) * width + (x0 + gx)) * 2
                let o = (gy * cw + gx) * 2
                scratch[o] = offsets[i]
                scratch[o + 1] = offsets[i + 1]
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
                func offsetAt(_ x: Int, _ y: Int) -> SIMD2<Float> {
                    let o = (y * cw + x) * 2
                    return SIMD2(scratch[o], scratch[o + 1])
                }
                let top = offsetAt(ix, iy) + (offsetAt(ix + 1, iy) - offsetAt(ix, iy)) * fx
                let bottom = offsetAt(ix, iy + 1) + (offsetAt(ix + 1, iy + 1) - offsetAt(ix, iy + 1)) * fx
                let moved = top + (bottom - top) * fy - move * w
                let oi = (py * width + px) * 2
                offsets[oi] = moved.x
                offsets[oi + 1] = moved.y
                write(px, py, sampleOriginal(Float(px) + moved.x, Float(py) + moved.y))
            }
        }
    }
}
