// Portable port of Compositor/Document/SmudgeLiquify.swift's `WarpStroke` (the
// raster class the file map's "Keep logic" tier covers; the two tool-mode enums
// are already ported in BrushModes.swift, and the `EditorSession` extension is
// the Qt-side controller milestone).
//
// Kept verbatim: the smudge carry buffer with pick-up and re-deposition, the
// weight profile (flat to the hardness radius, smoothstep to the rim), forward
// warp with a pre-dab scratch copy and bilinear back-sample, dab spacing, and
// the document-size working buffer that the canvas shows in place of the layer.
//
// Replaced: the CGContext working surface with a canvas-size `PixelBuffer`
// (the layer is placed into it via the portable `LayerRenderer.draw`, the exact
// placement math of the macOS original). The working image is exposed as a
// computed `PortableImage` view — no per-dab full-size copies; the commit path
// (finishWarp's clone stroke) materializes once.

import Foundation

/// A Smudge or Liquify stroke in progress. It works on the active layer as the canvas shows it, at document size,
/// changing it dab by dab; the canvas shows that working copy in place of the layer. When the stroke ends, the result
/// is painted into the layer's own pixels along the stroke's path (see `EditorSession.finishWarp` on macOS;
// the Qt controller drives the same sequence through `points` and `image`).
final class WarpStroke {
    let layer: ImageLayer
    let mode: BlurToolMode
    let diameter: CGFloat
    let hardness: CGFloat
    let strength: CGFloat
    let width: Int
    let height: Int
    var working: PixelBuffer
    /// Every dab's center, for painting the result into the layer.
    private(set) var points: [CGPoint] = []
    private var last: CGPoint?
    /// Smudge: the color the brush carries, a (2r+1)² RGBA square.
    private var carried: [Float] = []
    private var scratch: [Float] = []

    /// The working surface as an image (computed: no per-dab copy).
    var image: PortableImage { PortableImage(working) }

    init(layer: ImageLayer, image: RasterImage, transform: LayerTransform, canvas: CGSize,
         mode: BlurToolMode, settings: BrushSettings) throws {
        self.layer = layer
        self.mode = mode
        diameter = max(2, settings.diameter)
        hardness = min(0.98, max(0, settings.hardness))
        strength = min(1, max(0.01, settings.opacity))
        width = Int(canvas.width); height = Int(canvas.height)
        guard width > 0, height > 0 else { throw ProjectError.tooLarge }
        working = PixelBuffer(width: width, height: height)
        LayerRenderer.draw(image, transform: transform, center: transform.center, into: &working)
    }

    private var radius: Int { Int((diameter / 2).rounded(.up)) }
    /// How much a dab moves pixels at a distance `u` (0 center, 1 rim) from its center.
    private func weight(_ u: Float) -> Float {
        guard u < 1 else { return 0 }
        let h = Float(hardness)
        guard u > h else { return 1 }
        let t = (1 - u) / (1 - h)
        return t * t * (3 - 2 * t)
    }

    /// Continues the stroke to `point`, dabbing along the way.
    func append(_ point: CGPoint) {
        guard let from = last else {
            last = point
            if mode == .smudge { pickUp(at: point) }
            return
        }
        let distance = hypot(point.x - from.x, point.y - from.y)
        let spacing = max(1, diameter * (mode == .smudge ? 0.08 : 0.025))
        guard distance >= spacing else { return }
        let steps = Int((distance / spacing).rounded(.up))
        var previous = from
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let next = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            if mode == .smudge { smudge(at: next) } else { push(from: previous, to: next) }
            points.append(next)
            previous = next
        }
        last = point
    }

    private func pickUp(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        carried = [Float](repeating: 0, count: side * side * 4)
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let p = (y * width + x) * 4, c = ((dy + r) * side + dx + r) * 4
                for k in 0..<4 { carried[c + k] = Float(working.bytes[p + k]) }
            }
        }
    }

    private func smudge(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let keep = Float(strength), invR = 1 / Float(diameter / 2)
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                let p = (y * width + x) * 4, c = ((dy + r) * side + dx + r) * 4
                for k in 0..<4 {
                    let under = Float(working.bytes[p + k])
                    let painted = under + (carried[c + k] - under) * w
                    working.bytes[p + k] = UInt8(max(0, min(255, painted.rounded())))
                    // The brush picks up some of what it just left, more the weaker the smudge.
                    carried[c + k] = painted + (carried[c + k] - painted) * keep
                }
            }
        }
    }

    /// Forward warp: pixels under the brush move with it, most at its center, fading to none at its rim.
    private func push(from a: CGPoint, to b: CGPoint) {
        let r = radius
        let move = SIMD2<Float>(Float(b.x - a.x), Float(b.y - a.y)) * Float(strength)
        let margin = Int(ceil(max(abs(move.x), abs(move.y)))) + 2
        let cx = Int(b.x.rounded()), cy = Int(b.y.rounded())
        // A copy of the area as it was before this dab, which the dab samples from.
        let x0 = max(0, cx - r - margin), x1 = min(width - 1, cx + r + margin)
        let y0 = max(0, cy - r - margin), y1 = min(height - 1, cy + r + margin)
        guard x0 <= x1, y0 <= y1 else { return }
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        if scratch.count < cw * ch * 4 { scratch = [Float](repeating: 0, count: cw * ch * 4) }
        for y in 0..<ch {
            for x in 0..<cw {
                let p = ((y + y0) * width + x + x0) * 4, s = (y * cw + x) * 4
                for k in 0..<4 { scratch[s + k] = Float(working.bytes[p + k]) }
            }
        }
        let invR = 1 / Float(diameter / 2)
        for dy in -r...r {
            let y = cy + dy
            guard y >= y0, y <= y1 else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= x0, x <= x1 else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                // Bilinear sample of the old pixels, from behind the brush's travel.
                let sx = min(Float(cw - 1), max(0, Float(x - x0) - move.x * w))
                let sy = min(Float(ch - 1), max(0, Float(y - y0) - move.y * w))
                let ix = min(cw - 2, Int(sx)), iy = min(ch - 2, Int(sy))
                guard ix >= 0, iy >= 0 else { continue }
                let fx = sx - Float(ix), fy = sy - Float(iy)
                let p = (y * width + x) * 4
                let s00 = (iy * cw + ix) * 4, s10 = s00 + 4, s01 = s00 + cw * 4, s11 = s01 + 4
                for k in 0..<4 {
                    let top = scratch[s00 + k] + (scratch[s10 + k] - scratch[s00 + k]) * fx
                    let bottom = scratch[s01 + k] + (scratch[s11 + k] - scratch[s01 + k]) * fx
                    working.bytes[p + k] = UInt8(max(0, min(255, (top + (bottom - top) * fy).rounded())))
                }
            }
        }
    }
}
