import Foundation
import CoreGraphics
import CoreImage
import Compression
import XCTest

final class NativeVariableBlurReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let schema: Int
        let width: Int
        let height: Int
        let cases: [Sample]
    }
    private struct Sample: Decodable {
        let group: String
        let fixture: String
        let radius: Double
        let maskIntensity: Double
        let phaseX: Int?
        let phaseY: Int?
        let renderMargin: Int?
        let maskKind: String?
        let geometryKind: String?
        let extent: [Double]?
        let rgbaDeflate: Data
        let floatsDeflate: Data
    }

    private func reference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-variable-blur-reference.json")
        let result = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(result.schema, 1)
        XCTAssertEqual(result.cases.count, 258)
        return result
    }

    private func decoded(_ data: Data, count: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: count)
        let actual = data.withUnsafeBytes { raw in
            compression_decode_buffer(&output, count, raw.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        XCTAssertEqual(actual, count)
        return output
    }

    private func check(_ sample: Sample, in reference: Reference) throws {
        let width = reference.width, height = reference.height
        var pixels = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            if sample.fixture.hasPrefix("opaque-gradient") {
                pixels[x, y] = (UInt8(x * 255 / (width - 1)), UInt8(y * 255 / (height - 1)), 100, 255)
            } else {
                let value: UInt8 = x == width / 2 + (sample.phaseX ?? 0) && y == height / 2 + (sample.phaseY ?? 0) ? 255 : 0
                pixels[x, y] = (value, value, value, value)
            }
        } }
        var input = CIImage(cgImage: CGImage(pixels))
        if sample.fixture.hasSuffix("-clamped") { input = input.clampedToExtent() }
        switch sample.geometryKind {
        case "translated-positive": input = input.transformed(by: CGAffineTransform(translationX: 14, y: 8))
        case "translated-negative": input = input.transformed(by: CGAffineTransform(translationX: -13, y: -7))
        case "cropped": input = input.cropped(to: CGRect(x: 3, y: 5, width: 61, height: 37))
        default: break
        }
        let gray = sample.maskIntensity
        let mask: CIImage
        switch sample.maskKind {
        case "linear":
            mask = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: CGFloat(height)), "inputPoint1": CIVector(x: 0, y: 0),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white])?.outputImage)
        case "radial":
            mask = try XCTUnwrap(CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: CGFloat(width) / 2, y: CGFloat(height) / 2),
                "inputRadius0": 0, "inputRadius1": hypot(Double(width) / 2, Double(height) / 2),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white])?.outputImage)
        case "red": mask = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        case "green": mask = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
        case "blue": mask = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
        case "gray": mask = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        default: mask = CIImage(color: CIColor(red: gray, green: gray, blue: gray))
        }
        let image = sample.group == "mask-input" ? mask : input.applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": mask, kCIInputRadiusKey: sample.radius])
        if let extent = sample.extent {
            XCTAssertEqual(image.extent, CGRect(x: extent[0], y: extent[1], width: extent[2], height: extent[3]))
        }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let margin = sample.renderMargin ?? 0
        let renderWidth = width + margin * 2, renderHeight = height + margin * 2
        let bounds = CGRect(x: -margin, y: -margin, width: renderWidth, height: renderHeight)
        var floats = [Float](repeating: .nan, count: renderWidth * renderHeight * 4)
        floats.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: renderWidth * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: space)
        }
        let expectedFloatBytes = try decoded(sample.floatsDeflate, count: width * height * 16)
        var floatError: Float = 0
        expectedFloatBytes.withUnsafeBytes { raw in
            for y in 0..<height { for x in 0..<(width * 4) {
                let actual = floats[((y + margin) * renderWidth + margin) * 4 + x]
                if !actual.isFinite { floatError = .infinity; continue }
                let bits = raw.loadUnaligned(fromByteOffset: (y * width * 4 + x) * 4, as: UInt32.self)
                let expected = Float(bitPattern: UInt32(littleEndian: bits))
                floatError = max(floatError, abs(actual - expected))
            } }
        }
        let label = "\(sample.group) \(sample.fixture), r=\(sample.radius), mask=\(sample.maskKind ?? String(gray)), phase=\(sample.phaseX ?? 0),\(sample.phaseY ?? 0), margin=\(margin), geometry=\(sample.geometryKind ?? "identity")"
        XCTAssertLessThanOrEqual(floatError * 255, 1, label)
        let actualBytes: [UInt8]
        if sample.group == "request" {
            var expanded = [UInt8](repeating: 0, count: renderWidth * renderHeight * 4)
            expanded.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: renderWidth * 4,
                               bounds: bounds, format: .RGBA8, colorSpace: space)
            }
            actualBytes = (0..<height).flatMap { y in
                let start = ((y + margin) * renderWidth + margin) * 4
                return Array(expanded[start..<(start + width * 4)])
            }
        } else {
            actualBytes = try XCTUnwrap(context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: space)).portableImage.bytes
        }
        let expectedBytes = try decoded(sample.rgbaDeflate, count: width * height * 4)
        XCTAssertEqual(actualBytes.count, expectedBytes.count)
        let byteError = zip(actualBytes, expectedBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(byteError, 1, label)
    }

    func testDefaultFiniteRequestMatchesNative() throws {
        let reference = try reference()
        let sample = try XCTUnwrap(reference.cases.first {
            $0.group == "pyramid" && $0.fixture == "opaque-gradient" && $0.radius == 10 && $0.maskIntensity == 1
        })
        try check(sample, in: reference)
    }

    func testAllPyramidAndRequestSamplesMatchNative() throws {
        let reference = try reference()
        for sample in reference.cases { try check(sample, in: reference) }
    }

    func testVaryingBlurPreservesExtendedColorsAtInteractiveSizes() throws {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: true])
        let input = CIImage(color: CIColor(red: 4, green: -0.25, blue: 2, alpha: 0.5))
        let expected: [Float] = [2, -0.125, 1, 0.5]
        for (width, height) in [(512, 512), (1920, 1080)] {
            let mask = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: CGFloat(height)),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white])?.outputImage)
            let image = input.applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": mask, kCIInputRadiusKey: 35])
            var values = [Float](repeating: .nan, count: width * height * 4)
            let start = ProcessInfo.processInfo.systemUptime
            values.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                               bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            var worst: Float = 0
            for i in values.indices {
                worst = values[i].isFinite ? max(worst, abs(values[i] - expected[i % 4])) : .infinity
            }
            XCTAssertLessThanOrEqual(worst, 0.00001, "Extended premultiplied colors survive a varying blur")
            print("Variable blur CPU \(width)x\(height): \(milliseconds) ms; HDR max error \(worst)")
        }
    }
}
