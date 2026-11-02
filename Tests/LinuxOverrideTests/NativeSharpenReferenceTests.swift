import AppKit
import Foundation
import Testing
@testable import Compositor

@MainActor
struct NativeSharpenReferenceTests {
    private struct Sample: Decodable {
        let name: String
        let radius: Double, amount: Double
        let overlay: Bool
        let rgbaBase64: Data
    }
    private struct Reference: Decodable {
        let schema: Int, width: Int, height: Int
        let platform: String, upstream: String
        let cases: [Sample]
    }

    @Test func transparentBordersMatchIndependentNativeApplicationCaptures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coreimage-unsharp-application-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        #expect(reference.schema == 1 && reference.platform == "macOS")
        #expect(reference.upstream == "2d75d9172835e1dd6111cb2b659958ec33fa5abf")
        #expect(reference.cases.count == 5)
        let width = reference.width, height = reference.height
        for sample in reference.cases {
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let alpha = sample.overlay ? (x < 12 || y < 12 || x > 80 || y > 58 ? 0 : 160) : 255
                let offset = y * context.bytesPerRow + x * 4
                pixels[offset] = UInt8((x * 255 / (width - 1)) * alpha / 255)
                pixels[offset + 1] = UInt8((y * 255 / (height - 1)) * alpha / 255)
                pixels[offset + 2] = UInt8((sample.overlay ? 220 : 100) * alpha / 255)
                pixels[offset + 3] = UInt8(alpha)
            } }
            var settings = FilterSettings()
            settings.sharpenRadius = sample.radius
            settings.sharpenAmount = sample.amount
            var job = FilterJob(kind: .sharpen, image: try #require(context.makeImage()), settings: settings,
                                scale: 1, selection: nil, mapping: .identity)
            job.canvas = CGRect(x: 0, y: 0, width: width, height: height)
            let actual = try UpstreamEditor.rgbaBytes(of: PixelFilter.run(job)).bytes
            let expected = Array(sample.rgbaBase64)
            try #require(actual.count == expected.count && actual.count == width * height * 4)
            var maximum = 0
            for offset in stride(from: 0, to: actual.count, by: 4) {
                let alpha = Int(expected[offset + 3])
                for channel in 0..<4 {
                    let value = channel == 3 ? alpha : (Int(expected[offset + channel]) * alpha + 127) / 255
                    maximum = max(maximum, abs(Int(actual[offset + channel]) - value))
                }
            }
            #expect(maximum <= 1, "\(sample.name): native maximum byte difference \(maximum)")
        }
    }
}
