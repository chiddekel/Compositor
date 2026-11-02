import Foundation
import CoreGraphics
import CoreImageKernels
import Testing
@testable import CoreImage

@Suite(.serialized) struct VulkanCanvasRasterTests {
    private let bounds = CGRect(x: -11, y: 7, width: 128, height: 80)
    private func image(_ offset: Int) -> CIImage {
        var values = [Float](repeating: 0, count: 128 * 80 * 4)
        for i in stride(from: 0, to: values.count, by: 4) {
            let a = Float((i / 4 + offset) % 17) / 16
            values[i] = Float((i + offset) % 53) / 13 * a
            values[i + 1] = Float((i + offset * 7) % 31 - 10) / 20 * a
            values[i + 2] = i % 32 == 0 ? Float.leastNonzeroMagnitude : 0.37 * a
            values[i + 3] = a
        }
        let data = values.withUnsafeBytes { Array($0) }
        return CIImage(cgImage: CGImage(PortableImage(width: 128, height: 80, kind: .rgba, depth: .float32,
            bytesPerRow: 128 * 16, bytes: data)))
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }
    private func context(software: Bool) -> CIContext {
        CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: software])
    }
    private func backend() -> VulkanRaster? {
        let gpu = VulkanRaster()
        if gpu == nil && ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" {
            Issue.record("Hardware Core Image unavailable")
        }
        return gpu
    }
    private func raster(_ red: Float, width: Int = 8, height: Int = 4) -> Raster {
        Raster(rect: CGRect(x: 0, y: 0, width: width, height: height),
            data: (0..<(width * height)).flatMap { _ in [red, 0.125, 0.25, 0.5] })
    }
    private func over(_ source: Raster, _ background: Raster) -> [Float] {
        var values = source.data
        for i in stride(from: 0, to: values.count, by: 4) {
            let keep = 1 - source.data[i + 3]
            for c in 0..<4 { values[i + c] = source.data[i + c] + background.data[i + c] * keep }
        }
        return values
    }
    @Test func retainedInputsSurviveMutationReshapeAndMaskChanges() throws {
        guard let gpu = backend() else { return }
        var source = raster(0.25), background = raster(0.375), mask = raster(0.5)
        let bytes = UInt64(source.data.count * MemoryLayout<Float>.stride)
        #expect(try #require(gpu.render(1, source: source, background: background)).data == over(source, background))
        #expect(try #require(gpu.render(1, source: source, background: background)).data == over(source, background))
        #expect(gpu.uploadBytes == 2 * bytes)
        source.data[0] = 4
        #expect(try #require(gpu.render(1, source: source, background: background)).data == over(source, background))
        #expect(gpu.uploadBytes == 3 * bytes)
        background.data[1] = -2
        #expect(try #require(gpu.render(1, source: source, background: background)).data == over(source, background))
        #expect(gpu.uploadBytes == 4 * bytes)
        // Mask alpha .5 mixes the images equally; changing mask storage must upload it.
        let masked = try #require(gpu.render(2, source: source, background: background, mask: mask, channel: 3))
        #expect(masked.data == zip(source.data, background.data).map { $0 * 0.5 + $1 * 0.5 })
        #expect(gpu.uploadBytes == 5 * bytes)
        for i in stride(from: 3, to: mask.data.count, by: 4) { mask.data[i] = 1 }
        #expect(try #require(gpu.render(2, source: source, background: background, mask: mask, channel: 3)).data == source.data)
        #expect(gpu.uploadBytes == 6 * bytes)
        // Same storage with a different shape changes dispatch geometry, not pixels.
        source.rect.size = CGSize(width: 4, height: 8); background.rect = source.rect
        #expect(try #require(gpu.render(1, source: source, background: background)).data == over(source, background))
        #expect(gpu.uploadBytes == 6 * bytes)
        source = raster(2, width: 17, height: 9); background = raster(0.75, width: 17, height: 9)
        #expect(try #require(gpu.render(1, source: source, background: background)).data == over(source, background))
        #expect(gpu.uploadBytes == 6 * bytes + UInt64(source.data.count * 8))
    }
    @Test func interveningDirectCallerInvalidatesRetainedInputs() throws {
        guard let gpu = backend() else { return }
        let source = raster(0.25), background = raster(0.375)
        let first = try #require(gpu.render(1, source: source, background: background))
        let before = gpu.uploadBytes
        let alien = raster(8)
        var output = [Float](repeating: 0, count: alien.data.count)
        let code = alien.data.withUnsafeBufferPointer { a in
            output.withUnsafeMutableBufferPointer { o in
                compositor_vulkan_raster_render(gpu.backend, 8, 4, 6, 0, a.baseAddress, nil, nil, nil, o.baseAddress)
            }
        }
        #expect(code == 0 && output[0] == 8)
        #expect(try #require(gpu.render(1, source: source, background: background)).data == first.data)
        #expect(gpu.uploadBytes == before + UInt64(source.data.count * 12))
    }
    @Test func retainedInputsSerializeConcurrentRenderers() async throws {
        guard let gpu = backend() else { return }
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<16 {
                group.addTask {
                    let rect = CGRect(x: 0, y: 0, width: 4, height: 4)
                    let data = (0..<16).flatMap { _ in [Float(i), Float(0.25), Float(0.5), Float(1)] }
                    let source = Raster(rect: rect, data: data)
                    return gpu.render(5, source: source)?.data == data
                }
            }
            for await accurate in group { #expect(accurate) }
        }
        #expect(gpu.submissions == 16)
    }
    @Test func residentGraphPreservesBranchesAndReusesScratchBuffers() throws {
        guard let gpu = backend() else { return }
        let top = raster(2), bottom = raster(0.375)
        let steps = [VulkanRasterStep(operation: 6, source: 0),
                     VulkanRasterStep(operation: 5, source: 1),
                     VulkanRasterStep(operation: 1, source: 2, background: 3)]
        let result = try #require(gpu.renderGraph(sources: [top, bottom], steps: steps))
        var maximum = top, straight = bottom
        for i in stride(from: 0, to: top.data.count, by: 4) {
            let m = max(top.data[i], max(top.data[i + 1], top.data[i + 2]))
            for c in 0..<3 { maximum.data[i + c] = m; straight.data[i + c] /= straight.data[i + 3] }
        }
        #expect(result.data == over(maximum, straight))
        #expect(try #require(gpu.renderGraph(sources: [top, bottom], steps: steps)).data == result.data)
        let bytes = UInt64(top.data.count * 4)
        #expect(gpu.submissions == 2 && gpu.readbackBytes == 2 * bytes && gpu.uploadBytes == 2 * bytes)
        // A long chain exercises alternating scratch slots after the branched graph.
        var opaque = top
        for i in stride(from: 3, to: opaque.data.count, by: 4) { opaque.data[i] = 1 }
        let chain = (0..<64).map { VulkanRasterStep(operation: 5, source: $0) }
        #expect(try #require(gpu.renderGraph(sources: [opaque], steps: chain)).data == opaque.data)
        #expect(gpu.submissions == 3 && gpu.readbackBytes == 3 * bytes)
    }
    @Test func malformedGraphLeavesOutputUntouchedAndValidGraphRecovers() throws {
        guard let gpu = backend() else { return }
        let source = raster(2)
        var invalid = CompositorVulkanRasterStep()
        invalid.operation = 1; invalid.source = 1; invalid.background = 0 // Forward/self reference.
        var output = [Float](repeating: 123, count: source.data.count)
        let code = source.data.withUnsafeBufferPointer { input in
            var pointer = input.baseAddress
            return output.withUnsafeMutableBufferPointer { o in
                compositor_vulkan_raster_render_graph(gpu.backend, 8, 4, &pointer, 1, &invalid, 1, nil, nil, o.baseAddress)
            }
        }
        #expect(code == -1 && output.allSatisfy { $0 == 123 } && gpu.submissions == 0)
        #expect(gpu.renderGraph(sources: [source], steps: [VulkanRasterStep(operation: 6, source: 0)]) != nil)
        #expect(gpu.submissions == 1)
    }
    @Test func alternatingCallersCannotCertifyTheOtherCachesStorage() throws {
        guard let gpu = backend() else { return }
        let source = raster(0.25), background = raster(0.375), alien = raster(8)
        let single = try #require(gpu.render(1, source: source, background: background))
        var output = [Float](repeating: 0, count: alien.data.count)
        #expect(alien.data.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { o in
                compositor_vulkan_raster_render(gpu.backend, 8, 4, 6, 0, input.baseAddress, nil, nil, nil, o.baseAddress)
            }
        } == 0)
        let steps = [VulkanRasterStep(operation: 5, source: 0), VulkanRasterStep(operation: 5, source: 1)]
        let graph = try #require(gpu.renderGraph(sources: [source], steps: steps))
        #expect(try #require(gpu.render(1, source: source, background: background)).data == single.data)
        var native = [CompositorVulkanRasterStep(), CompositorVulkanRasterStep()]
        native[0].operation = 5; native[0].source = 0
        native[1].operation = 5; native[1].source = 1
        #expect(alien.data.withUnsafeBufferPointer { input in
            var pointer = input.baseAddress
            return native.withUnsafeBufferPointer { steps in
                output.withUnsafeMutableBufferPointer { o in
                    compositor_vulkan_raster_render_graph(gpu.backend, 8, 4, &pointer, 1, steps.baseAddress, 2, nil, nil, o.baseAddress)
                }
            }
        } == 0)
        #expect(try #require(gpu.render(1, source: source, background: background)).data == single.data)
        #expect(try #require(gpu.renderGraph(sources: [source], steps: steps)).data == graph.data)
    }
    @Test(arguments: [false, true], ["alpha", "red", "luma"])
    func residentImageGraphMatchesSoftware(linear: Bool, mask: String) throws {
        let gpu = CIContext(options: [.workingColorSpace: linear ? CGColorSpace(name: CGColorSpace.linearSRGB)! : NSNull()]),
            cpu = CIContext(options: [.workingColorSpace: linear ? CGColorSpace(name: CGColorSpace.linearSRGB)! : NSNull(), .useSoftwareRenderer: true])
        guard gpu.gpuDevice != nil else {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { Issue.record("Hardware Core Image unavailable") }
            return
        }
        let source = image(3).applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: 0.1, y: 0.2, z: 0.3, w: 0)])
        let background = image(11).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: -0.2, y: -0.2, z: -0.2, w: 0),
            "inputMaxComponents": CIVector(x: 2, y: 2, z: 2, w: 0.9)])
        let coverage = image(7).applyingFilter("CIMaximumComponent")
        let result = source.applyingFilter(mask == "alpha" ? "CIBlendWithAlphaMask" : mask == "red" ? "CIBlendWithRedMask" : "CIBlendWithMask",
            parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: coverage])
            .composited(over: background).unpremultiplyingAlpha()
        let actual = pixels(result, context: gpu), expected = pixels(result, context: cpu)
        #expect(zip(actual, expected).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(gpu.gpuSubmissionCount == 1)
        #expect(gpu.gpuReadbackBytes == UInt64(128 * 80 * 16))
    }
    private func pixels(_ image: CIImage, context: CIContext) -> [Float] {
        var output = [Float](repeating: 0, count: 128 * 80 * 4)
        output.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 128 * 16, bounds: bounds,
                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return output
    }
    @Test(arguments: ["over", "alphaMask", "redMask", "lumaMask", "matrix", "clamp", "unpremultiply", "maximum"])
    func hardwarePixelsMatchSoftware(operation: String) throws {
        let gpu = context(software: false), cpu = context(software: true)
        guard gpu.gpuDevice != nil else {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { Issue.record("Hardware Core Image unavailable") }
            return
        }
        #expect(gpu.gpuDeviceType == 1 || gpu.gpuDeviceType == 2)
        let source = image(3), background = image(11), mask = image(7)
        let result: CIImage
        switch operation {
        case "over": result = source.composited(over: background)
        case "alphaMask", "redMask", "lumaMask":
            result = source.applyingFilter(operation == "alphaMask" ? "CIBlendWithAlphaMask" : operation == "redMask" ? "CIBlendWithRedMask" : "CIBlendWithMask",
                parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask])
        case "matrix":
            result = source.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.7, y: -0.1, z: 0.2, w: 0.03),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.6),
                "inputBiasVector": CIVector(x: 0.1, y: 0.2, z: -0.05, w: 0.1)])
        case "clamp": result = source.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: -0.2, y: -0.2, z: -0.2, w: 0),
            "inputMaxComponents": CIVector(x: 2, y: 2, z: 2, w: 0.9)])
        case "unpremultiply": result = source.unpremultiplyingAlpha()
        default: result = source.applyingFilter("CIMaximumComponent")
        }
        let actual = pixels(result, context: gpu), expected = pixels(result, context: cpu)
        #expect(zip(actual, expected).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(gpu.gpuSubmissionCount > 0)
        #expect(cpu.gpuSubmissionCount == 0 && cpu.gpuDevice == nil)
    }

    @Test(arguments: [false, true]) func failedSubmissionLeavesOutputUntouchedAndContextRecoversOnCPU(graph: Bool) throws {
        let gpu = context(software: false), cpu = context(software: true)
        guard let backend = gpu.gpuBackend else {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { Issue.record("Hardware Core Image unavailable") }
            return
        }
        let result = image(3).composited(over: image(11)).unpremultiplyingAlpha()
        let expected = pixels(result, context: cpu)
        #expect(pixels(result, context: gpu) == expected)
        let before = gpu.gpuSubmissionCount
        var sentinel: Float = 123
        var input: Float = 0
        if graph {
            var step = CompositorVulkanRasterStep(); step.operation = 5
            var generation: UInt64 = 77
            withUnsafePointer(to: &input) { pointer in
                var source: UnsafePointer<Float>? = pointer
                #expect(compositor_vulkan_raster_render_graph(backend, 65_536, 65_536, &source, 1, &step, 1, nil, &generation, &sentinel) == -2)
            }
            #expect(generation == 77)
        } else {
            #expect(compositor_vulkan_raster_render(backend, 65_536, 65_536, 1, 0, &input, &input, nil, nil, &sentinel) == -2)
        }
        #expect(sentinel == 123)
        #expect(pixels(result, context: gpu) == expected)
        #expect(gpu.gpuSubmissionCount == before)
    }

    @Test(arguments: [false, true]) func compositingTiming(masked: Bool) throws {
        let gpu = context(software: false), cpu = context(software: true)
        guard gpu.gpuDevice != nil else {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { Issue.record("Hardware Core Image unavailable") }
            return
        }
        let width = 1024, height = 512
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        func source(_ offset: Int) -> CIImage {
            var values = [Float](repeating: 0, count: width * height * 4)
            for i in stride(from: 0, to: values.count, by: 4) {
                let a = Float((i / 4 + offset) % 17) / 16
                values[i] = Float((i / 4 + offset) % 47) / 30 * a
                values[i + 1] = 0.3 * a; values[i + 2] = 0.7 * a; values[i + 3] = a
            }
            let bytes = values.withUnsafeBytes { Array($0) }
            return CIImage(cgImage: CGImage(PortableImage(width: width, height: height, kind: .rgba,
                depth: .float32, bytesPerRow: width * 16, bytes: bytes)))
        }
        let top = source(3), bottom = source(11)
        let result = masked ? top.applyingFilter("CIBlendWithRedMask", parameters: [
            kCIInputBackgroundImageKey: bottom, kCIInputMaskImageKey: source(7)]) : top.composited(over: bottom)
        var output = [Float](repeating: 0, count: width * height * 4)
        func render(_ context: CIContext) {
            output.withUnsafeMutableBytes {
                context.render(result, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: rect,
                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
        }
        render(cpu); let expected = output
        render(gpu); #expect(output == expected)
        func mean(_ context: CIContext) -> Double {
            for _ in 0..<2 { render(context) }
            let start = ContinuousClock.now
            for _ in 0..<10 { render(context) }
            let elapsed = start.duration(to: .now).components
            return (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) / 10
        }
        let gpuMS = mean(gpu), cpuMS = mean(cpu)
        #expect(output == expected)
        #expect(gpu.gpuSubmissionCount == 13)
        #expect(gpu.gpuUploadBytes == UInt64(width * height * 16 * (masked ? 3 : 2)))
        print("Vulkan canvas \(masked ? "mask" : "over") 1024x512: GPU \(gpuMS) ms CPU \(cpuMS) ms; \(gpu.gpuDevice ?? "unavailable")")
    }
    @Test func residentCanvasTiming() throws {
        let gpu = context(software: false), cpu = context(software: true)
        guard gpu.gpuDevice != nil else {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { Issue.record("Hardware Core Image unavailable") }
            return
        }
        let width = 1024, height = 512, count = width * height * 4
        var images: [CIImage] = []
        for layer in 0..<6 {
            let values = (0..<(width * height)).flatMap { pixel -> [Float] in
                let a = Float((pixel + layer) % 17) / 16
                return [Float((pixel + layer * 7) % 37) / 20 * a, 0.3 * a, 0.7 * a, a]
            }
            let bytes = values.withUnsafeBytes { Array($0) }
            images.append(CIImage(cgImage: CGImage(PortableImage(width: width, height: height,
                kind: .rgba, depth: .float32, bytesPerRow: width * 16, bytes: bytes)))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.75)]))
        }
        let result = images.dropFirst().reduce(images[0]) { $1.composited(over: $0) }
        var output = [Float](repeating: 0, count: count)
        func render(_ context: CIContext) {
            output.withUnsafeMutableBytes {
                context.render(result, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
        }
        render(cpu); let expected = output
        render(gpu); #expect(zip(output, expected).allSatisfy { $0.bitPattern == $1.bitPattern })
        func mean(_ context: CIContext) -> Double {
            for _ in 0..<2 { render(context) }
            let start = ContinuousClock.now
            for _ in 0..<10 { render(context) }
            let elapsed = start.duration(to: .now).components
            return (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) / 10
        }
        let gpuMS = mean(gpu), cpuMS = mean(cpu)
        #expect(zip(output, expected).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(gpu.gpuSubmissionCount == 13 && gpu.gpuReadbackBytes == UInt64(count * 4 * 13))
        #expect(gpu.gpuUploadBytes == UInt64(count * 4 * 6))
        print("Vulkan resident canvas 6 layers/11 operations 1024x512: GPU \(gpuMS) ms CPU \(cpuMS) ms; \(gpu.gpuDevice ?? "unavailable")")
    }
}
