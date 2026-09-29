// VulkanCanvasBackend.swift — Metal → Vulkan CG canvas factory.
//
// When a Vulkan device exists, this factory sits first in `CanvasBackends.factories`. Drawing still uses the
// Skia CompCanvas ABI into caller-owned CPU pixels (Qt already consumes that contract); after each
// `draw(image:)` that covers the full buffer with source-over, an optional GPU composite via the active
// CompRenderer trampoline (`compositor_compat_set_render_fn`) exercises the Vulkan path and readback.
// Without Vulkan, the factory reports unavailable and Skia-only remains the default.

import Foundation
#if canImport(Glibc)
import Glibc
#endif

struct VulkanGPUCanvasFactory: CanvasBackendFactory {
    var name: String { "skia-vulkan" }

    var isAvailable: Bool {
        CompCanvasBridge.shared.isAvailable && Self.vulkanGPUAvailable()
    }

    func makeCanvas(pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                    format: CGContext.PixelFormat) -> CanvasBackend? {
        guard let skia = SkiaCanvasFactory().makeCanvas(pixels: pixels, width: width, height: height,
                                                        bytesPerRow: bytesPerRow, format: format) else { return nil }
        return VulkanGPUCanvasBackend(inner: skia, pixels: pixels, width: width, height: height,
                                      bytesPerRow: bytesPerRow, format: format)
    }

    private static func vulkanGPUAvailable() -> Bool {
        if let forced = ProcessInfo.processInfo.environment["COMPOSITOR_CANVAS_GPU"]?.lowercased() {
            if forced == "0" || forced == "off" || forced == "cpu" { return false }
            if forced == "1" || forced == "on" || forced == "vulkan" { return probeVulkan() }
        }
        return probeVulkan()
    }

    private static func probeVulkan() -> Bool {
        typealias Fn = @convention(c) () -> Int32
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "compositor_vulkan_gpu_available")
            ?? CompCanvasBridge.loadedHandle.flatMap({ dlsym($0, "compositor_vulkan_gpu_available") }) {
            let fn = unsafeBitCast(sym, to: Fn.self)
            return fn() != 0
        }
        return false
    }
}

final class VulkanGPUCanvasBackend: CanvasBackend, @unchecked Sendable {
    private let inner: CanvasBackend
    private let pixels: UnsafeMutablePointer<UInt8>
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let format: CGContext.PixelFormat
    var name: String { "skia-vulkan" }

    init(inner: CanvasBackend, pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int,
         bytesPerRow: Int, format: CGContext.PixelFormat) {
        self.inner = inner
        self.pixels = pixels
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.format = format
    }

    func save() { inner.save() }
    func restore() { inner.restore() }
    func setAlpha(_ alpha: Float) { inner.setAlpha(alpha) }
    func setBlendMode(_ rawValue: Int32) { inner.setBlendMode(rawValue) }
    func setInterpolationQuality(_ rawValue: Int32) { inner.setInterpolationQuality(rawValue) }
    func setAntialias(_ enabled: Bool) { inner.setAntialias(enabled) }
    func translate(_ tx: Float, _ ty: Float) { inner.translate(tx, ty) }
    func scale(_ sx: Float, _ sy: Float) { inner.scale(sx, sy) }
    func rotate(_ radians: Float) { inner.rotate(radians) }
    func concat(_ transform: CGAffineTransform) { inner.concat(transform) }
    var totalMatrix: CGAffineTransform? { inner.totalMatrix }
    func clip(rect: CGRect, antialias: Bool) { inner.clip(rect: rect, antialias: antialias) }
    func clip(path: [PathSegment], evenOdd: Bool, antialias: Bool) {
        inner.clip(path: path, evenOdd: evenOdd, antialias: antialias)
    }
    func clip(mask: [UInt8], width: Int, height: Int, stride: Int, rect: CGRect, isGray: Bool) {
        inner.clip(mask: mask, width: width, height: height, stride: stride, rect: rect, isGray: isGray)
    }
    var clipBounds: CGRect { inner.clipBounds }
    func fill(rect: CGRect, color: CGColor) { inner.fill(rect: rect, color: color) }
    func fill(path: [PathSegment], evenOdd: Bool, color: CGColor) {
        inner.fill(path: path, evenOdd: evenOdd, color: color)
    }
    func stroke(path: [PathSegment], width: Float, cap: Int32, join: Int32, miterLimit: Float, color: CGColor) {
        inner.stroke(path: path, width: width, cap: cap, join: join, miterLimit: miterLimit, color: color)
    }
    func clear(rect: CGRect) { inner.clear(rect: rect) }
    func beginLayer(alpha: Float) { inner.beginLayer(alpha: alpha) }
    func endLayer() { inner.endLayer() }
    func linearGradient(_ gradient: CGGradient, from start: CGPoint, to end: CGPoint, options: Int32) {
        inner.linearGradient(gradient, from: start, to: end, options: options)
    }
    func radialGradient(_ gradient: CGGradient, from start: CGPoint, startRadius: Float,
                        to end: CGPoint, endRadius: Float, options: Int32) {
        inner.radialGradient(gradient, from: start, startRadius: startRadius, to: end, endRadius: endRadius, options: options)
    }

    func draw(image: PortableImage, isGray: Bool, in rect: CGRect, opacity: Float, blendMode: Int32, quality: Int32) {
        // Full-buffer opaque composite: prefer the active Vulkan CompRenderer trampoline
        // (upload → GPU blend → readback) for Normal and the colour modes (Soft Light, Multiply, …).
        if !isGray, format == .rgba, opacity >= 0.999,
           Int(rect.minX.rounded()) == 0, Int(rect.minY.rounded()) == 0,
           Int(rect.width.rounded()) == width, Int(rect.height.rounded()) == height,
           image.width == width, image.height == height, bytesPerRow == width * 4,
           let render = compositor_compat_current_render_fn() {
            var ok = false
            image.bytes.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                ok = render(base, pixels, width, height, blendMode) == 0
            }
            if ok { return }
        }
        inner.draw(image: image, isGray: isGray, in: rect, opacity: opacity, blendMode: blendMode, quality: quality)
    }
}
