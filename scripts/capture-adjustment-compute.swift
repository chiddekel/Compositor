// Independent native outputs from the unchanged upstream Bokeh and dispersion Metal shaders.
#if os(macOS)
import Foundation
import Metal
import CryptoKit

enum CaptureError: Error { case invalid(String) }
struct BokehParameters {
    var radius: Float
    var shape: UInt32
    var ring: Float
    var regionOrigin = SIMD2<Float>.zero
    var regionSize = SIMD2<Float>(96, 72)
    var outputTop = SIMD2<Float>(0, 72)
    var inputTop = SIMD2<Float>(-36, 108)
}
struct DispersionParameters {
    var center = SIMD2<Float>(30.5, 30.5)
    var direction = SIMD2<Float>(1, 0)
    var distance: Float
    var blur: Float = 16
    var reach: Float = 30.5
    var radial: UInt32
    var sides: UInt32 = 0
    var spectral: UInt32 = 8
    var smear: UInt32 = 8
    var outputOrigin = SIMD2<Float>.zero
    var inputOrigin = SIMD2<Float>.zero
    var rowSign: Float = 1
}
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func shader(_ root: URL, _ name: String) throws -> String {
    let text = try String(contentsOf: root.appendingPathComponent("Compositor/Rendering/\(name).swift"), encoding: .utf8)
    guard let start = text.range(of: "private static let source = \"\"\"\n"),
          let end = text.range(of: "\n\"\"\"", range: start.upperBound..<text.endIndex) else {
        throw CaptureError.invalid("Missing original shader in \(name)")
    }
    return String(text[start.upperBound..<end.lowerBound])
}
func buffer(_ texture: MTLTexture, bits: Int) -> [String: Any] {
    let rowBytes = texture.width * 4 * bits / 8
    var data = Data(count: rowBytes * texture.height)
    data.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: rowBytes,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    }
    return ["width": texture.width, "height": texture.height, "bits": bits,
            "rgbaBase64": data.base64EncodedString(), "sha256": hash(data)]
}
func capture() throws -> [String: Any] {
    guard CommandLine.arguments.count == 3 else { throw CaptureError.invalid("Expected source directory and upstream commit") }
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let bokeh = try shader(root, "MetalBokeh"), dispersion = try shader(root, "MetalDispersion")
    guard MemoryLayout<BokehParameters>.stride == 48,
          MemoryLayout<BokehParameters>.offset(of: \.regionOrigin) == 16,
          MemoryLayout<BokehParameters>.offset(of: \.inputTop) == 40,
          MemoryLayout<DispersionParameters>.stride == 72,
          MemoryLayout<DispersionParameters>.offset(of: \.outputOrigin) == 48,
          MemoryLayout<DispersionParameters>.offset(of: \.rowSign) == 64,
          let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        throw CaptureError.invalid("Native Metal device or ABI unavailable")
    }
    let bokehLibrary = try device.makeLibrary(source: bokeh, options: nil)
    let dispersionLibrary = try device.makeLibrary(source: dispersion, options: nil)
    func pipeline(_ library: MTLLibrary, _ name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else { throw CaptureError.invalid("Missing \(name)") }
        return try device.makeComputePipelineState(function: function)
    }
    let weights = try pipeline(bokehLibrary, "discWeights"), gather = try pipeline(bokehLibrary, "bokeh")
    let smear = try pipeline(dispersionLibrary, "smear"), spectrum = try pipeline(dispersionLibrary, "spectrum")
    func texture(_ width: Int, _ height: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let result = device.makeTexture(descriptor: descriptor) else { throw CaptureError.invalid("Texture allocation") }
        return result
    }
    func command() throws -> MTLCommandBuffer {
        guard let result = queue.makeCommandBuffer() else { throw CaptureError.invalid("Command allocation") }
        return result
    }
    func finish(_ command: MTLCommandBuffer) throws {
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? CaptureError.invalid("Native shader execution") }
    }
    var inputs: [String: Any] = [:], cases: [[String: Any]] = []
    for fixture in ["hdr-gradient", "impulse"] {
        let input = try texture(168, 144, .rgba16Float)
        var values = [Float16](repeating: 0, count: 168 * 144 * 4)
        for y in 0..<144 { for x in 0..<168 {
            let wx = min(95, max(0, x - 36)), wy = min(71, max(0, 107 - y))
            let i = (y * 168 + x) * 4
            if fixture == "impulse" {
                let v: Float16 = wx == 48 && wy == 36 ? 1 : 0
                for c in 0..<4 { values[i + c] = v }
            } else {
                let r = Float(wx) / 95, g = Float(wy) / 71, alpha = 0.25 + r * 0.75
                for (c, value) in [r * 2 * alpha, g * 1.5 * alpha, -0.125 * alpha, alpha].enumerated() {
                    values[i + c] = Float16(value)
                }
            }
        } }
        values.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, 168, 144), mipmapLevel: 0,
                                              withBytes: $0.baseAddress!, bytesPerRow: 168 * 8) }
        inputs[fixture] = buffer(input, bits: 16)
        for shape in UInt32(0)...3 { for radius in [Float(2), Float(7), Float(20)] { for ring in [Float(0), Float(1)] {
            for tile in [false, true] {
                let width = tile ? 48 : 96, height = tile ? 36 : 72
                let output = try texture(width, height, .rgba16Float)
                var p = BokehParameters(radius: radius, shape: shape, ring: ring)
                if tile { p.outputTop = SIMD2(13, 43) }
                let rx = Int(ceil(radius)), ry = Int(ceil(radius * (shape == 2 ? 1.62 : 1)))
                let count = (rx * 2 + 1) * (ry * 2 + 1)
                guard let table = device.makeBuffer(length: count * 4, options: .storageModePrivate) else {
                    throw CaptureError.invalid("Aperture table allocation")
                }
                let cmd = try command()
                guard let encoder = cmd.makeComputeCommandEncoder() else { throw CaptureError.invalid("Bokeh encoder") }
                encoder.setBytes(&p, length: MemoryLayout<BokehParameters>.stride, index: 0)
                encoder.setBuffer(table, offset: 0, index: 1)
                if shape != 3 {
                    encoder.setComputePipelineState(weights)
                    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                }
                encoder.setComputePipelineState(gather)
                encoder.setTexture(input, index: 0)
                encoder.setTexture(output, index: 1)
                encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.endEncoding()
                try finish(cmd)
                cases.append(["fixture": fixture, "shape": shape, "radius": radius, "ring": ring,
                              "tile": tile, "regionOrigin": [0, 0], "regionSize": [96, 72],
                              "inputTop": [-36, 108], "outputTop": tile ? [13, 43] : [0, 72],
                              "output": buffer(output, bits: 16)])
            }
        } } }
    }
    let source = try texture(61, 61, .rgba8Unorm)
    var pixels = [UInt8](repeating: 0, count: 61 * 61 * 4)
    for y in 28...32 { for x in 28...32 { for c in 0..<4 { pixels[(y * 61 + x) * 4 + c] = 255 } } }
    pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 61, 61), mipmapLevel: 0,
                                           withBytes: $0.baseAddress!, bytesPerRow: 61 * 4) }
    var splitCases: [[String: Any]] = []
    for radial in [UInt32(0), UInt32(1)] { for distance in [Float(4), Float(10)] {
        let pad = Int(ceil(Double(distance) * (radial == 0 ? 1 : sqrt(2)))) + 2
        let side = 61 + pad * 2, streaks = try texture(side, side, .rgba16Float)
        let output = try texture(61, 61, .rgba8Unorm), cmd = try command()
        var first = DispersionParameters(distance: distance, radial: radial)
        first.outputOrigin = SIMD2(-Float(pad), -Float(pad))
        var last = DispersionParameters(distance: distance, radial: radial)
        last.inputOrigin = SIMD2(-Float(pad), -Float(pad)); last.sides = 15
        for (state, input, destination, settings) in [(smear, source, streaks, first), (spectrum, streaks, output, last)] {
            guard let encoder = cmd.makeComputeCommandEncoder() else { throw CaptureError.invalid("Dispersion encoder") }
            var p = settings
            encoder.setComputePipelineState(state)
            encoder.setTexture(input, index: 0); encoder.setTexture(destination, index: 1)
            encoder.setBytes(&p, length: MemoryLayout<DispersionParameters>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
        try finish(cmd)
        splitCases.append(["radial": radial, "distance": distance, "blur": 16, "reach": 30.5,
                           "spectral": 8, "smear": 8, "pad": pad,
                           "streaks": buffer(streaks, bits: 16), "output": buffer(output, bits: 8)])
    } }
    return ["schema": 1, "platform": "macOS", "upstreamCommit": CommandLine.arguments[2],
            "device": device.name, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scriptSHA256": hash(try Data(contentsOf: URL(fileURLWithPath: #filePath))),
            "shaderSHA256": ["bokeh": hash(Data(bokeh.utf8)), "dispersion": hash(Data(dispersion.utf8))],
            "bokehParameterStride": MemoryLayout<BokehParameters>.stride,
            "dispersionParameterStride": MemoryLayout<DispersionParameters>.stride,
            "bokehInputs": inputs, "bokehCases": cases,
            "dispersionInput": buffer(source, bits: 8), "dispersionCases": splitCases]
}
do {
    let data = try JSONSerialization.data(withJSONObject: capture(), options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Native adjustment compute capture failed: \(error)\n".utf8)); exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("This reference capture requires native macOS Metal.\n".utf8))
exit(1)
#endif
