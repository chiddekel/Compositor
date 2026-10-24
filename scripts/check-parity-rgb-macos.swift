// Capture RGB Split's edge pixels and sine-based jitter on a native Metal device.
// Run from the checkout: swift scripts/check-parity-rgb-macos.swift "$PWD" > rgb-metal-parity.json
// The production shader is read unchanged from upstream's protected source, not copied into this probe.
#if os(macOS)
import Foundation
import Metal
import CryptoKit

enum ProbeError: Error { case failed(String) }

struct Parameters {
    var center = SIMD2<Float>(30.5, 30.5)
    var direction = SIMD2<Float>(1, 0)
    var distance: Float
    var blur: Float
    var reach: Float = 1
    var radial: UInt32 = 0
    var sides: UInt32 = 0
    var spectral: UInt32
    var smear: UInt32
    var outputOrigin = SIMD2<Float>.zero
    var inputOrigin = SIMD2<Float>.zero
    var rowSign: Float = 1
}

func capture() throws -> [String: Any] {
    let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
    let path = root.appendingPathComponent("Compositor/Rendering/MetalDispersion.swift")
    let file = try String(contentsOf: path, encoding: .utf8)
    guard let start = file.range(of: "private static let source = \"\"\"\n"),
          let end = file.range(of: "\n\"\"\"", range: start.upperBound..<file.endIndex) else {
        throw ProbeError.failed("Cannot locate upstream's Metal shader source")
    }
    let source = String(file[start.upperBound..<end.lowerBound])
    let hashPattern = try NSRegularExpression(pattern: #"float jitter = ([^;]+);"#)
    guard let match = hashPattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
          let expressionRange = Range(match.range(at: 1), in: source) else {
        throw ProbeError.failed("Cannot locate upstream's jitter expression")
    }
    let jitterExpression = String(source[expressionRange])
    // This separate kernel observes the same hash expression. The production disperse kernel stays unchanged.
    let hashSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void hashProbe(device float *values [[buffer(0)]], uint2 pixel [[thread_position_in_grid]]) {
        if (pixel.x >= 61 || pixel.y >= 61) return;
        float jitter = \(jitterExpression);
        values[pixel.y * 61 + pixel.x] = jitter;
    }
    """
    guard MemoryLayout<Parameters>.stride == 72,
          MemoryLayout<Parameters>.offset(of: \.outputOrigin) == 48,
          MemoryLayout<Parameters>.offset(of: \.rowSign) == 64 else {
        throw ProbeError.failed("Probe parameter layout does not match MetalDispersion.Parameters")
    }
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        throw ProbeError.failed("No native Metal device/queue; reference output cannot be captured")
    }
    let library = try device.makeLibrary(source: source, options: nil)
    let hashLibrary = try device.makeLibrary(source: hashSource, options: nil)
    guard let function = library.makeFunction(name: "disperse"),
          let hashFunction = hashLibrary.makeFunction(name: "hashProbe") else {
        throw ProbeError.failed("Cannot compile probe entry points")
    }
    let pipeline = try device.makeComputePipelineState(function: function)
    let hashPipeline = try device.makeComputePipelineState(function: hashFunction)
    let size = 61, rowBytes = size * 4
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for y in 28...32 { for x in 28...32 { for channel in 0..<4 { pixels[(y * size + x) * 4 + channel] = 255 } } }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
        width: size, height: size, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    guard let input = device.makeTexture(descriptor: descriptor),
          let output = device.makeTexture(descriptor: descriptor),
          let hashes = device.makeBuffer(length: size * size * MemoryLayout<Float>.stride, options: .storageModeShared) else {
        throw ProbeError.failed("Cannot allocate Metal probe buffers")
    }
    let region = MTLRegionMake2D(0, 0, size, size)
    input.replace(region: region, mipmapLevel: 0, withBytes: pixels, bytesPerRow: rowBytes)
    func run(_ parameters: Parameters) throws -> [UInt8] {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw ProbeError.failed("Cannot encode production shader")
        }
        var parameters = parameters
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? ProbeError.failed("Production shader failed") }
        var result = pixels
        output.getBytes(&result, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
        return result
    }
    let flat = try run(Parameters(distance: 8, blur: 0, spectral: 8, smear: 1))
    let streaked = try run(Parameters(distance: 4, blur: 16, spectral: 4, smear: 8))
    guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
        throw ProbeError.failed("Cannot encode jitter observer")
    }
    encoder.setComputePipelineState(hashPipeline)
    encoder.setBuffer(hashes, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { throw command.error ?? ProbeError.failed("Jitter observer failed") }
    let jitter = hashes.contents().bindMemory(to: Float.self, capacity: size * size)
    let flatAlpha = (44...48).map { Int(flat[(30 * size + $0) * 4 + 3]) }
    let streakedAlpha = (44...48).map { Int(streaked[(30 * size + $0) * 4 + 3]) }
    let edgePixels: [[String: Any]] = (40...48).map { x in
        ["x": x, "y": 30, "diagnosticJitter": Double(jitter[30 * size + x]),
         "flatRGBA": (0..<4).map { Int(flat[(30 * size + x) * 4 + $0]) },
         "streakedRGBA": (0..<4).map { Int(streaked[(30 * size + x) * 4 + $0]) }]
    }
    return ["device": device.name, "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "shaderSHA256": SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined(),
        "fixture": "61x61 transparent RGBA8, white pixels x/y 28...32, row 30",
        "fixtureSHA256": SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined(),
        "jitterExpression": jitterExpression, "parameterStride": MemoryLayout<Parameters>.stride,
        "flatTailAlpha": flatAlpha, "streakedTailAlpha": streakedAlpha,
        "passesUpstreamTailAssertion": flatAlpha.reduce(0, +) == 0 && streakedAlpha.reduce(0, +) > 0,
        "edgePixels": edgePixels]
}

do {
    let result = try capture()
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("RGB Metal parity capture failed: \(error)\n".utf8))
    exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("RGB Metal parity capture requires macOS and a native Metal device.\n".utf8))
exit(1)
#endif
