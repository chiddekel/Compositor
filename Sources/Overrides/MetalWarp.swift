// OVERRIDE for Compositor/Rendering/MetalWarp.swift (excluded from the Linux build).
//
// Same surface as upstream's Metal type so WarpStroke compiles unmodified. Metal is unavailable here; init always
// fails and the stroke keeps its CPU dabs (portable path). Canvas behavior stays complete without a GPU working copy.

import Foundation
import CoreGraphics
import CoreImage

@MainActor final class MetalWarp {
    let width: Int
    let height: Int
    var image: CIImage? { nil }

    init?(pixels: CGContext) {
        _ = pixels
        return nil
    }

    func read(into pixels: CGContext) { _ = pixels }
    func commit() {}
    func pickUp(at center: CGPoint, radius: Int) { _ = (center, radius) }
    func smudge(at center: CGPoint, radius: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        _ = (center, radius, diameter, hardness, strength)
    }
    func push(from a: CGPoint, to b: CGPoint, radius r: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        _ = (a, b, r, diameter, hardness, strength)
    }
}
