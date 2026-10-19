import Foundation
import CoreGraphics
import Testing
@testable import Compositor

/// A live Smudge turn dabs for a time budget, not a fixed count: at 4 dabs a turn (1 px apart) a fast drag fell
/// further behind the pointer every frame, and the queue then ran after the button came up.
// Regression: smudge trails a fast drag and keeps working after release
// Found by /investigate on 2026-10-19
@MainActor
@Suite(.serialized) struct WarpLiveBudgetTests {
    @Test func liveTurnKeepsUpWithAFastJump() throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 120, count: 400 * 120 * 4), width: 400, height: 120, name: "Grey",
                                  replacing: true) == 0)
        let session = editor.session
        session.blurMode = .smudge
        session.brushSettings.diameter = 40
        let old = WarpStroke.timeSlicesLiveStrokes
        WarpStroke.timeSlicesLiveStrokes = true
        defer { WarpStroke.timeSlicesLiveStrokes = old }
        session.beginWarp(at: CGPoint(x: 40, y: 60))
        let warp = try #require(session.warpStroke)
        // One pointer event 60 px on: 60 dabs at Smudge's 1 px spacing. They fit one turn's budget many times over.
        warp.append(CGPoint(x: 100, y: 60))
        #expect(warp.points.count > 4, "a live turn laid only \(warp.points.count) dabs")
        #expect(!warp.hasPendingDabs || warp.points.count >= 8)
        session.finishWarp()
    }
}
