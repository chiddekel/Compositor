import Foundation
import CoreGraphics
import Vision
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_REQUIRE_SUBJECT_MODEL"] == "1"))
struct SubjectModelAcceptanceTests {
    private func fixture() -> PixelBuffer {
        let width = 128, height = 96
        var pixels = PixelBuffer(width: width, height: height, fill: 0xf4f4f4ff)
        for y in 0..<height { for x in 0..<width {
            let dx = Double(x - width / 2) / 32, dy = Double(y - height / 2) / 28
            if dx * dx + dy * dy < 1 { pixels[x, y] = (200, 40, 30, 255) }
        } }
        return pixels
    }

    @Test func shippedModelSuppliesOriginalBackgroundMask() throws {
        let previous = ForegroundSegmentationRegistry.backend
        defer { ForegroundSegmentationRegistry.backend = previous }
        try #require(U2NetSegmenter.install(), "The contract requires the shipped model and OpenCV DNN")
        #expect(ForegroundSegmentationRegistry.backend is U2NetSegmenter)

        let pixels = fixture(), width = pixels.width, height = pixels.height
        let result = try U2NetSegmenter().segment(rgba: pixels.bytes, width: width, height: height)
        let confidence = try #require(result.confidence)
        #expect(result.width == width && result.height == height && result.instanceCount > 0)
        #expect(result.labels.count == width * height && confidence.count == width * height)
        #expect(confidence.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(result.labels[height / 2 * width + width / 2] != 0 && result.labels[0] == 0)
        #expect(confidence.contains { $0 > 0.05 && $0 < 0.95 }, "Learned mask must retain a soft fringe")

        let mask = try SubjectRemoval.subjectMask(CGImage(pixels), under: nil, settings: FilterSettings())
        #expect(mask.width == width && mask.height == height && mask.bitsPerPixel == 8)
        let bytes = Array(try #require(mask.dataProvider?.data) as Data)
        for y in 0..<height { for x in 0..<width {
            #expect(abs(Double(bytes[y * mask.bytesPerRow + x]) / 255 - Double(confidence[y * width + x])) <= 2.0 / 255,
                    "Original Remove Background must receive the learned confidence mask")
        } }
    }

    @Test func bridgeSelectionAndBackgroundRemovalPreserveSourceAndHistory() async throws {
        let previous = ForegroundSegmentationRegistry.backend
        defer { ForegroundSegmentationRegistry.backend = previous }
        try #require(U2NetSegmenter.install())
        let pixels = fixture()
        let editor = UpstreamEditor()
        try #require(editor.importRGBA(pixels.bytes, width: pixels.width, height: pixels.height,
                                     name: "Learned subject", replacing: true) == 0)
        let session = editor.session
        let source = try #require(session.activeLayer?.asset?.image)
        let layerID = session.activeLayerID
        func send(_ action: String) async throws {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "action": action] as [String: Any])
            try #require(await editor.commandAsync(data) == 0)
            #expect(!session.isProjectBusy)
        }

        try await send("selectSubject")
        let selection = try #require(session.selection)
        #expect(selection.path.contains(CGPoint(x: 64, y: 48)))
        #expect(!selection.path.contains(CGPoint(x: 1, y: 1)))
        #expect(session.activeLayer?.asset?.image === source && session.activeLayerID == layerID)
        try await send("undo")
        #expect(session.selection == nil)
        try await send("redo")
        #expect(session.selection?.path.boundingBoxOfPath == selection.path.boundingBoxOfPath)
        try await send("undo")

        try await send("removeBackground")
        let mask = try #require(session.activeLayer?.mask)
        #expect(mask.isEnabled && mask.isLinked && mask.placement == nil)
        #expect(mask.asset.image.width == source.width && mask.asset.image.height == source.height)
        #expect(session.activeLayer?.asset?.image === source && session.activeLayerID == layerID)
        #expect(session.filterEdit == nil && session.selection == nil)
        try await send("undo")
        #expect(session.activeLayer?.mask == nil && session.activeLayer?.asset?.image === source)
        try await send("redo")
        #expect(session.activeLayer?.mask == mask && session.activeLayer?.asset?.image === source)
    }
}
