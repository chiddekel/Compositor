// Native blur and sampling references using the same unmanaged CIContext as PixelAdjust.
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

func bitmap() throws -> CGContext {
    guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw CaptureError.failed("Cannot allocate bitmap")
    }
    return result
}

func padded(_ image: CGImage, margin: Int) throws -> CIImage {
    guard let target = CGContext(data: nil, width: image.width + margin * 2, height: image.height + margin * 2,
        bitsPerComponent: 8, bytesPerRow: (image.width + margin * 2) * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw CaptureError.failed("Cannot allocate padded bitmap")
    }
    target.setBlendMode(.copy)
    target.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
    guard let result = target.makeImage() else { throw CaptureError.failed("Cannot create padded source image") }
    return CIImage(cgImage: result)
}

func describe(_ data: Data, bits: Int) -> [String: Any] {
    ["width": width, "height": height, "rowBytes": width * 4 * bits / 8,
     "bitsPerComponent": bits, "rgbaBase64": data.base64EncodedString(), "sha256": digest(data)]
}

func render(_ image: CIImage, bitmapBytes: Bool = false) throws -> [String: Any] {
    var floats = [Float](repeating: 0, count: width * height * 4)
    floats.withUnsafeMutableBytes { buffer in
        context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                       bounds: bounds, format: .RGBAf, colorSpace: space)
    }
    let floatData = floats.withUnsafeBytes { Data($0) }
    if bitmapBytes {
        // A hard crop can make createCGImage return only the intersection (or nil for disjoint bounds).
        // toBitmap always records the requested fixed-size domain, including its transparent exterior.
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                           bounds: bounds, format: .RGBA8, colorSpace: space)
        }
        return ["float": describe(floatData, bits: 32), "byte": describe(bytes, bits: 8)]
    }
    guard let result = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: space) else {
        throw CaptureError.failed("Cannot create native RGBA8 image with extent \(image.extent)")
    }
    guard result.width == width, result.height == height else {
        throw CaptureError.failed("Unexpected native RGBA8 size \(result.width)x\(result.height) for extent \(image.extent)")
    }
    let target = try bitmap()
    target.setBlendMode(.copy)
    target.draw(result, in: bounds)
    guard let pixels = target.data else { throw CaptureError.failed("Missing bitmap pixels") }
    var bytes = Data()
    for y in 0..<height {
        bytes.append(pixels.advanced(by: y * target.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * 4)
    }
    return ["float": describe(floatData, bits: 32), "byte": describe(bytes, bits: 8)]
}

func renderRegion(_ image: CIImage, in rect: CGRect, freshContext: Bool) -> [String: Any] {
    let renderer = freshContext
        ? CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        : context
    let regionWidth = Int(rect.width), regionHeight = Int(rect.height)
    var floats = [Float](repeating: 0, count: regionWidth * regionHeight * 4)
    floats.withUnsafeMutableBytes { buffer in
        renderer.render(image, toBitmap: buffer.baseAddress!, rowBytes: regionWidth * 16,
                       bounds: rect, format: .RGBAf, colorSpace: space)
    }
    var bytes = Data(count: regionWidth * regionHeight * 4)
    bytes.withUnsafeMutableBytes { buffer in
        renderer.render(image, toBitmap: buffer.baseAddress!, rowBytes: regionWidth * 4,
                       bounds: rect, format: .RGBA8, colorSpace: space)
    }
    func packed(_ data: Data, bits: Int) -> [String: Any] {
        ["width": regionWidth, "height": regionHeight, "rowBytes": regionWidth * 4 * bits / 8,
         "bitsPerComponent": bits, "rgbaBase64": data.base64EncodedString(), "sha256": digest(data)]
    }
    return ["float": packed(floats.withUnsafeBytes { Data($0) }, bits: 32), "byte": packed(bytes, bits: 8)]
}

func filtered(_ name: String, input: CIImage, parameters: [String: Any]) throws -> CIImage {
    guard let filter = CIFilter(name: name, parameters: parameters.merging([kCIInputImageKey: input]) { _, input in input }),
          let output = filter.outputImage else { throw CaptureError.failed("Cannot create \(name)") }
    return output
}

func describeExtent(_ image: CIImage) -> [String: Any] {
    let rect = image.extent
    if rect.isInfinite { return ["infinite": true] }
    if rect.isNull { return ["null": true] }
    return ["x": Double(rect.minX), "y": Double(rect.minY),
            "width": Double(rect.width), "height": Double(rect.height)]
}

func captureWorkingPrecision() throws -> [[String: Any]] {
    var cases = [[String: Any]]()
    var renderers = [(String, CIContext)]()
    for name in ["default", "RGBAh", "RGBAf"] {
        var options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                             .cacheIntermediates: false]
        if name != "default" {
            options[.workingFormat] = NSNumber(value: (name == "RGBAh" ? CIFormat.RGBAh : CIFormat.RGBAf).rawValue)
        }
        renderers.append((name, CIContext(options: options)))
    }
    for floating in [false, true] {
        for fixture in ["opaque-rectangle", "step-x", "step-y", "impulse"] {
            for alphaLevel in [1.0, 0.5, 0.25] {
                let components = floating ? CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                                          : CGBitmapInfo.byteOrder32Big.rawValue
                guard let source = CGContext(data: nil, width: width, height: height, bitsPerComponent: floating ? 32 : 8,
                    bytesPerRow: width * (floating ? 16 : 4), space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | components), let pixels = source.data else {
                    throw CaptureError.failed("Cannot allocate working-precision source")
                }
                for y in 0..<height { for x in 0..<width {
                    let inside = fixture == "opaque-rectangle" || (fixture == "step-x" && x < width / 2)
                        || (fixture == "step-y" && y < height / 2)
                        || (fixture == "impulse" && x == width / 2 && y == height / 2)
                    let alpha = inside ? alphaLevel : 0
                    let values = [alpha * 0.25, alpha * 0.5, alpha * 0.75, alpha]
                    if floating {
                        let row = pixels.advanced(by: y * source.bytesPerRow).assumingMemoryBound(to: Float.self)
                        for c in 0..<4 { row[x * 4 + c] = Float(values[c]) }
                    } else {
                        let row = pixels.advanced(by: y * source.bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        for c in 0..<4 { row[x * 4 + c] = UInt8((values[c] * 255).rounded()) }
                    }
                } }
                guard let image = source.makeImage() else { throw CaptureError.failed("Cannot make working-precision image") }
                var inputBytes = Data()
                for y in 0..<height {
                    inputBytes.append(pixels.advanced(by: y * source.bytesPerRow).assumingMemoryBound(to: UInt8.self),
                                      count: width * (floating ? 16 : 4))
                }
                let input = CIImage(cgImage: image)
                for radius in [0.5, 1.0, 2.0, 5.0, 10.0, 17.0, 35.0] {
                    let blurred = input.applyingGaussianBlur(sigma: radius)
                    for (workingFormat, renderer) in renderers {
                        var floats = [Float](repeating: 0, count: width * height * 4)
                        floats.withUnsafeMutableBytes { buffer in
                            renderer.render(blurred, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                                            bounds: bounds, format: .RGBAf, colorSpace: space)
                        }
                        var bytes = Data(count: width * height * 4)
                        bytes.withUnsafeMutableBytes { buffer in
                            renderer.render(blurred, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                                            bounds: bounds, format: .RGBA8, colorSpace: space)
                        }
                        cases.append(["fixture": fixture, "alphaLevel": alphaLevel, "radius": radius,
                                      "sourceFormat": floating ? "RGBAf" : "RGBA8", "workingFormat": workingFormat,
                                      "contextPolicy": "shared-no-cache", "input": describe(inputBytes, bits: floating ? 32 : 8),
                                      "output": ["float": describe(floats.withUnsafeBytes { Data($0) }, bits: 32),
                                                 "byte": describe(bytes, bits: 8)]])
                    }
                }
            }
        }
    }
    return cases
}

func capture() throws -> [String: Any] {
    var inputs = [[String: Any]](), cases = [[String: Any]]()
    var regionalProbes: [(fixture: String, radius: Double, image: CIImage)] = []
    for fixture in ["opaque-gradient", "impulse"] {
        let source = try bitmap()
        guard let pixels = source.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CaptureError.failed("Missing source pixels")
        }
        for y in 0..<height { for x in 0..<width {
            let at = y * source.bytesPerRow + x * 4
            if fixture == "opaque-gradient" {
                pixels[at] = UInt8(x * 255 / (width - 1))
                pixels[at + 1] = UInt8(y * 255 / (height - 1))
                pixels[at + 2] = 100
                pixels[at + 3] = 255
            } else {
                let value: UInt8 = x == width / 2 && y == height / 2 ? 255 : 0
                for c in 0..<4 { pixels[at + c] = value }
            }
        } }
        guard let image = source.makeImage() else { throw CaptureError.failed("Cannot create source image") }
        let input = CIImage(cgImage: image)
        inputs.append(["fixture": fixture, "identity": try render(input)])
        let toneProfiles: [(String, [[Double]])] = [
            ("identity", [[0, 0], [0.25, 0.25], [0.5, 0.5], [0.75, 0.75], [1, 1]]),
            ("threshold-75", [[0, 0], [0.75, 0], [0.85, 0.25], [0.9375, 0.7], [1, 1]]),
            ("threshold-95", [[0, 0], [0.95, 0], [0.97, 0.25], [0.9875, 0.7], [1, 1]]),
            ("contrast", [[0, 0], [0.25, 0.15], [0.5, 0.5], [0.75, 0.85], [1, 1]])]
        for (profile, points) in toneProfiles {
            for gain in [1.0, 2.0] {
                let source = input.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                guard let filter = CIFilter(name: "CIToneCurve") else { throw CaptureError.failed("Missing CIToneCurve") }
                filter.setValue(source, forKey: kCIInputImageKey)
                for index in 0..<5 {
                    filter.setValue(CIVector(x: points[index][0], y: points[index][1]), forKey: "inputPoint\(index)")
                }
                guard let output = filter.outputImage else { throw CaptureError.failed("Missing tone curve output") }
                let extrapolate = filter.inputKeys.contains("inputExtrapolate") ? filter.value(forKey: "inputExtrapolate") : nil
                cases.append(["fixture": fixture, "filter": "CIToneCurve", "radius": 0, "profile": profile,
                              "points": points, "sourceGain": gain, "defaultExtrapolate": extrapolate ?? NSNull(),
                              "outputExtent": describeExtent(output), "output": try render(output)])
            }
        }
        for radius in [0.0, 0.1, 0.5, 1 / sqrt(3.0), 1, 2, 5, 10, 17, 35] {
            let output = try filtered("CIGaussianBlur", input: input, parameters: [kCIInputRadiusKey: radius])
            cases.append(["fixture": fixture, "filter": "CIGaussianBlur", "radius": radius,
                          "inputExtent": describeExtent(input), "outputExtent": describeExtent(output),
                          "output": try render(output)])
            if radius == 0.5 || radius == 5 {
                let magnified = output.transformed(by: CGAffineTransform(scaleX: 2, y: 1))
                cases.append(["fixture": fixture, "filter": "gaussian-magnified", "radius": radius,
                              "scaleX": 2, "blurredExtent": describeExtent(output),
                              "outputExtent": describeExtent(magnified), "output": try render(magnified)])
                regionalProbes.append((fixture, radius, magnified))
                for offset in [14.4, -14.4] {
                    let shifted = output.transformed(by: CGAffineTransform(translationX: CGFloat(offset), y: 0))
                    cases.append(["fixture": fixture, "filter": "gaussian-affine", "radius": radius,
                                  "translationX": offset, "blurredExtent": describeExtent(output),
                                  "outputExtent": describeExtent(shifted), "output": try render(shifted)])
                }
            }
            if radius == 10 {
                // The default Gaussian adjustment pads by its three-sigma halo plus two pixels.
                // Materialize that padding so graph fusion cannot remove the input-grid control.
                let margin = Int(ceil(radius * 3 + 2))
                let expanded = try padded(image, margin: margin)
                let restore = CGAffineTransform(translationX: -CGFloat(margin), y: -CGFloat(margin))
                cases.append(["fixture": fixture, "filter": "identity-padding", "radius": 0,
                              "sourcePadding": margin, "output": try render(expanded.transformed(by: restore))])
                let blurred = try filtered("CIGaussianBlur", input: expanded, parameters: [kCIInputRadiusKey: radius])
                cases.append(["fixture": fixture, "filter": "CIGaussianBlur", "radius": radius,
                              "sourcePadding": margin, "output": try render(blurred.transformed(by: restore))])
            }
        }
        for radius in [0.0, 0.1, 0.5, 1 / sqrt(3.0), 1, 2, 10 / sqrt(12.0), 35 / sqrt(12.0)] {
            // Cardinal and near-cardinal angles distinguish blur weights from rotation sampling.
            for degrees in [0.0, -35, 35, 90, -90, 180, 360, 0.125] {
                let output = try filtered("CIMotionBlur", input: input, parameters: [
                    kCIInputRadiusKey: radius, kCIInputAngleKey: degrees * .pi / 180])
                cases.append(["fixture": fixture, "filter": "CIMotionBlur", "radius": radius,
                              "degrees": degrees, "output": try render(output)])
            }
        }
        for aspect in [1.0, 0.5, 1 / 6.0, 1 / 12.0, 1 / 30.0, 1 / 90.0, 1 / 115.2] {
            let scaled = try filtered("CILanczosScaleTransform", input: input, parameters: [
                kCIInputScaleKey: 1.0, kCIInputAspectRatioKey: aspect])
            cases.append(["fixture": fixture, "filter": "CILanczosScaleTransform", "radius": 0,
                          "aspectRatio": aspect,
                          "extent": [Double(scaled.extent.minX), Double(scaled.extent.minY),
                                     Double(scaled.extent.width), Double(scaled.extent.height)],
                          "output": try render(scaled)])
            if aspect < 1 {
                let blurred = try filtered("CIGaussianBlur", input: scaled, parameters: [kCIInputRadiusKey: 0.5])
                let restored = blurred.transformed(by: CGAffineTransform(scaleX: CGFloat(1 / aspect), y: 1))
                cases.append(["fixture": fixture, "filter": "lanczos-gaussian-roundtrip", "radius": 0.5,
                              "aspectRatio": aspect, "scaledExtent": describeExtent(scaled),
                              "blurredExtent": describeExtent(blurred), "outputExtent": describeExtent(restored),
                              "output": try render(restored)])
            }
        }
        for offset in [14.4, -14.4, 14.688, -14.112] {
            let moved = input.transformed(by: CGAffineTransform(translationX: CGFloat(offset), y: 0))
            cases.append(["fixture": fixture, "filter": "CIAffineTransform", "radius": 0,
                          "translationX": offset, "outputExtent": describeExtent(moved), "output": try render(moved)])
            let linear = input.unpremultiplyingAlpha().settingAlphaOne(in: input.extent)
                .applyingFilter("CISRGBToneCurveToLinear")
            let shifted = linear.transformed(by: CGAffineTransform(translationX: CGFloat(offset), y: 0))
            cases.append(["fixture": fixture, "filter": "linear-alpha-one-affine", "radius": 0,
                          "translationX": offset, "preparedExtent": describeExtent(linear),
                          "outputExtent": describeExtent(shifted), "output": try render(shifted)])
            // Isolate each pointwise step so a change in sampling order cannot be mistaken for edge clamping.
            let variants: [(String, CIImage)] = [
                ("unpremultiply-affine", input.unpremultiplyingAlpha()),
                ("alpha-one-affine", input.settingAlphaOne(in: input.extent)),
                ("linear-affine", input.applyingFilter("CISRGBToneCurveToLinear")),
                ("unpremultiply-alpha-one-affine", input.unpremultiplyingAlpha().settingAlphaOne(in: input.extent))]
            for (name, prepared) in variants {
                let transformed = prepared.transformed(by: CGAffineTransform(translationX: CGFloat(offset), y: 0))
                cases.append(["fixture": fixture, "filter": name, "radius": 0, "translationX": offset,
                              "preparedExtent": describeExtent(prepared), "outputExtent": describeExtent(transformed),
                              "output": try render(transformed)])
            }
        }
        for rect in [bounds.insetBy(dx: 24, dy: 18), CGRect(x: 120, y: 0, width: 24, height: height)] {
            let prepared = input.settingAlphaOne(in: rect)
            for offset in [0.0, 14.4] {
                let output = prepared.transformed(by: CGAffineTransform(translationX: CGFloat(offset), y: 0))
                cases.append(["fixture": fixture, "filter": "alpha-one-rectangle", "radius": 0,
                              "rectangle": [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
                              "translationX": offset, "preparedExtent": describeExtent(prepared),
                              "outputExtent": describeExtent(output), "byteRender": "CIContext.toBitmap",
                              "output": try render(output, bitmapBytes: true)])
            }
        }
        for radius in [1.0, 10, 35] {
            for intensity in [0.0, 0.02, 0.05, 0.1, 0.25, 0.5, 0.75, 1] {
                let mask = CIImage(color: CIColor(red: intensity, green: intensity, blue: intensity, alpha: 1))
                let output = try filtered("CIMaskedVariableBlur", input: input, parameters: [
                    kCIInputRadiusKey: radius, "inputMask": mask])
                cases.append(["fixture": fixture, "filter": "CIMaskedVariableBlur", "radius": radius,
                              "maskIntensity": intensity, "output": try render(output)])
            }
        }
    }
    // Materialize the impulse at successive pixels so a graph translation cannot hide sampling phases.
    for offset in 0..<8 {
        let source = try bitmap()
        guard let pixels = source.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CaptureError.failed("Missing phase source pixels")
        }
        for at in 0..<(source.bytesPerRow * height) { pixels[at] = 0 }
        let at = (height / 2) * source.bytesPerRow + (width / 2 + offset) * 4
        for channel in 0..<4 { pixels[at + channel] = 255 }
        guard let image = source.makeImage() else { throw CaptureError.failed("Cannot create phase source image") }
        let input = CIImage(cgImage: image), fixture = "impulse-phase-\(offset)"
        cases.append(["fixture": fixture, "filter": "identity-phase", "radius": 0,
                      "sourceOffsetX": offset, "output": try render(input)])
        for radius in [5.0, 10] {
            let output = try filtered("CIGaussianBlur", input: input, parameters: [kCIInputRadiusKey: radius])
            cases.append(["fixture": fixture, "filter": "CIGaussianBlur", "radius": radius,
                          "sourceOffsetX": offset, "output": try render(output)])
        }
    }
    // Keep the preceding recipes' render order unchanged before probing cache-sensitive regional requests.
    for probe in regionalProbes {
        for freshContext in [false, true] {
            for sampleBounds in [CGRect(x: 0, y: 0, width: 192, height: 72),
                                 CGRect(x: 20, y: 8, width: 32, height: 24),
                                 CGRect(x: 80, y: 24, width: 32, height: 24)] {
                cases.append(["fixture": probe.fixture, "filter": "gaussian-magnified-region", "radius": probe.radius,
                              "scaleX": 2, "sampleBounds": [Double(sampleBounds.minX), Double(sampleBounds.minY),
                                                           Double(sampleBounds.width), Double(sampleBounds.height)],
                              "contextPolicy": freshContext ? "fresh-no-cache" : "shared-default-cache",
                              "byteRender": "CIContext.toBitmap", "outputExtent": describeExtent(probe.image),
                              "output": renderRegion(probe.image, in: sampleBounds, freshContext: freshContext)])
            }
        }
    }
    return ["schema": 1, "platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "recipe": "PixelAdjust unmanaged CIContext; finite input with transparent exterior; constant infinite masks",
            "floatFormat": "RGBAFloat32LE in CIContext toBitmap row order; compare identity to determine orientation",
            "byteFormat": "premultiplied RGBA8; CGImage copied into identity-CTM bitmap; packed memory rows",
            "scriptSha256": digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))),
            "inputs": inputs, "cases": cases, "workingPrecision": try captureWorkingPrecision()]
}

do {
    let data = try JSONSerialization.data(withJSONObject: capture(), options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Core Image capture failed: \(error)\n".utf8))
    exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("Core Image capture requires native macOS.\n".utf8))
exit(1)
#endif
