// Direct Metal controls isolate texture storage, sampler result type and interpolation.
#if os(macOS)
import Foundation
import Metal
import CryptoKit

enum SamplingError: Error { case failed(String) }
let width = 24, height = 16
let offsets: [[Float]] = [[0, 0], [1 / 256, 1 / 256], [3 / 256, 3 / 256],
    [24 / 256, 24 / 256], [54 / 256, 54 / 256], [-54 / 256, -54 / 256],
    [0.409254816, 0], [1.409254816, 0], [0, 1.409254816], [3.29831846, 0]]
func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func packed(_ data: Data) -> [String: Any] {
    ["base64": data.base64EncodedString(), "sha256": digest(data)]
}

func capture() throws -> [String: Any] {
    guard CommandLine.arguments.count == 2 else { throw SamplingError.failed("Expected native reference path") }
    let referenceData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let reference = try JSONSerialization.jsonObject(with: referenceData) as! [String: Any]
    let controls = reference["inputs"] as! [[String: Any]]
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        throw SamplingError.failed("Native Metal device required")
    }
    let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Parameters { float2 offset; uint clamped; uint averaged; };
    #define SAMPLER_KERNEL(NAME, TYPE) \
    kernel void NAME(texture2d<TYPE, access::sample> source [[texture(0)]], \
        texture2d<float, access::write> output [[texture(1)]], \
        constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) { \
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return; \
        constexpr sampler zero(coord::pixel, address::clamp_to_zero, filter::linear); \
        constexpr sampler edge(coord::pixel, address::clamp_to_edge, filter::linear); \
        float2 center = float2(gid) + 0.5f; \
        float4 value = 0; \
        if (p.averaged) { \
            for (int y = -1; y <= 1; y += 2) for (int x = -1; x <= 1; x += 2) { \
                float2 location = center + p.offset * float2(x, y); \
                value += float4(p.clamped ? source.sample(edge, location) : source.sample(zero, location)) * 0.25f; \
            } \
        } else { \
            float2 location = center + p.offset; \
            value = float4(p.clamped ? source.sample(edge, location) : source.sample(zero, location)); \
        } \
        output.write(value, gid); \
    }
    SAMPLER_KERNEL(sampleFloat, float)
    SAMPLER_KERNEL(sampleHalf, half)
    """
    let library = try device.makeLibrary(source: shader, options: nil)
    var pipelines: [String: MTLComputePipelineState] = [:]
    for name in ["sampleFloat", "sampleHalf"] {
        guard let function = library.makeFunction(name: name) else { throw SamplingError.failed("Missing kernel") }
        pipelines[name] = try device.makeComputePipelineState(function: function)
    }
    struct Parameters {
        var offset: SIMD2<Float>
        var clamped: UInt32
        var averaged: UInt32
    }
    func dispatch(_ source: MTLTexture, _ output: MTLTexture, _ pipeline: MTLComputePipelineState,
                  offset: [Float], clamped: Bool, averaged: Bool = false) throws {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw SamplingError.failed("Cannot encode sampling")
        }
        var parameters = Parameters(offset: SIMD2(offset[0], offset[1]), clamped: clamped ? 1 : 0,
            averaged: averaged ? 1 : 0)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0); encoder.setTexture(output, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw SamplingError.failed("Sampling command failed: \(String(describing: command.error))") }
    }
    func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let result = device.makeTexture(descriptor: descriptor) else {
            throw SamplingError.failed("Cannot allocate texture")
        }
        return result
    }
    let output = try texture(.rgba32Float)
    let region = MTLRegionMake2D(0, 0, width, height)
    var inputs = [[String: Any]](), cases = [[String: Any]]()
    for fixture in ["opaque-gradient", "float-hdr", "impulse"] {
        let control = controls.first { ($0["fixture"] as? String) == fixture && ($0["workingFormat"] as? String) == "RGBAf" }!
        let snapshot = control["output"] as! [String: Any]
        let floats = Data(base64Encoded: snapshot["floatBase64"] as! String)!
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for (storage, format, bytesPerPixel) in [("RGBA8", MTLPixelFormat.rgba8Unorm, 4),
            ("RGBAh", .rgba16Float, 8), ("RGBAf", .rgba32Float, 16), ("RGBAhGPU", .rgba16Float, 8)] {
            let source = try texture(format)
            let data: Data
            switch storage {
            case "RGBA8": data = Data(floats.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
            case "RGBAh": data = floats.map(Float16.init).withUnsafeBytes { Data($0) }
            case "RGBAhGPU":
                let original = try texture(.rgba32Float)
                floats.withUnsafeBytes { original.replace(region: region, mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
                try dispatch(original, source, pipelines["sampleFloat"]!, offset: [0, 0], clamped: false)
                var stored = [UInt16](repeating: 0, count: width * height * 4)
                stored.withUnsafeMutableBytes { source.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                    from: region, mipmapLevel: 0) }
                data = stored.withUnsafeBytes { Data($0) }
            default: data = floats.withUnsafeBytes { Data($0) }
            }
            if storage != "RGBAhGPU" {
                data.withUnsafeBytes { source.replace(region: region, mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: width * bytesPerPixel) }
            }
            inputs.append(["fixture": fixture, "storage": storage, "pixels": packed(data)])
            for resultType in ["float", "half"] {
                let pipeline = pipelines[resultType == "float" ? "sampleFloat" : "sampleHalf"]!
                for operation in ["sample", "compact"] {
                    let chosenOffsets = operation == "sample" ? offsets : Array(offsets[1...4])
                    for clamped in [false, true] { for offset in chosenOffsets {
                    try dispatch(source, output, pipeline, offset: offset, clamped: clamped, averaged: operation == "compact")
                    var values = [Float](repeating: 0, count: width * height * 4)
                    values.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 16,
                        from: region, mipmapLevel: 0) }
                    guard values.allSatisfy(\.isFinite) else { throw SamplingError.failed("Nonfinite sample") }
                    cases.append(["fixture": fixture, "storage": storage, "resultType": resultType, "operation": operation,
                        "clamped": clamped, "offset": offset,
                        "output": packed(values.withUnsafeBytes { Data($0) })])
                } } }
            }
        }
    }
    return ["schema": 1, "platform": "macOS", "device": device.name,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "scriptSHA256": digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))),
        "sourceReferenceSHA256": digest(referenceData), "width": width, "height": height,
        "offsets": offsets, "inputs": inputs, "cases": cases]
}
do {
    let data = try JSONSerialization.data(withJSONObject: capture(), options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("Native Metal sampling capture failed: \(error)\n".utf8)); exit(1)
}
#else
fatalError("Metal sampling capture requires macOS")
#endif
