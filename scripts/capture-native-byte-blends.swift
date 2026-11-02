// Capture Core Graphics byte compositing independently of the Linux graphics backend.
#if os(macOS)
import Foundation
import CoreGraphics
import CryptoKit

enum CaptureError: Error { case failed(String) }
func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func capture() throws -> [String: Any] {
    guard CommandLine.arguments.count == 2 else { throw CaptureError.failed("Expected output directory") }
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let side = 256
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CaptureError.failed("sRGB") }
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    var cases = [[String: Any]]()
    for opaque in [true, false] {
        var source = [UInt8](), backdrop = [UInt8]()
        for a in 0..<side { for v in 0..<side {
            let da = opaque ? 255 : v
            source += [UInt8(32 * a / 255), UInt8(43 * a / 255), UInt8(220 * a / 255), UInt8(a)]
            backdrop += [UInt8(v * da / 255), UInt8((255 - v) * da / 255), UInt8(100 * da / 255), UInt8(da)]
        } }
        let sourceData = Data(source), backdropData = Data(backdrop)
        guard let provider = CGDataProvider(data: sourceData as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: side * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CaptureError.failed("Source image")
        }
        for mode in 0...15 { for divisor in [1, 2, 4] {
            var pixels = backdrop
            try pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: info),
                    let blend = CGBlendMode(rawValue: Int32(mode)) else { throw CaptureError.failed("Bitmap context or blend mode") }
                context.interpolationQuality = .none
                context.setShouldAntialias(false)
                context.setBlendMode(blend)
                context.setAlpha(1 / Double(divisor))
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            let name = "mode-\(mode)-divisor-\(divisor)-opaque-\(opaque).rgba"
            let data = Data(pixels)
            try data.write(to: output.appendingPathComponent(name))
            cases.append(["mode": mode, "divisor": divisor, "opaqueBackdrop": opaque,
                "file": name, "sourceSHA256": digest(sourceData), "backdropSHA256": digest(backdropData),
                "outputSHA256": digest(data)])
        } }
    }
    return ["schema": 1, "platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "width": side, "height": side, "layout": "RGBA8-premultipliedLast-byteOrder32Big-sRGB",
        "scriptSHA256": digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))), "cases": cases]
}
do {
    let data = try JSONSerialization.data(withJSONObject: capture(), options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("Native byte blend capture failed: \(error)\n".utf8)); exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("Native byte blend capture requires macOS.\n".utf8)); exit(1)
#endif
