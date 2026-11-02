import Foundation
import CoreGraphics
@testable import CoreImage
import CoreImageKernels
import AppKit
import Metal
import Testing
@testable import Compositor

@Suite(.serialized) @MainActor struct GPUCanvasDefaultTests {
    private var forced: Bool { ProcessInfo.processInfo.environment["COMPOSITOR_COREIMAGE_BACKEND"] == "vulkan" }
    private var disabled: Bool { ProcessInfo.processInfo.environment["COMPOSITOR_COREIMAGE_BACKEND"] == "cpu" }
    private var required: Bool {
        ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" && !disabled
    }
    private func context(software: Bool = false) -> CIContext {
        CIContext(options: [.workingColorSpace: DeepLayer.hdrSpace, .hardwareCanvas: true, .useSoftwareRenderer: software])
    }
    private func image(width: Int, height: Int) -> CIImage {
        var values = [Float](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: values.count, by: 4) {
            let a = Float((i / 4) % 17) / 16
            values[i] = Float((i / 4) % 43) / 20 * a
            values[i + 1] = -0.2 * a; values[i + 2] = 0.7 * a; values[i + 3] = a
        }
        let bytes = values.withUnsafeBytes { Array($0) }
        return CIImage(cgImage: CGImage(PortableImage(width: width, height: height, kind: .rgba,
            depth: .float32, bytesPerRow: width * 16, bytes: bytes)))
    }
    private func pixels(_ image: CIImage, _ context: CIContext, _ bounds: CGRect) -> [Float] {
        var values = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        values.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(bounds.width) * 16,
                bounds: bounds, format: .RGBAf, colorSpace: DeepLayer.hdrSpace)
        }
        return values
    }
    @Test func ordinaryAndSoftwareContextsStayCPUByDefault() {
        let ordinary = CIContext(options: [.workingColorSpace: DeepLayer.hdrSpace])
        if !forced { #expect(ordinary.gpuDevice == nil && !ordinary.gpuAvailable) }
        let software = context(software: true)
        #expect(software.gpuDevice == nil && !software.gpuAvailable && software.gpuSubmissionCount == 0)
    }
    @Test(arguments: ["small", "single", "graph"])
    func canvasPolicyAndPixels(kind: String) {
        let hardware = context(), software = context(software: true)
        if required { #expect(hardware.gpuAvailable) }
        if disabled { #expect(hardware.gpuDevice == nil) }
        let width = kind == "small" ? 128 : 256, height = width
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let source = image(width: width, height: height)
        let bottom = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)).cropped(to: bounds)
        let over = source.composited(over: bottom)
        let result = kind == "single" ? over : over.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.8, y: 0.1, z: 0.1, w: 0),
            "inputBiasVector": CIVector(x: 0.1, y: 0, z: 0, w: 0)])
        let actual = pixels(result, hardware, bounds), expected = pixels(result, software, bounds)
        #expect(zip(actual, expected).allSatisfy { $0.bitPattern == $1.bitPattern })
        let submits = hardware.gpuAvailable && (forced || kind == "graph") ? 1 : 0
        #expect(hardware.gpuSubmissionCount == UInt64(submits))
        #expect(hardware.gpuReadbackBytes == UInt64(width * height * 16 * submits))
        #expect(software.gpuSubmissionCount == 0)
    }
    @Test func defaultCanvasGraphFailureReturnsExactCPUOutput() throws {
        let hardware = context(), software = context(software: true)
        guard let backend = hardware.gpuBackend else {
            if required { Issue.record("Hardware canvas unavailable") }
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let frame = image(width: 256, height: 256).applyingFilter("CIMaximumComponent").unpremultiplyingAlpha()
        let expected = pixels(frame, software, bounds)
        #expect(pixels(frame, hardware, bounds) == expected && hardware.gpuSubmissionCount == 1)
        var step = CompositorVulkanRasterStep(); step.operation = 5
        var input: Float = 0, sentinel: Float = 123
        withUnsafePointer(to: &input) { pointer in
            var source: UnsafePointer<Float>? = pointer
            #expect(compositor_vulkan_raster_render_graph(backend, 65_536, 65_536, &source, 1, &step, 1, nil, nil, &sentinel) == -2)
        }
        #expect(sentinel == 123 && !hardware.gpuAvailable)
        let recovered = pixels(frame, hardware, bounds)
        #expect(zip(recovered, expected).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(hardware.gpuSubmissionCount == 1)
    }
    @Test(arguments: ["inside", "fractional", "partial", "empty"])
    func croppedGraphsKeepTheOriginalCPUEvaluationDomain(kind: String) {
        let hardware = context(), software = context(software: true)
        if required { #expect(hardware.gpuAvailable) }
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let crop: CGRect
        switch kind {
        case "inside": crop = CGRect(x: 17, y: 23, width: 91, height: 77)
        case "fractional": crop = CGRect(x: 17.3, y: 23.7, width: 90.2, height: 76.6)
        case "partial": crop = CGRect(x: -11.3, y: 23.7, width: 100, height: 256)
        default: crop = CGRect(x: 300, y: 300, width: 10, height: 10)
        }
        let source = image(width: 256, height: 256)
        let clipped = source.applyingGaussianBlur(sigma: 1.3)
            .applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: 0.3, y: 0.1, z: 0.2, w: 0.2)])
            .cropped(to: crop)
        let result = clipped.composited(over: source.unpremultiplyingAlpha())
        let actual = pixels(result, hardware, bounds), expected = pixels(result, software, bounds)
        #expect(zip(actual, expected).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(hardware.gpuSubmissionCount == (hardware.gpuAvailable ? 1 : 0))
    }
    @Test(arguments: ["identity", "opacity", "bias"])
    func matrixPreservesExtendedValuesAccordingToTheDocumentedFormula(kind: String) {
        let hardware = context(), software = context(software: true)
        if required { #expect(hardware.gpuAvailable) }
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let source = CIImage(color: CIColor(red: 2, green: -0.25, blue: 0.5, alpha: 0.5)).cropped(to: bounds)
        let parameters: [String: Any], expected: [Float]
        switch kind {
        case "opacity":
            parameters = ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)]
            expected = [0.5, -0.0625, 0.125, 0.25]
        case "bias":
            parameters = ["inputBiasVector": CIVector(x: 0.5, y: -0.5, z: 1, w: 0.75)]
            expected = [3.125, -0.9375, 1.875, 1.25]
        default:
            parameters = [:]; expected = [1, -0.125, 0.25, 0.5]
        }
        let result = source.applyingFilter("CIColorMatrix", parameters: parameters).cropped(to: bounds)
        for evaluator in [hardware, software] {
            let actual = pixels(result, evaluator, bounds)
            #expect(actual.enumerated().allSatisfy { $0.element.bitPattern == expected[$0.offset % 4].bitPattern })
        }
        #expect(hardware.gpuSubmissionCount == (hardware.gpuAvailable ? 1 : 0))
    }
    @Test(arguments: ["sdr", "hdr", "hdrImported"])
    func actualCanvasFrameTiming(kind: String) throws {
        guard let renderer = GPUCanvasRenderer.shared else {
            if required { Issue.record("Default canvas renderer unavailable") }
            return
        }
        let width = 512, height = 512, size = CGSize(width: width, height: height)
        let session = EditorSession()
        session.viewport.resize(to: size, backingScale: 1, documentSize: nil)
        session.createDocument(width: width, height: height)
        let software = context(software: true)
        let assetImage = try #require(software.createCGImage(image(width: width, height: height),
            from: CGRect(origin: .zero, size: size), format: kind == "sdr" ? .RGBA8 : .RGBAf, colorSpace: DeepLayer.hdrSpace))
        for i in 0..<6 {
            let asset = kind == "hdrImported" ? try DeepLayer.wideAsset(assetImage, name: "Layer \(i)")
                : ImportedImage(image: assetImage, thumbnail: assetImage, name: "Layer \(i)")
            if kind == "hdrImported" { #expect(asset.isHDR && asset.image.bitsPerComponent == 8) }
            session.insert(asset)
            let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
            session.document!.layers[index].opacity = 0.75
        }
        session.selectLayer(nil); session.zoom(to: 1)
        let canvas = CanvasView(session: session); canvas.frame = CGRect(origin: .zero, size: size)
        _ = canvas.synchronizeDisplay()
        let frame = try #require(canvas.gpuFrame(size: size))
        let bounds = CGRect(origin: .zero, size: size)
        let before = renderer.context.gpuSubmissionCount
        let expected = pixels(frame, software, bounds), actual = pixels(frame, renderer.context, bounds)
        #expect(zip(actual, expected).allSatisfy { $0.bitPattern == $1.bitPattern })
        if renderer.context.gpuAvailable { #expect(renderer.context.gpuSubmissionCount == before + 1) }
        func mean(_ context: CIContext) -> Double {
            _ = pixels(frame, context, bounds)
            let start = ContinuousClock.now
            for _ in 0..<5 { _ = pixels(frame, context, bounds) }
            let elapsed = start.duration(to: .now).components
            return (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) / 5
        }
        let gpuMS = mean(renderer.context), cpuMS = mean(software)
        #expect(zip(pixels(frame, renderer.context, bounds), expected).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(session.document?.layers.count == 6)
        let cg = try BrushRaster.context(width: width, height: height, mask: false)
        // BrushRaster.context already installs the view's y-down transform.
        canvas.allowsGPU = false
        func drawCG() {
            cg.saveGState()
            defer { cg.restoreGState() }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        drawCG()
        let firstReference = Array(UnsafeBufferPointer(start: try #require(cg.data).assumingMemoryBound(to: UInt8.self),
            count: cg.bytesPerRow * height))
        let start = ContinuousClock.now
        for _ in 0..<5 { drawCG() }
        let elapsed = start.duration(to: .now).components
        let cgMS = (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) / 5
        // Use the upstream comparison's texture path, including its coordinate and row conversion.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.context.render(frame, to: texture, commandBuffer: buffer, bounds: bounds, colorSpace: renderer.space)
        buffer.commit(); buffer.waitUntilCompleted()
        let reference = firstReference
        #expect(Array(UnsafeBufferPointer(start: try #require(cg.data).assumingMemoryBound(to: UInt8.self),
            count: cg.bytesPerRow * height)) == firstReference)
        var graphBytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&graphBytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var total = 0, outside = 0
        for y in 0..<height { for x in 0..<width {
            var largest = 0
            for c in 0..<3 {
                let difference = abs(Int(reference[y * cg.bytesPerRow + x * 4 + c]) - Int(graphBytes[y * width * 4 + x * 4 + c]))
                largest = max(largest, difference); total += difference
            }
            if largest > 12 { outside += 1 }
        } }
        let meanDifference = Double(total) / Double(width * height * 3)
        let outsideFraction = Double(outside) / Double(width * height)
        if kind == "sdr" {
            // The same tolerance as upstream GPUCanvasTests' ordinary canvas comparison.
            #expect(meanDifference < 1.5 && outsideFraction < 0.01)
        }
        print("Actual upstream CanvasView \(kind) 6 layers 512x512: hardware graph \(gpuMS) ms CPU graph \(cpuMS) ms Core Graphics \(cgMS) ms; mean pixel difference \(meanDifference), fraction over 12 \(outsideFraction); \(renderer.context.gpuDevice ?? "CPU fallback")")
    }
    @Test(arguments: [Float(1), Float(0.25)])
    func canonicalHDRCanvasRetainsHighlightsBeforeOpacity(opacity: Float) throws {
        guard let renderer = GPUCanvasRenderer.shared else {
            if required { Issue.record("Hardware HDR canvas unavailable") }
            return
        }
        if required { #expect(renderer.context.gpuAvailable) }
        let width = 32, height = 32, size = CGSize(width: width, height: height)
        let values = (0..<(width * height)).flatMap { _ in [Float16(2), Float16(0.25), Float16(0.5), Float16(1)] }
        let source = CGImage(PortableImage(width: width, height: height, kind: .rgba, depth: .half,
            bytesPerRow: width * 8, bytes: values.withUnsafeBytes { Array($0) }))
        let asset = try DeepLayer.wideAsset(source, name: "HDR highlights")
        #expect(asset.isHDR && asset.image.bitsPerComponent == 8 && asset.deep?.bitsPerComponent == 16)
        let session = EditorSession()
        session.viewport.resize(to: size, backingScale: 1, documentSize: nil)
        session.createDocument(width: width, height: height)
        session.insert(asset)
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document!.layers[index].opacity = Double(opacity)
        session.selectLayer(nil); session.zoom(to: 1)
        let canvas = CanvasView(session: session); canvas.frame = CGRect(origin: .zero, size: size)
        _ = canvas.synchronizeDisplay()
        let bounds = CGRect(origin: .zero, size: size), frame = try #require(canvas.gpuFrame(size: size))
        let before = renderer.context.gpuSubmissionCount
        let actual = pixels(frame, renderer.context, bounds), cpu = pixels(frame, context(software: true), bounds)
        if required && forced { #expect(renderer.context.gpuSubmissionCount == before + 1) }
        #expect(zip(actual, cpu).allSatisfy { $0.bitPattern == $1.bitPattern })
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.context.render(frame, to: texture, commandBuffer: buffer, bounds: bounds, colorSpace: renderer.space)
        buffer.commit(); buffer.waitUntilCompleted()
        var display = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&display, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // The unchanged GPU canvas composites deep extended-sRGB pixels, rather than the clipped display preview.
        for (x, background) in [(5, Float(0.35)), (15, Float(0.30))] {
            let offset = (5 * width + x) * 4
            for (channel, source) in [Float(2), Float(0.25), Float(0.5)].enumerated() {
                let expected = source * opacity + background * (1 - opacity)
                #expect(abs(actual[offset + channel] - expected) < 0.002)
                #expect(abs(Int(display[offset + channel]) - Int(min(1, max(0, expected)) * 255 + 0.5)) <= 1)
            }
            #expect(actual[offset + 3] == 1)
            #expect(display[offset + 3] == 255)
            #expect(actual[offset] > opacity + background * (1 - opacity) + 0.2)
        }
    }
    @Test func rendererPresentsHardwareGraphWithoutAnEnvironmentOverride() throws {
        guard let renderer = GPUCanvasRenderer.shared else {
            if required && ProcessInfo.processInfo.environment["COMPOSITOR_CPU_CANVAS"] != "1" { Issue.record("Default canvas renderer unavailable") }
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let source = image(width: 256, height: 256)
        let frame = source.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.75)])
            .composited(over: source.applyingFilter("CIMaximumComponent"))
        let expected = try #require(context(software: true).createCGImage(frame, from: bounds))
        let before = renderer.context.gpuSubmissionCount
        let layer = CAMetalLayer(); layer.drawableSize = bounds.size
        let target = try BrushRaster.context(width: 256, height: 256, mask: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: target, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        renderer.present(frame, in: layer)
        let actual = try #require(layer.lastPresented)
        #expect(actual.portableImage.bytes == expected.portableImage.bytes)
        if renderer.context.gpuAvailable { #expect(renderer.context.gpuSubmissionCount == before + 1) }
    }
}
