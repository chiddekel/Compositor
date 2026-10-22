import Foundation
import CoreGraphics
import Testing
@testable import Compositor

/// Upstream README features with no upstream test of their own, checked through the unchanged upstream code on Linux.
/// (SVG import needs Qt's renderer and a QGuiApplication: the native `--svg-import-probe` journey covers it.)
@MainActor
struct ReadmeFeatureAcceptanceTests {
    private func editor() -> UpstreamEditor {
        let editor = UpstreamEditor()
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        for y in 0..<32 { for x in 0..<32 {
            let i = (y * 32 + x) * 4
            bytes[i] = x < 16 ? 255 : 0; bytes[i + 1] = UInt8(y * 8); bytes[i + 2] = x < 16 ? 0 : 255; bytes[i + 3] = 255
        } }
        #expect(editor.importRGBA(bytes, width: 32, height: 32, name: "Pattern", replacing: true) == 0)
        return editor
    }

    /// Filter › Last Filter (⌃⌘F) runs the last filter again with the same settings, without its panel.
    @Test func lastFilterRunsTheFilterAgainWithItsSettings() async throws {
        let e = editor(), s = e.session
        let original = try e.renderRGBA().bytes
        #expect(!s.canRepeatLastFilter, "nothing to repeat before a filter")
        s.beginFilter(.gaussianBlur)
        #expect(s.filterEdit != nil)
        await s.commitFilter()
        e.settle()
        let once = try e.renderRGBA().bytes
        #expect(once != original, "the blur changed the pattern")
        #expect(s.lastFilter == .gaussianBlur && s.canRepeatLastFilter)
        s.undo()
        e.settle()
        #expect(try e.renderRGBA().bytes == original)
        await s.repeatLastFilter()
        e.settle()
        #expect(s.filterEdit == nil, "Last Filter applies without leaving a panel open")
        #expect(try e.renderRGBA().bytes == once, "the same filter with the same settings")
        #expect(s.history.undoName == "Gaussian Blur")
    }
}
