import Foundation
import CoreImage
import CoreGraphics
import Testing
import SwiftUI
@testable import CompatSupport
@testable import Compositor

private enum RawFixture {
    nonisolated(unsafe) static var flags: UInt32 = 0
    nonisolated(unsafe) static var received: (Float, Int32, Int32)?
    static let probe: RawDecoding.ProbeFn = { _, w, h in w?.pointee = 256; h?.pointee = 256; return 0 }
    static let open: RawDecoding.OpenFn = { _, w, h, temperature, tint in
        w?.pointee = 256; h?.pointee = 256; temperature?.pointee = 5500; tint?.pointee = 7
        return OpaquePointer(bitPattern: 65)
    }
    static let close: RawDecoding.CloseFn = { _ in }
    static let capabilities: RawDecoding.CapabilitiesFn = { _, flags, noise, lens, highlight in
        flags?.pointee = RawFixture.flags; noise?.pointee = 0.25
        lens?.pointee = 0; highlight?.pointee = 1
        return 0
    }
    static let develop: RawDecoding.DevelopFn = { _, _, _, _, _, noise, lens, highlight, _, _, pixels, w, h in
        received = (noise, lens, highlight)
        guard let buffer = malloc(16 * 16 * 4) else { return -1 }
        let data = buffer.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(16 * 16) {
            data[i * 4] = UInt8(noise * 255); data[i * 4 + 1] = highlight != 0 ? 200 : 10
            data[i * 4 + 2] = 30; data[i * 4 + 3] = 255
        }
        pixels?.pointee = data; w?.pointee = 16; h?.pointee = 16
        return 0
    }
}

@MainActor
@Suite(.serialized) struct RawDevelopCapabilityTests {
    private func withBackend(_ flags: UInt32, body: (URL) throws -> Void) rethrows {
        let old = (RawDecoding.probeFn, RawDecoding.openFn, RawDecoding.developFn, RawDecoding.closeFn, RawDecoding.capabilitiesFn)
        RawFixture.flags = flags; RawFixture.received = nil
        compositor_raw_register(RawFixture.probe, RawFixture.open, RawFixture.develop, RawFixture.close, RawFixture.capabilities)
        defer { compositor_raw_register(old.0, old.1, old.2, old.3, old.4) }
        try body(URL(fileURLWithPath: "/tmp/\(UUID().uuidString).dng"))
    }

    @Test(arguments: [UInt32(0), UInt32(5)])
    func defaultsCapabilitiesAndControlsReachDecoder(flags: UInt32) throws {
        try withBackend(flags) { url in
            let filter = try #require(CIRAWFilter(imageURL: url))
            #expect(filter.neutralTemperature == 5500 && filter.neutralTint == 7)
            #expect(filter.luminanceNoiseReductionAmount == 0.25)
            #expect(filter.isHighlightRecoveryEnabled)
            #expect(filter.isLuminanceNoiseReductionSupported == (flags & 1 != 0))
            #expect(filter.isHighlightRecoverySupported == (flags & 4 != 0))
            #expect(!filter.isLensCorrectionSupported)
            filter.luminanceNoiseReductionAmount = 0.9
            filter.isHighlightRecoveryEnabled = false
            filter.isLensCorrectionEnabled = true
            let output = try #require(filter.outputImage)
            let image = try #require(CIContext().createCGImage(output, from: output.extent))
            #expect(image.width == 16 && image.height == 16)
            #expect(RawFixture.received?.0 == (flags & 1 != 0 ? Float(0.9) : Float(0.25)))
            #expect(RawFixture.received?.1 == 0)
            #expect(RawFixture.received?.2 == (flags & 4 != 0 ? 0 : 1))
        }
    }

    @Test func rawSheetPreservesEveryControlInTheModifiedGroup() throws {
        try withBackend(5) { url in
            let settings = try #require(RawImporter.asShot(url))
            let root = ViewResolver.resolve(RawDevelopSheet(session: EditorSession(), url: url, settings: settings))
            func descendants(_ node: RenderNode) -> [RenderNode] {
                [node] + node.children.flatMap(descendants)
            }
            let nodes = descendants(root)
            let labels = nodes.filter { $0.kind == "Text" }.compactMap { $0.stringParams["text"] }
            for title in ["Exposure", "Temperature", "Tint", "Boost", "Noise Reduction", "Lens Correction", "Highlight Recovery", "Reset", "Cancel", "Import"] {
                #expect(labels.contains(title), "RAW sheet lost \(title)")
            }
            #expect(nodes.filter { $0.kind == "Slider" }.count == 5)
            #expect(nodes.filter { $0.kind == "Toggle" }.count == 2)
            #expect(nodes.filter { $0.kind == "Button" }.count == 3)
            let lens = try #require(nodes.first { node in
                node.kind == "Toggle" && descendants(node).contains { $0.stringParams["text"] == "Lens Correction" }
            })
            #expect(lens.modifiers.contains { if case .disabled(true) = $0 { return true }; return false })
            #expect(lens.modifiers.contains { if case .help(let text) = $0 { return text.contains("unavailable on Linux") }; return false })
        }
    }

    @Test func resetReturnsToBackendDefaults() throws {
        try withBackend(5) { url in
            var settings = try #require(RawImporter.asShot(url))
            #expect(settings.isAsShot)
            settings.exposure = 2; settings.noiseReduction = 0.9; settings.highlightRecovery = false
            #expect(!settings.isAsShot)
            settings.reset()
            #expect(settings.isAsShot)
            #expect(settings.noiseReduction == 0.25 && settings.highlightRecovery)
            #expect(settings.supportsNoiseReduction && settings.supportsHighlightRecovery)
            #expect(!settings.supportsLensCorrection && !settings.lensCorrection)
        }
    }
}
