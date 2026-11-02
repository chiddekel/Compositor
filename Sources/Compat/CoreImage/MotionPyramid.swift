import Foundation
import CoreGraphics

/// Horizontal/vertical motion uses a reduction pyramid before reconstructing the output lattice.
enum MotionPyramid {
    private struct Reduction {
        let factor: Int
        let first: Int
        let weights: [Float]

        init(factor: Int, first: Int, pairs: [Double]) {
            self.factor = factor; self.first = first
            let values = pairs + pairs.reversed()
            let total = values.reduce(0, +)
            weights = values.map { Float($0 / total) }
        }
    }

    // Fixed symmetric kernels identified from native impulse phases, checked on independent step/stripe inputs.
    private static let two = Reduction(factor: 2, first: -4, pairs: [
        0.010689121596139106, 0.03266226755168261, 0.08339895941375644,
        0.15663916325572938, 0.21637774341507598,
    ])
    private static let four = Reduction(factor: 4, first: -8, pairs: [
        0.000021522132164456298, 0.004746585691210635, 0.008166987073116097,
        0.015590651618483243, 0.02775504101385105, 0.04593294925139386,
        0.06821154414084038, 0.09200798985773846, 0.11287013276594927, 0.12452291763786155,
    ])

    private struct Plan {
        let stages: [Reduction]
        let scale: Double
        let gaussian: [Float]
        let vertical: Bool

        init?(radius: Double, angle: Double) {
            guard radius.isFinite, radius >= 3 else { return nil }
            if abs(sin(angle)) < 1e-12 { vertical = false }
            else if abs(cos(angle)) < 1e-12 { vertical = true }
            else { return nil }
            let removedVariance: Double
            if radius >= sqrt(264) { stages = [four, four]; scale = 16; removedVariance = 264 }
            else if radius >= sqrt(83) { stages = [four, two]; scale = 8; removedVariance = 83 }
            // Native captures already select factor four at 3.99; 3.9 still selects factor two.
            else if radius >= 3.99 { stages = [four]; scale = 4; removedVariance = 16 }
            else { stages = [two]; scale = 2; removedVariance = 4.5 }
            // Solve the discrete kernel's variance, including its pixel footprint, rather than a continuous sigma.
            gaussian = MotionPyramid.gaussian(variance: max(0, (radius * radius - removedVariance) / (scale * scale)))
        }

        func replacingAxis(_ rect: CGRect, first: Double, last: Double) -> CGRect {
            vertical ? CGRect(x: rect.minX, y: first, width: rect.width, height: last - first + 1)
                : CGRect(x: first, y: rect.minY, width: last - first + 1, height: rect.height)
        }

        func reconstructionRegion(_ output: CGRect) -> CGRect {
            let first = vertical ? output.minY : output.minX, last = vertical ? output.maxY : output.maxX
            return replacingAxis(output, first: floor((first + 0.5) / scale - 0.5) - 1,
                                 last: floor((last - 0.5) / scale - 0.5) + 2)
        }

        func regions(_ output: CGRect) -> [CGRect] {
            let reconstruction = reconstructionRegion(output), reach = Double(gaussian.count / 2)
            var regions = [CGRect](repeating: output, count: stages.count + 1)
            regions[stages.count] = replacingAxis(reconstruction,
                first: (vertical ? reconstruction.minY : reconstruction.minX) - reach,
                last: (vertical ? reconstruction.maxY : reconstruction.maxX) - 1 + reach)
            for level in stages.indices.reversed() {
                let stage = stages[level], target = regions[level + 1], factor = Double(stage.factor)
                regions[level] = replacingAxis(target,
                    first: (vertical ? target.minY : target.minX) * factor + Double(stage.first),
                    last: ((vertical ? target.maxY : target.maxX) - 1) * factor + Double(stage.first + stage.weights.count - 1))
            }
            return regions
        }
    }

    private static func kernel(sigma: Double) -> [Double] {
        let reach = Int(ceil(3 * sigma)), denominator = sigma * sqrt(2)
        let weights = (-reach...reach).map { offset -> Double in
            if abs(offset) == reach { return erfc((Double(reach) - 0.5) / denominator) / 2 }
            return (erf((Double(offset) + 0.5) / denominator) - erf((Double(offset) - 0.5) / denominator)) / 2
        }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }

    private static func gaussian(variance: Double) -> [Float] {
        guard variance > 0 else { return [1] }
        var lower = 0.0, upper = max(1, sqrt(variance))
        for _ in 0..<48 {
            let sigma = (lower + upper) / 2, weights = kernel(sigma: sigma), reach = weights.count / 2
            let measured = weights.enumerated().reduce(0.0) { $0 + $1.element * Double(($1.offset - reach) * ($1.offset - reach)) }
            if measured > variance { upper = sigma } else { lower = sigma }
        }
        return kernel(sigma: (lower + upper) / 2).map(Float.init)
    }

    static func inputRegion(for output: CGRect, radius: Double, angle: Double) -> CGRect? {
        guard !output.isEmpty, let plan = Plan(radius: radius, angle: angle) else { return nil }
        return plan.regions(output)[0]
    }

    private static func convolve(_ input: Raster, region: CGRect, factor: Int, first: Int,
                                 weights: [Float], vertical: Bool) -> Raster {
        var output = Raster(rect: region, uninitialized: true)
        let ix = Int(input.rect.minX), iy = Int(input.rect.minY)
        for y in 0..<output.height { for x in 0..<output.width {
            let sx = (Int(region.minX) + x) * (vertical ? 1 : factor) - ix
            let sy = (Int(region.minY) + y) * (vertical ? factor : 1) - iy
            var value = SIMD4<Float>.zero
            for tap in weights.indices {
                let px = sx + (vertical ? 0 : first + tap), py = sy + (vertical ? first + tap : 0)
                guard px >= 0, px < input.width, py >= 0, py < input.height else { continue }
                let i = input.index(px, py)
                value += SIMD4(input.data[i], input.data[i + 1], input.data[i + 2], input.data[i + 3]) * weights[tap]
            }
            let i = output.index(x, y)
            for channel in 0..<4 { output.data[i + channel] = value[channel] }
        } }
        return output
    }

    static func render(_ input: Raster, radius: Double, angle: Double, output region: CGRect) -> Raster? {
        guard !region.isEmpty, let plan = Plan(radius: radius, angle: angle) else { return nil }
        let regions = plan.regions(region)
        var current = input
        for (level, stage) in plan.stages.enumerated() {
            current = convolve(current, region: regions[level + 1], factor: stage.factor,
                first: stage.first, weights: stage.weights, vertical: plan.vertical)
        }
        current = convolve(current, region: plan.reconstructionRegion(region), factor: 1,
            first: -(plan.gaussian.count / 2), weights: plan.gaussian, vertical: plan.vertical)
        let count = plan.vertical ? Int(region.height) : Int(region.width)
        let origin = plan.vertical ? region.minY : region.minX
        let sourceOrigin = Int(plan.vertical ? current.rect.minY : current.rect.minX)
        let taps: [(SIMD4<Int32>, SIMD4<Float>)] = (0..<count).map { position in
            let q = (origin + Double(position) + 0.5) / plan.scale - 0.5, base = floor(q), t = q - base
            let w = [pow(1 - t, 3) / 6, (3*t*t*t - 6*t*t + 4) / 6,
                     (-3*t*t*t + 3*t*t + 3*t + 1) / 6, t*t*t / 6]
            var indices = SIMD4<Int32>.zero, weights = SIMD4<Float>.zero
            for pair in [0, 2] {
                let total = w[pair] + w[pair + 1]
                let lookup = base + Double(pair - 1) + w[pair + 1] / total, lower = floor(lookup)
                let fraction = Float(((lookup - lower) * 256).rounded(.toNearestOrEven) / 256)
                indices[pair] = Int32(Int(lower) - sourceOrigin); indices[pair + 1] = indices[pair] + 1
                weights[pair] = Float(total) * (1 - fraction); weights[pair + 1] = Float(total) * fraction
            }
            return (indices, weights)
        }
        var output = Raster(rect: region, uninitialized: true)
        for y in 0..<output.height { for x in 0..<output.width {
            let (indices, weights) = taps[plan.vertical ? y : x]
            var value = SIMD4<Float>.zero
            for tap in 0..<4 {
                let sx = plan.vertical ? x : Int(indices[tap]), sy = plan.vertical ? Int(indices[tap]) : y
                let i = current.index(sx, sy)
                value += SIMD4(current.data[i], current.data[i + 1], current.data[i + 2], current.data[i + 3]) * weights[tap]
            }
            let i = output.index(x, y)
            for channel in 0..<4 { output.data[i + channel] = value[channel] }
        } }
        return output
    }
}
