import Foundation
import CompositorBrushBackend
import Testing

struct VulkanWarpPackingTests {
    @Test(arguments: [0, 1, 2])
    func packingMatchesNativeRoundingAtTies(format: Int) throws {
        let backend = compositor_vulkan_smudge_create()
        defer { compositor_vulkan_smudge_destroy(backend) }
        guard let backend else {
            #expect(ProcessInfo.processInfo.environment["COMPOSITOR_REQUIRE_WARP_VULKAN"] != "1")
            return
        }
        let weights: [Float] = [1]
        #expect(weights.withUnsafeBufferPointer { compositor_vulkan_warp_weights(backend, 0, $0.baseAddress, 1) } == 0)
        var u = CompositorSmudgePackedUniforms()
        u.width = 1; u.height = 1; u.canvas_width = 1; u.canvas_height = 1
        u.strength = 1; u.format = UInt32(format)
        let values: [Float] = [0.49999997, 0.5, 127.49999, 127.5, 254.5, 255.5,
            32767.5, 65534.5, 65535.5, -0.5, 1.00048828125, 1.00146484375,
            -1.00048828125, Float(1.0 / 33554432.0), Float(1.0 / 33554432.0).nextUp,
            Float.leastNonzeroMagnitude, 65504, 65520, .infinity, -.infinity]
        for value in values {
            let bpp = format == 0 ? 4 : 8
            let under = [UInt8](repeating: 0, count: bpp)
            var carried = [Float](repeating: value, count: 4)
            var packed = [UInt8](repeating: 0xcc, count: bpp)
            let status = under.withUnsafeBytes { raw in
                carried.withUnsafeMutableBufferPointer { c in
                    packed.withUnsafeMutableBytes { out in
                        compositor_vulkan_smudge_packed(backend, &u, raw.baseAddress, c.baseAddress, c.baseAddress, out.baseAddress)
                    }
                }
            }
            #expect(status == 0)
            var expected = [UInt8](repeating: 0, count: bpp)
            expected.withUnsafeMutableBytes { raw in
                for k in 0..<4 {
                    if format == 0 {
                        raw.storeBytes(of: UInt8(max(0, min(255, value.rounded()))), toByteOffset: k, as: UInt8.self)
                    } else if format == 1 {
                        raw.storeBytes(of: UInt16(max(0, min(65535, value.rounded()))), toByteOffset: k * 2, as: UInt16.self)
                    } else {
                        raw.storeBytes(of: Float16(value), toByteOffset: k * 2, as: Float16.self)
                    }
                }
            }
            #expect(packed == expected, "format \(format), value \(value)")
            #expect(carried == [Float](repeating: value, count: 4))
        }
    }

    @Test func invalidPackedFormatPreservesBothOutputs() {
        let backend = compositor_vulkan_smudge_create()
        defer { compositor_vulkan_smudge_destroy(backend) }
        var u = CompositorSmudgePackedUniforms()
        u.width = 1; u.height = 1; u.canvas_width = 1; u.canvas_height = 1
        u.strength = 1; u.format = 3
        let under = [UInt8](repeating: 0, count: 4)
        var carried: [Float] = [3, 4, 5, 6], packed = [UInt8](repeating: 0xcc, count: 4)
        let status = under.withUnsafeBytes { raw in
            carried.withUnsafeMutableBufferPointer { c in
                packed.withUnsafeMutableBytes { out in
                    compositor_vulkan_smudge_packed(backend, &u, raw.baseAddress, c.baseAddress, c.baseAddress, out.baseAddress)
                }
            }
        }
        #expect(status == -1)
        #expect(carried == [3, 4, 5, 6])
        #expect(packed == [UInt8](repeating: 0xcc, count: 4))
    }
}
