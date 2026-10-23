import CoreGraphics
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct GIFTimelineIntegrationTests {
    private func nodes(_ tree: RenderNode) -> [RenderNode] {
        [tree] + tree.children.flatMap(nodes)
    }

    @Test(arguments: [false, true])
    func originalDelayLabelsSurviveNativeResolution(uniform: Bool) throws {
        let thumbnail = try #require(BrushRaster.context(width: 1, height: 1, mask: false).makeImage())
        // Stable identities differ from display positions, and edited delays override source metadata.
        let frames = [GIFTimelineFrame(index: 4, thumbnail: thumbnail, duration: 0.04),
                      GIFTimelineFrame(index: 2, thumbnail: thumbnail, duration: 0.16)]
        var timing = GIFFrameTiming()
        timing.frameDelays[4] = 0.08
        timing.mode = uniform ? .uniform : .perFrame
        timing.uniformDelay = 0.1
        let view = GIFTimeline(frames: frames, selectedFrameIndex: 4, isPlaying: false, canPlay: true,
                               timing: timing, canEditFrames: true, canEditTiming: true,
                               onSelectFrame: { _ in }, onTogglePlayback: {}, onStopPlayback: {},
                               onChangeTiming: { _ in }, onDuplicateFrame: { _ in }, onDeleteFrame: { _ in })
        let labels = nodes(ViewResolver.resolve(view)).compactMap { $0.stringParams["text"] }
        #expect(labels.contains(uniform ? "100ms" : "80–160ms"))
        #expect(labels.contains("80–160 ms · Original"))
    }
}
