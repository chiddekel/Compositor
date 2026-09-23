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
