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
    var paths = Array(CommandLine.arguments.dropFirst())
    let whiteBalance = paths.first == "--white-balance"
    if whiteBalance { paths.removeFirst() }
    guard #available(macOS 26.0, *), paths.count == 6 else {
        throw CaptureError.failed("Requires macOS 26 and the five canonical DNGs plus precision-ramp.dng")
    }
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    // Keep RawImporter's half-float, linear-light working context. Float output separates
    // Apple's tone interpretation from the final integer quantization and upstream dither.
    let context = CIContext(options: [.useSoftwareRenderer: false, .workingFormat: CIFormat.RGBAh,
                                     .workingColorSpace: linear])
    var controls: [(String, Float?, Float?, Float?, Float?)] = [
        ("decoder-default", nil, nil, nil, nil),
        ("boost-0", 0, 0, nil, nil), ("boost-0.5", 0, 0.5, nil, nil), ("boost-1", 0, 1, nil, nil),
        ("exposure-minus-1-boost-0", -1, 0, nil, nil), ("exposure-plus-1-boost-0", 1, 0, nil, nil),
        ("exposure-minus-1-boost-1", -1, 1, nil, nil), ("exposure-plus-1-boost-1", 1, 1, nil, nil),
    ]
    if whiteBalance {
        for boost in [Float(0), Float(1)] {
            let suffix = Int(boost)
            controls += [("temperature-3000-boost-\(suffix)", 0, boost, 3000, nil),
                         ("temperature-8000-boost-\(suffix)", 0, boost, 8000, nil),
                         ("tint-minus-50-boost-\(suffix)", 0, boost, nil, -50),
                         ("tint-plus-50-boost-\(suffix)", 0, boost, nil, 50)]
        }
    }
    var inputs = [[String: Any]]()
    for path in paths {
        let url = URL(fileURLWithPath: path)
        var cases = [[String: Any]]()
        for (name, exposure, boost, temperature, tint) in controls {
            // A fresh decoder makes every recipe independent of preceding slider changes.
            guard let filter = CIRAWFilter(imageURL: url) else {
                throw CaptureError.failed("Cannot open \(url.lastPathComponent)")
            }
            let defaults: [String: Any] = ["exposure": filter.exposure, "boost": filter.boostAmount,
                "temperature": filter.neutralTemperature, "tint": filter.neutralTint,
                "scale": filter.scaleFactor, "draft": filter.isDraftModeEnabled]
            if let exposure { filter.exposure = exposure }
            if let boost { filter.boostAmount = boost }
            if let temperature { filter.neutralTemperature = temperature }
            if let tint { filter.neutralTint = tint }
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
    return ["schema": whiteBalance ? 2 : 1, "platform": "macOS", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
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
