// Diagnostic controls for Apple's RAW tone interpretation; never a replacement parity oracle.
#if os(macOS)
import Foundation
import CoreImage
import CoreGraphics
import CryptoKit
import Metal

enum CaptureError: Error { case failed(String) }

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func capture() throws -> [String: Any] {
    guard #available(macOS 26.0, *), CommandLine.arguments.count == 7 else {
        throw CaptureError.failed("Requires macOS 26 and the five canonical DNGs plus precision-ramp.dng")
    }
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    // Keep RawImporter's half-float, linear-light working context. Float output separates
    // Apple's tone interpretation from the final integer quantization and upstream dither.
    let context = CIContext(options: [.useSoftwareRenderer: false, .workingFormat: CIFormat.RGBAh,
                                     .workingColorSpace: linear])
    let controls: [(String, Float?, Float?)] = [
        ("decoder-default", nil, nil),
        ("boost-0", 0, 0), ("boost-0.5", 0, 0.5), ("boost-1", 0, 1),
        ("exposure-minus-1-boost-0", -1, 0), ("exposure-plus-1-boost-0", 1, 0),
        ("exposure-minus-1-boost-1", -1, 1), ("exposure-plus-1-boost-1", 1, 1),
    ]
    var inputs = [[String: Any]]()
    for path in CommandLine.arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        var cases = [[String: Any]]()
        for (name, exposure, boost) in controls {
            // A fresh decoder makes every recipe independent of preceding slider changes.
            guard let filter = CIRAWFilter(imageURL: url) else {
                throw CaptureError.failed("Cannot open \(url.lastPathComponent)")
            }
            let defaults: [String: Any] = ["exposure": filter.exposure, "boost": filter.boostAmount,
                "temperature": filter.neutralTemperature, "tint": filter.neutralTint,
                "scale": filter.scaleFactor, "draft": filter.isDraftModeEnabled]
            if let exposure { filter.exposure = exposure }
            if let boost { filter.boostAmount = boost }
            guard let output = filter.outputImage else {
                throw CaptureError.failed("Cannot develop \(url.lastPathComponent) / \(name)")
            }
            let extent = output.extent.integral
            guard !extent.isInfinite, !extent.isNull, extent.width > 32, extent.height > 32 else {
                throw CaptureError.failed("Unexpected RAW extent \(extent)")
            }
            // Retain one interior row, excluding the demosaic boundary; no averaging or fitting.
            let sample = CGRect(x: extent.minX + 16, y: floor(extent.midY), width: extent.width - 32, height: 1)
            let width = Int(sample.width)
            var buffers = [[String: Any]]()
            for (spaceName, space, bits, format) in [
                ("extendedLinearSRGB", linear, 32, CIFormat.RGBAf),
                ("sRGB", srgb, 32, CIFormat.RGBAf),
                ("sRGB", srgb, 16, CIFormat.RGBA16),
            ] {
                let rowBytes = width * 4 * bits / 8
                var data = Data(count: rowBytes)
                data.withUnsafeMutableBytes { buffer in
                    context.render(output, toBitmap: buffer.baseAddress!, rowBytes: rowBytes,
                                   bounds: sample, format: format, colorSpace: space)
                }
                buffers.append(["colorSpace": spaceName, "bitsPerComponent": bits,
                    "width": width, "height": 1, "rowBytes": rowBytes,
                    "byteOrder": "little", "rgbaBase64": data.base64EncodedString(), "sha256": digest(data)])
            }
            cases.append(["name": name, "defaults": defaults,
                "settings": ["exposure": filter.exposure, "boost": filter.boostAmount,
                    "temperature": filter.neutralTemperature, "tint": filter.neutralTint,
                    "scale": filter.scaleFactor, "draft": filter.isDraftModeEnabled],
                "extent": [extent.minX, extent.minY, extent.width, extent.height],
                "sampleBounds": [sample.minX, sample.minY, sample.width, sample.height], "buffers": buffers])
        }
        inputs.append(["file": url.lastPathComponent, "sha256": digest(try Data(contentsOf: url)), "cases": cases])
    }
    return ["schema": 1, "platform": "macOS", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        "device": MTLCreateSystemDefaultDevice()?.name ?? "none",
        "workingFormat": "RGBAh", "workingColorSpace": "extendedLinearSRGB", "inputs": inputs]
}

do {
    let result = try JSONSerialization.data(withJSONObject: capture(), options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(result)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("RAW reference capture failed: \(error)\n".utf8))
    exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("RAW reference capture requires native macOS.\n".utf8))
exit(1)
#endif
