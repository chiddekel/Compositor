import Foundation
import Dispatch
import CoreGraphics
import CompositorBrushBackend
import Testing
@testable import Compositor

@MainActor
struct VulkanLiquifyTests {
    @Test(arguments: [0, 1, 2], [CGSize(width: 19, height: 13), CGSize(width: 1, height: 13), CGSize(width: 19, height: 1)])
    func repeatedDabsKeepOriginalAndMatchCPU(format: Int, size: CGSize) throws {
        let width = Int(size.width), height = Int(size.height)
        let actual = try context(width: width, height: height, format: format)
        let expected = try context(width: width, height: height, format: format)
        let gpu = try #require(MetalWarp(pixels: actual, acceleratedWarp: true))
        let cpu = try #require(MetalWarp(pixels: expected, acceleratedWarp: false))
        if ProcessInfo.processInfo.environment["COMPOSITOR_REQUIRE_WARP_VULKAN"] == "1" {
            #expect(gpu.warpGPUDevice != nil)
        }
        if ProcessInfo.processInfo.environment["COMPOSITOR_REQUIRE_WARP_HARDWARE"] == "1" {
            #expect(gpu.warpGPUDeviceType == 1 || gpu.warpGPUDeviceType == 2)
        }
        var previous = CGPoint(x: 5, y: 6)
        for point in [CGPoint(x: 10, y: 6), CGPoint(x: 17, y: 12), CGPoint(x: -1, y: 0), CGPoint(x: 6, y: 4)] {
            gpu.push(from: previous, to: point, radius: 4, diameter: 8.5, hardness: 0.25, strength: 0.7)
            cpu.push(from: previous, to: point, radius: 4, diameter: 8.5, hardness: 0.25, strength: 0.7)
            previous = point
            let a = try #require(actual.data), b = try #require(expected.data)
            for y in 0..<height {
                #expect(Data(bytes: a + y * actual.bytesPerRow, count: width * 4 * (format == 0 ? 1 : 2))
                    == Data(bytes: b + y * expected.bytesPerRow, count: width * 4 * (format == 0 ? 1 : 2)))
            }
        }
        #expect(cpu.liquifyGPUDispatchCount == 0)
        if width > 1 && height > 1 && gpu.warpGPUDevice != nil {
            #expect(gpu.liquifyGPUDispatchCount == 4)
            print("Liquify Vulkan device: \(gpu.warpGPUDevice!), successful submissions: \(gpu.liquifyGPUDispatchCount)")
        } else { #expect(gpu.liquifyGPUDispatchCount == 0) }
    }

    @Test func sourceFailurePreservesBothOutputs() throws {
        let c = compositor_vulkan_smudge_create()
        defer { compositor_vulkan_smudge_destroy(c) }
        let rgba = [Float](repeating: 1, count: 16)
        // Guaranteed to exceed Vulkan's uint32 storage range, before reading the small input.
        let status = rgba.withUnsafeBufferPointer {
            compositor_vulkan_liquify_original(c, 65536, 65536, $0.baseAddress)
        }
        #expect(status == -2)
        var parameters = CompositorLiquifyUniforms()
        parameters.source_width = 2; parameters.source_height = 2
        parameters.width = 2; parameters.height = 2
        let prior = [Float](repeating: 0, count: 8), weights = [Float](repeating: 1, count: 4)
        var offsets = [Float](repeating: -9, count: 8), pixels = [Float](repeating: -9, count: 16)
        let result = prior.withUnsafeBufferPointer { p in
            weights.withUnsafeBufferPointer { w in
                offsets.withUnsafeMutableBufferPointer { o in
                    pixels.withUnsafeMutableBufferPointer { colors in
                        compositor_vulkan_liquify_render(c, &parameters, p.baseAddress, w.baseAddress, o.baseAddress, colors.baseAddress)
                    }
                }
            }
        }
        #expect(result == -2)
        #expect(offsets == [Float](repeating: -9, count: 8))
        #expect(pixels == [Float](repeating: -9, count: 16))
    }

    @Test(arguments: [0, 1, 2])
    func failedBackendResumesOnCPUAfterSuccessfulDab(format: Int) throws {
        let actual = try context(width: 32, height: 24, format: format)
        let expected = try context(width: 32, height: 24, format: format)
        let gpu = try #require(MetalWarp(pixels: actual, acceleratedWarp: true))
        let cpu = try #require(MetalWarp(pixels: expected, acceleratedWarp: false))
        let first = CGPoint(x: 8, y: 8), second = CGPoint(x: 14, y: 9)
        for warp in [gpu, cpu] {
            warp.push(from: first, to: second, radius: 4, diameter: 8.5, hardness: 0.25, strength: 0.7)
        }
        if ProcessInfo.processInfo.environment["COMPOSITOR_REQUIRE_WARP_VULKAN"] == "1" {
            #expect(gpu.warpGPUBackend != nil)
        }
        let initialSubmissions = gpu.warpGPUBackend == nil ? 0 : 1
        #expect(gpu.liquifyGPUDispatchCount == initialSubmissions)
        if let backend = gpu.warpGPUBackend {
            let tinySource: [Float] = [1, 1, 1, 1]
            let failure = tinySource.withUnsafeBufferPointer {
                compositor_vulkan_liquify_original(backend, 65536, 65536, $0.baseAddress)
            }
            #expect(failure == -2)
        }
        var previous = second
        for point in [CGPoint(x: 20, y: 15), CGPoint(x: 7, y: 6)] {
            for warp in [gpu, cpu] {
                warp.push(from: previous, to: point, radius: 4, diameter: 8.5, hardness: 0.25, strength: 0.7)
            }
            previous = point
        }
        for warp in [gpu, cpu] {
            warp.pickUp(at: first, radius: 4)
            warp.smudge(at: second, radius: 4, diameter: 8.5, hardness: 0.25, strength: 0.7)
        }
        #expect(gpu.liquifyGPUDispatchCount == initialSubmissions)
        #expect(gpu.smudgeGPUDispatchCount == 0)
        try expectEqualPixels(actual, expected, format: format)
    }

    @Test(arguments: [BlurToolMode.liquify, .smudge], [64, 128, 256])
    func largeRepeatedDabsMatchCPUAndRecordTimings(mode: BlurToolMode, radius: Int) throws {
        let width = max(384, radius * 4), height = max(256, radius * 3)
        let actual = try context(width: width, height: height, format: 0)
        let expected = try context(width: width, height: height, format: 0)
        let gpu = try #require(MetalWarp(pixels: actual, acceleratedWarp: true))
        let cpu = try #require(MetalWarp(pixels: expected, acceleratedWarp: false))
        let start = CGPoint(x: width / 2 - 12, y: height / 2 - 8)
        for warp in [gpu, cpu] { warp.pickUp(at: start, radius: radius) }
        var previous = start
        var gpuTime: UInt64 = 0, cpuTime: UInt64 = 0
        for step in 0..<18 {
            let point = CGPoint(x: Int(start.x) + 2 + step * 2, y: Int(start.y) + step % 3)
            func dab(_ warp: MetalWarp) {
                if mode == .smudge {
                    warp.smudge(at: point, radius: radius, diameter: CGFloat(radius * 2), hardness: 0.5, strength: 0.7)
                } else {
                    warp.push(from: previous, to: point, radius: radius, diameter: CGFloat(radius * 2), hardness: 0.5, strength: 0.7)
                }
            }
            let g0 = DispatchTime.now().uptimeNanoseconds
            dab(gpu)
            let g1 = DispatchTime.now().uptimeNanoseconds
            dab(cpu)
            let c1 = DispatchTime.now().uptimeNanoseconds
            if step >= 2 { gpuTime += g1 - g0; cpuTime += c1 - g1 }
            previous = point
        }
        try expectEqualPixels(actual, expected, format: 0)
        let submissions = mode == .smudge ? gpu.smudgeGPUDispatchCount : gpu.liquifyGPUDispatchCount
        if ProcessInfo.processInfo.environment["COMPOSITOR_REQUIRE_WARP_VULKAN"] == "1" { #expect(submissions == 18) }
        let cached = compositor_vulkan_warp_cached_buffers(gpu.warpGPUBackend)
        print("Warp \(mode), radius \(radius), \(gpu.warpGPUDevice ?? "CPU fallback"), submissions \(submissions), cached bindings \(cached), steady dab mean: GPU \(Double(gpuTime) / 16e6) ms, CPU \(Double(cpuTime) / 16e6) ms")
    }

    private func context(width: Int, height: Int, format: Int) throws -> CGContext {
        let c = try (format == 0 ? BrushRaster.context(width: width, height: height, mask: false)
            : DeepLayer.context(width: width, height: height, hdr: format == 2))
        let p = try #require(c.data)
        for y in 0..<height { for x in 0..<width { for k in 0..<4 {
            let value = Float((x * 7 + y * 11 + k * 3) % 29) / 29
            let i = y * c.bytesPerRow + (x * 4 + k) * (format == 0 ? 1 : 2)
            if format == 0 { p.storeBytes(of: UInt8((value * 255).rounded()), toByteOffset: i, as: UInt8.self) }
            else if format == 1 { p.storeBytes(of: UInt16((value * 65535).rounded()), toByteOffset: i, as: UInt16.self) }
            else { p.storeBytes(of: Float16(value * 3 - 0.5), toByteOffset: i, as: Float16.self) }
        } } }
        return c
    }

    private func expectEqualPixels(_ actual: CGContext, _ expected: CGContext, format: Int) throws {
        let a = try #require(actual.data), b = try #require(expected.data)
        for y in 0..<actual.height {
            #expect(Data(bytes: a + y * actual.bytesPerRow, count: actual.width * 4 * (format == 0 ? 1 : 2))
                == Data(bytes: b + y * expected.bytesPerRow, count: expected.width * 4 * (format == 0 ? 1 : 2)))
        }
    }
}
