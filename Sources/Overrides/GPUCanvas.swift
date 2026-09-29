// OVERRIDE for Compositor/Rendering/GPUCanvas.swift (excluded from the Linux build).
//
// Upstream draws the canvas on Metal when `GPUCanvasRenderer.shared` is present. Linux keeps the Core Graphics canvas
// (Qt/Skia), which is the portable path for every tool. `shared` is nil so EditorCanvas always takes that path; the
// types below exist so the tip's GPU helpers still type-check.

import Foundation
import AppKit
import CoreGraphics
import CoreImage

/// Stand-in for QuartzCore's Metal layer: only the fields EditorCanvas reads when a GPU view would present.
final class CAMetalLayer {
    var drawableSize = CGSize.zero
    var contentsScale: CGFloat = 1
}

@MainActor final class GPUCanvasRenderer {
    /// No Metal device on Linux: every frame uses Core Graphics.
    static let shared: GPUCanvasRenderer? = nil

    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    func image(_ image: CGImage, level: Int = 0, mask: Bool = false, transient: Bool = false) -> CIImage? {
        _ = (image, level, mask, transient); return nil
    }
    func image(_ stroke: BrushStroke, base: CIImage?) -> CIImage? { _ = (stroke, base); return nil }
    func image(_ raster: RasterSnapshot, level: Int = 0) -> CIImage? { _ = (raster, level); return nil }
    func cachedLevels(of image: CGImage) -> [Int] { _ = image; return [] }
    func endFrame() {}
    func present(_ image: CIImage, in layer: CAMetalLayer) { _ = (image, layer) }

    static func size(_ width: Int, _ height: Int, level: Int) -> CGSize {
        CGSize(width: max(1, width >> level), height: max(1, height >> level))
    }
    static func grayCopy(_ image: CGImage) throws -> CGContext { throw ExportError.render }
    static func reduced(_ full: CIImage, width: Int, height: Int, level: Int) -> CIImage {
        _ = (width, height, level); return full
    }
}

final class MetalCanvasView: NSView {
    let metalLayer = CAMetalLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func fit(scale: CGFloat) {
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}

@MainActor struct GPUPlacement {
    let mapping: CGAffineTransform
    let scale: CGFloat
    let renderer: GPUCanvasRenderer

    func place(width: Int, height: Int, transform: LayerTransform, mask: Bool = false,
               source: (Int) -> CIImage?) -> CIImage? {
        _ = (width, height, transform, mask, source); return nil
    }
    func warp(_ image: CGImage, transform: LayerTransform, corners: [CGPoint], mask: Bool = false) -> CIImage? {
        _ = (image, transform, corners, mask); return nil
    }
    func place(_ image: CGImage, transform: LayerTransform, mask: Bool = false) -> CIImage? {
        _ = (image, transform, mask); return nil
    }
    func place(live image: CIImage, width: Int, height: Int, transform: LayerTransform) -> CIImage? {
        _ = (image, width, height, transform); return nil
    }
    func place(transient image: CGImage, transform: LayerTransform, mask: Bool = false) -> CIImage? {
        _ = (image, transform, mask); return nil
    }
    func place(_ raster: RasterSnapshot, transform: LayerTransform) -> CIImage? {
        _ = (raster, transform); return nil
    }
}

enum GPUBlend {
    static func blend(_ top: CIImage, over bottom: CIImage, mode: LayerBlendMode) -> CIImage {
        _ = mode; return top.composited(over: bottom)
    }
    static func filterName(_ mode: LayerBlendMode) -> String? { _ = mode; return nil }
    static func masked(_ image: CIImage, by mask: CIImage) -> CIImage {
        _ = mask; return image
    }
    static func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        _ = opacity; return image
    }
}

enum GPUAdjustment {
    static func apply(_ adjustment: LayerAdjustment, to image: CIImage, scale: CGFloat, mapping: CGAffineTransform) -> CIImage? {
        _ = (adjustment, image, scale, mapping); return nil
    }
    static let dimension = 33
    static func cube(for adjustment: LayerAdjustment) -> Data? { _ = adjustment; return nil }
}
