import Foundation
import CoreImageKernels

/// Direct motion's finite Gaussian kernels, including native linear-texture sampling precision.
enum MotionKernel {
    static func taps(radius: Double, angle: Double) -> [CompositorMotionTap]? {
        guard radius.isFinite, radius > 0, radius < 3 else { return nil }
        let denominator = radius * sqrt(2)
        var weights: [Double] = (0..<10).map { index -> Double in
            let upper = (Double(index) + 0.5) / denominator
            let lower = (Double(index) - 0.5) / denominator
            return (erf(upper) - erf(lower)) / 2
        }
        let reach = max(1, Int(ceil(3 * radius - 0.5)))
        if reach < 8 {
            weights[reach] = weights[reach...].reduce(0, +)
            weights = Array(weights[...reach])
        }
        var samples: [(Double, Double)] = []
        if [2, 4, 6].contains(reach) {
            samples = (-reach...reach).map { (Double($0), weights[abs($0)]) }
        } else {
            for first in stride(from: 0, to: weights.count - 1, by: 2) {
                let total = (first == 0 ? weights[0] / 2 : weights[first]) + weights[first + 1]
                // The largest direct kernel folds the final pair onto its inner texel.
                let offset: Double = first == 8 ? 8 : Double(first) + weights[first + 1] / total
                samples.append((-offset, total)); samples.append((offset, total))
            }
        }
        return samples.map { offset, weight in
            let x = offset * cos(angle), y = offset * sin(angle), ix = floor(x), iy = floor(y)
            let tx = ((x - ix) * 256).rounded(.toNearestOrEven) / 256
            let ty = ((y - iy) * 256).rounded(.toNearestOrEven) / 256
            return CompositorMotionTap(x: Int(ix), y: Int(iy), tx: Float(tx), ty: Float(ty), weight: Float(weight))
        }
    }
}
