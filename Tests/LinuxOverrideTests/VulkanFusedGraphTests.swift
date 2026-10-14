import Foundation
import CoreGraphics
import CoreImageKernels
import Testing
@testable import CoreImage

/// The fused graph pass keeps intermediates in registers. It must give exactly the bits of evaluating each operation
/// on its own (the one-operation shader, itself checked against the CPU evaluator), fall back to the multi-pass graph
/// when a graph needs more registers, and never reuse retained inputs filled by the other path.
@Suite(.serialized) struct VulkanFusedGraphTests {
    private let width = 40, height = 24
    private func backend() -> VulkanRaster? {
        let gpu = VulkanRaster()
        if gpu == nil && ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" {
            Issue.record("Hardware Core Image unavailable")
        }
        return gpu
    }
    /// Premultiplied pixels with extended, negative, subnormal and transparent values.
    private func raster(_ seed: Int) -> Raster {
        var values = [Float](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            let a = Float((pixel * 7 + seed) % 9) / 8
            values[pixel * 4] = Float((pixel + seed * 3) % 23 - 4) / 7 * a
            values[pixel * 4 + 1] = pixel % 11 == 0 ? Float.leastNonzeroMagnitude : Float((pixel * 5 + seed) % 13) / 9 * a
            values[pixel * 4 + 2] = Float((pixel + seed) % 5) / 2 * a
            values[pixel * 4 + 3] = a
        }
        return Raster(rect: CGRect(x: 0, y: 0, width: width, height: height), data: values)
    }
    private func parameters(_ operation: UInt32, _ seed: Int) -> [Float] {
        switch operation {
        case 3: return (0..<20).map { Float(($0 * 3 + seed) % 7 - 2) / 5 }
        case 4: return [-0.25, 0, 0.1, 0.2, 1.5, 0.75, 2, 0.9]
        case 7: return [Float(3 + seed % 5), 2, Float(width - 4), Float(height - 3)]
        default: return []
        }
    }
    /// Each step evaluated on its own by the one-operation shader.
    private func reference(_ gpu: VulkanRaster, _ sources: [Raster], _ steps: [VulkanRasterStep]) throws -> Raster {
        var nodes = sources
        for step in steps {
            let result = try #require(gpu.render(step.operation, source: nodes[step.source],
                background: step.operation <= 2 ? nodes[step.background] : nil,
                mask: step.operation == 2 ? nodes[step.mask] : nil, channel: step.channel, parameters: step.parameters))
            nodes.append(result)
        }
        return nodes.last!
    }
    private func same(_ a: Raster, _ b: Raster) -> Bool {
        a.data.count == b.data.count && zip(a.data, b.data).allSatisfy { $0.bitPattern == $1.bitPattern }
    }

    @Test(arguments: [0, 1, 2]) func fusedGraphsMatchEachOperationBitForBit(seed: Int) throws {
        guard let gpu = backend() else { return }
        let sources = (0..<4).map { raster($0 + seed * 4) }
        var steps: [VulkanRasterStep] = []
        // Every operation and mask channel, branching and joining over earlier inputs and results.
        for (index, operation) in ([1, 2, 3, 4, 5, 6, 7, 2, 2, 3, 1, 5, 4, 6, 7, 1] as [UInt32]).enumerated() {
            let nodes = sources.count + steps.count
            steps.append(VulkanRasterStep(operation: operation, source: (index * 5 + seed) % nodes,
                background: (index * 3 + 1) % nodes, mask: (index + 2) % nodes,
                channel: [0, 3, 4][index % 3], parameters: parameters(operation, index + seed)))
        }
        let fusedBefore = gpu.fusedSubmissions
        let fused = try #require(gpu.renderGraph(sources: sources, steps: steps))
        #expect(gpu.fusedSubmissions == fusedBefore + 1)
        #expect(same(fused, try reference(gpu, sources, steps)))
    }

    @Test func graphsNeedingMoreRegistersUseTheMultiPassGraph() throws {
        guard let gpu = backend() else { return }
        let sources = [raster(1), raster(2)]
        // Twenty unary results stay live until a chain of source-over combines them.
        var steps = (0..<20).map { VulkanRasterStep(operation: [5, 6][$0 % 2], source: $0 % 2) }
        var accumulated = sources.count
        for index in 1..<20 {
            steps.append(VulkanRasterStep(operation: 1, source: sources.count + index, background: accumulated))
            accumulated = sources.count + steps.count - 1
        }
        let fusedBefore = gpu.fusedSubmissions, submitted = gpu.submissions
        let result = try #require(gpu.renderGraph(sources: sources, steps: steps))
        #expect(gpu.fusedSubmissions == fusedBefore && gpu.submissions == submitted + 1)
        #expect(same(result, try reference(gpu, sources, steps)))
    }

    @Test func switchingGraphPathsUploadsTheCurrentInputs() throws {
        guard let gpu = backend() else { return }
        let first = [raster(3), raster(4)], second = [raster(5), raster(6)]
        let small = [VulkanRasterStep(operation: 1, source: 0, background: 1)]
        var large = (0..<20).map { VulkanRasterStep(operation: 5, source: $0 % 2) }
        var accumulated = 2
        for index in 1..<20 {
            large.append(VulkanRasterStep(operation: 1, source: 2 + index, background: accumulated))
            accumulated = 2 + large.count - 1
        }
        // Fused fills its inputs with `first`; the multi-pass graph then sees `second`, and the fused graph is asked
        // for `second` again: the wrapper reports unchanged storage, but the fused inputs still hold `first`.
        _ = try #require(gpu.renderGraph(sources: first, steps: small))
        _ = try #require(gpu.renderGraph(sources: second, steps: large))
        let again = try #require(gpu.renderGraph(sources: second, steps: small))
        #expect(same(again, try reference(gpu, second, small)))
        let back = try #require(gpu.renderGraph(sources: second, steps: large))
        #expect(same(back, try reference(gpu, second, large)))
    }

    @Test func aGraphBeyondTheSizeLimitsLeavesTheDeviceUsable() throws {
        guard let gpu = backend() else { return }
        // Forty 16 MiB inputs (one shared array) exceed the retained-graph budget: refused, evaluated on the CPU instead.
        let large = Raster(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let sources = [Raster](repeating: large, count: 40)
        let steps = (1..<40).map { VulkanRasterStep(operation: 1, source: $0, background: $0 == 1 ? 0 : 40 + $0 - 2) }
        let submitted = gpu.submissions
        #expect(gpu.renderGraph(sources: sources, steps: steps) == nil)
        #expect(gpu.isAvailable && gpu.submissions == submitted)
        let small = [raster(7), raster(8)]
        let recovered = try #require(gpu.renderGraph(sources: small, steps: [VulkanRasterStep(operation: 1, source: 0, background: 1)]))
        #expect(gpu.submissions == submitted + 1)
        #expect(same(recovered, try reference(gpu, small, [VulkanRasterStep(operation: 1, source: 0, background: 1)])))
    }

    @Test func cachedGeneratorLeavesFollowTheirParameters() throws {
        let hardware = CIContext(options: [.workingColorSpace: NSNull(), .hardwareCanvas: true])
        let software = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: true])
        guard hardware.gpuAvailable else {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" { Issue.record("Hardware canvas unavailable") }
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 260)
        func frame(_ shade: CGFloat, _ step: CGFloat, _ blur: Double) -> CIImage {
            let checker = CIImage(color: CIColor(red: shade, green: shade, blue: shade, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: step, height: step))
                .composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                    .cropped(to: CGRect(x: 0, y: 0, width: step * 2, height: step * 2)))
                .applyingFilter("CIAffineTile", parameters: ["inputTransform": CGAffineTransform.identity])
            let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5))
                .cropped(to: CGRect(x: 40, y: 30, width: 200, height: 180))
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blur])
            let page = CIImage(color: CIColor(red: 0.9, green: 0.4, blue: shade, alpha: 0.75))
                .cropped(to: CGRect(x: 50, y: 40, width: 180, height: 160))
            return page.composited(over: shadow.composited(over: checker.cropped(to: bounds))).cropped(to: bounds)
        }
        func pixels(_ image: CIImage, _ context: CIContext) -> [Float] {
            var values = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
            values.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(bounds.width) * 16, bounds: bounds,
                               format: .RGBAf, colorSpace: nil)
            }
            return values
        }
        func matches(_ image: CIImage) -> Bool {
            zip(pixels(image, hardware), pixels(image, software)).allSatisfy { $0.bitPattern == $1.bitPattern }
        }
        let original = frame(0.8, 8, 6)
        #expect(matches(original))
        let uploaded = hardware.gpuUploadBytes
        #expect(matches(original))
        #expect(hardware.gpuUploadBytes == uploaded, "an unchanged frame uploaded its generated inputs again")
        for changed in [frame(0.6, 8, 6), frame(0.8, 12, 6), frame(0.8, 8, 9), original] { #expect(matches(changed)) }
        #expect(hardware.gpuFusedSubmissionCount > 0)
    }
}
