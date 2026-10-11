import Foundation
import CoreGraphics
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized) struct WarpCommitParityTests {
    @Test(arguments: [BlurToolMode.liquify, .smudge], [31.5, 65.0])
    func finalPixelsAndHistoryMatchUpstream(mode: BlurToolMode, diameter: Double) throws {
        try verify(mode: mode, diameter: diameter, timeSliced: true)
    }

    @Test(arguments: [BlurToolMode.liquify, .smudge], [31.5, 65.0])
    func synchronousCommitMatchesUpstream(mode: BlurToolMode, diameter: Double) throws {
        try verify(mode: mode, diameter: diameter, timeSliced: false)
    }

    @Test(arguments: [BlurToolMode.liquify, .smudge])
    func selectedTransformedLayerSurvivesRepeatedResumes(mode: BlurToolMode) throws {
        try verify(mode: mode, diameter: 31.5, timeSliced: true, transformed: true, edges: false)
    }
    @Test(arguments: [BlurToolMode.liquify, .smudge])
    func canvasEdgesAndOutsideSamplesMatchUpstream(mode: BlurToolMode) throws {
        try verify(mode: mode, diameter: 65, timeSliced: true, transformed: false, edges: true)
    }
    @Test(arguments: [false, true])
    func changedTargetsRefuseCommit(replaceAsset: Bool) throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 120, count: 32 * 32 * 4), width: 32, height: 32, name: "Original", replacing: true) == 0)
        let session = editor.session
        session.beginWarp(at: CGPoint(x: 5, y: 5))
        let warp = try #require(session.warpStroke)
        warp.append(CGPoint(x: 20, y: 20))
        if replaceAsset {
            let layer = try #require(session.activeLayer)
            let context = try BrushRaster.context(width: 32, height: 32, mask: false)
            let image = try #require(context.makeImage())
            session.document?.layers[0].asset = ImportedImage(image: image, thumbnail: image, name: layer.name)
        } else { session.document?.layers[0].transform.origin.x += 1 }
        // Rendering an active warp includes its live preview; compare the current document instead.
        session.warpStroke = nil
        let before = try editor.renderRGBA().bytes
        let beforeAsset = session.activeLayer?.asset?.image
        session.warpStroke = warp
        let undoName = session.history.undoName
        session.finishWarp()
        let after = try editor.renderRGBA().bytes
        let mismatches = zip(after, before).filter { $0 != $1 }.count
        #expect(mismatches == 0)
        #expect(session.activeLayer?.asset?.image === beforeAsset)
        #expect(session.warpStroke == nil && session.history.undoName == undoName)
    }

    private func verify(mode: BlurToolMode, diameter: Double, timeSliced: Bool, transformed: Bool = false, edges: Bool = false) throws {
        let width = 128, height = 96
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8((x * 7) % 64)
            bytes[offset + 1] = UInt8((y * 11) % 64)
            bytes[offset + 2] = UInt8((x + y * 3) % 64)
            bytes[offset + 3] = UInt8(64 + (x * y) % 192)
        } }
        let actual = UpstreamEditor(), expected = UpstreamEditor()
        for editor in [actual, expected] {
            #expect(editor.importRGBA(bytes, width: width, height: height, name: "Pattern", replacing: true) == 0)
            editor.session.blurMode = mode
            editor.session.brushSettings.diameter = diameter
            editor.session.brushSettings.hardness = 0.5
            editor.session.brushSettings.opacity = 0.7
        }
        if transformed {
            for editor in [actual, expected] {
                editor.session.document?.layers[0].transform = LayerTransform(origin: CGPoint(x: 5, y: 7), size: CGSize(width: 108, height: 78), rotation: 17)
                editor.session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 20, y: 20, width: 45, height: 35), transform: nil)), name: "Select")
            }
        }
        let before = try actual.renderRGBA().bytes
        let referenceLayer = try #require(expected.session.activeLayer)
        let referenceImage = try #require(referenceLayer.asset?.image)
        let reference = try ReferenceWarpStroke(layer: referenceLayer, image: referenceImage,
            transform: referenceLayer.transform, canvas: CGSize(width: width, height: height), mode: mode,
            settings: expected.session.brushSettings)
        let points = edges
            ? [CGPoint(x: -12, y: -3), CGPoint(x: 8, y: 15), CGPoint(x: 115, y: 85), CGPoint(x: 135, y: 110), CGPoint(x: 5, y: 90)]
            : [CGPoint(x: 18, y: 18), CGPoint(x: 70, y: 25), CGPoint(x: 55, y: 65), CGPoint(x: 20, y: 42)]
        let oldTimeSlices = WarpStroke.timeSlicesLiveStrokes
        WarpStroke.timeSlicesLiveStrokes = timeSliced
        defer { WarpStroke.timeSlicesLiveStrokes = oldTimeSlices }
        actual.session.beginWarp(at: points[0])
        let warp = try #require(actual.session.warpStroke)
        reference.append(points[0])
        for point in points.dropFirst() {
            warp.append(point); reference.append(point)
            if transformed || edges { _ = warp.continuePending(); _ = warp.continuePending() }
        }
        actual.session.finishWarp()
        expected.session.finishReferenceWarp(reference)
        let pointMismatchCount = zip(warp.points, reference.points).filter { $0 != $1 }.count + abs(warp.points.count - reference.points.count)
        #expect(pointMismatchCount == 0)
        #expect(actual.session.brushError == nil)
        #expect(expected.session.brushError == nil)
        let committed = try actual.renderRGBA().bytes
        let referencePixels = try expected.renderRGBA().bytes
        #expect(committed != before)
        let pixelMismatchCount = zip(committed, referencePixels).filter { $0 != $1 }.count + abs(committed.count - referencePixels.count)
        #expect(pixelMismatchCount == 0)
        let actualAsset = try #require(actual.session.activeLayer?.asset?.image.bytes)
        let referenceAsset = try #require(expected.session.activeLayer?.asset?.image.bytes)
        let assetMismatchCount = zip(actualAsset, referenceAsset).filter { $0 != $1 }.count + abs(actualAsset.count - referenceAsset.count)
        #expect(assetMismatchCount == 0)
        for editor in [actual, expected] { editor.session.undo() }
        let undone = try actual.renderRGBA().bytes, referenceUndone = try expected.renderRGBA().bytes
        #expect(undone == before)
        #expect(referenceUndone == before)
        for editor in [actual, expected] { editor.session.redo() }
        let redone = try actual.renderRGBA().bytes, referenceRedone = try expected.renderRGBA().bytes
        #expect(redone == committed)
        #expect(referenceRedone == referencePixels)
    }
}
