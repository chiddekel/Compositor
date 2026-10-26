// Independent native controls for unsharp normalization, blur sampling and working precision.
#if os(macOS)
import Foundation
import CoreGraphics
import CoreImage
import CryptoKit
import Metal

enum CaptureError: Error { case failed(String) }
let width = 24, height = 16
let bounds = CGRect(x: 0, y: 0, width: width, height: height)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let radii = [0.1, 1 / 6.0 - 0.000001, 1 / 6.0, 1 / 6.0 + 0.000001,
             0.17, 0.18, 0.2, 0.3, 0.4, 0.5, 1, 1.1, 1.2, 2, 5]
let intensities = [0.0, 0.5, 1, 2]

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func source(_ name: String) throws -> (CIImage, Data, String) {
    if name == "float-hdr" {
        var values = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let alpha: Float = [0, 0.25, 0.5, 1][(x / 6 + y / 4) % 4]
            let i = (y * width + x) * 4
            values[i] = (Float(x) / Float(width - 1) * 3 - 0.5) * alpha
            values[i + 1] = Float(y) / Float(height - 1) * alpha
            values[i + 2] = 1.25 * alpha
            values[i + 3] = alpha
        } }
        let data = values.withUnsafeBytes { Data($0) }
        return (CIImage(bitmapData: data, bytesPerRow: width * 16, size: bounds.size,
                        format: .RGBAf, colorSpace: space), data, "RGBAf")
    }
    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self) else {
        throw CaptureError.failed("Cannot allocate byte source")
    }
    for y in 0..<height { for x in 0..<width {
        if name == "impulse" {
            let value: UInt8 = x == width / 2 && y == height / 2 ? 255 : 0
            let i = y * bitmap.bytesPerRow + x * 4
            for channel in 0..<4 { pixels[i + channel] = value }
            continue
        }
        let alpha = name == "overlay-gradient" ? (x < 3 || y < 3 || x > 20 || y > 12 ? 0 : 160) : 255
        let i = y * bitmap.bytesPerRow + x * 4
        pixels[i] = UInt8((x * 255 / (width - 1)) * alpha / 255)
        pixels[i + 1] = UInt8((y * 255 / (height - 1)) * alpha / 255)
        pixels[i + 2] = UInt8((name == "overlay-gradient" ? 220 : 100) * alpha / 255)
        pixels[i + 3] = UInt8(alpha)
    } }
    guard let image = bitmap.makeImage() else { throw CaptureError.failed("Cannot make byte image") }
    return (CIImage(cgImage: image), Data(bytes: pixels, count: width * height * 4), "RGBA8")
}

func snapshot(_ image: CIImage, context: CIContext) throws -> [String: Any] {
    var floats = [Float](repeating: 0, count: width * height * 4)
    floats.withUnsafeMutableBytes {
        context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                       bounds: bounds, format: .RGBAf, colorSpace: space)
    }
    guard floats.allSatisfy(\.isFinite) else { throw CaptureError.failed("Nonfinite native output") }
    let floatData = floats.withUnsafeBytes { Data($0) }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes {
        context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                       bounds: bounds, format: .RGBA8, colorSpace: space)
    }
    let byteData = Data(bytes)
    let description = image.debugDescription
    guard description.count <= 65_536 else { throw CaptureError.failed("Native graph description too large") }
    return ["floatBase64": floatData.base64EncodedString(), "floatSHA256": digest(floatData),
            "rgbaBase64": byteData.base64EncodedString(), "rgbaSHA256": digest(byteData),
            "description": description]
}

func capture() throws -> [String: Any] {
    guard let device = MTLCreateSystemDefaultDevice() else { throw CaptureError.failed("Native Metal device required") }
    var inputs = [[String: Any]](), cases = [[String: Any]]()
    for fixture in ["opaque-gradient", "overlay-gradient", "float-hdr", "impulse"] {
        let (image, data, sourceFormat) = try source(fixture)
        for (formatName, format) in [("RGBAh", CIFormat.RGBAh), ("RGBAf", CIFormat.RGBAf)] {
            let context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(),
                .outputColorSpace: NSNull(), .workingFormat: format])
            inputs.append(["fixture": fixture, "workingFormat": formatName, "sourceFormat": sourceFormat,
                "sourceBase64": data.base64EncodedString(), "sourceSHA256": digest(data),
                "output": try snapshot(image, context: context)])
            for clamped in [false, true] {
                let input = clamped ? image.clampedToExtent() : image
                for radius in radii {
                    cases.append(["fixture": fixture, "workingFormat": formatName, "clamped": clamped,
                        "filter": "CIGaussianBlur", "radius": radius,
                        "output": try snapshot(input.applyingGaussianBlur(sigma: radius), context: context)])
                    for intensity in intensities {
                        let result = input.applyingFilter("CIUnsharpMask", parameters: [
                            kCIInputRadiusKey: radius, kCIInputIntensityKey: intensity])
                        cases.append(["fixture": fixture, "workingFormat": formatName, "clamped": clamped,
                            "filter": "CIUnsharpMask", "radius": radius, "intensity": intensity,
                            "output": try snapshot(result, context: context)])
                    }
                }
            }
        }
    }
    return ["schema": 1, "platform": "macOS", "device": device.name,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "scriptSHA256": digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))),
        "width": width, "height": height, "radii": radii, "intensities": intensities,
        "inputs": inputs, "cases": cases]
}

do {
    let result = try capture()
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("Native unsharp capture failed: \(error)\n".utf8))
    exit(1)
}
#else
fatalError("Native unsharp capture requires macOS")
#endif
