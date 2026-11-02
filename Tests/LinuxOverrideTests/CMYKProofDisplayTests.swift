import Foundation
import CoreGraphics
import Testing
@testable import Compositor

/// View › CMYK › Proof Colors / Gamut Warning on the Linux canvas: the displayed pixels go through upstream's proof
/// lookups on white paper, as `EditorCanvas.gpuFrame` draws them, while the document composite stays as it is.
@MainActor
struct CMYKProofDisplayTests {
    private func profile() throws -> CMYKProfile {
        try #require(CMYK.installed().first { $0.name == "Generic CMYK Profile" }, "the runner installs a CMYK profile")
    }

    /// Distinct pixels in a 4×2 grid (top row first), so a flipped row or column cannot pass.
    private let pixels: [[UInt8]] = [
        [0, 0, 255, 255], [128, 128, 128, 255], [128, 0, 0, 128], [0, 0, 0, 0],
        [255, 0, 0, 255], [0, 255, 0, 255], [255, 255, 255, 255], [40, 90, 200, 255],
    ]

    private func editor() throws -> UpstreamEditor {
        let editor = UpstreamEditor()
        var bytes = [UInt8](repeating: 0, count: 4 * 2 * 4)
        for (i, pixel) in [[0, 0, 255, 255], [0, 0, 0, 255]].enumerated() { bytes.replaceSubrange(i * 4..<i * 4 + 4, with: pixel.map(UInt8.init)) }
        #expect(editor.importRGBA(bytes, width: 4, height: 2, name: "Swatches", replacing: true) == 0)
        return editor
    }

    /// Independent oracle: the premultiplied pixel over white, then a trilinear lookup into `table` (red fastest).
    private func expected(_ pixel: [UInt8], _ table: Data) -> [Float] {
        let n = CMYK.dimension
        let a = Float(pixel[3]) / 255
        let color = (0..<3).map { min(1, max(0, Float(pixel[$0]) / 255 + (1 - a))) * Float(n - 1) }
        let lo = color.map { min(Int($0), n - 2) }, t = (0..<3).map { color[$0] - Float(lo[$0]) }
        return table.withUnsafeBytes { raw -> [Float] in
            let floats = raw.bindMemory(to: Float.self)
            return (0..<3).map { c in
                var v: Float = 0
                for db in 0...1 { for dg in 0...1 { for dr in 0...1 {
                    let w = (dr == 1 ? t[0] : 1 - t[0]) * (dg == 1 ? t[1] : 1 - t[1]) * (db == 1 ? t[2] : 1 - t[2])
                    v += w * floats[(((lo[2] + db) * n + lo[1] + dg) * n + lo[0] + dr) * 4 + c]
                } } }
                return v
            }
        }
    }

    private func display() -> [UInt8] { pixels.flatMap { $0 } }

    private func check(_ e: UpstreamEditor, table: Data) {
        var bytes = display()
        #expect(e.proofForDisplay(&bytes, width: 4, height: 2))
        for (i, pixel) in pixels.enumerated() {
            let got = Array(bytes[i * 4..<i * 4 + 4])
            let want = expected(pixel, table)
            #expect(got[3] == 255, "white paper makes pixel \(i) opaque: \(got)")
            for c in 0..<3 {
                #expect(abs(Float(got[c]) / 255 - want[c]) <= 1.5 / 255, "pixel \(i) channel \(c): \(got) vs \(want.map { $0 * 255 })")
            }
        }
    }

    @Test func offLeavesTheDisplayAsItIs() throws {
        let e = try editor()
        var bytes = display()
        #expect(!e.proofForDisplay(&bytes, width: 4, height: 2))
        #expect(bytes == display())
    }

    @Test func proofColorsUsesTheProofLookupOnWhitePaper() throws {
        let e = try editor(), lookups = try #require(CMYK.proofLookups(try profile()))
        e.session.proofProfile = try profile()
        e.session.proofsColors = true
        check(e, table: lookups.proof)
    }

    @Test func gamutWarningAloneMarksTheDocumentsOwnColors() throws {
        let e = try editor(), lookups = try #require(CMYK.proofLookups(try profile()))
        e.session.proofProfile = try profile()
        e.session.showsGamutWarning = true
        check(e, table: lookups.marked)
        var bytes = display()
        _ = e.proofForDisplay(&bytes, width: 4, height: 2)
        #expect(Array(bytes[0..<3]) == [128, 128, 128], "saturated blue is marked gray")
        #expect(Array(bytes[24..<27]) == [255, 255, 255], "white stays white")
    }

    @Test func bothTogetherUseTheWarningLookup() throws {
        let e = try editor(), lookups = try #require(CMYK.proofLookups(try profile()))
        e.session.proofProfile = try profile()
        e.session.proofsColors = true
        e.session.showsGamutWarning = true
        check(e, table: lookups.warning)
    }

    @Test func theDocumentCompositeKeepsItsColors() throws {
        let e = try editor()
        let before = try e.renderRGBA().bytes
        let key = e.renderKey()
        e.session.proofProfile = try profile()
        e.session.proofsColors = true
        #expect(e.renderKey() != key, "a proof toggle redraws the canvas")
        #expect(try e.renderRGBA().bytes == before, "exports and copies read the document's own colors")
    }
}
