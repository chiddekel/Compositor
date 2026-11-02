import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized) struct SystemFontTests {
    private struct FontLabel: @preconcurrency NSViewRepresentable {
        var font: NSFont
        func makeNSView(context: Context) -> NSTextField { NSTextField(labelWithString: "Weighted") }
        func updateNSView(_ view: NSTextField, context: Context) { view.font = font }
    }
    private func fonts(_ node: RenderNode) -> [String] {
        node.modifiers.compactMap { if case .font(let token) = $0 { return token }; return nil }
            + node.children.flatMap(fonts)
    }

    @Test func systemWeightsReachNativeLowering() {
        let previous = NativeLowering.isActive
        NativeLowering.isActive = true
        defer { NativeLowering.isActive = previous }
        let weights: [(NSFont.Weight, String)] = [(.ultraLight, "ultraLight"), (.thin, "thin"), (.light, "light"),
            (.regular, "regular"), (.medium, "medium"), (.semibold, "semibold"), (.bold, "bold"),
            (.heavy, "heavy"), (.black, "black")]
        for (weight, name) in weights {
            let node = ViewResolver.resolve(FontLabel(font: .systemFont(ofSize: 12, weight: weight)))
            #expect(fonts(node).contains("system:12.0+weight:\(name)"))
        }
        #expect(NSFont.systemFont(ofSize: 12).fontName == "System")
    }

    @Test func fixedPitchAndDigitFactoriesRetainTheirTraits() {
        let previous = NativeLowering.isActive
        NativeLowering.isActive = true
        defer { NativeLowering.isActive = previous }
        let mono = ViewResolver.resolve(FontLabel(font: .monospacedSystemFont(ofSize: 13, weight: .medium)))
        #expect(fonts(mono).contains("system:13.0+weight:medium+design:monospaced"))
        let digits = ViewResolver.resolve(FontLabel(font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)))
        #expect(fonts(digits).contains("system:13.0+weight:semibold+monospacedDigit"))
    }

    @Test func namedFontsReachLoweringWithTheirFullFaceName() throws {
        let previous = NativeLowering.isActive
        NativeLowering.isActive = true
        defer { NativeLowering.isActive = previous }
        for name in ["Helvetica-BoldOblique", "System-semibold"] {
            let font = try #require(NSFont(name: name, size: 17))
            let node = ViewResolver.resolve(FontLabel(font: font))
            #expect(fonts(node).contains("native:17.0:\(name)"))
        }
    }

    @Test func bundledInterNamesAreAcceptedAndPreserved() throws {
        let previous = NativeLowering.isActive
        NativeLowering.isActive = true
        defer { NativeLowering.isActive = previous }
        for name in ["Inter-SemiBold", "Inter SemiBold"] {
            let font = try #require(NSFont(name: name, size: 17))
            #expect(font.fontName == name)
            let node = ViewResolver.resolve(FontLabel(font: font))
            #expect(fonts(node).contains("native:17.0:\(name)"))
        }
    }

    @Test func monospacedFactoryNamesCanBeReopened() throws {
        let previous = NativeLowering.isActive
        NativeLowering.isActive = true
        defer { NativeLowering.isActive = previous }
        for weight in [NSFont.Weight.regular, .medium, .semibold, .bold] {
            let original = NSFont.monospacedSystemFont(ofSize: 17, weight: weight)
            let restored = try #require(NSFont(name: original.fontName, size: original.pointSize))
            #expect(restored.fontName == original.fontName)
            let node = ViewResolver.resolve(FontLabel(font: restored))
            #expect(fonts(node).contains("native:17.0:\(original.fontName)"))
        }
    }

    @Test func upstreamMaskBadgeRetainsSemiboldNativeTitle() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32, emptyLayer: true)
        let layer = try #require(session.activeLayer)
        let previous = NativeLowering.isActive
        NativeLowering.isActive = false
        defer { NativeLowering.isActive = previous }
        let host = NSHostingView(rootView: MaskAloneBadge(session: session, layer: layer))
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let title = try #require(fields(host).first { $0.stringValue == "Layer Mask" })
        #expect(title.font?._systemWeightName == "semibold")
        #expect(title.font?.pointSize == 12)
    }
}
