#if os(Linux)
import AppKit
import Foundation
import Testing
import RenderParitySupport

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_PARITY_OUTPUT"] != nil))
struct TextGlyphGeometryTests {
    private struct Reference: Decodable {
        struct Sample: Decodable {
            struct Glyph: Decodable {
                let glyph: UInt32
                let characterIndex: Int
                let location: [Double]
                let lineFragment: [Double]
                let effectiveRange: [Int]?
            }
            struct Fallback: Decodable { let range: [Int] }
            let name: String?
            let face: String
            let size: Double
            let text: String?
            let width: Double?
            let lineHeight: Double?
            let tracking: Double?
            let alignment: Int?
            let nativeFallbacks: [Fallback]?
            let glyphs: [Glyph]
        }
        let text: String?
        let containerWidth: Double?
        let cases: [Sample]
    }

    private func verify(_ filename: String, count: Int) throws {
        try #require(compositor_parity_install() != 0)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/" + filename)
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        #expect(reference.cases.count == count)
        for sample in reference.cases {
            let font = try #require(NSFont(name: sample.face, size: sample.size))
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let tracking = sample.tracking { attributes[.kern] = tracking }
            if sample.width != nil {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = CGFloat(sample.lineHeight ?? 0)
                paragraph.maximumLineHeight = paragraph.minimumLineHeight
                paragraph.alignment = sample.alignment == 1 ? .center : sample.alignment == 2 ? .right : .left
                attributes[.paragraphStyle] = paragraph
            }
            let content = try #require(sample.text ?? reference.text)
            let storage = NSTextStorage(attributedString: NSAttributedString(string: content, attributes: attributes))
            let manager = NSLayoutManager()
            let width = try #require(sample.width ?? reference.containerWidth)
            let container = NSTextContainer(size: CGSize(width: width, height: 1e7))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            let range = manager.glyphRange(for: container)
            #expect(range == NSRange(location: 0, length: sample.glyphs.count))
            #expect(manager.numberOfGlyphs == sample.glyphs.count)
            let fallbacks = sample.nativeFallbacks ?? []
            for (index, expected) in sample.glyphs.enumerated() {
                let id = manager.glyph(at: index)
                let platformGlyph = fallbacks.contains {
                    expected.characterIndex >= $0.range[0] && expected.characterIndex < $0.range[0] + $0.range[1]
                }
                if platformGlyph && expected.glyph != 0 && expected.glyph != 0x00FFFFFF {
                    #expect(id != 0)
                } else {
                    #expect(id == expected.glyph)
                }
                #expect(manager.characterIndexForGlyph(at: index) == expected.characterIndex)
                let location = manager.location(forGlyphAt: index)
                var effective = NSRange(location: NSNotFound, length: 0)
                let fragment = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
                if fallbacks.isEmpty {
                    #expect(abs(Double(location.x) - expected.location[0]) <= 4.0 / 64)
                    #expect(Double(location.y) == expected.location[1])
                    #expect(fragment == CGRect(x: expected.lineFragment[0], y: expected.lineFragment[1],
                                               width: expected.lineFragment[2], height: expected.lineFragment[3]))
                } else {
                    // Native font identity records Apple Color Emoji; Linux uses
                    // its installed fallback. Preserve UTF-16 and glyph ranges
                    // without treating different fonts' metrics as equal inputs.
                    #expect(location.x.isFinite && location.y.isFinite && fragment.height > 0)
                }
                let expectedRange = expected.effectiveRange.map { NSRange(location: $0[0], length: $0[1]) } ?? range
                #expect(effective == expectedRange)
            }
        }
    }

    @Test func glyphGeometryMatchesNativeLayout() throws {
        try verify("text-glyph-geometry-reference.json", count: 18)
    }

    @Test func paragraphsMatchNativeGlyphSemantics() throws {
        try verify("text-paragraph-geometry-reference.json", count: 45)
    }
}
#endif
