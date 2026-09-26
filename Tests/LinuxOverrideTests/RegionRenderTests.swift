import Foundation
import Testing
@testable import Compositor

/// `UpstreamEditor.renderRegionRGBA` (the mid-stroke partial render behind `compositor_session_render_dirty`) must
/// produce exactly the pixels of the same area of the whole-document render.
@MainActor
struct RegionRenderTests {
    private func cmd(_ action: String, _ fields: String = "") -> Data {
        Data(#"{"version":1,"action":"\#(action)"\#(fields.isEmpty ? "" : "," + fields)}"#.utf8)
    }

    @Test(arguments: [BlurToolMode.liquify, .smudge], [false, true])
    func warpPreviewAndDirtyRegion(mode: BlurToolMode, masked: Bool) throws {
        let w = 240, h = 180
        var pattern = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            pattern[i] = UInt8(x % 128); pattern[i + 1] = UInt8(y % 128)
        } }
        let e = UpstreamEditor()
        #expect(e.importRGBA(pattern, width: w, height: h, name: "Pattern", replacing: true) == 0)
        let entry = Entry(editor: e)
        let s = e.session
        if masked {
            let context = try BrushRaster.context(width: 2, height: 2, mask: true)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            context.setFillColor(gray: 0.25, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            let image = try #require(context.makeImage())
            s.document?.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: image))
            s.document?.layers[0].transform = LayerTransform(origin: CGPoint(x: 20, y: 10),
                                                           size: CGSize(width: 200, height: 150))
        }
        s.selectTool(.blur)
        s.blurMode = mode
        s.brushSettings.diameter = 32
        s.brushSettings.hardness = 0.5
        s.brushSettings.opacity = 0.7
        let original = try e.renderRGBA().bytes
        s.beginWarp(at: CGPoint(x: 90, y: 80))
        entry.noteStrokeProgress()
        #expect(entry.strokeDirty == nil)
        s.continueBrush(at: CGPoint(x: 130, y: 90))
        entry.noteStrokeProgress()
        let dirty = try #require(entry.strokeDirty)
        #expect(dirty.width < CGFloat(w) && dirty.height < CGFloat(h))
        let whole = try e.renderRGBA()
        #expect(whole.bytes != original, "Warp must be visible before release")
        let region = try e.renderRegionRGBA(dirty)
        var mismatchCount = 0
        for y in 0..<region.height {
            let start = ((Int(region.rect.minY) + y) * w + Int(region.rect.minX)) * 4
            for x in 0..<(region.width * 4) where whole.bytes[start + x] != region.bytes[y * region.width * 4 + x] {
                mismatchCount += 1
            }
        }
        #expect(mismatchCount == 0, "Partial warp render must match the same pixels in a whole frame")
        // Reading a frame consumes the region; a stationary event must not republish old dabs.
        entry.strokeDirty = nil
        entry.noteStrokeProgress()
        #expect(entry.strokeDirty == nil)
        s.cancelBrush()
        entry.noteStrokeProgress()
        #expect(entry.strokeDirty == nil)
        #expect(try e.renderRGBA().bytes == original)
        s.beginWarp(at: CGPoint(x: 0, y: 0))
        s.continueBrush(at: CGPoint(x: 10, y: 5))
        entry.noteStrokeProgress()
        let edge = try #require(entry.strokeDirty)
        #expect(edge.minX == 0 && edge.minY == 0)
        #expect(edge.maxX < 40 && edge.maxY < 40, "New stroke must not retain the old dirty area")
        s.cancelBrush()
    }

    @Test func regionMatchesWholeRenderMidStroke() async throws {
        let w = 1600, h = 1200
        var pattern = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            pattern[i] = UInt8(x * 255 / w); pattern[i + 1] = UInt8(y * 255 / h); pattern[i + 2] = 90; pattern[i + 3] = 255
        } }
        let e = UpstreamEditor()
        #expect(e.importRGBA(pattern, width: w, height: h, name: "Imported", replacing: true) == 0)
        #expect(await e.commandAsync(cmd("addLayer")) == 0)
        #expect(await e.commandAsync(cmd("brushBegin", #""x":300,"y":300,"parameters":{"diameter":40,"hardness":0.5,"opacity":0.8,"red":1,"green":0,"blue":0}"#)) == 0)
        for step in 1...20 { #expect(await e.commandAsync(cmd("brushMove", #""x":\#(300 + step * 10),"y":\#(300 + step * 4)"#)) == 0) }
        let dirty = try #require(e.session.brushStroke?.dirtyDocumentRect)

        var clock = ContinuousClock.now
        let whole = try e.renderRGBA()
        let wholeTime = ContinuousClock.now - clock
        clock = ContinuousClock.now
        let region = try e.renderRegionRGBA(dirty)
        let regionTime = ContinuousClock.now - clock
        print("RegionRenderTests: whole \(w)x\(h) \(wholeTime), region \(region.rect) \(regionTime)")

        let rw = Int(region.rect.width), rh = Int(region.rect.height), rx = Int(region.rect.minX), ry = Int(region.rect.minY)
        #expect(region.bytes.count == rw * rh * 4)
        var mismatches = 0
        for y in 0..<rh { for x in 0..<rw {
            let a = ((ry + y) * w + rx + x) * 4, b = (y * rw + x) * 4
            for c in 0..<4 where abs(Int(whole.bytes[a + c]) - Int(region.bytes[b + c])) > 1 { mismatches += 1 }
        } }
        #expect(mismatches == 0)
        #expect(await e.commandAsync(cmd("brushEnd")) == 0)
    }
}
