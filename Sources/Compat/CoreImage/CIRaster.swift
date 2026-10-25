// CIRaster.swift — float pixel rasters and the filter maths behind the CoreImage shim.
//
// Core Image's coordinate system has its origin at the bottom-left with y up; a raster's row 0 is y = rect.minY.
// Pixels are premultiplied RGBA floats in 0...1. Colour management: when `linear` evaluation is requested, sources
// are converted from sRGB to linear light on entry and back on exit, as Core Image's default working space does.

import Foundation
import CoreGraphics
import Dispatch
import CoreImageKernels

struct Raster {
    var rect: CGRect              // integral, in CI coordinates
    var width: Int { Int(rect.width) }
    var height: Int { Int(rect.height) }
    var data: [Float]

    init(rect: CGRect) {
        self.rect = rect
        data = [Float](repeating: 0, count: max(0, Int(rect.width) * Int(rect.height) * 4))
    }
    init(rect: CGRect, uninitialized: Bool) {
        self.rect = rect
        let count = max(0, Int(rect.width) * Int(rect.height) * 4)
        if uninitialized {
            data = Array<Float>(unsafeUninitializedCapacity: count) { _, initializedCount in
                initializedCount = count
            }
        } else {
            data = [Float](repeating: 0, count: count)
        }
    }
    init(rect: CGRect, data: [Float]) { self.rect = rect; self.data = data }

    @inline(__always) func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    /// Copy of `region` (which may extend beyond this raster; outside is transparent).
    func cropped(to region: CGRect) -> Raster {
        if rect == region { return self }
        var out = Raster(rect: region)
        let inter = region.intersection(rect)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return out }
        let x0 = Int(inter.minX - rect.minX), y0 = Int(inter.minY - rect.minY)
        let ox = Int(inter.minX - region.minX), oy = Int(inter.minY - region.minY)
        let copyBytes = Int(inter.width) * 4 * MemoryLayout<Float>.stride
        let h = Int(inter.height)
        let outWidth = out.width
        out.data.withUnsafeMutableBufferPointer { outBuf in
            self.data.withUnsafeBufferPointer { srcBuf in
                guard let dstPtr = outBuf.baseAddress, let srcPtr = srcBuf.baseAddress else { return }
                for y in 0..<h {
                    let s = index(x0, y0 + y)
                    let d = ((oy + y) * outWidth + ox) * 4
                    memcpy(dstPtr + d, srcPtr + s, copyBytes)
                }
            }
        }
        return out
    }

    /// Pixel at integer position, edge-replicated.
    @inline(__always) func clamped(_ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        let i = index(cx, cy)
        return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }

    /// A region with edge pixels repeated outside the image, using the same integer coordinates as `clamped`.
    func clamped(to region: CGRect) -> Raster {
        if rect == region { return self }
        var out = Raster(rect: region)
        let sourceWidth = width, sourceHeight = height, outputWidth = out.width, outputHeight = out.height
        guard sourceWidth > 0, sourceHeight > 0, outputWidth > 0, outputHeight > 0 else { return out }
        let x0 = Int(region.minX) - Int(rect.minX), y0 = Int(region.minY) - Int(rect.minY)
        let left = min(outputWidth, max(0, -x0))
        let firstSource = min(sourceWidth, max(0, x0))
        let middle = min(outputWidth - left, sourceWidth - firstSource)
        data.withUnsafeBufferPointer { source in
            out.data.withUnsafeMutableBufferPointer { target in
                guard let src = source.baseAddress, let dst = target.baseAddress else { return }
                for y in 0..<outputHeight {
                    let sy = min(max(y0 + y, 0), sourceHeight - 1)
                    let row = src + sy * sourceWidth * 4, destination = dst + y * outputWidth * 4
                    for x in 0..<left { memcpy(destination + x * 4, row, 4 * MemoryLayout<Float>.size) }
                    if middle > 0 {
                        memcpy(destination + left * 4, row + firstSource * 4, middle * 4 * MemoryLayout<Float>.size)
                    }
                    let last = row + (sourceWidth - 1) * 4
                    for x in (left + middle)..<outputWidth {
                        memcpy(destination + x * 4, last, 4 * MemoryLayout<Float>.size)
                    }
                }
            }
        }
        return out
    }

    /// Bilinear sample at continuous device coordinates (pixel centres at +0.5); outside is transparent.
    /// The pixel containing the point (`fx`, `fy` in pixel units from this raster's origin); transparent outside.
    func nearest(_ fx: Double, _ fy: Double) -> (Float, Float, Float, Float) {
        let ix = Int(floor(fx)), iy = Int(floor(fy))
        guard ix >= 0, iy >= 0, ix < width, iy < height else { return (0, 0, 0, 0) }
        let i = index(ix, iy); return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }

    func bilinear(_ fx: Double, _ fy: Double) -> (Float, Float, Float, Float) {
        let x = fx - 0.5, y = fy - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let tx = Float(x - Double(x0)), ty = Float(y - Double(y0))
        func px(_ ix: Int, _ iy: Int) -> (Float, Float, Float, Float) {
            guard ix >= 0, iy >= 0, ix < width, iy < height else { return (0, 0, 0, 0) }
            let i = index(ix, iy); return (data[i], data[i + 1], data[i + 2], data[i + 3])
        }
        let a = px(x0, y0), b = px(x0 + 1, y0), c = px(x0, y0 + 1), d = px(x0 + 1, y0 + 1)
        func mix(_ p: Float, _ q: Float, _ r: Float, _ s: Float) -> Float { (p * (1 - tx) + q * tx) * (1 - ty) + (r * (1 - tx) + s * tx) * ty }
        return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2), mix(a.3, b.3, c.3, d.3))
    }
}

enum Gamma {
    static func toLinear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func toSRGB(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    /// Applies `f` to the colour channels of every (unpremultiplied) pixel and re-premultiplies. As in Core Image's
    /// extended spaces, values past 0...1 are not clipped: the curve is mirrored for negatives and carried on past
    /// white (an HDR layer's highlights survive a linear working space).
    static func map(_ r: inout Raster, _ f: (Float) -> Float) {
        var i = 0
        while i < r.data.count {
            let a = r.data[i + 3]
            if a > 0 {
                for c in 0..<3 {
                    let v = r.data[i + c] / a
                    r.data[i + c] = (v < 0 ? -f(-v) : f(v)) * a
                }
            }
            i += 4
        }
    }
}

// MARK: - Filters over rasters

enum RasterFilters {
    /// Spatially varying Gaussian blur, interpolated in variance between logarithmically spaced radii.
    /// Only two blurred rasters are retained; premultiplied float channels keep alpha and HDR precision.
    static func variableBlur(_ input: Raster, mask: Raster, radius: Double, output region: CGRect) -> Raster {
        var lower = input.cropped(to: region)
        guard radius > 0 && radius.isFinite else { return lower }
        let mask = mask.cropped(to: region)
        var output = lower
        let radii = stride(from: 0, to: mask.data.count, by: 4).map { i -> Double in
            let luminance = Double(mask.data[i] * 0.2126 + mask.data[i + 1] * 0.7152 + mask.data[i + 2] * 0.0722)
            return luminance.isFinite ? min(1, max(0, luminance)) * radius : 0
        }
        var from = 0.0
        while from < radius {
            let to = min(radius, max(0.5, from * sqrt(2)))
            let upper = gaussian(input, sigma: to, output: region)
            for pixel in 0..<radii.count where radii[pixel] > from && radii[pixel] <= to {
                let amount = Float((radii[pixel] * radii[pixel] - from * from) / (to * to - from * from))
                let i = pixel * 4
                for channel in 0..<4 { output.data[i + channel] = lower.data[i + channel] * (1 - amount) + upper.data[i + channel] * amount }
            }
            lower = upper
            from = to
        }
        return output
    }

    /// Separable Gaussian. The input raster already includes the margin the kernel needs.
    static func gaussian(_ input: Raster, sigma: Double, output region: CGRect) -> Raster {
        let radius = Int(ceil(sigma * 3))
        guard radius > 0, sigma > 0 else { return input.cropped(to: region) }
        var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = kernel.reduce(0, +); kernel = kernel.map { $0 / total }
        let w = input.width, h = input.height
        let visible = region.intersection(input.rect)
        guard w > 0, h > 0, !visible.isNull, !visible.isEmpty else { return Raster(rect: region) }
        let x0 = Int(visible.minX - input.rect.minX), y0 = Int(visible.minY - input.rect.minY)
        let ow = Int(visible.width), oh = Int(visible.height)
        let firstRow = max(0, y0 - radius), lastRow = min(h, y0 + oh + radius)
        let rowsNeeded = lastRow - firstRow
        // Large finite kernels are cheaper in frequency space. Small regions
        // (including brush tiles) keep the direct convolution to avoid FFT setup.
        let plan = radius >= 48 && max(ow, oh) >= 256
            ? kernel.withUnsafeBufferPointer { compositor_gaussian_plan($0.baseAddress!, radius) } : nil
        defer { compositor_gaussian_plan_free(plan) }
        // Only horizontal results feeding the requested output are needed. The vertical pass
        // reads this narrow strip plus its halo, with the same finite-kernel support as a full render.
        var tmp = [Float](repeating: 0, count: ow * rowsNeeded * 4)
        var out = Raster(rect: visible)
        func rows(_ count: Int, _ body: @escaping (Int) -> Void) {
            let workers = min(count, min(16, ProcessInfo.processInfo.activeProcessorCount))
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for y in (worker * count / workers)..<((worker + 1) * count / workers) { body(y) }
            }
        }
        kernel.withUnsafeBufferPointer { coefficients in
            let weights = coefficients.baseAddress!
            input.data.withUnsafeBufferPointer { source in
                tmp.withUnsafeMutableBufferPointer { temporary in
                    let src = source.baseAddress!, dst = temporary.baseAddress!
                    rows(rowsNeeded) { row in
                        if let plan, ow >= 256,
                           compositor_gaussian_fft(plan, src + (firstRow + row) * w * 4,
                               w, 4, x0, ow, dst + row * ow * 4, 4) != 0 { return }
                        compositor_gaussian_horizontal(src + (firstRow + row) * w * 4,
                            w, x0, ow, weights, radius, dst + row * ow * 4)
                    }
                }
            }
            tmp.withUnsafeBufferPointer { temporary in
                out.data.withUnsafeMutableBufferPointer { destination in
                    let src = temporary.baseAddress!, dst = destination.baseAddress!
                    if let plan, oh >= 256 {
                        rows(ow) { x in
                            if compositor_gaussian_fft(plan, src + x * 4, rowsNeeded, ow * 4,
                                y0 - firstRow, oh, dst + x * 4, ow * 4) != 0 { return }
                            // Allocation failure keeps the direct implementation available.
                            for row in 0..<oh {
                                let y = y0 + row
                                let lo = max(-radius, -y), hi = min(radius, h - y - 1)
                                for c in 0..<4 {
                                    var sum: Float = 0
                                    for k in lo...hi {
                                        sum += src[((y + k - firstRow) * ow + x) * 4 + c] * weights[k + radius]
                                    }
                                    dst[(row * ow + x) * 4 + c] = sum
                                }
                            }
                        }
                        return
                    }
                    rows(oh) { row in
                        let y = y0 + row
                        let lo = max(-radius, -y), hi = min(radius, h - y - 1)
                        compositor_gaussian_vertical(src + (y + lo - firstRow) * ow * 4,
                            ow, weights + lo + radius, hi - lo + 1, dst + row * ow * 4)
                    }
                }
            }
        }
        return out.cropped(to: region)
    }

    /// Gaussian-weighted line at `angle` radians; radius is its standard deviation, as upstream calibrates Distance.
    static func motionBlur(_ input: Raster, radius: Double, angle: Double, output region: CGRect) -> Raster {
        guard radius > 0, radius.isFinite else { return input.cropped(to: region) }
        var out = Raster(rect: region)
        let reach = Int(ceil(radius * 3))
        let denominator = radius * sqrt(2.0)
        // Integrate each tap's pixel footprint, retaining the tails at the outer taps.
        let weights = (-reach...reach).map { offset -> Double in
            if abs(offset) == reach { return erfc((Double(reach) - 0.5) / denominator) / 2 }
            return (erf((Double(offset) + 0.5) / denominator) - erf((Double(offset) - 0.5) / denominator)) / 2
        }
        let total = weights.reduce(0, +)
        let dx = cos(angle), dy = sin(angle)
        let width = out.width, height = out.height, sourceWidth = input.width, sourceHeight = input.height
        guard width > 0, height > 0, sourceWidth > 0, sourceHeight > 0 else { return out }
        let firstX = Int(region.minX - input.rect.minX), firstY = Int(region.minY - input.rect.minY)
        // Every output pixel uses the same offsets and fractions. Computing these in
        // the inner loop made even the default adjustment stall the desktop for seconds.
        let kernel = (-reach...reach).map { t -> CompositorMotionTap in
            let s = Double(t)
            let x = s * dx, y = s * dy, ix = floor(x), iy = floor(y)
            return CompositorMotionTap(x: Int(ix), y: Int(iy), tx: Float(x - ix), ty: Float(y - iy),
                                       weight: Float(weights[t + reach] / total))
        }
        kernel.withUnsafeBufferPointer { kernel in
            input.data.withUnsafeBufferPointer { source in
                out.data.withUnsafeMutableBufferPointer { destination in
                    let src = source.baseAddress!, dst = destination.baseAddress!, weights = kernel.baseAddress!
                    let workers = min(height, min(16, ProcessInfo.processInfo.activeProcessorCount))
                    DispatchQueue.concurrentPerform(iterations: workers) { worker in
                        for y in (worker * height / workers)..<((worker + 1) * height / workers) {
                            compositor_motion_row(src, sourceWidth, sourceHeight, firstX, firstY + y,
                                                  width, weights, kernel.count, dst + y * width * 4)
                        }
                    }
                }
            }
        }
        return out
    }

    /// CIColorMatrix: on unpremultiplied color, out = M * rgba + bias, premultiplied again. HDR stays unclipped.
    static func colorMatrix(_ input: Raster, r: [Float], g: [Float], b: [Float], a: [Float], bias: [Float]) -> Raster {
        var out = input
        var i = 0
        while i < out.data.count {
            let alpha = input.data[i + 3]
            let c: [Float] = alpha > 0 ? [input.data[i] / alpha, input.data[i + 1] / alpha, input.data[i + 2] / alpha, alpha] : [0, 0, 0, 0]
            func dot(_ v: [Float], _ bias: Float) -> Float { v[0] * c[0] + v[1] * c[1] + v[2] * c[2] + v[3] * c[3] + bias }
            let na = dot(a, bias[3])
            out.data[i] = dot(r, bias[0]) * na; out.data[i + 1] = dot(g, bias[1]) * na
            out.data[i + 2] = dot(b, bias[2]) * na; out.data[i + 3] = na
            i += 4
        }
        return out
    }

    /// CIBloom adds the positive difference between the blurred image and its source, scaled by intensity.
    /// This preserves a translucent source while extending its halo. Keep HDR until final conversion.
    static func bloom(_ source: Raster, blurred: Raster, intensity: Float) -> Raster {
        var out = source
        var i = 0
        while i < out.data.count {
            for channel in 0..<4 {
                let value = source.data[i + channel]
                out.data[i + channel] = value + max(0, blurred.data[i + channel] - value) * intensity
            }
            i += 4
        }
        return out
    }

    /// CIColorClamp: clamps each unpremultiplied component into [min, max].
    static func colorClamp(_ input: Raster, minimum: [Float], maximum: [Float]) -> Raster {
        var out = input
        var i = 0
        while i < out.data.count {
            let alpha = input.data[i + 3]
            var c: [Float] = alpha > 0 ? [input.data[i] / alpha, input.data[i + 1] / alpha, input.data[i + 2] / alpha, alpha] : [0, 0, 0, 0]
            for k in 0..<4 { c[k] = min(maximum[k], max(minimum[k], c[k])) }
            out.data[i] = c[0] * c[3]; out.data[i + 1] = c[1] * c[3]; out.data[i + 2] = c[2] * c[3]; out.data[i + 3] = c[3]
            i += 4
        }
        return out
    }

    /// CIColorCube: trilinear lookup into an N^3 table of premultiplied-in / RGBA float entries (r fastest).
    static func colorCube(_ input: Raster, dimension n: Int, cube: [Float]) -> Raster {
        guard n >= 2, cube.count >= n * n * n * 4 else { return input }
        var out = input
        func entry(_ r: Int, _ g: Int, _ b: Int, _ c: Int) -> Float { cube[((b * n + g) * n + r) * 4 + c] }
        var i = 0
        while i < out.data.count {
            let alpha = input.data[i + 3]
            if alpha > 0 {
                let p = [input.data[i] / alpha, input.data[i + 1] / alpha, input.data[i + 2] / alpha].map { min(1, max(0, $0)) * Float(n - 1) }
                let lo = p.map { min(Int($0), n - 2) }, t = zip(p, lo).map { $0 - Float($1) }
                var result: [Float] = [0, 0, 0]
                for c in 0..<3 {
                    var v: Float = 0
                    for db in 0...1 { for dg in 0...1 { for dr in 0...1 {
                        let w = (dr == 1 ? t[0] : 1 - t[0]) * (dg == 1 ? t[1] : 1 - t[1]) * (db == 1 ? t[2] : 1 - t[2])
                        v += w * entry(lo[0] + dr, lo[1] + dg, lo[2] + db, c)
                    } } }
                    result[c] = v
                }
                out.data[i] = result[0] * alpha; out.data[i + 1] = result[1] * alpha; out.data[i + 2] = result[2] * alpha
            }
            i += 4
        }
        return out
    }

    /// CIBlendWithMask: mix(background, input, mask) where the mask value is its (unpremultiplied) red channel.
    /// `channel`: 0 the mask's red, 3 its alpha, 4 its luminance (as CIBlendWithRedMask / AlphaMask / BlendWithMask).
    static func blendWithMask(_ input: Raster, background: Raster, mask: Raster, channel: Int = 0) -> Raster {
        var out = Raster(rect: input.rect, uninitialized: true)
        let w = input.width, h = input.height
        out.data.withUnsafeMutableBufferPointer { outBuf in
            input.data.withUnsafeBufferPointer { inBuf in
                background.data.withUnsafeBufferPointer { bgBuf in
                    mask.data.withUnsafeBufferPointer { mskBuf in
                        guard let outPtr = outBuf.baseAddress,
                              let inPtr = inBuf.baseAddress,
                              let bgPtr = bgBuf.baseAddress,
                              let mskPtr = mskBuf.baseAddress else { return }
                        let chunks = min(h, max(1, ProcessInfo.processInfo.activeProcessorCount * 2))
                        let chunkSize = (h + chunks - 1) / chunks
                        DispatchQueue.concurrentPerform(iterations: chunks) { c in
                            let startY = c * chunkSize
                            guard startY < h else { return }
                            let endY = min(h, startY + chunkSize)
                            for y in startY..<endY {
                                let rowStart = y * w * 4
                                var outP = outPtr + rowStart
                                var inP = inPtr + rowStart
                                var bgP = bgPtr + rowStart
                                var mskP = mskPtr + rowStart
                                for _ in 0..<w {
                                    let ma = mskP[3]
                                    if ma <= 0 {
                                        outP[0] = bgP[0]; outP[1] = bgP[1]; outP[2] = bgP[2]; outP[3] = bgP[3]
                                    } else {
                                        let m: Float = channel == 3 ? ma
                                            : channel == 4 ? (0.2126 * mskP[0] + 0.7152 * mskP[1] + 0.0722 * mskP[2]) / ma
                                            : (ma == 1.0 ? mskP[0] : mskP[0] / ma)
                                        if m <= 0.0 {
                                            outP[0] = bgP[0]; outP[1] = bgP[1]; outP[2] = bgP[2]; outP[3] = bgP[3]
                                        } else if m >= 1.0 {
                                            outP[0] = inP[0]; outP[1] = inP[1]; outP[2] = inP[2]; outP[3] = inP[3]
                                        } else {
                                            let invM = 1.0 - m
                                            outP[0] = inP[0] * m + bgP[0] * invM
                                            outP[1] = inP[1] * m + bgP[1] * invM
                                            outP[2] = inP[2] * m + bgP[2] * invM
                                            outP[3] = inP[3] * m + bgP[3] * invM
                                        }
                                    }
                                    outP += 4; inP += 4; bgP += 4; mskP += 4
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Separable-blend compositing (source over backdrop) in premultiplied form, per the W3C compositing model.
    static func separableBlend(_ source: Raster, backdrop: Raster, _ blend: (Float, Float) -> Float) -> Raster {
        var out = source
        var i = 0
        while i < out.data.count {
            let as_ = source.data[i + 3], ab = backdrop.data[i + 3]
            for c in 0..<3 {
                let cs = as_ > 0 ? source.data[i + c] / as_ : 0
                let cb = ab > 0 ? backdrop.data[i + c] / ab : 0
                let mixed = as_ * ab * blend(cb, cs)
                out.data[i + c] = (1 - ab) * source.data[i + c] + (1 - as_) * backdrop.data[i + c] + mixed
            }
            out.data[i + 3] = as_ + ab - as_ * ab
            i += 4
        }
        return out
    }
    static func colorDodge(_ cb: Float, _ cs: Float) -> Float { cb == 0 ? 0 : (cs >= 1 ? 1 : min(1, cb / (1 - cs))) }
    static func colorBurn(_ cb: Float, _ cs: Float) -> Float { cb >= 1 ? 1 : (cs <= 0 ? 0 : 1 - min(1, (1 - cb) / cs)) }
    /// W3C / PDF soft-light separable blend (matches Core Image's CISoftLightBlendMode closely enough for canvas parity).
    static func softLight(_ cb: Float, _ cs: Float) -> Float {
        if cs <= 0.5 {
            return cb - (1 - 2 * cs) * cb * (1 - cb)
        }
        let d: Float = cb <= 0.25
            ? ((16 * cb - 12) * cb + 4) * cb
            : sqrt(cb)
        return cb + (2 * cs - 1) * (d - cb)
    }
    static func linearBurn(_ cb: Float, _ cs: Float) -> Float { max(0, cb + cs - 1) }
    static func linearDodge(_ cb: Float, _ cs: Float) -> Float { min(1, cb + cs) }
    static func vividLight(_ cb: Float, _ cs: Float) -> Float {
        cs <= 0.5 ? colorBurn(cb, max(cs * 2, 1e-6)) : colorDodge(cb, min(2 * (cs - 0.5), 1 - 1e-6))
    }
    static func linearLight(_ cb: Float, _ cs: Float) -> Float { min(1, max(0, cb + 2 * cs - 1)) }
    static func pinLight(_ cb: Float, _ cs: Float) -> Float {
        cs <= 0.5 ? min(cb, 2 * cs) : max(cb, 2 * cs - 1)
    }
    static func hardMix(_ cb: Float, _ cs: Float) -> Float { vividLight(cb, cs) < 0.5 ? 0 : 1 }
    static func subtract(_ cb: Float, _ cs: Float) -> Float { max(0, cb - cs) }
    static func divide(_ cb: Float, _ cs: Float) -> Float { cs <= 0 ? 1 : min(1, cb / cs) }

    static func separableFormula(_ filterName: String) -> (Float, Float) -> Float {
        switch filterName {
        case "CIColorBurnBlendMode": return colorBurn
        case "CIColorDodgeBlendMode": return colorDodge
        case "CISoftLightBlendMode": return softLight
        case "CILinearBurnBlendMode": return linearBurn
        case "CILinearDodgeBlendMode": return linearDodge
        case "CIVividLightBlendMode": return vividLight
        case "CILinearLightBlendMode": return linearLight
        case "CIPinLightBlendMode": return pinLight
        case "CIHardMixBlendMode": return hardMix
        case "CISubtractBlendMode": return subtract
        case "CIDivideBlendMode": return divide
        case "CIMultiplyBlendMode": return { cb, cs in cb * cs }
        case "CIScreenBlendMode": return screen
        case "CIOverlayBlendMode": return { cb, cs in hardLight(cs, cb) }
        case "CIDarkenBlendMode": return min
        case "CILightenBlendMode": return max
        case "CIHardLightBlendMode": return hardLight
        case "CIDifferenceBlendMode": return { cb, cs in abs(cb - cs) }
        case "CIExclusionBlendMode": return { cb, cs in cb + cs - 2 * cb * cs }
        default: return { cb, _ in cb }
        }
    }
    static func screen(_ cb: Float, _ cs: Float) -> Float { cb + cs - cb * cs }
    static func hardLight(_ cb: Float, _ cs: Float) -> Float { cs <= 0.5 ? cb * 2 * cs : screen(cb, 2 * cs - 1) }

    /// The W3C non-separable modes (Hue, Saturation, Color, Luminosity), which mix whole colors rather than channels.
    static let nonSeparableModes: Set<String> = ["CIHueBlendMode", "CISaturationBlendMode", "CIColorBlendMode", "CILuminosityBlendMode"]

    static func nonSeparableBlend(_ source: Raster, backdrop: Raster, mode: String) -> Raster {
        typealias RGB = (Float, Float, Float)
        func lum(_ c: RGB) -> Float { 0.3 * c.0 + 0.59 * c.1 + 0.11 * c.2 }
        func clip(_ c: RGB) -> RGB {
            let l = lum(c), n = min(c.0, c.1, c.2), x = max(c.0, c.1, c.2)
            var r = c
            if n < 0 { r = (l + (r.0 - l) * l / (l - n), l + (r.1 - l) * l / (l - n), l + (r.2 - l) * l / (l - n)) }
            if x > 1 { r = (l + (r.0 - l) * (1 - l) / (x - l), l + (r.1 - l) * (1 - l) / (x - l), l + (r.2 - l) * (1 - l) / (x - l)) }
            return r
        }
        func setLum(_ c: RGB, _ l: Float) -> RGB { let d = l - lum(c); return clip((c.0 + d, c.1 + d, c.2 + d)) }
        func sat(_ c: RGB) -> Float { max(c.0, c.1, c.2) - min(c.0, c.1, c.2) }
        func setSat(_ c: RGB, _ s: Float) -> RGB {
            var v = [c.0, c.1, c.2]
            let order = v.indices.sorted { v[$0] < v[$1] }
            let lo = order[0], mid = order[1], hi = order[2]
            if v[hi] > v[lo] { v[mid] = (v[mid] - v[lo]) * s / (v[hi] - v[lo]); v[hi] = s } else { v[mid] = 0; v[hi] = 0 }
            v[lo] = 0
            return (v[0], v[1], v[2])
        }
        var out = source
        var i = 0
        while i < out.data.count {
            let a = source.data[i + 3], ab = backdrop.data[i + 3]
            let cs: RGB = a > 0 ? (source.data[i] / a, source.data[i + 1] / a, source.data[i + 2] / a) : (0, 0, 0)
            let cb: RGB = ab > 0 ? (backdrop.data[i] / ab, backdrop.data[i + 1] / ab, backdrop.data[i + 2] / ab) : (0, 0, 0)
            let mixed: RGB
            switch mode {
            case "CIHueBlendMode": mixed = setLum(setSat(cs, sat(cb)), lum(cb))
            case "CISaturationBlendMode": mixed = setLum(setSat(cb, sat(cs)), lum(cb))
            case "CIColorBlendMode": mixed = setLum(cs, lum(cb))
            default: mixed = setLum(cb, lum(cs))   // Luminosity
            }
            let m = [mixed.0, mixed.1, mixed.2]
            for c in 0..<3 {
                out.data[i + c] = (1 - ab) * source.data[i + c] + (1 - a) * backdrop.data[i + c] + a * ab * m[c]
            }
            out.data[i + 3] = a + ab - a * ab
            i += 4
        }
        return out
    }

    /// Inverse-maps `output` through a projective transform given by the 3x3 matrix `inverse` (device -> source).
    static func projective(_ input: Raster, inverse m: [Double], output region: CGRect, nearest: Bool = false) -> Raster {
        if let copied = alignedAffine(input, inverse: m, output: region) { return copied }
        var out = Raster(rect: region)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let px = Double(out.rect.minX) + Double(x) + 0.5, py = Double(out.rect.minY) + Double(y) + 0.5
                let w = m[6] * px + m[7] * py + m[8]
                guard abs(w) > 1e-12 else { continue }
                let sx = (m[0] * px + m[1] * py + m[2]) / w - Double(input.rect.minX)
                let sy = (m[3] * px + m[4] * py + m[5]) / w - Double(input.rect.minY)
                let p = nearest ? input.nearest(sx, sy) : input.bilinear(sx, sy)
                let o = out.index(x, y)
                out.data[o] = p.0; out.data[o + 1] = p.1; out.data[o + 2] = p.2; out.data[o + 3] = p.3
            }
        }
        return out
    }

    /// Unit-scale axis flips and integer translations map pixel centers exactly; no interpolation is needed.
    private static func alignedAffine(_ input: Raster, inverse m: [Double], output region: CGRect) -> Raster? {
        guard m.count == 9, m[1] == 0, m[3] == 0, m[6] == 0, m[7] == 0, m[8] == 1,
              (m[0] == 1 || m[0] == -1), (m[4] == 1 || m[4] == -1),
              m[2].isFinite, m[5].isFinite, m[2].rounded() == m[2], m[5].rounded() == m[5]
        else { return nil }
        // Keep exact pixel-center arithmetic: fractional and very large coordinate origins use the general path.
        let coordinates = [Double(input.rect.minX), Double(input.rect.minY), Double(region.minX), Double(region.minY), m[2], m[5]]
        guard coordinates.allSatisfy({ $0.isFinite && abs($0) < 1_099_511_627_776 && $0.rounded() == $0 }) else { return nil }
        // Preserve the general sampler's IEEE arithmetic for nonfinite, subnormal and negative-zero samples.
        guard input.data.allSatisfy({ value in
            let bits = value.bitPattern, exponent = bits & 0x7f800000
            return exponent != 0x7f800000 && (exponent != 0 || bits == 0)
        }) else { return nil }
        if m[0] == 1, m[4] == 1, m[2] == 0, m[5] == 0, input.rect == region { return input }
        var out = Raster(rect: region)
        let initialX = m[0] * Double(out.rect.minX) + m[2] - Double(input.rect.minX) + (m[0] < 0 ? -1 : 0)
        let initialY = m[4] * Double(out.rect.minY) + m[5] - Double(input.rect.minY) + (m[4] < 0 ? -1 : 0)
        let limit = Double(Int.max / 4)
        guard initialX.isFinite, initialY.isFinite, abs(initialX) < limit, abs(initialY) < limit,
              initialX.rounded() == initialX, initialY.rounded() == initialY else { return nil }
        let x0 = Int(initialX), y0 = Int(initialY), dx = Int(m[0]), dy = Int(m[4])
        let first = max(0, dx == 1 ? -x0 : x0 - input.width + 1)
        let end = min(out.width, dx == 1 ? input.width - x0 : x0 + 1)
        guard first < end else { return out }
        let outputWidth = out.width, outputHeight = out.height
        input.data.withUnsafeBufferPointer { source in
            out.data.withUnsafeMutableBufferPointer { target in
                guard let src = source.baseAddress, let dst = target.baseAddress else { return }
                for y in 0..<outputHeight {
                    let sy = y0 + dy * y
                    guard sy >= 0 && sy < input.height else { continue }
                    let row = src + sy * input.width * 4
                    let destination = dst + (y * outputWidth + first) * 4
                    if dx == 1 {
                        memcpy(destination, row + (x0 + first) * 4, (end - first) * 4 * MemoryLayout<Float>.size)
                    } else {
                        for x in first..<end {
                            let pixel = row + (x0 - x) * 4, offset = (x - first) * 4
                            for channel in 0..<4 { destination[offset + channel] = pixel[channel] }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Homography taking the unit-square corners (p0..p3 in order) to the target points, returned as a 3x3 row-major.
    static func homography(from src: [CGPoint], to dst: [CGPoint]) -> [Double]? {
        // Solve 8 equations for the 8 unknowns (h33 = 1) with Gaussian elimination.
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y), u = Double(dst[i].x), v = Double(dst[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        for col in 0..<8 {
            var pivot = col
            for r in col..<8 where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for r in 0..<8 where r != col {
                let f = a[r][col] / a[col][col]
                for k in col..<9 { a[r][k] -= f * a[col][k] }
            }
        }
        return (0..<8).map { a[$0][8] / a[$0][$0] } + [1]
    }

    static func invert3(_ m: [Double]) -> [Double]? {
        let det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
        guard abs(det) > 1e-14 else { return nil }
        return [
            (m[4] * m[8] - m[5] * m[7]) / det, (m[2] * m[7] - m[1] * m[8]) / det, (m[1] * m[5] - m[2] * m[4]) / det,
            (m[5] * m[6] - m[3] * m[8]) / det, (m[0] * m[8] - m[2] * m[6]) / det, (m[2] * m[3] - m[0] * m[5]) / det,
            (m[3] * m[7] - m[4] * m[6]) / det, (m[1] * m[6] - m[0] * m[7]) / det, (m[0] * m[4] - m[1] * m[3]) / det]
    }

    /// CIEdgePreserveUpsampleFilter: upsample `small` to the guide's size by joint-bilateral weighting, so the result's
    /// edges follow the guide image's luminance edges.
    static func edgePreserveUpsample(guide: Raster, small: Raster, spatialSigma: Double, lumaSigma: Double) -> Raster {
        var out = Raster(rect: guide.rect)
        let gw = guide.width, gh = guide.height, sw = small.width, sh = small.height
        guard gw > 0, gh > 0, sw > 0, sh > 0 else { return out }
        func luma(_ r: Raster, _ x: Int, _ y: Int) -> Float {
            let (a, b, c, al) = r.clamped(x, y)
            return al > 0 ? 0.2126 * a / al + 0.7152 * b / al + 0.0722 * c / al : 0
        }
        let radius = max(1, Int(ceil(spatialSigma / max(1, Double(gw) / Double(sw)))) + 1)
        let sx = Double(sw) / Double(gw), sy = Double(sh) / Double(gh)
        let twoS2 = 2 * max(0.25, spatialSigma * spatialSigma / max(1, Double(gw) / Double(sw))), twoL2 = Float(2 * lumaSigma * lumaSigma)
        for y in 0..<gh {
            for x in 0..<gw {
                let cxs = (Double(x) + 0.5) * sx - 0.5, cys = (Double(y) + 0.5) * sy - 0.5
                let gl = luma(guide, x, y)
                var acc: (Float, Float, Float, Float) = (0, 0, 0, 0), total: Float = 0
                for ny in Int(floor(cys)) - radius + 1...Int(floor(cys)) + radius {
                    for nx in Int(floor(cxs)) - radius + 1...Int(floor(cxs)) + radius {
                        let d2 = pow(Double(nx) - cxs, 2) + pow(Double(ny) - cys, 2)
                        let ws = Float(exp(-d2 / twoS2))
                        // Guide luma where that coarse sample sits in guide coordinates.
                        let gx = min(gw - 1, max(0, Int((Double(nx) + 0.5) / sx))), gy = min(gh - 1, max(0, Int((Double(ny) + 0.5) / sy)))
                        let dl = luma(guide, gx, gy) - gl
                        let wr = exp(-dl * dl / twoL2)
                        let p = small.clamped(nx, ny), w = ws * wr
                        acc.0 += p.0 * w; acc.1 += p.1 * w; acc.2 += p.2 * w; acc.3 += p.3 * w; total += w
                    }
                }
                let o = out.index(x, y)
                if total > 0 { out.data[o] = acc.0 / total; out.data[o + 1] = acc.1 / total; out.data[o + 2] = acc.2 / total; out.data[o + 3] = acc.3 / total }
            }
        }
        return out
    }

    @inline(__always) private static func mix32(_ x: UInt32) -> UInt32 {
        var v = x
        v ^= v >> 16; v &*= 0x7feb352d
        v ^= v >> 15; v &*= 0x846ca68b
        v ^= v >> 16
        return v
    }

    @inline(__always) private static func unitNoise(_ key: UInt32) -> Float {
        Float(mix32(key) >> 8) * (1.0 / 16_777_216.0)
    }

    @inline(__always) private static func latticeNoise(_ ix: Int32, _ iy: Int32, _ seed: UInt32) -> Float {
        let h = mix32((UInt32(bitPattern: ix) &* 0x9E3779B1) ^ mix32((UInt32(bitPattern: iy) &* 0x85EBCA77) ^ seed))
        return Float(h & 0xFFFF) / 65535.0 + Float(h >> 16) / 65535.0 - 1.0
    }

    @inline(__always) private static func grainField(_ u: Float, _ v: Float, _ scale: Float, _ seed: UInt32) -> Float {
        let cellX = floor(u / scale), cellY = floor(v / scale)
        var tx = u / scale - cellX, ty = v / scale - cellY
        tx = tx * tx * (3.0 - 2.0 * tx)
        ty = ty * ty * (3.0 - 2.0 * ty)
        let ix = Int32(cellX), iy = Int32(cellY)
        let n00 = latticeNoise(ix, iy, seed), n10 = latticeNoise(ix &+ 1, iy, seed)
        let n01 = latticeNoise(ix, iy &+ 1, seed), n11 = latticeNoise(ix &+ 1, iy &+ 1, seed)
        let top = n00 + (n10 - n00) * tx, bottom = n01 + (n11 - n01) * tx
        return (top + (bottom - top) * ty) * 1.6
    }

    static func addNoise(_ src: Raster, parameters p: [Float]) -> Raster {
        guard p.count >= 6 else { return src }
        var out = src
        let w = out.width, h = out.height
        let amount = p[0], gaussian = p[1] != 0, monochromatic = p[2] != 0
        let seed = p[3].bitPattern
        let originX = Int32(bitPattern: p[4].bitPattern)
        let originY = Int32(bitPattern: p[5].bitPattern)
        let spread = amount / 100.0 * 127.5
        out.data.withUnsafeMutableBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            for y in 0..<h {
                let py = UInt32(bitPattern: originY &+ Int32(y))
                let pyHash = mix32(py &* 0x85ebca6b)
                let row = y * w * 4
                for x in 0..<w {
                    let i = row + x * 4
                    let a = ptr[i + 3]
                    guard a * 255.0 > 0 else { continue }
                    let px = UInt32(bitPattern: originX &+ Int32(x))
                    let base = mix32(seed ^ mix32((px &* 0x9e3779b9) ^ pyHash))
                    for c in 0..<3 {
                        let key = monochromatic ? base : base &+ UInt32(c) &* 0x9e3779b9
                        let n: Float
                        if gaussian {
                            let u1 = unitNoise(key), u2 = unitNoise(key ^ 0x68e31da4)
                            n = sqrt(-2.0 * log(1.0 - u1)) * cos(6.2831853 * u2) * spread * (2.0 / 3.0)
                        } else {
                            n = (unitNoise(key) * 2.0 - 1.0) * spread
                        }
                        let v = min(255.0, max(0.0, ptr[i + c] * 255.0 / a + n))
                        ptr[i + c] = v / 255.0 * a
                    }
                }
            }
        }
        return out
    }

    static func addGrain(_ src: Raster, parameters p: [Float]) -> Raster {
        guard p.count >= 10 else { return src }
        var out = src
        let w = out.width, h = out.height
        let strength = p[0], roughness = p[1], size = p[2], detailSize = p[3]
        let originX = p[4], originY = p[5], unitsPerPixel = p[6]
        let seed = p[7].bitPattern
        let fineSeed = mix32(seed ^ 0xA511E9B3)
        let minX = Int32(bitPattern: p[8].bitPattern)
        let minY = Int32(bitPattern: p[9].bitPattern)
        out.data.withUnsafeMutableBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            for y in 0..<h {
                let v = originY + (Float(minY &+ Int32(y)) + 0.5) * unitsPerPixel
                let row = y * w * 4
                for x in 0..<w {
                    let i = row + x * 4
                    let a = ptr[i + 3]
                    guard a > 0 else { continue }
                    let u = originX + (Float(minX &+ Int32(x)) + 0.5) * unitsPerPixel
                    let smooth = grainField(u, v, size, seed)
                    let fine = grainField(u, v, detailSize, fineSeed)
                    let noise = smooth + (fine - smooth) * roughness
                    let r = ptr[i] / a * 255.0, g = ptr[i + 1] / a * 255.0, b = ptr[i + 2] / a * 255.0
                    let level = min(1.0, (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0)
                    let delta = noise * strength * (0.4 + 2.4 * level * (1.0 - level))
                    ptr[i] = min(255.0, max(0.0, r + delta)) / 255.0 * a
                    ptr[i + 1] = min(255.0, max(0.0, g + delta)) / 255.0 * a
                    ptr[i + 2] = min(255.0, max(0.0, b + delta)) / 255.0 * a
                }
            }
        }
        return out
    }
}
