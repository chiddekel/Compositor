// Apple Vision's subject model, on Linux: U²-Net-small (backends/vision, OpenCV DNN) behind the Vision compat's
// segmentation seam, so upstream's Select Subject, Object Selection and Remove Background (unmodified) get a learned
// subject mask as they do on macOS. Without the model file or the DNN build the classical segmenter stays in place.
import CompositorVisionBackend
import Foundation
import Vision

final class U2NetSegmenter: ForegroundSegmentationBackend {
    func segment(rgba: [UInt8], width: Int, height: Int) throws -> SegmentationResult {
        var labels = [UInt8](repeating: 0, count: width * height)
        var confidence = [Float](repeating: 0, count: width * height)
        var count: Int32 = 0
        let code = rgba.withUnsafeBufferPointer { pixels in
            labels.withUnsafeMutableBufferPointer { labels in
                confidence.withUnsafeMutableBufferPointer { confidence in
                    compositor_u2net_segment(pixels.baseAddress, Int32(width), Int32(height), labels.baseAddress,
                                             confidence.baseAddress, &count)
                }
            }
        }
        if ProcessInfo.processInfo.environment["COMPOSITOR_DEBUG_VISION"] != nil {
            FileHandle.standardError.write(Data("subject model: \(width)x\(height) -> \(code == 0 ? "\(count) subjects" : "failed (\(code))")\n".utf8))
        }
        guard code == 0 else { throw VNError.segmentationFailed }
        return SegmentationResult(labels: labels, width: width, height: height, instanceCount: Int(count), confidence: confidence)
    }

    /// Where the model is: COMPOSITOR_SEGMENTATION_MODEL, the Flatpak's share directory, or the source tree's copy.
    static var modelPath: String? {
        // The checkout's copy: the nearest directory above this file (reached through Sources/UpstreamCore's
        // symlinks, so its depth varies) that holds third_party/models.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var checkout: String?
        while directory.path != "/" {
            let model = directory.appendingPathComponent("third_party/models/u2netp.onnx").path
            if FileManager.default.fileExists(atPath: model) { checkout = model; break }
            directory = directory.deletingLastPathComponent()
        }
        let candidates: [String?] = [ProcessInfo.processInfo.environment["COMPOSITOR_SEGMENTATION_MODEL"],
                                     "/app/share/compositor/models/u2netp.onnx", checkout]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Installs the model-backed segmenter when the model loads; returns whether it did.
    @discardableResult static func install() -> Bool {
        guard let modelPath else { return false }
        let status = compositor_u2net_load(modelPath)
        if ProcessInfo.processInfo.environment["COMPOSITOR_DEBUG_VISION"] != nil {
            FileHandle.standardError.write(Data("subject model \(modelPath): \(status == 0 ? "loaded" : "unavailable (\(status))")\n".utf8))
        }
        guard status == 0 else { return false }
        ForegroundSegmentationRegistry.backend = U2NetSegmenter()
        return true
    }
}

/// The subject model, once per process (the host calls it at startup; tests may call it directly).
@_cdecl("compositor_install_subject_model")
nonisolated public func compositorInstallSubjectModel() -> Int32 {
    onMain { U2NetSegmenter.install() ? 0 : -1 }
}
