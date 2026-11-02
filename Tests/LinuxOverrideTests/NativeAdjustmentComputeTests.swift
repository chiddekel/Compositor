import Foundation
import Compression
import Metal
import Testing
@testable import Compositor

@MainActor
struct NativeAdjustmentComputeTests {
    private struct Buffer: Decodable {
        let width: Int, height: Int, bits: Int
        let rgbaBase64: Data
    }
    private struct Sample: Decodable {
        let fixture: String
        let radius: Float, ring: Float
        let shape: UInt32
        let regionOrigin: [Float], regionSize: [Float], inputTop: [Float], outputTop: [Float]
        let output: Buffer
    }
    private struct Reference: Decodable {
        let upstreamCommit: String
        let bokehInputs: [String: Buffer]
        let bokehCases: [Sample]
    }

    @Test func apertureGatherMatchesAllNativeMetalOutputs() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/metal/adjustment-compute-reference.json.gz")
        let gzip = try Data(contentsOf: url)
        #expect(Array(gzip.prefix(4)) == [0x1f, 0x8b, 8, 0])
        let count = gzip.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: gzip.count - 4, as: UInt32.self).littleEndian) }
        var json = [UInt8](repeating: 0, count: count)
        let payload = gzip.dropFirst(10).dropLast(8)
        let decoded = payload.withUnsafeBytes {
            compression_decode_buffer(&json, count, $0.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
        }
        #expect(decoded == count)
        let reference = try JSONDecoder().decode(Reference.self, from: Data(json))
        #expect(reference.upstreamCommit == "7651033e0abab135db40e9375a639fae55c313ff")
        #expect(reference.bokehCases.count == 96)
        let gpu = try #require(MetalBokeh.shared)
        func texture(_ buffer: Buffer) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: buffer.width, height: buffer.height, mipmapped: false)
            let texture = MTLTexture(descriptor: descriptor)
            texture.rgbaBytes = Array(buffer.rgbaBase64)
            return texture
        }
        for sample in reference.bokehCases {
            let source = try #require(reference.bokehInputs[sample.fixture])
            let output = texture(sample.output)
            output.rgbaBytes = [UInt8](repeating: 0, count: output.width * output.height * 8)
            var p = MetalBokeh.Parameters(radius: sample.radius, shape: sample.shape, ring: sample.ring)
            p.regionOrigin = SIMD2(sample.regionOrigin[0], sample.regionOrigin[1])
            p.regionSize = SIMD2(sample.regionSize[0], sample.regionSize[1])
            p.outputTop = SIMD2(sample.outputTop[0], sample.outputTop[1])
            p.inputTop = SIMD2(sample.inputTop[0], sample.inputTop[1])
            let command = MTLCommandBuffer()
            let encoder = try #require(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(gpu.pipeline)
            encoder.setTexture(texture(source), index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&p, length: MemoryLayout<MetalBokeh.Parameters>.stride, index: 0)
            encoder.endEncoding()
            command.commit()
            #expect(command.status == .completed)
            let expected = sample.output.rgbaBase64
            let worst = output.rgbaBytes.withUnsafeBytes { actual in
                expected.withUnsafeBytes { expected in
                    (0..<(output.width * output.height * 4)).reduce(Float(0)) { worst, i in
                        let a = Float(Float16(bitPattern: actual.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                        let b = Float(Float16(bitPattern: expected.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                        return max(worst, abs(a - b))
                    }
                }
            }
            #expect(worst <= 0.002, "Native Bokeh \(sample.fixture), shape \(sample.shape), radius \(sample.radius), ring \(sample.ring), origin \(sample.outputTop): \(worst)")
        }
    }
}
