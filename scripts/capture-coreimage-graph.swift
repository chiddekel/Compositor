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

func snapshot(_ image: CIImage, includePixels: Bool = false, includeFloats: Bool = false,
              renderMargin: Int = 0, renderContext: CIContext? = nil,
              bitmapBytes: Bool = false) throws -> [String: Any] {
    let before = image.debugDescription
    let drawingContext = renderContext ?? context
    let renderBounds = bounds.insetBy(dx: -CGFloat(renderMargin), dy: -CGFloat(renderMargin))
    let renderWidth = width + renderMargin * 2, renderHeight = height + renderMargin * 2
    var renderedFloats = [Float](repeating: 0, count: renderWidth * renderHeight * 4)
    renderedFloats.withUnsafeMutableBytes { buffer in
        drawingContext.render(image, toBitmap: buffer.baseAddress!, rowBytes: renderWidth * 16,
                       bounds: renderBounds, format: .RGBAf, colorSpace: space)
    }
    guard renderedFloats.allSatisfy(\.isFinite) else { throw CaptureError.failed("Nonfinite native components") }
    let floats = renderMargin == 0 ? renderedFloats : (0..<height).flatMap { row in
        let start = ((row + renderMargin) * renderWidth + renderMargin) * 4
        return Array(renderedFloats[start..<(start + width * 4)])
    }
    let floatData = floats.withUnsafeBytes { Data($0) }
    var bytes = Data()
    if bitmapBytes {
        // CGImage export clips to finite image extents. Bitmap rendering keeps the requested domain intact.
        var expanded = [UInt8](repeating: 0, count: renderWidth * renderHeight * 4)
        expanded.withUnsafeMutableBytes { buffer in
            drawingContext.render(image, toBitmap: buffer.baseAddress!, rowBytes: renderWidth * 4,
                                  bounds: renderBounds, format: .RGBA8, colorSpace: space)
        }
        for y in 0..<height {
            let start = ((y + renderMargin) * renderWidth + renderMargin) * 4
            bytes.append(contentsOf: expanded[start..<(start + width * 4)])
        }
    } else {
        guard let rendered = drawingContext.createCGImage(image, from: renderBounds, format: .RGBA8, colorSpace: space),
              rendered.width == renderWidth, rendered.height == renderHeight else {
            throw CaptureError.failed("Cannot create a fixed-size native image")
        }
        let target = try bitmap()
        target.setBlendMode(.copy)
        target.draw(rendered, in: renderBounds)
        guard let pixels = target.data else { throw CaptureError.failed("Missing rendered bitmap pixels") }
        for y in 0..<height {
            bytes.append(pixels.advanced(by: y * target.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
    }
    let after = image.debugDescription
    var result: [String: Any] = ["width": width, "height": height, "floatBytes": floatData.count, "byteBytes": bytes.count,
            "floatSha256": digest(floatData), "byteSha256": digest(bytes), "floatFinite": true,
            "descriptionBeforeRender": String(before.prefix(65_536)),
            "descriptionAfterRender": String(after.prefix(65_536)),
            "descriptionTruncated": before.count > 65_536 || after.count > 65_536]
    if includePixels { result["rgbaBase64"] = bytes.base64EncodedString() }
    if includeFloats { result["floatBase64"] = floatData.base64EncodedString() }
    if bitmapBytes { result["byteRender"] = "CIContext.toBitmap" }
    if renderMargin > 0 {
        result["renderBounds"] = [Double(renderBounds.minX), Double(renderBounds.minY),
                                  Double(renderBounds.width), Double(renderBounds.height)]
    }
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
    // Append variable-blur diagnostics after every preceding recipe, preserving their render order.
    // Constant masks expose the pyramid's level selection; materialized impulses expose sampling phases.
    var variable = [[String: Any]]()
    for (fixture, input) in sources {
        for radius in [1.0, 10, 35] {
            for intensity in [0.0, 0.02, 0.05, 0.1, 0.25, 0.5, 0.75, 1] {
                let mask = CIImage(color: CIColor(red: intensity, green: intensity, blue: intensity))
                let output = input.applyingFilter("CIMaskedVariableBlur", parameters: [
                    "inputMask": mask, kCIInputRadiusKey: radius])
                variable.append(["fixture": fixture, "filter": "CIMaskedVariableBlur", "radius": radius,
                                 "maskIntensity": intensity, "outputExtent": extent(output),
                                 "output": try snapshot(output, includePixels: true, includeFloats: true)])
            }
        }
    }
    var phaseSources = [(Int, Int, CIImage)]()
    for phaseY in 0..<4 { for phaseX in 0..<4 {
        let source = try bitmap()
        guard let pixels = source.data?.assumingMemoryBound(to: UInt8.self) else {
            throw CaptureError.failed("Missing phase impulse pixels")
        }
        for y in 0..<height { for x in 0..<width {
            let value: UInt8 = x == width / 2 + phaseX && y == height / 2 + phaseY ? 255 : 0
            for channel in 0..<4 { pixels[y * source.bytesPerRow + x * 4 + channel] = value }
        } }
        guard let image = source.makeImage() else { throw CaptureError.failed("Cannot create phase impulse") }
        for radius in [1.5, 3, 6] {
            let output = CIImage(cgImage: image).applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": CIImage(color: .white), kCIInputRadiusKey: radius])
            variable.append(["fixture": "phase-impulse", "phaseX": phaseX, "phaseY": phaseY,
                             "filter": "CIMaskedVariableBlur", "radius": radius, "maskIntensity": 1,
                             "outputExtent": extent(output),
                             "output": try snapshot(output, includePixels: true, includeFloats: true)])
        }
        phaseSources.append((phaseX, phaseY, CIImage(cgImage: image)))
    } }
    // Coarser levels and clamped sources separate sampling phase from finite-image edge behavior.
    for (phaseX, phaseY, input) in phaseSources {
        for radius in [12.0, 24, 48] {
            let output = input.applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": CIImage(color: .white), kCIInputRadiusKey: radius])
            variable.append(["fixture": "phase-impulse", "phaseX": phaseX, "phaseY": phaseY,
                             "filter": "CIMaskedVariableBlur", "radius": radius, "maskIntensity": 1,
                             "outputExtent": extent(output),
                             "output": try snapshot(output, includePixels: true, includeFloats: true)])
        }
    }
    for (fixture, input) in sources {
        for radius in [10.0, 35] {
            for intensity in [0.0, 0.1, 0.25, 0.5, 0.75, 1] {
                let mask = CIImage(color: CIColor(red: intensity, green: intensity, blue: intensity))
                let output = input.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
                    "inputMask": mask, kCIInputRadiusKey: radius])
                variable.append(["fixture": fixture + "-clamped", "filter": "CIMaskedVariableBlur",
                                 "radius": radius, "maskIntensity": intensity, "outputExtent": extent(output),
                                 "output": try snapshot(output, includePixels: true, includeFloats: true)])
            }
        }
    }
    // Request larger regions, then retain only the original view. No image crop node is inserted.
    var requests = [[String: Any]]()
    for (fixture, input) in sources {
        for clamped in [false, true] {
            if fixture == "impulse" && clamped { continue }
            for radius in (fixture == "impulse" ? [35.0] : [10.0, 35]) {
                for intensity in (fixture == "impulse" ? [1.0] : [0.75, 1]) {
                    let mask = CIImage(color: CIColor(red: intensity, green: intensity, blue: intensity))
                    let prepared = clamped ? input.clampedToExtent() : input
                    let output = prepared.applyingFilter("CIMaskedVariableBlur", parameters: [
                        "inputMask": mask, kCIInputRadiusKey: radius])
                    for margin in [0, 16, 64, 256] {
                        let freshContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
                        requests.append(["fixture": fixture + (clamped ? "-clamped" : ""),
                                         "filter": "CIMaskedVariableBlur", "radius": radius,
                                         "maskIntensity": intensity, "renderMargin": margin, "freshContext": true,
                                         "output": try snapshot(output, includePixels: true, includeFloats: true,
                                                                renderMargin: margin, renderContext: freshContext,
                                                                bitmapBytes: true)])
                    }
                }
            }
        }
    }
    let linearMask = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: CGFloat(height)), "inputPoint1": CIVector(x: 0, y: 0),
        "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!
    let radialMask = CIFilter(name: "CIRadialGradient", parameters: [
        kCIInputCenterKey: CIVector(x: CGFloat(width) / 2, y: CGFloat(height) / 2),
        "inputRadius0": 0, "inputRadius1": hypot(Double(width) / 2, Double(height) / 2),
        "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!
    let masks = [("linear", linearMask), ("radial", radialMask)]
    let colors: [(String, CIColor)] = [
        ("red", CIColor(red: 1, green: 0, blue: 0)), ("green", CIColor(red: 0, green: 1, blue: 0)),
        ("blue", CIColor(red: 0, green: 0, blue: 1)), ("gray", CIColor(red: 0.5, green: 0.5, blue: 0.5))]
    var maskInputs = [[String: Any]](), varying = [[String: Any]](), colored = [[String: Any]]()
    for (kind, mask) in masks {
        maskInputs.append(["maskKind": kind, "output": try snapshot(mask, includePixels: true, includeFloats: true)])
    }
    for (kind, color) in colors {
        maskInputs.append(["maskKind": kind, "output": try snapshot(CIImage(color: color), includePixels: true, includeFloats: true)])
    }
    for (fixture, input) in sources {
        for clamped in [false, true] {
            let prepared = clamped ? input.clampedToExtent() : input
            for radius in [10.0, 35, 55, 250] {
                for (kind, mask) in masks {
                    let output = prepared.applyingFilter("CIMaskedVariableBlur", parameters: [
                        "inputMask": mask, kCIInputRadiusKey: radius])
                    varying.append(["fixture": fixture + (clamped ? "-clamped" : ""), "radius": radius,
                                    "maskKind": kind, "outputExtent": extent(output),
                                    "output": try snapshot(output, includePixels: true, includeFloats: true)])
                }
            }
        }
        for (kind, color) in colors {
            let output = input.applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": CIImage(color: color), kCIInputRadiusKey: 10])
            colored.append(["fixture": fixture, "radius": 10, "maskKind": kind,
                            "output": try snapshot(output, includePixels: true, includeFloats: true)])
        }
    }
    var geometry = [[String: Any]]()
    let source = sources.first { $0.0 == "opaque-gradient" }!.1
    let geometries: [(String, CIImage)] = [
        ("identity", source), ("translated-positive", source.transformed(by: CGAffineTransform(translationX: 14, y: 8))),
        ("translated-negative", source.transformed(by: CGAffineTransform(translationX: -13, y: -7))),
        ("cropped", source.cropped(to: CGRect(x: 3, y: 5, width: 61, height: 37)))]
    for (kind, input) in geometries {
        for radius in [1.0, 35] {
            let output = input.applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": CIImage(color: .white), kCIInputRadiusKey: radius])
            geometry.append(["geometryKind": kind, "radius": radius, "inputExtent": extent(input),
                             "outputExtent": extent(output),
                             "output": try snapshot(output, includePixels: true, includeFloats: true)])
        }
    }
    return ["schema": 1, "platform": "macOS", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scriptSha256": digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))),
            "contextDescription": String(context.debugDescription.prefix(65_536)),
            "recipe": "Unmanaged shared CIContext; finite RGBA8 sources; RGBAf bitmap and RGBA8 CGImage copied into an identity bitmap",
            "diagnosticDescriptions": true, "inputs": inputs, "cases": cases,
            "probeRadii": radii, "smallRadiusProbes": probes, "variableBlurProbes": variable,
            "variableRequestProbes": requests, "variableMaskInputs": maskInputs,
            "variableMaskProbes": varying, "variableColorMaskProbes": colored,
            "variableGeometryProbes": geometry]
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
