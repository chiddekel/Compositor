// Capture native ImageIO's conversion of every valid premultiplied byte/alpha pair.
#if os(macOS)
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

enum CaptureError: Error { case failed(String) }
func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func capture() throws -> [String: Any] {
    guard CommandLine.arguments.count == 2 else { throw CaptureError.failed("Expected PNG output path") }
    let width = 256, height = 256
    var pixels = [UInt8]()
    for a in 0..<height { for x in 0..<width {
        pixels += [UInt8(min(x, a)), UInt8(min((x * 73) % 256, a)), UInt8(min((x * 151 + 17) % 256, a)), UInt8(a)]
    } }
    let data = Data(pixels)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
              bytesPerRow: width * 4, space: space,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw CaptureError.failed("Cannot create native premultiplied image")
    }
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
        throw CaptureError.failed("Cannot create native PNG encoder")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CaptureError.failed("Native PNG export failed") }
    let encoded = png as Data
    try encoded.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    return ["schema": 1, "platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "width": width, "height": height, "sourceLayout": "RGBA8-premultipliedLast-byteOrder32Big-sRGB",
        "sourceSHA256": digest(data), "pngSHA256": digest(encoded), "validColorAlphaPairs": 32896,
        "scriptSHA256": digest(try Data(contentsOf: URL(fileURLWithPath: #filePath)))]
}
do {
    let data = try JSONSerialization.data(withJSONObject: capture(), options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("Native PNG capture failed: \(error)\n".utf8)); exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("Native PNG capture requires macOS.\n".utf8)); exit(1)
#endif
