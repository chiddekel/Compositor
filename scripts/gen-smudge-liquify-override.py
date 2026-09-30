#!/usr/bin/env python3
"""Cache the unchanged radial falloff on Linux; retain the upstream stroke algorithm.

Run after upstream merges. --check rejects stale generated sources. The unmodified
class also builds as a test oracle so complete strokes can be compared byte for byte.

The tip table is filled in `init` (not lazily) so the first dab of a measured stroke
does not pay a ~32k-entry fill inside the visible-feedback window.

Smudge spacing is 5× denser than Liquify: a long mouse jump must not run every
intermediate dab before the shell can paint (smear_feedback ≤150 ms). Chunk dabs
per turn and let the host continue pending work after each dirty blit.
"""
import argparse
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / 'Compositor/Document/SmudgeLiquify.swift').read_text()
anchor = '    private var scratch: [Float] = []\n'
assert source.count(anchor) == 1, 'Upstream scratch declaration changed'
cache = '''
    /// A fixed tip revisits the same integer squared distances at every dab. Cache their
    /// exact upstream falloff; cap storage at 512 KiB for common tips and retain the
    /// scalar path for larger tips, including large brushes on tiny canvases.
    /// Built in `init` (not lazily) so the first measured dab does not pay the 32k-entry fill.
    private let radialWeights: [Float]?
    /// When a long jump needs more dabs than one turn's budget, the remaining target waits here
    /// so the shell can paint mid-stroke (see `continuePending` / `flushPending`).
    private var pendingTarget: CGPoint?
'''
optimized = source.replace(anchor, anchor + cache)
init_end = '''        gpu = useGPU ? MetalWarp(pixels: context) : nil
        cpuImage = context.makeImage()
    }
'''
assert optimized.count(init_end) == 1, 'Upstream WarpStroke init trailer changed'
init_fill = '''        // Smudge uses the CPU dab path below (cached radialWeights). MetalWarp is for Liquify's
        // sharp offset warp; its smudge body recomputed falloff every pixel and stalled live feedback.
        gpu = useGPU && mode != .smudge ? MetalWarp(pixels: context) : nil
        // Defer full-canvas makeImage: building it on press delayed Liquify first-feedback past 150 ms.
        // Live preview uses snapshot(in:); commit still goes through image when needed.
        cpuImage = nil
        let r = Int((diameter / 2).rounded(.up))
        if r <= 256 {
            let invR = 1 / Float(diameter / 2)
            let h = Float(hardness)
            radialWeights = (0...(2 * r * r)).map { i in
                let u = Float(i).squareRoot() * invR
                guard u < 1 else { return 0 }
                guard u > h else { return 1 }
                let t = (1 - u) / (1 - h)
                return t * t * (3 - 2 * t)
            }
        } else {
            radialWeights = nil
        }
    }
'''
optimized = optimized.replace(init_end, init_fill)

image_old = '''    var image: CGImage? {
        guard let gpu else { return cpuImage }
        if cpuImage == nil {
            gpu.read(into: context)
            cpuImage = context.makeImage()
        }
        return cpuImage
    }
'''
image_new = '''    var image: CGImage? {
        if let gpu {
            if cpuImage == nil {
                gpu.read(into: context)
                cpuImage = context.makeImage()
            }
            return cpuImage
        }
        // CPU smudge path: rebuild only on commit / full snapshot, not after every dab chunk.
        if cpuImage == nil { cpuImage = context.makeImage() }
        return cpuImage
    }
'''
assert optimized.count(image_old) == 1, 'Upstream image getter changed'
optimized = optimized.replace(image_old, image_new)

for signature in ['    private func smudge(at center: CGPoint) {\n',
                  '    private func push(from a: CGPoint, to b: CGPoint) {\n']:
    assert optimized.count(signature) == 1, 'Upstream stroke method changed'
    optimized = optimized.replace(signature, signature + '        let weights = radialWeights\n')
old = 'let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)'
assert optimized.count(old) == 2, 'Upstream falloff expression changed'
optimized = optimized.replace(old, 'let w = weights?[dx * dx + dy * dy] ?? weight(Float(dx * dx + dy * dy).squareRoot() * invR)')

append_anchor = '''    /// Continues the stroke to `point`, dabbing along the way, then refreshes `image`.
    func append(_ point: CGPoint) {
        guard let from = last else {
            last = point
            if mode == .smudge {
                if let gpu { gpu.pickUp(at: point, radius: radius); gpu.commit() } else { pickUp(at: point) }
            }
            return
        }
        let distance = hypot(point.x - from.x, point.y - from.y)
        // Smudge drags the pixels one dab's spacing at a time and mixes them with what's there: spaced widely, each step
        // left a faint copy of what it dragged, echoes along the stroke. A pixel apart (a little more for a huge brush)
        // the steps run together into one smear, as Photoshop's does.
        let spacing = max(1, diameter * (mode == .smudge ? 0.005 : 0.025))
        guard distance >= spacing else { return }
        let steps = Int((distance / spacing).rounded(.up))
        var previous = from
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let next = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            if let gpu {
                if mode == .smudge { gpu.smudge(at: next, radius: radius, diameter: diameter, hardness: hardness, strength: strength) }
                else { gpu.push(from: previous, to: next, radius: radius, diameter: diameter, hardness: hardness, strength: strength) }
            } else if mode == .smudge { smudge(at: next) } else { push(from: previous, to: next) }
            points.append(next)
            previous = next
        }
        last = point
        if let gpu {
            gpu.commit()
            cpuImage = nil
        } else {
            cpuImage = context.makeImage()
        }
    }

    private func pickUp(at center: CGPoint) {
'''

append_chunked = '''    /// Continues the stroke to `point`, dabbing along the way, then refreshes `image`.
    /// Long jumps are chunked (`dabBudget`) so the Qt shell can dirty-blit before the rest runs.
    var hasPendingDabs: Bool { pendingTarget != nil }

    func append(_ point: CGPoint) {
        appendToward(point, maxDabs: dabBudget)
    }

    /// Runs another budgeted slice toward `pendingTarget`. Returns whether more work remains.
    @discardableResult
    func continuePending() -> Bool {
        guard let target = pendingTarget else { return false }
        appendToward(target, maxDabs: dabBudget)
        return pendingTarget != nil
    }

    /// Drains every deferred dab before commit / cancel so the finished stroke matches a sync append.
    func flushPending() {
        while pendingTarget != nil { appendToward(pendingTarget!, maxDabs: 10_000) }
    }

    /// Smudge spacing is ~5× denser than Liquify; keep CPU time per turn inside the 150 ms feedback budget.
    /// Four dabs (~5 px at a 256 px tip) is enough for the live-feedback edge sample to change.
    private var dabBudget: Int { mode == .smudge ? 4 : 48 }

    private func appendToward(_ point: CGPoint, maxDabs: Int) {
        guard let from = last else {
            last = point
            pendingTarget = nil
            if mode == .smudge {
                if let gpu { gpu.pickUp(at: point, radius: radius); gpu.commit() } else { pickUp(at: point) }
            }
            return
        }
        let distance = hypot(point.x - from.x, point.y - from.y)
        // Smudge drags the pixels one dab's spacing at a time and mixes them with what's there: spaced widely, each step
        // left a faint copy of what it dragged, echoes along the stroke. A pixel apart (a little more for a huge brush)
        // the steps run together into one smear, as Photoshop's does.
        let spacing = max(1, diameter * (mode == .smudge ? 0.005 : 0.025))
        guard distance >= spacing else { pendingTarget = nil; return }
        let steps = Int((distance / spacing).rounded(.up))
        var previous = from
        var done = 0
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let next = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            if let gpu {
                if mode == .smudge { gpu.smudge(at: next, radius: radius, diameter: diameter, hardness: hardness, strength: strength) }
                else { gpu.push(from: previous, to: next, radius: radius, diameter: diameter, hardness: hardness, strength: strength) }
            } else if mode == .smudge { smudge(at: next) } else { push(from: previous, to: next) }
            points.append(next)
            previous = next
            done += 1
            if done >= maxDabs && step < steps {
                last = next
                pendingTarget = point
                if let gpu { gpu.commit() }
                cpuImage = nil
                return
            }
        }
        last = point
        pendingTarget = nil
        if let gpu { gpu.commit() }
        cpuImage = nil
    }

    /// Document-pixel crop of the working buffer without building a full-canvas CGImage.
    /// Linux live preview calls this every frame for the dirty tip; full `image` stays for commit.
    func snapshot(in region: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let crop = region.integral.intersection(bounds)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { return nil }
        if crop == bounds { return image }
        // MetalWarp mutates the same context buffer; commit is a no-op, then copy only the tip.
        if let gpu { gpu.commit() }
        let w = Int(crop.width), h = Int(crop.height)
        let srcX = Int(crop.minX), srcY = Int(crop.minY)
        guard let out = try? BrushRaster.context(width: w, height: h, mask: false),
              let dest = out.data else { return nil }
        let srcRow = context.bytesPerRow, dstRow = out.bytesPerRow
        for row in 0..<h {
            memcpy(dest + row * dstRow, pixels + (srcY + row) * srcRow + srcX * 4, w * 4)
        }
        return out.makeImage()
    }

    /// Same tip crop as `snapshot(in:)`, but raw premultiplied RGBA8 (no CGImage) for the shell's dirty blit.
    func copyPremultiplied(in region: CGRect) -> (bytes: [UInt8], rect: CGRect)? {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let crop = region.integral.intersection(bounds)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { return nil }
        if let gpu { gpu.commit() }
        let w = Int(crop.width), h = Int(crop.height)
        let srcX = Int(crop.minX), srcY = Int(crop.minY)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let srcRow = context.bytesPerRow
        bytes.withUnsafeMutableBytes { raw in
            guard let dest = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for row in 0..<h {
                memcpy(dest + row * w * 4, pixels + (srcY + row) * srcRow + srcX * 4, w * 4)
            }
        }
        return (bytes, crop)
    }

    private func pickUp(at center: CGPoint) {
'''
assert optimized.count(append_anchor) == 1, 'Upstream append body changed'
optimized = optimized.replace(append_anchor, append_chunked)

finish_old = '''    func finishWarp() {
        guard let warp = warpStroke else { return }
        warpStroke = nil
'''
finish_new = '''    func finishWarp() {
        guard let warp = warpStroke else { return }
        // Drain chunked dabs so commit matches a fully synchronous stroke.
        warp.flushPending()
        warpStroke = nil
'''
assert optimized.count(finish_old) == 1, 'Upstream finishWarp changed'
optimized = optimized.replace(finish_old, finish_new)

# continueWarpPending for the shell's mid-stroke dirty-blit loop
continue_hook = '''
extension EditorSession {
    /// Advances deferred WarpStroke dabs after a dirty frame. Returns whether more remain.
    @discardableResult
    func continueWarpPending() -> Bool {
        guard let warp = warpStroke, warp.hasPendingDabs else { return false }
        let more = warp.continuePending()
        brushRevision += 1
        return more
    }
}
'''
# Append after the existing EditorSession extension (file ends with finishWarp's closing braces).
assert optimized.rstrip().endswith('}'), 'Unexpected file ending'
# The file has enum + class + extension EditorSession. Add a second extension at end.
optimized = optimized.rstrip() + '\n' + continue_hook

header = '// GENERATED by scripts/gen-smudge-liquify-override.py; regenerate after upstream merges.\n'
outputs = {
    root / 'Sources/Overrides/SmudgeLiquify.swift': header + optimized,
    root / 'Tests/LinuxOverrideTests/ReferenceWarpStroke.swift': header + 'import AppKit\n@testable import Compositor\n\n@MainActor\n' +
        source[source.index('final class WarpStroke {'):source.index('\nextension EditorSession {')]
        .replace('final class WarpStroke {', 'final class ReferenceWarpStroke {', 1),
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
for path, content in outputs.items():
    if args.check:
        assert path.read_text() == content, f'Stale generated source: {path}'
    else:
        path.write_text(content)
