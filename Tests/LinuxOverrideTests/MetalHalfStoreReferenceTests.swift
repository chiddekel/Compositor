import Foundation
import Metal
import Testing
@testable import Compositor

struct MetalHalfStoreReferenceTests {
    private struct Reference: Decodable {
        struct Sample: Decodable {
            let fixture: String
            let float32Base64: Data
            let nativeHalfBase64: Data
        }
        let schema: Int, nativeRun: Int, width: Int, height: Int
        let components: Int, nearestHalfMismatches: Int
        let platform: String
        let cases: [Sample]
    }

    @Test func dispersionStoresNativeHalfTextureBits() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/metal/half-texture-store-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        #expect(reference.schema == 1 && reference.platform == "macOS")
        #expect(reference.nativeRun == 40318276957 && reference.components == 4608)
        #expect(reference.nearestHalfMismatches == 510 && reference.cases.count == 3)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let gpu = try #require(MetalDispersion.shared)
        let width = reference.width, height = reference.height
        var components = 0, nearestMismatches = 0
        for sample in reference.cases {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            let source = try #require(device.makeTexture(descriptor: descriptor))
            descriptor.pixelFormat = .rgba16Float
            let output = try #require(device.makeTexture(descriptor: descriptor))
            let region = MTLRegionMake2D(0, 0, width, height)
            #expect(sample.float32Base64.count == width * height * 16)
            #expect(sample.nativeHalfBase64.count == width * height * 8)
            sample.float32Base64.withUnsafeBytes {
                source.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16)
            }
            let command = try #require(queue.makeCommandBuffer())
            let encoder = try #require(command.makeComputeCommandEncoder())
            // A zero-length, single-tap smear copies Float32 texels through the
            // real upstream entry point; the native reference isolates texture storage.
            let parameters = MetalDispersion.Parameters(center: .zero, direction: SIMD2(1, 0),
                distance: 0, blur: 0, reach: 1, radial: 0, sides: 15, spectral: 1, smear: 1)
            gpu.encode(source, into: output, parameters, pass: "smear", with: encoder)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var actual = [UInt16](repeating: 0, count: width * height * 4)
            actual.withUnsafeMutableBytes {
                output.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: region, mipmapLevel: 0)
            }
            let expected = sample.nativeHalfBase64.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            let original = sample.float32Base64.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let mismatches = zip(actual, expected).filter { $0 != $1 }.count
            #expect(mismatches == 0, "Native \(sample.fixture): \(mismatches) half bits differ")
            nearestMismatches += zip(original, expected).filter { Float16($0).bitPattern != $1 }.count
            components += expected.count
        }
        #expect(components == reference.components)
        #expect(nearestMismatches == reference.nearestHalfMismatches)
    }
}
