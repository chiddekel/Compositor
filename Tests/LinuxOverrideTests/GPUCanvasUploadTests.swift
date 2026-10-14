import Foundation
import CoreGraphics
@testable import CoreImage
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct GPUCanvasUploadTests {
    @Test(arguments: ["identity", "shift", "flip", "fractional"])
    func immutableGeometryLeavesReuseUploadsAndInvalidateOnChanges(kind: String) throws {
        let hardware = CIContext(options: [.workingColorSpace: DeepLayer.hdrSpace, .hardwareCanvas: true])
        guard hardware.gpuAvailable else {
            if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" {
                Issue.record("Hardware canvas unavailable")
            }
            return
        }
        let software = CIContext(options: [.workingColorSpace: DeepLayer.hdrSpace, .useSoftwareRenderer: true])
        let width = 256, height = 256, bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func source(_ red: UInt8) -> CIImage {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = red + UInt8((x * 3 + y * 5) % 31)
                bytes[offset + 1] = UInt8(128 + y % 50)
                bytes[offset + 2] = 192
            } }
            return CIImage(cgImage: CGImage(PortableImage(width: width, height: height, kind: .rgba,
                bytesPerRow: width * 4, bytes: bytes)))
        }
        let original = source(64)
        let transform: CGAffineTransform
        switch kind {
        case "shift": transform = CGAffineTransform(translationX: 3, y: -5)
        case "flip": transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        case "fractional": transform = CGAffineTransform(translationX: 0.25, y: -0.5)
        default: transform = .identity
        }
        func frame(_ image: CIImage, _ placement: CGAffineTransform) -> CIImage {
            image.samplingNearest().clampedToExtent().transformed(by: placement)
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.75)])
                .cropped(to: bounds).composited(over: CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: bounds))
        }
        func render(_ image: CIImage, _ context: CIContext, region: CGRect? = nil) -> [Float] {
            var output = [Float](repeating: 0, count: width * height * 4)
            output.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: region ?? bounds, format: .RGBAf, colorSpace: DeepLayer.hdrSpace)
            }
            return output
        }
        let initial = frame(original, transform), first = render(initial, hardware)
        #expect(first.map(\.bitPattern) == render(initial, software).map(\.bitPattern))
        let uploads = hardware.gpuUploadBytes, submissions = hardware.gpuSubmissionCount
        #expect(submissions == 1)
        #expect(render(initial, hardware).map(\.bitPattern) == first.map(\.bitPattern))
        #expect(hardware.gpuSubmissionCount == submissions + 1)
        #expect(hardware.gpuUploadBytes - uploads < uploads)
        for changed in [frame(original, transform.concatenating(CGAffineTransform(translationX: 1, y: 2))),
                        frame(source(192), transform)] {
            let actual = render(changed, hardware), expected = render(changed, software)
            #expect(expected.map(\.bitPattern) != first.map(\.bitPattern))
            #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
        }
        let shiftedBounds = bounds.offsetBy(dx: 17, dy: -11)
        let shifted = render(initial, hardware, region: shiftedBounds)
        let shiftedExpected = render(initial, software, region: shiftedBounds)
        #expect(shiftedExpected.map(\.bitPattern) != first.map(\.bitPattern))
        #expect(shifted.map(\.bitPattern) == shiftedExpected.map(\.bitPattern))
        #expect(render(initial, hardware).map(\.bitPattern) == first.map(\.bitPattern))
    }

    @Test(arguments: ["whole", "inside", "partial", "left", "right", "above", "below", "fractional", "fractionalSource", "corner"], [false, true])
    func clampedRowsMatchPixelOracle(kind: String, exceptional: Bool) {
        var input = Raster(rect: CGRect(x: kind == "fractionalSource" ? -2.5 : -2,
                                       y: kind == "fractionalSource" ? 3.5 : 3, width: 5, height: 4))
        for i in input.data.indices { input.data[i] = Float(i % 19 - 7) / 13 }
        if exceptional {
            input.data[7] = .nan; input.data[21] = .infinity; input.data[25] = Float(bitPattern: 0x80000000)
        }
        let region: CGRect
        switch kind {
        case "whole": region = input.rect
        case "inside": region = CGRect(x: -1, y: 4, width: 3, height: 2)
        case "partial": region = CGRect(x: -4, y: 1, width: 9, height: 8)
        case "left": region = CGRect(x: -8, y: 3, width: 3, height: 4)
        case "right": region = CGRect(x: 5, y: 3, width: 3, height: 4)
        case "above": region = CGRect(x: -2, y: -4, width: 5, height: 3)
        case "below": region = CGRect(x: -2, y: 8, width: 5, height: 3)
        case "fractional", "fractionalSource": region = CGRect(x: -1.5, y: 4.5, width: 3, height: 2)
        default: region = CGRect(x: -10, y: -10, width: 3, height: 3)
        }
        var expected = Raster(rect: region)
        for y in 0..<expected.height { for x in 0..<expected.width {
            let pixel = input.clamped(Int(region.minX) + x - Int(input.rect.minX),
                                      Int(region.minY) + y - Int(input.rect.minY))
            let i = expected.index(x, y)
            expected.data[i] = pixel.0; expected.data[i + 1] = pixel.1
            expected.data[i + 2] = pixel.2; expected.data[i + 3] = pixel.3
        } }
        #expect(input.clamped(to: region).data.map(\.bitPattern) == expected.data.map(\.bitPattern))
    }

    @Test(arguments: ["identity", "translate", "flipX", "flipY", "flipBoth", "fractional", "scale", "phase", "matchedPhase", "largeOrigin"], [false, true])
    func alignedTransformsMatchGeneralSampler(kind: String, nearest: Bool) {
        let fractionalOrigin = kind == "phase" || kind == "matchedPhase"
        var source = Raster(rect: CGRect(x: kind == "largeOrigin" ? 1e16 : fractionalOrigin ? -1.75 : -2,
                                       y: fractionalOrigin ? 3.5 : 3, width: 5, height: 4))
        for i in source.data.indices { source.data[i] = Float(i % 19 - 7) / 13 }
        var matrix: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        switch kind {
        case "translate": matrix[2] = 3; matrix[5] = -2
        case "flipX": matrix[0] = -1; matrix[2] = 2
        case "flipY": matrix[4] = -1; matrix[5] = 8
        case "flipBoth": matrix[0] = -1; matrix[4] = -1; matrix[2] = 2; matrix[5] = 8
        case "fractional": matrix[2] = 0.25; matrix[5] = -0.5
        case "scale": matrix[0] = 0.5; matrix[4] = 2
        default: break
        }
        let region = CGRect(x: kind == "largeOrigin" ? 1e16 : kind == "matchedPhase" ? -3.75 : -4,
                            y: kind == "matchedPhase" ? -0.5 : -1, width: 11, height: 11)
        let actual = RasterFilters.projective(source, inverse: matrix, output: region, nearest: nearest)
        let expected = generalSampler(source, inverse: matrix, output: region, nearest: nearest)
        #expect(actual.data.map(\.bitPattern) == expected.data.map(\.bitPattern))
    }

    @Test(arguments: [Float(bitPattern: 0x80000000), Float.leastNonzeroMagnitude, Float.infinity, Float.nan])
    func alignedTransformsPreserveExceptionalSampleArithmetic(value: Float) {
        var source = Raster(rect: CGRect(x: 0, y: 0, width: 3, height: 3))
        source.data = [Float](repeating: 0.5, count: 36)
        source.data[16] = value
        let matrix: [Double] = [1, 0, 0, 0, -1, 3, 0, 0, 1]
        let actual = RasterFilters.projective(source, inverse: matrix, output: source.rect)
        let expected = generalSampler(source, inverse: matrix, output: source.rect, nearest: false)
        #expect(actual.data.map(\.bitPattern) == expected.data.map(\.bitPattern))
    }

    private func generalSampler(_ input: Raster, inverse m: [Double], output region: CGRect, nearest: Bool) -> Raster {
        var out = Raster(rect: region)
        for y in 0..<out.height { for x in 0..<out.width {
            let px = Double(out.rect.minX) + Double(x) + 0.5, py = Double(out.rect.minY) + Double(y) + 0.5
            let w = m[6] * px + m[7] * py + m[8]
            guard abs(w) > 1e-12 else { continue }
            let sx = (m[0] * px + m[1] * py + m[2]) / w - Double(input.rect.minX)
            let sy = (m[3] * px + m[4] * py + m[5]) / w - Double(input.rect.minY)
            let pixel = nearest ? input.nearest(sx, sy) : input.bilinear(sx, sy)
            let index = out.index(x, y)
            out.data[index] = pixel.0; out.data[index + 1] = pixel.1
            out.data[index + 2] = pixel.2; out.data[index + 3] = pixel.3
        } }
        return out
    }

    @Test
    func cpuLeafTransformsPreservePixelsAndReportCost() {
        let width = 512, height = 512
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            bytes[i] = UInt8(20 + (x * 7 + y) % 200)
            bytes[i + 1] = UInt8(40 + (x + y * 3) % 150)
            bytes[i + 2] = UInt8(60 + (x * 3 + y) % 120)
        } }
        let source = CIImage(cgImage: CGImage(PortableImage(width: width, height: height, kind: .rgba,
                                                           bytesPerRow: width * 4, bytes: bytes)))
        let identity = source.transformed(by: .identity)
        let clamped = source.clampedToExtent()
        let flip = source.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
        let evaluator = CIContext(options: [.workingColorSpace: DeepLayer.hdrSpace, .useSoftwareRenderer: true])
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func render(_ image: CIImage) -> [Float] {
            var output = [Float](repeating: 0, count: width * height * 4)
            output.withUnsafeMutableBytes {
                evaluator.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                                 bounds: bounds, format: .RGBAf, colorSpace: DeepLayer.hdrSpace)
            }
            return output
        }
        let original = render(source)
        #expect(zip(render(clamped), original).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(zip(render(identity), original).allSatisfy { $0.bitPattern == $1.bitPattern })
        var reversed: [Float] = []
        for y in (0..<height).reversed() {
            reversed.append(contentsOf: original[(y * width * 4)..<((y + 1) * width * 4)])
        }
        #expect(zip(render(flip), reversed).allSatisfy { $0.bitPattern == $1.bitPattern })
        func mean(_ image: CIImage) -> Double {
            _ = render(image)
            let start = ContinuousClock.now
            for _ in 0..<5 { _ = render(image) }
            let elapsed = start.duration(to: .now).components
            return (Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) / 5
        }
        print("CPU canvas leaf 512x512: source \(mean(source)) ms, identity \(mean(identity)) ms, vertical flip \(mean(flip)) ms, clamped \(mean(clamped)) ms")
    }

    @Test(arguments: ["uint8", "uint16", "half", "float32"], [false, true])
    func uploadMatchesUpstreamTextureFormat(depth: String, mask: Bool) throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let width = 4, height = 3
        let hdr = depth == "half" || depth == "float32"
        var values: [Float] = []
        for y in 0..<height { for x in 0..<width {
            let alpha = Float(0.31 + Double(x + y) * 0.11)
            values += [(hdr ? 1.83 : 0.47) * alpha, (hdr ? -0.13 : 0.23) * alpha,
                       (0.63 + Float(y) * 0.017) * alpha, alpha]
        } }
        let bytes: [UInt8], format: PortableImage.Depth, stride: Int
        switch depth {
        case "uint8":
            bytes = values.map { UInt8(($0 * 255).rounded()) }; format = .uint8; stride = width * 4
        case "uint16":
            bytes = values.map { UInt16(($0 * 65535).rounded()) }.withUnsafeBytes { Array($0) }
            format = .uint16; stride = width * 8
        case "half":
            bytes = values.map { Float16($0) }.withUnsafeBytes { Array($0) }
            format = .half; stride = width * 8
        default:
            bytes = values.withUnsafeBytes { Array($0) }; format = .float32; stride = width * 16
        }
        let source = CGImage(PortableImage(width: width, height: height, kind: .rgba, depth: format,
                                           bytesPerRow: stride, bytes: bytes))
        // Upstream GPUCanvas.upload copies 16-bit SDR to rgba16Unorm, other SDR to rgba8Unorm and HDR to rgba16Float;
        // the texture rows are top-down. Masks use its opaque gray-copy path.
        let canonical = try mask ? GPUCanvasRenderer.grayCopy(source)
            : hdr ? DeepLayer.hdr(source) : depth == "uint16" ? DeepLayer.canonical(source) : BrushRaster.copy(source)
        let expected = CIImage(cgImage: try #require(canonical.makeImage()))
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
        let actual = try #require(renderer.image(source, mask: mask))
        let evaluator = CIContext(options: [.workingColorSpace: DeepLayer.hdrSpace, .useSoftwareRenderer: true])
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func render(_ image: CIImage) -> [Float] {
            var output = [Float](repeating: 0, count: width * height * 4)
            output.withUnsafeMutableBytes {
                evaluator.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                                 bounds: bounds, format: .RGBAf, colorSpace: DeepLayer.hdrSpace)
            }
            return output
        }
        #expect(render(actual).map(\.bitPattern) == render(expected).map(\.bitPattern))
    }
}
