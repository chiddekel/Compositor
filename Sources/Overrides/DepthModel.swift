import CoreGraphics
import CoreImage
import CoreML
import CryptoKit
import Foundation
import Vision

/// Linux stand-in for tip `Compositor/IO/DepthModel.swift`.
/// Apple's DepthMini `.mlpackage` is not runnable here; this downloads Depth Anything V2 Small (uint8 ONNX, Apache-2.0)
/// into the same Application Support layout and runs it through Compat Core ML (`CompositorDepthBackend`).
nonisolated enum DepthModel {
    /// ONNX weights (HF onnx-community). Override with `COMPOSITOR_DEPTH_MODEL` for a local file.
    static var source = URL(string: "https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/main/onnx/")!
    static let version = "4-onnx-uint8"
    private static let files: [(name: String, path: String, sha256: String)] = [
        ("model_uint8.onnx", "model.onnx", "fcf51f1b230362b28690bb9d1809bf0431f29cad20534e3f589bd7285547f20d"),
    ]
    static let shapes = [(512, 512), (512, 384), (512, 288), (384, 512), (288, 512)]

    static func shape(for image: CGImage) -> (width: Int, height: Int) {
        let aspect = log(Double(image.width) / Double(max(1, image.height)))
        return shapes.min {
            abs(log(Double($0.0) / Double($0.1)) - aspect) < abs(log(Double($1.0) / Double($1.1)) - aspect)
        }!
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Compositor/Depth Model \(version)", isDirectory: true)
    }
    private static var compiled: URL { folder.appendingPathComponent("DepthMini.mlmodelc", isDirectory: true) }

    private static let state = State()
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var model: MLModel?
        var loading: Task<Bool, Never>?
        var cached: (image: CGImage, depth: DepthMap)?
    }

    static var isReady: Bool { state.lock.withLock { state.model != nil } }

    @discardableResult static func prepare() async -> Bool {
        if let env = ProcessInfo.processInfo.environment["COMPOSITOR_DEPTH_MODEL"],
           FileManager.default.fileExists(atPath: env) {
            return await loadLocal(URL(fileURLWithPath: env))
        }
        let task: Task<Bool, Never> = state.lock.withLock {
            if state.model != nil { return Task { true } }
            if let loading = state.loading { return loading }
            let loading = Task.detached(priority: .userInitiated) { await load() }
            state.loading = loading
            return loading
        }
        let ready = await task.value
        state.lock.withLock { state.loading = nil }
        return ready
    }

    private static func loadLocal(_ onnx: URL) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            let dest = compiled.appendingPathComponent("model.onnx")
            if dest.path != onnx.path {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: onnx, to: dest)
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            state.lock.withLock { state.model = model }
            return true
        } catch {
            return false
        }
    }

    private static func load() async -> Bool {
        do {
            if !FileManager.default.fileExists(atPath: compiled.appendingPathComponent("model.onnx").path) {
                try await download()
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            state.lock.withLock { state.model = model }
            return true
        } catch {
            try? FileManager.default.removeItem(at: compiled)
            return false
        }
    }

    private static func download() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("DepthMini-\(UUID().uuidString).mlpackage")
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for file in files {
            // Linux Foundation has no working URLSession.shared; Data(contentsOf:) still fetches https.
            let data = try Data(contentsOf: source.appendingPathComponent(file.name))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256 else { throw URLError(.cannotDecodeContentData) }
            let destination = package.appendingPathComponent(file.path)
            try data.write(to: destination)
        }
        let built = try await MLModel.compileModel(at: package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: compiled)
        try FileManager.default.moveItem(at: built, to: compiled)
    }

    static let refinedSide = 640

    static func depth(for image: CGImage) -> DepthMap? {
        let (model, cached) = state.lock.withLock { (state.model, state.cached) }
        guard let model else { return nil }
        if let cached, cached.image === image { return cached.depth }
        let (columns, rows) = shape(for: image)
        guard let small = pixels(of: image, width: columns, height: rows),
              let input = try? MLFeatureValue(cgImage: small.image, pixelsWide: columns, pixelsHigh: rows,
                                              pixelFormatType: kCVPixelFormatType_32BGRA,
                                              options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]),
              let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let array = output.featureValue(for: "depth")?.multiArrayValue, array.count == columns * rows else { return nil }
        let values = MLShapedArray<Float>(converting: array).scalars
        guard let low = values.min(), let high = values.max(), high > low else { return nil }
        let scale = Double(refinedSide) / Double(max(image.width, image.height))
        let width = max(8, Int((Double(image.width) * scale).rounded()))
        let height = max(8, Int((Double(image.height) * scale).rounded()))
        guard let guide = pixels(of: image, width: width, height: height) else { return nil }
        var enlarged = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let fy = min(Float(rows - 1), max(0, (Float(y) + 0.5) * Float(rows) / Float(height) - 0.5))
            let y0 = Int(fy), y1 = min(rows - 1, y0 + 1), ty = fy - Float(y0)
            for x in 0..<width {
                let fx = min(Float(columns - 1), max(0, (Float(x) + 0.5) * Float(columns) / Float(width) - 0.5))
                let x0 = Int(fx), x1 = min(columns - 1, x0 + 1), tx = fx - Float(x0)
                let top = values[y0 * columns + x0] * (1 - tx) + values[y0 * columns + x1] * tx
                let bottom = values[y1 * columns + x0] * (1 - tx) + values[y1 * columns + x1] * tx
                enlarged[y * width + x] = ((top * (1 - ty) + bottom * ty) - low) / (high - low)
            }
        }
        let refined = GuidedMatte.filter(mask: enlarged, guide: guide.gray, width: width, height: height,
                                         radius: max(2, refinedSide / 48), epsilon: 1e-3).map { max(0, min(1, $0)) }
        let depth = DepthMap(values: refined, width: width, height: height)
        state.lock.withLock { state.cached = (image, depth) }
        return depth
    }

    private static func pixels(of image: CGImage, width: Int, height: Int) -> (image: CGImage, gray: [Float])? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let made = context.makeImage(), let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var gray = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = bytes + y * context.bytesPerRow + x * 4
                gray[y * width + x] = (0.2126 * Float(p[0]) + 0.7152 * Float(p[1]) + 0.0722 * Float(p[2])) / 255
            }
        }
        return (made, gray)
    }

    static func image(_ depth: DepthMap, over extent: CGRect) -> CIImage {
        let levels = depth.values.map { UInt16(max(0, min(1, $0)) * 65535) }
        guard let provider = CGDataProvider(data: levels.withUnsafeBytes { Data($0) } as CFData),
              let gray = CGImage(width: depth.width, height: depth.height, bitsPerComponent: 16, bitsPerPixel: 16,
                                 bytesPerRow: depth.width * 2, space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            return CIImage.black.cropped(to: extent)
        }
        return CIImage(cgImage: gray, options: [.colorSpace: NSNull()]).samplingLinear()
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)
                .scaledBy(x: extent.width / CGFloat(depth.width), y: extent.height / CGFloat(depth.height)))
            .cropped(to: extent)
    }
}

nonisolated struct DepthMap: Sendable {
    let values: [Float]
    let width: Int
    let height: Int

    func equalized(_ amount: Float) -> DepthMap {
        guard amount > 0, values.count > 1 else { return self }
        let order = values.indices.sorted { values[$0] < values[$1] }
        var spread = values
        let last = Float(values.count - 1)
        for (rank, index) in order.enumerated() { spread[index] += (Float(rank) / last - values[index]) * amount }
        return DepthMap(values: spread, width: width, height: height)
    }
}
