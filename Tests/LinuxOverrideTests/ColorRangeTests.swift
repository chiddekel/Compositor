import Foundation
import Testing
import AppKit
@testable import Compositor

@MainActor
struct ColorRangeTests {
    private func editor() -> UpstreamEditor {
        let e = UpstreamEditor()
        var pixels = [UInt8]()
        for _ in 0..<8 {
            for x in 0..<16 {
                pixels += x < 4 || (8..<12).contains(x) ? [255, 0, 0, 255] : x < 8 ? [0, 0, 255, 255] : [0, 0, 0, 0]
            }
        }
        #expect(e.importRGBA(pixels, width: 16, height: 8, name: "Colors", replacing: true) == 0)
        return e
    }

    private func wait(_ s: EditorSession) async throws {
        // Full-suite rendering can occupy the main actor for more than five
        // seconds. This bounds completion, not the performance of the worker.
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: .seconds(60))
        while s.colorRange?.isWorking == true, clock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
        try #require(s.colorRange?.isWorking != true)
        #expect(s.colorRange?.error == nil)
    }

    private func selected(_ s: EditorSession, _ x: Int, _ y: Int = 4) -> Bool {
        s.selection?.path.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) == true
    }

    @Test func samplesAllVisiblePixelsAndCommitsOneUndoStep() async throws {
        let e = editor(), s = e.session
        s.selectAll()
        let original = s.selection, revision = s.history.currentRevision
        s.beginColorRange()
        #expect(!s.canEditSelection && !s.canUseHistory && !s.canStartProjectOperation)
        s.sampleColorRange(at: CGPoint(x: 2, y: 4), shift: false, option: false)
        #expect(s.colorRange?.isWorking == true)
        s.commitColorRange()
        #expect(s.colorRange != nil) // Computing cannot accept an obsolete preview.
        try await wait(s)
        #expect(selected(s, 2) && selected(s, 10) && !selected(s, 6) && !selected(s, 14))
        #expect(s.colorRange?.preview != nil)
        #expect(s.history.currentRevision == revision)
        s.commitColorRange()
        let chosen = s.selection
        #expect(s.colorRange == nil && s.canEditSelection)
        #expect(s.history.currentRevision != revision)
        s.undo(); #expect(s.selection == original && s.history.currentRevision == revision)
        s.redo(); #expect(s.selection == chosen)
    }

    @Test func addRemoveInvertAndCancelRestoreOriginal() async throws {
        let s = editor().session
        s.beginColorRange()
        s.sampleColorRange(at: CGPoint(x: 2, y: 4), shift: false, option: false)
        s.sampleColorRange(at: CGPoint(x: 6, y: 4), shift: true, option: false)
        try await wait(s)
        #expect(selected(s, 2) && selected(s, 6) && selected(s, 10))
        s.sampleColorRange(at: CGPoint(x: 2, y: 4), shift: true, option: true)
        try await wait(s)
        #expect(!selected(s, 2) && selected(s, 6) && !selected(s, 10))
        s.colorRange?.invert = true; s.updateColorRange()
        try await wait(s)
        #expect(selected(s, 2) && !selected(s, 6) && selected(s, 14))
        s.cancelColorRange(); #expect(s.selection == nil)
    }

    @Test func latestPreviewWinsAndCancelDiscardsPendingJobs() async throws {
        let s = editor().session
        s.selectAll(); let original = s.selection, revision = s.history.currentRevision
        s.beginColorRange()
        for index in 0..<20 {
            s.sampleColorRange(at: CGPoint(x: index.isMultiple(of: 2) ? 2 : 6, y: 4), shift: false, option: false)
        }
        try await wait(s)
        #expect(!selected(s, 2) && selected(s, 6))
        s.sampleColorRange(at: CGPoint(x: 2, y: 4), shift: false, option: false)
        s.cancelColorRange()
        try await Task.sleep(for: .milliseconds(100))
        #expect(s.colorRange == nil && s.selection == original && s.history.currentRevision == revision)
    }

    @Test func transparentAndInvalidSamplesLeaveEditUnchanged() async throws {
        let s = editor().session
        s.beginColorRange()
        for point in [CGPoint(x: 14, y: 4), CGPoint(x: -1, y: 0), CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: CGFloat.nan, y: 0)] {
            s.sampleColorRange(at: point, shift: false, option: false)
        }
        #expect(s.colorRange?.hasColors == false && s.colorRange?.isWorking == false)
        s.commitColorRange(); #expect(s.selection == nil && s.colorRange == nil)
    }

    @Test func fuzzinessUsesStraightColorsAndIgnoresTransparency() async throws {
        let e = UpstreamEditor()
        var pixels = [UInt8]()
        for _ in 0..<8 {
            for x in 0..<16 {
                pixels += x < 4 ? [255, 0, 0, 255] : x < 8 ? [235, 0, 0, 255] : x < 12 ? [128, 0, 0, 128] : [0, 0, 0, 0]
            }
        }
        #expect(e.importRGBA(pixels, width: 16, height: 8, name: "Tolerance", replacing: true) == 0)
        let s = e.session
        s.beginColorRange(); s.colorRange?.fuzziness = 0
        s.sampleColorRange(at: CGPoint(x: 2, y: 4), shift: false, option: false)
        try await wait(s)
        #expect(selected(s, 2) && !selected(s, 6) && selected(s, 10) && !selected(s, 14))
        s.colorRange?.fuzziness = 20; s.updateColorRange(); try await wait(s)
        #expect(selected(s, 6))
        s.colorRange?.fuzziness = 19; s.updateColorRange(); try await wait(s)
        #expect(!selected(s, 6))
        s.cancelColorRange()
    }

    @Test func removingEveryPickedColorCommitsAnEmptySelectionUndoably() async throws {
        let s = editor().session
        s.selectAll(); let original = s.selection
        s.beginColorRange()
        s.sampleColorRange(at: CGPoint(x: 2, y: 4), shift: false, option: false)
        s.sampleColorRange(at: CGPoint(x: 2, y: 4), shift: false, option: true)
        try await wait(s)
        #expect(s.selection == nil)
        s.commitColorRange(); #expect(s.selection == nil && s.colorRange == nil)
        s.undo(); #expect(s.selection == original)
        s.redo(); #expect(s.selection == nil)
    }
}
