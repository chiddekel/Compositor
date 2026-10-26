// Independent execution of upstream RGB Split; no Linux renderer is linked.
#if os(macOS)
import Foundation
import Metal
import CryptoKit

enum CaptureError: Error { case failed(String) }
let width = 96, height = 72
func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func packed(_ data: Data) -> [String: Any] {
    ["base64": data.base64EncodedString(), "sha256": digest(data)]
}
struct Parameters {
    var center = SIMD2<Float>(48, 36)
    var direction: SIMD2<Float>
    var distance: Float
    var blur: Float = 0
    var reach: Float = 1000
    var radial: UInt32 = 0
    var sides: UInt32 = 0
    var spectral: UInt32
    var smear: UInt32 = 1
    var outputOrigin = SIMD2<Float>(0, 72)
    var inputOrigin = SIMD2<Float>(0, 72)
    var rowSign: Float = -1
}
func capture() throws -> [String: Any] {
    guard MemoryLayout<Parameters>.stride == 72,
          MemoryLayout<Parameters>.offset(of: \.outputOrigin) == 48,
          MemoryLayout<Parameters>.offset(of: \.rowSign) == 64,
          let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        throw CaptureError.failed("Native Metal device and unchanged parameter ABI required")
    }
    let path = URL(fileURLWithPath: "Compositor/Rendering/MetalDispersion.swift")
    let file = try String(contentsOf: path, encoding: .utf8)
    guard let start = file.range(of: "private static let source = \"\"\"\n"),
          let end = file.range(of: "\n\"\"\"", range: start.upperBound..<file.endIndex) else {
        throw CaptureError.failed("Cannot locate upstream shader")
    }
    let source = String(file[start.upperBound..<end.lowerBound])
    let observer = """
    kernel void observer(device float4 *output [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= 96 || gid.y >= 72) return;
        float phase = dot(float2(gid), float2(12.9898, 78.233));
        float sine = sin(phase), noise = sine * 43758.5453;
        output[gid.y * 96 + gid.x] = float4(phase, sine, noise, fract(noise));
    }
    """
    let library = try device.makeLibrary(source: source + "\n" + observer, options: nil)
    guard let entry = library.makeFunction(name: "disperse"),
          let observe = library.makeFunction(name: "observer") else {
        throw CaptureError.failed("Missing native entry point")
    }
    let pipeline = try device.makeComputePipelineState(function: entry)
    let observerPipeline = try device.makeComputePipelineState(function: observe)
    func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
        guard let t = device.makeTexture(descriptor: d) else { throw CaptureError.failed("Cannot allocate texture") }
        return t
    }
    let region = MTLRegionMake2D(0, 0, width, height)
    func dispatch(_ input: MTLTexture, _ output: MTLTexture, _ parameters: Parameters) throws -> Data {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw CaptureError.failed("Cannot encode shader")
        }
        var parameters = parameters
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0); encoder.setTexture(output, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? CaptureError.failed("Native shader failed") }
        let size = output.pixelFormat == .rgba8Unorm ? 1 : 4
        var bytes = Data(count: width * height * 4 * size)
        bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 4 * size, from: region, mipmapLevel: 0) }
        return bytes
    }
    guard let buffer = device.makeBuffer(length: width * height * 16, options: .storageModeShared),
          let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
        throw CaptureError.failed("Cannot observe native hash")
    }
    encoder.setComputePipelineState(observerPipeline); encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw CaptureError.failed("Native hash observation failed") }
    let outputFloat = try texture(.rgba32Float), outputByte = try texture(.rgba8Unorm)
    var inputs = [[String: Any]](), cases = [[String: Any]]()
    for fixture in ["opaque", "overlay"] {
        var pixels = [UInt8]()
        for y in 0..<height { for x in 0..<width {
            let a = fixture == "opaque" ? 255 : (x < 12 || y < 12 || x > 80 || y > 58 ? 0 : 160)
            pixels += [UInt8((x * 255 / (width - 1)) * a / 255), UInt8((y * 255 / (height - 1)) * a / 255),
                UInt8((fixture == "opaque" ? 100 : 220) * a / 255), UInt8(a)]
        } }
        let floats = pixels.map { Float($0) / 255 }
        for storage in ["RGBA8", "RGBAh-RNE", "RGBAh-RTZ", "RGBAf"] {
            let format: MTLPixelFormat = storage == "RGBA8" ? .rgba8Unorm : storage == "RGBAf" ? .rgba32Float : .rgba16Float
            let input = try texture(format)
            let bytes: Data
            if storage == "RGBA8" { bytes = Data(pixels) }
            else if storage == "RGBAf" { bytes = floats.withUnsafeBytes { Data($0) } }
            else {
                let half = floats.map { value -> UInt16 in
                    var h = Float16(value)
                    if storage == "RGBAh-RTZ" && Float(h) > value { h = Float16(bitPattern: h.bitPattern - 1) }
                    return h.bitPattern
                }
                bytes = half.withUnsafeBytes { Data($0) }
            }
            bytes.withUnsafeBytes { input.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!,
                bytesPerRow: width * 4 * (storage == "RGBA8" ? 1 : storage == "RGBAf" ? 4 : 2)) }
            inputs.append(["fixture": fixture, "storage": storage, "data": packed(bytes)])
            for angle in [0, 35] {
                let radians = Double(angle) * .pi / 180
                let parameters = Parameters(direction: SIMD2(Float(cos(radians)), Float(sin(radians))),
                    distance: angle == 0 ? 10 : 35, spectral: angle == 0 ? 10 : 32)
                cases.append(["fixture": fixture, "storage": storage, "angle": angle,
                    "parameters": packed(withUnsafeBytes(of: parameters) { Data($0) }),
                    "float": packed(try dispatch(input, outputFloat, parameters)),
                    "byte": packed(try dispatch(input, outputByte, parameters))])
            }
        }
    }
    return ["schema": 1, "platform": "macOS", "device": device.name,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "width": width, "height": height, "parameterStride": MemoryLayout<Parameters>.stride,
        "scriptSHA256": digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))),
        "shaderSHA256": digest(Data(source.utf8)), "inputs": inputs, "cases": cases,
        "arithmetic": packed(Data(bytes: buffer.contents(), count: width * height * 16))]
}
do {
    let result = try capture()
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Native RGB sampling capture failed: \(error)\n".utf8)); exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("Native Metal on macOS required.\n".utf8)); exit(1)
#endif
