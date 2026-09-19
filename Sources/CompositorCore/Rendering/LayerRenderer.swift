// Portable port of Compositor/Rendering/LayerRenderer.swift (file-map tier:
// "Apple replacement/adaptation: Replace CoreGraphics compositing with Skia and
// exact custom blend kernels").
//
// Kept: the placement math (translate to center, rotate, flip, scale — the same
// matrix as `BrushRaster.pixelToDocument`), mask clipping over the layer bounds,
// opacity applied exactly once, and the blend-mode set incl. the two modes
// Core Graphics got wrong (Color Burn / Color Dodge) — here every mode is one
// exact PDF/W3C-spec kernel, which is what the macOS `SeparableBlend` CI
// workaround achieved for those two and CG achieved for the rest.
//
// Replaced: CGContext drawing with inverse-mapped per-pixel sampling into the
// canonical buffers (premultiplied source-over composite, per-channel blend of
// non-premultiplied color, W3C compositing formula). Sampling: nearest for
// `.nearest`, bilinear otherwise.
//
// Omitted (tracked):
//   - The sharp halving reduction (`DownsampleCache`) before the final
//     resample: quality divergence on large reductions only.
//     ponytail: bilinear-only shrinks alias slightly on >4x reductions; port
//     DownsampleCache halvings (or Skia) when fixture comparisons show drift.
//   - `drawBrushPreview` (tile preview fast path): the host canvas milestone;
//     `draw` over the committed raster produces the same pixels.
//
// The macOS original stays the source of truth for behavior.

import Foundation

nonisolated enum LayerRenderer {

    // MARK: Blend kernels (non-premultiplied color, 0...1)

    /// PDF/W3C separable blend of one channel (non-premultiplied, 0...1).
    @inline(__always)
    static func blendChannel(_ mode: LayerBlendMode, _ cb: Float, _ cs: Float) -> Float {
        switch mode {
        case .normal: return cs
        case .multiply: return cb * cs
        case .screen: return cb + cs - cb * cs
        case .overlay: return cb <= 0.5 ? 2 * cb * cs : 1 - 2 * (1 - cb) * (1 - cs)
        case .darken: return min(cb, cs)
        case .lighten: return max(cb, cs)
        case .difference: return abs(cb - cs)
        case .colorDodge: return cb >= 1 ? cb : min(1, cs / (1 - cb))
        case .colorBurn: return cb <= 0 ? cb : 1 - min(1, (1 - cs) / cb)
        case .hue, .saturation, .color, .luminosity:
            fatalError("non-separable mode reached the separable kernel")
        }
    }

    // W3C non-separable helpers.
    @inline(__always)
    private static func lum(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.3 * r + 0.59 * g + 0.11 * b
    }
    @inline(__always)
    private static func clipColor(_ r: inout Float, _ g: inout Float, _ b: inout Float) {
        let l = lum(r, g, b)
        let n = min(r, g, b), x = max(r, g, b)
        let d: Float = (n < 0) ? (l - n) : 0
        let e: Float = (x > 1) ? (l - x) : 0
        if d != 0 { r -= d; g -= d; b -= d }
        if e != 0 { r -= e; g -= e; b -= e }
    }
    @inline(__always)
    private static func setLum(_ r: Float, _ g: Float, _ b: Float, _ l: Float) -> (Float, Float, Float) {
        var (rr, gg, bb) = (r, g, b)
        let d = l - lum(rr, gg, bb)
        rr += d; gg += d; bb += d
        clipColor(&rr, &gg, &bb)
        return (rr, gg, bb)
    }
    @inline(__always)
    private static func sat(_ r: Float, _ g: Float, _ b: Float) -> Float {
        max(r, g, b) - min(r, g, b)
    }
    @inline(__always)
    private static func setSat(_ r: Float, _ g: Float, _ b: Float, _ s: Float) -> (Float, Float, Float) {
        // Order the channels, set the middle to s, keep the endpoints' spacing.
        var arr = [(r, 0), (g, 1), (b, 2)]
        arr.sort { $0.0 < $1.0 }
        let (cmin, _, cmax) = (arr[0].0, arr[1].0, arr[2].0)
        if cmax > cmin {
            let mid = cmin == cmax ? 0 : (arr[1].0 - cmin) * s / (cmax - cmin)
            let vals = [Float(0), mid, s]
            var out = [Float](repeating: 0, count: 3)
            for (index, pair) in arr.enumerated() { out[pair.1] = vals[index] }
            return (out[0], out[1], out[2])
        }
        return (0, 0, 0)
    }

    /// Full non-premultiplied blend of one pixel: W3C `Cs` over `Cb` at alpha `as`.
    @inline(__always)
    static func blendPixel(_ mode: LayerBlendMode,
                           _ cs: (Float, Float, Float), _ asAlpha: Float,
                           _ cb: (Float, Float, Float), _ ab: Float)
        -> (Float, Float, Float, Float) {
        var br: Float, bg: Float, bb: Float
        switch mode {
        case .hue:
            let s = sat(cb.0, cb.1, cb.2)
            let (r, g, b) = setSat(cs.0, cs.1, cs.2, s)
            (br, bg, bb) = setLum(r, g, b, lum(cb.0, cb.1, cb.2))
        case .saturation:
            let s = sat(cs.0, cs.1, cs.2)
            let (r, g, b) = setSat(cb.0, cb.1, cb.2, s)
            (br, bg, bb) = setLum(r, g, b, lum(cb.0, cb.1, cb.2))
        case .color:
            (br, bg, bb) = setLum(cs.0, cs.1, cs.2, lum(cb.0, cb.1, cb.2))
        case .luminosity:
            (br, bg, bb) = setLum(cb.0, cb.1, cb.2, lum(cs.0, cs.1, cs.2))
        default:
            br = blendChannel(mode, cb.0, cs.0)
            bg = blendChannel(mode, cb.1, cs.1)
            bb = blendChannel(mode, cb.2, cs.2)
        }
        // W3C compositing: Co = (1-αs)·αb·Cb + (1-αb)·αs·Cs + αs·αb·B(Cb,Cs)
        let or_ = (1 - asAlpha) * ab * cb.0 + (1 - ab) * asAlpha * cs.0 + asAlpha * ab * br
        let og = (1 - asAlpha) * ab * cb.1 + (1 - ab) * asAlpha * cs.1 + asAlpha * ab * bg
        let ob = (1 - asAlpha) * ab * cb.2 + (1 - ab) * asAlpha * cs.2 + asAlpha * ab * bb
        let ao = asAlpha + ab * (1 - asAlpha)
        // Non-premultiplied out; callers premultiply.
        let orC = ao > 0 ? min(1, max(0, or_ / ao)) : 0
        let ogC = ao > 0 ? min(1, max(0, og / ao)) : 0
        let obC = ao > 0 ? min(1, max(0, ob / ao)) : 0
        return (orC, ogC, obC, ao)
    }

    // MARK: Layer placement draw

    /// Draws one layer image through its transform into a canvas pixel buffer:
    /// premultiplied source-over (or any `LayerBlendMode`) at `opacity`, clipped
    /// by an optional mask placed over the same bounds.
    static func draw(_ image: RasterImage, transform: LayerTransform, center: CGPoint,
                     scale: CGFloat = 1, opacity: Double = 1, blendMode: LayerBlendMode = .normal,
                     mask: RasterImage? = nil, into buffer: inout PixelBuffer) {
        let pixels = image.pixels
        guard pixels.kind == .rgba else { return }
        var scaled = transform
        scaled.size = CGSize(width: transform.size.width * scale, height: transform.size.height * scale)
        // Image pixel -> document point.
        let mapping = BrushRaster.pixelToDocument(scaled, width: pixels.width, height: pixels.height)
        let inverse = mapping.inverted()
        let placeBounds = CGRect(x: 0, y: 0, width: CGFloat(pixels.width), height: CGFloat(pixels.height)).applying(mapping)
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(buffer.width), height: CGFloat(buffer.height)))
        guard !placeBounds.isNull, !placeBounds.isEmpty else { return }
        let nearest = transform.sampling == .nearest
        let opacityF = Float(min(1, max(0, opacity)))
        let x0 = max(0, Int(floor(placeBounds.minX))), x1 = min(buffer.width - 1, Int(ceil(placeBounds.maxX)) - 1)
        let y0 = max(0, Int(floor(placeBounds.minY))), y1 = min(buffer.height - 1, Int(ceil(placeBounds.maxY)) - 1)
        let maskPixels = mask?.pixels
        for y in y0...y1 {
            for x in x0...x1 {
                let local = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
                guard local.x >= 0, local.y >= 0, local.x < CGFloat(pixels.width), local.y < CGFloat(pixels.height) else { continue }
                let s: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
                if nearest {
                    s = RasterSample.rgbaNearest(pixels, fx: local.x, fy: local.y)
                } else {
                    s = RasterSample.rgbaBilinear(pixels, fx: local.x, fy: local.y)
                }
                var alpha = Float(s.a) / 255 * opacityF
                if let maskPixels {
                    // The mask covers the layer's bounds: sample it over the same
                    // normalized placement (CG clip(to:mask:) semantics).
                    let mx = local.x / CGFloat(pixels.width) * CGFloat(maskPixels.width)
                    let my = local.y / CGFloat(pixels.height) * CGFloat(maskPixels.height)
                    let mc = maskPixels.kind == .mask
                        ? Float(RasterSample.grayNearest(maskPixels, fx: mx, fy: my))
                        : Float(RasterSample.rgbaNearest(maskPixels, fx: mx, fy: my).a)
                    alpha *= mc / 255
                }
                guard alpha > 0 else { continue }
                let d = buffer[x, y]
                let sa = Float(d.a) / 255
                var cr: Float = 0, cg: Float = 0, cbS: Float = 0
                if s.a > 0 {
                    let inv = 1 / Float(s.a)
                    cr = Float(s.r) * inv
                    cg = Float(s.g) * inv
                    cbS = Float(s.b) * inv
                }
                let cs = (cr, cg, cbS)
                let cb: (Float, Float, Float)
                if d.a > 0 {
                    cb = (Float(d.r) / Float(d.a), Float(d.g) / Float(d.a), Float(d.b) / Float(d.a))
                } else {
                    cb = (0, 0, 0)
                }
                let out = blendPixel(blendMode, cs, alpha, cb, sa)
                // Premultiply the non-premultiplied blend result (0..1 → bytes).
                buffer[x, y] = (u8(out.0 * out.3 * 255), u8(out.1 * out.3 * 255),
                                u8(out.2 * out.3 * 255), u8(out.3 * 255))
            }
        }
    }

    /// Grayscale coverage of one image placed via `transform`: the mask's tone
    /// composited as white over the buffer (CG `clip(to:mask:)` + white fill).
    /// Used by the mask side of the blur sample and mask compositing.
    static func drawCoverage(_ image: RasterImage, transform: LayerTransform, into buffer: inout MaskBuffer) {
        let pixels = image.pixels
        let mapping = BrushRaster.pixelToDocument(transform, width: pixels.width, height: pixels.height)
        let inverse = mapping.inverted()
        let placeBounds = CGRect(x: 0, y: 0, width: CGFloat(pixels.width), height: CGFloat(pixels.height)).applying(mapping)
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(buffer.width), height: CGFloat(buffer.height)))
        guard !placeBounds.isNull, !placeBounds.isEmpty else { return }
        let nearest = transform.sampling == .nearest
        let x0 = max(0, Int(floor(placeBounds.minX))), x1 = min(buffer.width - 1, Int(ceil(placeBounds.maxX)) - 1)
        let y0 = max(0, Int(floor(placeBounds.minY))), y1 = min(buffer.height - 1, Int(ceil(placeBounds.maxY)) - 1)
        for y in y0...y1 {
            for x in x0...x1 {
                let local = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
                guard local.x >= 0, local.y >= 0, local.x < CGFloat(pixels.width), local.y < CGFloat(pixels.height) else { continue }
                let c: Float
                if pixels.kind == .mask {
                    c = nearest
                        ? Float(RasterSample.grayNearest(pixels, fx: local.x, fy: local.y))
                        : Float(RasterSample.grayBilinear(pixels, fx: local.x, fy: local.y))
                } else {
                    let s = nearest
                        ? RasterSample.rgbaNearest(pixels, fx: local.x, fy: local.y)
                        : RasterSample.rgbaBilinear(pixels, fx: local.x, fy: local.y)
                    c = Float(s.a)
                }
                let a = c / 255
                let base = Float(buffer[x, y])
                buffer[x, y] = u8(255 * a + base * (1 - a))
            }
        }
    }

    @inline(__always)
    private static func u8(_ v: Float) -> UInt8 {
        if v.isNaN { return 0 }
        if v <= 0 { return 0 }
        if v >= 255 { return 255 }
        return UInt8(v + 0.5)
    }
}
