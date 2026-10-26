// Native scanline probes for identifying spatial filters independently of their output quantization.
#if os(macOS)
import Foundation
import CoreGraphics
import CoreImage
import CryptoKit

enum CaptureError: Error { case failed(String) }

let width = 512, height = 8
let row = CGRect(x: 0, y: 3, width: width, height: 1)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
let defaultMotionRadii = [0.0, 0.5, 1, 2, 3, 4, 5, 6, 7, 8, 10, 35 / sqrt(12.0), 12, 17, 24, 35]
let gaussianRadii = [5.0, 10, 17]

func requestedMotionRadii() throws -> [Double] {
    guard CommandLine.arguments.count != 1 else { return defaultMotionRadii }
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--motion-radii" else {
        throw CaptureError.failed("Expected --motion-radii followed by a JSON number array")
    }
    let values = try JSONDecoder().decode([Double].self, from: Data(CommandLine.arguments[2].utf8))
    guard values.count <= 64, Set(values).count == values.count,
          values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 64 }) else {
        throw CaptureError.failed("Motion radii must be unique finite numbers in 0...64, at most 64")
    }
    return values.isEmpty ? defaultMotionRadii : values
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func bitmap(width: Int, height: Int) throws -> CGContext {
    guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw CaptureError.failed("Cannot allocate bitmap")
    }
    return result
}

func snapshot(_ image: CIImage) throws -> [String: Any] {
    var floats = [Float](repeating: 0, count: width * 4)
    floats.withUnsafeMutableBytes { buffer in
        context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                       bounds: row, format: .RGBAf, colorSpace: space)
    }
    guard floats.allSatisfy(\.isFinite) else { throw CaptureError.failed("Nonfinite native output") }
    let floatData = floats.withUnsafeBytes { Data($0) }
    guard let rendered = context.createCGImage(image, from: row, format: .RGBA8, colorSpace: space),
          rendered.width == width, rendered.height == 1 else {
        throw CaptureError.failed("Cannot render native scanline")
    }
    let target = try bitmap(width: width, height: 1)
    target.setBlendMode(.copy)
    target.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: 1))
    guard let pixels = target.data else { throw CaptureError.failed("Missing native bitmap pixels") }
    let bytes = Data(bytes: pixels, count: width * 4)
    let description = image.debugDescription
    guard description.count <= 65_536 else { throw CaptureError.failed("Native graph description truncated") }
    return ["width": width, "height": 1, "floatBytes": floatData.count, "byteBytes": bytes.count,
            "floatSha256": digest(floatData), "byteSha256": digest(bytes),
            "floatBase64": floatData.base64EncodedString(), "rgbaBase64": bytes.base64EncodedString(),
            "description": description]
}

func capture() throws -> [String: Any] {
    let motionRadii = try requestedMotionRadii()
    var inputs = [[String: Any]](), cases = [[String: Any]]()
    for fixture in ["impulse", "step", "stripes"] {
        for phase in 0..<16 {
            let source = try bitmap(width: width, height: height)
            guard let pixels = source.data?.assumingMemoryBound(to: UInt8.self) else {
                throw CaptureError.failed("Missing source pixels")
            }
            for y in 0..<height { for x in 0..<width {
                let value: UInt8
                switch fixture {
                case "impulse": value = x == width / 2 + phase ? 255 : 0
                case "step": value = x >= width / 2 + phase ? 255 : 0
                default: value = ((x + phase) / 7) % 2 == 0 ? 0 : 255
                }
                let at = y * source.bytesPerRow + x * 4
                pixels[at] = value; pixels[at + 1] = value; pixels[at + 2] = value; pixels[at + 3] = 255
            } }
            guard let image = source.makeImage() else { throw CaptureError.failed("Cannot create source image") }
            // Rows repeat and clamp vertically, isolating the horizontal response even for a 2D Gaussian.
            let input = CIImage(cgImage: image).clampedToExtent()
            inputs.append(["fixture": fixture, "phase": phase, "output": try snapshot(input)])
            for radius in motionRadii {
                let output = input.applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: radius, kCIInputAngleKey: 0.0])
                cases.append(["fixture": fixture, "phase": phase, "filter": "CIMotionBlur", "radius": radius,
                              "output": try snapshot(output)])
            }
            for radius in gaussianRadii {
                cases.append(["fixture": fixture, "phase": phase, "filter": "CIGaussianBlur", "radius": radius,
                              "output": try snapshot(input.applyingGaussianBlur(sigma: radius))])
            }
        }
    }
    return ["schema": 1, "platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scriptSha256": digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))),
            "contextDescription": String(context.debugDescription.prefix(65_536)),
            "recipe": "Opaque RGBA8 rows repeated vertically; clamped CIImage; unmanaged shared CIContext; native RGBAf and RGBA8 scanline at CI y=3",
            "sourceWidth": width, "sourceHeight": height, "scanlineY": 3,
            "motionRadii": motionRadii, "gaussianRadii": gaussianRadii,
            "inputs": inputs, "cases": cases]
}

do {
    let data = try JSONSerialization.data(withJSONObject: capture(), options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Core Image spatial capture failed: \(error)\n".utf8))
    exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("Core Image spatial capture requires native macOS.\n".utf8))
exit(1)
#endif
