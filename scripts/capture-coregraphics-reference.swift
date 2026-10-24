// Native Core Graphics samples for investigating high-quality image downsampling.
// The context and draw recipe match BrushRaster.context and DitherSettings.apply.
#if os(macOS)
import Foundation
import CoreGraphics
import CryptoKit

enum CaptureError: Error { case failed(String) }

func bitmap(width: Int, height: Int) throws -> CGContext {
    guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw CaptureError.failed("Cannot allocate native bitmap")
    }
    result.translateBy(x: 0, y: CGFloat(height))
    result.scaleBy(x: 1, y: -1)
    return result
}

func bytes(_ context: CGContext) throws -> Data {
    guard let data = context.data else { throw CaptureError.failed("Missing bitmap data") }
    var result = Data()
    for y in 0..<context.height {
        result.append(data.advanced(by: y * context.bytesPerRow).assumingMemoryBound(to: UInt8.self),
                      count: context.width * 4)
    }
    return result
}

func describe(_ context: CGContext) throws -> [String: Any] {
    let data = try bytes(context)
    return ["width": context.width, "height": context.height, "rowBytes": context.width * 4,
            "rgbaBase64": data.base64EncodedString(),
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
}

func capture() throws -> [String: Any] {
    let width = 96, height = 72
    var cases = [[String: Any]]()
    for fixture in ["overlay", "impulse-48", "impulse-49", "impulse-50", "impulse-51",
                    "vertical-48", "vertical-49", "constant"] {
        let source = try bitmap(width: width, height: height)
        guard let pointer = source.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CaptureError.failed("Missing source pixels")
        }
        for y in 0..<height { for x in 0..<width {
            let at = y * source.bytesPerRow + x * 4
            if fixture == "overlay" {
                let alpha = x < 12 || y < 12 || x > 80 || y > 58 ? 0 : 160
                pointer[at] = UInt8((x * 255 / (width - 1)) * alpha / 255)
                pointer[at + 1] = UInt8((y * 255 / (height - 1)) * alpha / 255)
                pointer[at + 2] = UInt8(220 * alpha / 255)
                pointer[at + 3] = UInt8(alpha)
            } else {
                let impulse = Int(fixture.split(separator: "-").last ?? "")
                let hit = fixture.hasPrefix("vertical") ? y == impulse : x == impulse
                pointer[at] = hit ? 255 : 127
                pointer[at + 1] = 63
                pointer[at + 2] = 191
                pointer[at + 3] = 255
            }
        } }
        guard let image = source.makeImage() else { throw CaptureError.failed("Cannot make source image") }
        for block in [1, 2, 6] {
            let small = try bitmap(width: (width + block - 1) / block, height: (height + block - 1) / block)
            small.saveGState()
            small.interpolationQuality = .high
            small.translateBy(x: 0, y: CGFloat(height) / CGFloat(block))
            small.scaleBy(x: 1, y: -1)
            small.setBlendMode(.copy)
            small.draw(image, in: CGRect(x: 0, y: 0,
                width: CGFloat(width) / CGFloat(block), height: CGFloat(height) / CGFloat(block)))
            small.restoreGState()
            cases.append(["fixture": fixture, "block": block, "input": try describe(source),
                          "output": try describe(small)])
        }
    }
    return ["schema": 1, "platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "format": "sRGB premultiplied RGBA8; packed bitmap-memory rows", "quality": "high",
            "recipe": "BrushRaster.context and the downsample stage of DitherSettings.apply", "cases": cases]
}

do {
    let result = try capture()
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Core Graphics capture failed: \(error)\n".utf8))
    exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("Core Graphics capture requires native macOS.\n".utf8))
exit(1)
#endif
