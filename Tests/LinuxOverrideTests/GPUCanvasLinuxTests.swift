import Foundation
import CoreGraphics
import CoreImage
import AppKit
import Testing
@testable import Compositor

/// Metal → Vulkan GPU canvas smoke: `GPUCanvasRenderer.shared` and `MetalWarp` when Vulkan/FORCE is set.
@MainActor struct GPUCanvasLinuxTests {
    @Test func sharedIsAvailableWhenForcedOrVulkan() {
        // COMPOSITOR_FORCE_GPU_CANVAS=1 or a loaded Skia bridge with Vulkan makes shared non-nil.
        #expect(GPUCanvasRenderer.shared != nil || ProcessInfo.processInfo.environment["COMPOSITOR_CPU_CANVAS"] == "1")
    }

    @Test func metalWarpInitsWhenGPUCanvasIsPresent() throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let context = try BrushRaster.context(width: 32, height: 32, mask: false)
        let warp = MetalWarp(pixels: context)
        #expect(warp != nil)
        warp?.pickUp(at: CGPoint(x: 16, y: 16), radius: 4)
        warp?.smudge(at: CGPoint(x: 16, y: 16), radius: 4, diameter: 8, hardness: 0.5, strength: 0.7)
        #expect(warp?.image != nil)
    }

    @Test func presentWritesIntoCurrentGraphicsContext() throws {
        guard let renderer = GPUCanvasRenderer.shared else { return }
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 8, height: 8)
        layer.contentsScale = 1
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let frame = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        renderer.present(frame, in: layer)
        #expect(layer.lastPresented != nil)
        // Look parity: solid red must land in the CG context Qt/canvas read (same sRGB channel order as Mac).
        guard let data = context.data else { return }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * 8)
        #expect(bytes[0] > 200) // R
        #expect(bytes[1] < 30)  // G
        #expect(bytes[2] < 30)  // B
    }
}
