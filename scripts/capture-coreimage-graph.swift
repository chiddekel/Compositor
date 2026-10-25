// Native filter diagnostics, with output hashes to check against the independent bitmap captures.
#if os(macOS)
import Foundation
import CoreGraphics
import CoreImage
import CryptoKit

enum CaptureError: Error { case failed(String) }

let width = 96, height = 72
let bounds = CGRect(x: 0, y: 0, width: width, height: height)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func probeRadii() throws -> [Double] {
    let defaults = [0.0, 0.1, 0.125, 1 / 6.0 - 0.000001, 1 / 6.0, 1 / 6.0 + 0.000001, 0.2, 0.25, 0.3, 0.4, 0.5]
    guard CommandLine.arguments.count != 1 else { return defaults }
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--small-radii" else {
        throw CaptureError.failed("Expected --small-radii followed by a JSON number array")
    }
    let values = try JSONDecoder().decode([Double].self, from: Data(CommandLine.arguments[2].utf8))
    guard values.count <= 64, Set(values).count == values.count,
          values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
        throw CaptureError.failed("Probe radii must be unique finite numbers in 0...1, at most 64")
    }
    return values.isEmpty ? defaults : values
}

func bitmap() throws -> CGContext {
    guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw CaptureError.failed("Cannot allocate bitmap")
    }
    return result
}

func extent(_ image: CIImage) -> [String: Any] {
    let rect = image.extent
    if rect.isInfinite { return ["infinite": true] }
    if rect.isNull { return ["null": true] }
    return ["x": Double(rect.minX), "y": Double(rect.minY),
            "width": Double(rect.width), "height": Double(rect.height)]
}

func snapshot(_ image: CIImage, includePixels: Bool = false) throws -> [String: Any] {
    let before = image.debugDescription
    var floats = [Float](repeating: 0, count: width * height * 4)
    floats.withUnsafeMutableBytes { buffer in
        context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                       bounds: bounds, format: .RGBAf, colorSpace: space)
    }
    guard floats.allSatisfy(\.isFinite) else { throw CaptureError.failed("Nonfinite native components") }
    let floatData = floats.withUnsafeBytes { Data($0) }
    guard let rendered = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: space),
          rendered.width == width, rendered.height == height else {
        throw CaptureError.failed("Cannot create a fixed-size native image")
    }
    let target = try bitmap()
    target.setBlendMode(.copy)
    target.draw(rendered, in: bounds)
    guard let pixels = target.data else { throw CaptureError.failed("Missing rendered bitmap pixels") }
    var bytes = Data()
    for y in 0..<height {
        bytes.append(pixels.advanced(by: y * target.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * 4)
    }
    let after = image.debugDescription
    var result: [String: Any] = ["width": width, "height": height, "floatBytes": floatData.count, "byteBytes": bytes.count,
            "floatSha256": digest(floatData), "byteSha256": digest(bytes), "floatFinite": true,
            "descriptionBeforeRender": String(before.prefix(65_536)),
            "descriptionAfterRender": String(after.prefix(65_536)),
            "descriptionTruncated": before.count > 65_536 || after.count > 65_536]
    if includePixels { result["rgbaBase64"] = bytes.base64EncodedString() }
    return result
}

func capture() throws -> [String: Any] {
    let radii = try probeRadii()
    var inputs = [[String: Any]](), cases = [[String: Any]]()
    var sources = [(String, CIImage)]()
    for fixture in ["opaque-gradient", "impulse"] {
        let source = try bitmap()
        guard let pixels = source.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CaptureError.failed("Missing source pixels")
        }
        for y in 0..<height { for x in 0..<width {
            let at = y * source.bytesPerRow + x * 4
            if fixture == "opaque-gradient" {
                pixels[at] = UInt8(x * 255 / (width - 1)); pixels[at + 1] = UInt8(y * 255 / (height - 1))
                pixels[at + 2] = 100; pixels[at + 3] = 255
            } else {
                let value: UInt8 = x == width / 2 && y == height / 2 ? 255 : 0
                for channel in 0..<4 { pixels[at + channel] = value }
            }
        } }
        guard let image = source.makeImage() else { throw CaptureError.failed("Cannot create source image") }
        let input = CIImage(cgImage: image)
        sources.append((fixture, input))
        inputs.append(["fixture": fixture, "output": try snapshot(input)])
        for radius in [0.0, 0.1, 0.5, 1 / sqrt(3.0), 1, 2, 5, 10, 17, 35] {
            let output = input.applyingGaussianBlur(sigma: radius)
            cases.append(["fixture": fixture, "filter": "CIGaussianBlur", "radius": radius,
                          "outputExtent": extent(output), "output": try snapshot(output)])
        }
        for radius in [0.0, 0.1, 0.5, 1 / sqrt(3.0), 1, 2, 10 / sqrt(12.0), 35 / sqrt(12.0)] {
            for degrees in [0.0, -35, 35, 37, 90, -90, 180, 360, 0.125] {
                guard let filter = CIFilter(name: "CIMotionBlur", parameters: [
                    kCIInputImageKey: input, kCIInputRadiusKey: radius, kCIInputAngleKey: degrees * .pi / 180]),
                      let output = filter.outputImage else { throw CaptureError.failed("Cannot create motion filter") }
                cases.append(["fixture": fixture, "filter": "CIMotionBlur", "radius": radius, "degrees": degrees,
                              "outputExtent": extent(output), "output": try snapshot(output)])
            }
        }
    }
    // Keep the original recipes' render order before checking the identity-to-blur boundary.
    var probes = [[String: Any]]()
    for (fixture, input) in sources {
        for radius in radii {
            for degrees in [0.0, -35] {
                let output = input.applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: radius, kCIInputAngleKey: degrees * .pi / 180])
                probes.append(["fixture": fixture, "filter": "CIMotionBlur", "radius": radius, "degrees": degrees,
                               "outputExtent": extent(output), "output": try snapshot(output, includePixels: true)])
            }
        }
    }
    return ["schema": 1, "platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scriptSha256": digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))),
            "contextDescription": String(context.debugDescription.prefix(65_536)),
            "recipe": "Unmanaged shared CIContext; finite RGBA8 sources; RGBAf bitmap and RGBA8 CGImage copied into an identity bitmap",
            "diagnosticDescriptions": true, "inputs": inputs, "cases": cases,
            "probeRadii": radii, "smallRadiusProbes": probes]
}

do {
    let data = try JSONSerialization.data(withJSONObject: capture(), options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Core Image graph capture failed: \(error)\n".utf8))
    exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("Core Image graph capture requires native macOS.\n".utf8))
exit(1)
#endif
