// CoreGraphicsCompat — CGContext shim over the Skia render-device bridge.
//
// Plan §3: the largest single leverage in the port is a CoreGraphics-shaped
// compatibility module so the existing Swift renderers and filters keep their
// CGContext call sites without a per-file rewrite. On macOS those calls draw
// into a CGContext (CoreGraphics). On Linux the same calls route through this
// shim into the Skia Raster/Vulkan backends (SkiaBridge C ABI).
//
// The existing portable core already uses CGPoint/CGRect/CGSize/CGFloat/
// CGAffineTransform/CGInterpolationQuality (CompositorGeometry.swift) and
// PortableImage/PixelBuffer/MaskBuffer (CompositorRaster.swift) as the
// CPU-addressable storage. This file adds the CGContext-shaped drawing
// surface that wraps a render device, so the filter/adjustment backends
// (Levels, Curves, HueSaturation, ImageAdjustments) can draw an image into a
// context and read the result back — the operation the macOS code does with
// `CGImage` + `CGContext.draw` + `CGContext.makeImage`.
//
// To keep the SwiftPM host build Skia-free (Skia headers only exist in /app
// inside the Flatpak build), the render device is injected as a Swift
// closure. The C++ side (SkiaBridge.cpp) supplies the closure at link time;
// the Swift core never imports Skia headers.
//
// Scope (Stage 5): source-over draw of one PortableImage into a context's
// backing buffer, at an offset, with opacity. The full CG path/clip/blend
// surface lands as the LayerRenderer parity work needs it.
//
// SOLID: the shim depends only on the portable raster substrate (ISP) and a
// Swift-injected render closure (DIP); it does not import Skia or Qt.

import Foundation

/// Render function injected by the C++ SkiaBridge. Composites `src` over
/// `dst` in place (premultiplied source-over, opacity 1.0), both canonical
/// RGBA8. Returns 0 on success, non-zero on device loss (caller falls back).
///
/// ABI: a C function pointer (Swift closure `@convention(c)`), so the C++
/// side can register one without crossing Swift closure runtime ABI.
public typealias CompRenderFn =
    @convention(c) (UnsafePointer<UInt8>, UnsafeMutablePointer<UInt8>,
                    Int, Int) -> Int32

/// CG-shaped drawing context backed by a render device. Replaces `CGContext`
/// for the Linux filter/adjustment raster backends.
///
/// The backing buffer is a `PixelBuffer` (CPU-addressable, premultiplied
/// RGBA8). A render closure (wrapping a Skia `CompRenderer*`) performs the
/// draw; if the closure is nil or returns non-zero, the draw falls back to
/// the pure-Swift `LayerRenderer.draw` (the ultimate Raster failsafe, plan §6).
public final class CGContextCompat {
    public let width: Int
    public let height: Int
    public private(set) var buffer: PixelBuffer
    private let render: CompRenderFn?

    /// Create a context of the given size, transparent. If a render closure
    /// is supplied (or the host registered one via `compositor_compat_set_render_fn`),
    /// draws route through Skia; otherwise the Swift fallback.
    public init(width: Int, height: Int, render: CompRenderFn? = nil) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.buffer = PixelBuffer(width: width, height: height)
        self.render = render ?? compositor_compat_current_render_fn()
    }

    /// Draw `image` into the context at `rect`, source-over at `opacity`.
    /// Stage 5 scope: identity placement (rect origin == (0,0), rect size ==
    /// image size); transforms/paths land with the LayerRenderer parity work.
    public func draw(_ image: PortableImage, in rect: CGRect, opacity: Double = 1) {
        guard image.kind == .rgba else { return }
        if opacity >= 1, rect.origin == .zero,
           rect.width == CGFloat(image.width),
           rect.height == CGFloat(image.height),
           let render = self.render {
            let rc = image.bytes.withUnsafeBufferPointer { srcPtr in
                buffer.bytes.withUnsafeMutableBufferPointer { dstPtr in
                    render(srcPtr.baseAddress!, dstPtr.baseAddress!,
                           image.width, image.height)
                }
            }
            if rc == 0 { return }
            // Device lost or error: fall back to Swift (plan §6 runtime loss).
        }
        drawSwift(image, in: rect, opacity: opacity)
    }

    private func drawSwift(_ image: PortableImage, in rect: CGRect, opacity: Double) {
        let raster = RasterImage(image)
        let placement = LayerTransform(origin: rect.origin,
                                       size: rect.size, sampling: .smooth)
        LayerRenderer.draw(raster, transform: placement,
            center: CGPoint(x: rect.midX, y: rect.midY),
            opacity: opacity, into: &buffer)
    }

    /// Read back the context's pixels as an immutable image (CGContext
    /// `makeImage` equivalent).
    public func makeImage() -> PortableImage { PortableImage(buffer) }
}