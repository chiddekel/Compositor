// Core ML compat: the surface tip DepthMini (`Compositor/IO/DepthModel.swift`) needs, backed by
// `CompositorDepthBackend` (OpenCV DNN + Depth Anything V2 Small ONNX). Apple's `.mlpackage` / `.mlmodelc` are not
// executed here — `compileModel` keeps a Linux folder with `model.onnx`, and `prediction` runs that file.

@_exported import CoreGraphics
@_exported import CoreVideo
import Foundation
import CompositorDepthBackend

public enum MLComputeUnits: Int, Sendable {
    case cpuOnly = 0
    case cpuAndGPU = 1
    case all = 2
    case cpuAndNeuralEngine = 3
}

public final class MLModelConfiguration: @unchecked Sendable {
    public var computeUnits: MLComputeUnits = .all
    public init() {}
}

public enum MLFeatureValueType: Int, Sendable {
    case invalid = 0
    case image = 1
    case multiArray = 2
}

public final class MLMultiArray: @unchecked Sendable {
    public let shape: [NSNumber]
    public private(set) var floats: [Float]

    public var count: Int { floats.count }

    public init(shape: [Int], floats: [Float]) {
        self.shape = shape.map { NSNumber(value: $0) }
        self.floats = floats
    }

    public subscript(index: Int) -> NSNumber {
        get { NSNumber(value: floats[index]) }
        set { floats[index] = newValue.floatValue }
    }
}

public struct MLShapedArray<Scalar: BinaryFloatingPoint & Sendable>: Sendable {
    public let scalars: [Scalar]
    public init(converting array: MLMultiArray) where Scalar == Float {
        scalars = array.floats
    }
}

public struct MLFeatureValue: @unchecked Sendable {
    public enum ImageOption: Hashable, Sendable {
        case cropAndScale
    }

    public let type: MLFeatureValueType
    public let multiArrayValue: MLMultiArray?
    /// Premultiplied BGRA8 row-major, tip DepthMini's Core ML pixel format.
    public let bgra: [UInt8]?
    public let width: Int
    public let height: Int

    public init(multiArray: MLMultiArray) {
        type = .multiArray
        multiArrayValue = multiArray
        bgra = nil
        width = 0
        height = 0
    }

    public init(cgImage image: CGImage, pixelsWide: Int, pixelsHigh: Int, pixelFormatType: OSType,
                options: [ImageOption: Any] = [:]) throws {
        _ = options
        guard pixelFormatType == kCVPixelFormatType_32BGRA || pixelFormatType.rawValue == kCVPixelFormatType_32BGRA.rawValue
        else { throw MLError.invalidInput }
        // Draw as RGBA premultipliedLast (Compat's well-tested path), then swizzle to BGRA for the depth backend.
        guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                      bytesPerRow: pixelsWide * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw MLError.invalidInput }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        guard let data = context.data else { throw MLError.invalidInput }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh * 4)
        for y in 0..<pixelsHigh {
            let src = bytes + y * context.bytesPerRow
            for x in 0..<pixelsWide {
                let i = (y * pixelsWide + x) * 4
                let r = src[x * 4], g = src[x * 4 + 1], b = src[x * 4 + 2], a = src[x * 4 + 3]
                pixels[i] = b; pixels[i + 1] = g; pixels[i + 2] = r; pixels[i + 3] = a
            }
        }
        type = .image
        multiArrayValue = nil
        bgra = pixels
        width = pixelsWide
        height = pixelsHigh
    }
}

public protocol MLFeatureProvider {
    var featureNames: Set<String> { get }
    func featureValue(for featureName: String) -> MLFeatureValue?
}

public struct MLDictionaryFeatureProvider: MLFeatureProvider {
    private let values: [String: MLFeatureValue]
    public var featureNames: Set<String> { Set(values.keys) }
    public init(dictionary: [String: MLFeatureValue]) { values = dictionary }
    public func featureValue(for featureName: String) -> MLFeatureValue? { values[featureName] }
}

public enum MLError: Error {
    case missingModel
    case invalidInput
    case predictionFailed
    case compileFailed
}

public final class MLModel: @unchecked Sendable {
    private let onnxPath: String

    public init(contentsOf url: URL, configuration: MLModelConfiguration = MLModelConfiguration()) throws {
        _ = configuration
        let onnx = url.appendingPathComponent("model.onnx")
        let path = FileManager.default.fileExists(atPath: onnx.path) ? onnx.path : url.path
        guard FileManager.default.fileExists(atPath: path), path.hasSuffix(".onnx") || FileManager.default.fileExists(atPath: onnx.path)
        else { throw MLError.missingModel }
        let loadPath = path.hasSuffix(".onnx") ? path : onnx.path
        let status = compositor_depth_load(loadPath)
        guard status == 0 else { throw MLError.missingModel }
        onnxPath = loadPath
    }

    /// Tip expects an async compile of an `.mlpackage`. On Linux the package (or a folder) must already contain
    /// `model.onnx`; this copies it into a temporary `.mlmodelc`-shaped directory Core ML would have produced.
    public static func compileModel(at url: URL) async throws -> URL {
        let onnx = url.appendingPathComponent("model.onnx")
        guard FileManager.default.fileExists(atPath: onnx.path) else { throw MLError.compileFailed }
        let built = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepthMini-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: built, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: onnx, to: built.appendingPathComponent("model.onnx"))
        return built
    }

    public func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider {
        guard let image = input.featureValue(for: "image"), let bgra = image.bgra, image.width > 0, image.height > 0
        else { throw MLError.invalidInput }
        var depth = [Float](repeating: 0, count: image.width * image.height)
        let code = bgra.withUnsafeBufferPointer { pixels in
            depth.withUnsafeMutableBufferPointer { out in
                compositor_depth_predict(pixels.baseAddress, Int32(image.width), Int32(image.height), out.baseAddress)
            }
        }
        guard code == 0 else { throw MLError.predictionFailed }
        let array = MLMultiArray(shape: [1, image.height, image.width], floats: depth)
        return MLDictionaryFeatureProvider(dictionary: ["depth": MLFeatureValue(multiArray: array)])
    }
}
