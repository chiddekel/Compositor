import Foundation
import CoreGraphics
import CompositorBrushBackend
import Testing
@testable import Compositor

@MainActor
struct VulkanSmudgeTests {
    @Test(arguments: [0, 1, 2])
    func repeatedEdgeDabsMatchCPU(format: Int) throws {
        func context() throws -> CGContext {
            let c = try (format == 0 ? BrushRaster.context(width: 19, height: 13, mask: false)
                : DeepLayer.context(width: 19, height: 13, hdr: format == 2))
            let p = try #require(c.data)
            for y in 0..<13 { for x in 0..<19 { for k in 0..<4 {
                let value = Float((x * 7 + y * 11 + k * 3) % 29) / 29
                let i = y * c.bytesPerRow + (x * 4 + k) * (format == 0 ? 1 : 2)
                if format == 0 { p.storeBytes(of: UInt8((value * 255).rounded()), toByteOffset: i, as: UInt8.self) }
                else if format == 1 { p.storeBytes(of: UInt16((value * 65535).rounded()), toByteOffset: i, as: UInt16.self) }
                else { p.storeBytes(of: Float16(value * 3 - 0.5), toByteOffset: i, as: Float16.self) }
            } } }
            return c
        }
        let actual = try context(), expected = try context()
        let gpu = try #require(MetalWarp(pixels: actual, acceleratedWarp: true))
        let cpu = try #require(MetalWarp(pixels: expected, acceleratedWarp: false))
        // A software Vulkan device is allowed explicitly here; production defaults require hardware.
        if ProcessInfo.processInfo.environment["COMPOSITOR_REQUIRE_WARP_VULKAN"] == "1" {
            #expect(gpu.warpGPUDevice != nil)
        }
        gpu.pickUp(at: CGPoint(x: 5, y: 6), radius: 4)
        cpu.pickUp(at: CGPoint(x: 5, y: 6), radius: 4)
        for point in [CGPoint(x: 10, y: 6), CGPoint(x: 17, y: 12), CGPoint(x: -1, y: 0), CGPoint(x: 6, y: 4)] {
            gpu.smudge(at: point, radius: 4, diameter: 8.5, hardness: 0.25, strength: 0.7)
            cpu.smudge(at: point, radius: 4, diameter: 8.5, hardness: 0.25, strength: 0.7)
            let a = try #require(actual.data), b = try #require(expected.data)
            for y in 0..<13 {
                #expect(Data(bytes: a + y * actual.bytesPerRow, count: 19 * 4 * (format == 0 ? 1 : 2))
                    == Data(bytes: b + y * expected.bytesPerRow, count: 19 * 4 * (format == 0 ? 1 : 2)))
            }
        }
        #expect(cpu.smudgeGPUDispatchCount == 0)
        if gpu.warpGPUDevice != nil {
            #expect(gpu.smudgeGPUDispatchCount == 4)
            print("Smudge Vulkan device: \(gpu.warpGPUDevice!), successful submissions: \(gpu.smudgeGPUDispatchCount)")
        }
    }

    @Test func refusalLeavesOutputUntouched() {
        let context = compositor_vulkan_smudge_create()
        defer { compositor_vulkan_smudge_destroy(context) }
        let under: [Float] = [1, 2, 3, 4], carried: [Float] = [5, 6, 7, 8], weights: [Float] = [1]
        var output: [Float] = [-9, -9, -9, -9]
        for strength in [Float.nan, Float.infinity, -1, 2] {
            let result = under.withUnsafeBufferPointer { u in
                carried.withUnsafeBufferPointer { c in
                    weights.withUnsafeBufferPointer { w in
                        output.withUnsafeMutableBufferPointer { o in
                            compositor_vulkan_smudge_render(context, 1, 1, strength, u.baseAddress, c.baseAddress, w.baseAddress, o.baseAddress)
                        }
                    }
                }
            }
            #expect(result == -1)
            #expect(output == [-9, -9, -9, -9])
        }
    }
}
