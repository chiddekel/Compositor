import Foundation
import CoreGraphics
import Testing
@testable import Compositor

@MainActor
struct LivePreviewTests {
    private func editor(masked: Bool = false, group: Bool = false) throws -> UpstreamEditor {
        let editor = UpstreamEditor()
        var bytes = [UInt8](repeating: 0, count: 64 * 32 * 4)
        for y in 0..<32 { for x in 0..<64 {
            let i = (y * 64 + x) * 4
            bytes[i] = UInt8(x * 3); bytes[i + 1] = UInt8(y * 6)
            bytes[i + 2] = 100; bytes[i + 3] = 255
        } }
        #expect(editor.importRGBA(bytes, width: 64, height: 32, name: "Pattern", replacing: true) == 0)
        let s = editor.session
        if group { s.groupSelectedLayers() }
        if masked {
            let context = try BrushRaster.context(width: 64, height: 32, mask: true)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 4, y: 8, width: 8, height: 16))
            let image = try #require(context.makeImage())
            let index = try #require(s.document?.layers.firstIndex { $0.id == s.activeLayerID })
            s.document?.layers[index].mask = LayerMask(asset: try LayerMask.asset(from: image))
        }
        return editor
    }

    private func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
        Array(bytes[(y * 64 + x) * 4..<(y * 64 + x + 1) * 4])
    }

    private func checkRegion(_ editor: UpstreamEditor, whole: [UInt8], rect: CGRect, tolerance: Int = 0) throws {
        let region = try editor.renderRegionRGBA(rect)
        var maximumDifference = 0
        for y in 0..<region.height {
            let a = ((Int(region.rect.minY) + y) * 64 + Int(region.rect.minX)) * 4
            let b = y * region.width * 4
            for x in 0..<region.width * 4 {
                maximumDifference = max(maximumDifference, abs(Int(whole[a + x]) - Int(region.bytes[b + x])))
            }
        }
        #expect(maximumDifference <= tolerance)
    }

    @Test(arguments: [false, true])
    func maskToggleChangesPixelsAndCacheKey(group: Bool) throws {
        let e = try editor(masked: true, group: group)
        let s = e.session
        #expect(s.activeLayer?.isGroup == group)
        let key = e.renderKey()
        let masked = try e.renderRGBA().bytes
        #expect(pixel(masked, 6, 16)[3] == 0)
        s.toggleLayerMask()
        #expect(e.renderKey() != key)
        let revealed = try e.renderRGBA().bytes
        #expect(pixel(revealed, 6, 16)[3] == 255)
        #expect(revealed != masked)
        s.undo()
        #expect(try e.renderRGBA().bytes == masked)
        s.redo()
        #expect(try e.renderRGBA().bytes == revealed)
    }

    @Test(arguments: [false, true], 0..<4)
    func maskTransformPreviewMatchesCommit(linked: Bool, variant: Int) throws {
        let maskTarget = variant & 1 != 0, resize = variant & 2 != 0
        let e = try editor(masked: true)
        let s = e.session
        let id = try #require(s.activeLayerID)
        if !linked { s.toggleMaskLink(id) }
        s.selectLayerTarget(id, mask: maskTarget)
        let original = try e.renderRGBA().bytes
        let originalTransform = try #require(s.activeLayer?.transform)
        let beginPreview = {
            s.beginTransform()
            var draft = try #require(s.transformEdit?.draft)
            if resize { draft.size.width *= 1.5 } else { draft.origin.x += 16 }
            s.previewTransform(draft)
        }
        try beginPreview()
        let layer = try #require(s.activeLayer)
        #expect(e.displayedSnapshot()?.manifest.layers.first?.maskPlacement == s.displayedMaskPlacement(for: layer))
        if maskTarget && !linked {
            #expect(s.displayedTransform(for: layer) == originalTransform)
            #expect(s.editedTransform(for: layer) == s.displayedMaskPlacement(for: layer))
        }
        let preview = try e.renderRGBA().bytes
        #expect(preview != original)
        // Fractional resampling can round one byte differently when translated
        // into a cropped surface, as in the existing region-render tests.
        try checkRegion(e, whole: preview, rect: CGRect(x: 8, y: 4, width: 32, height: 24), tolerance: resize ? 1 : 0)
        s.cancelTransform()
        #expect(try e.renderRGBA().bytes == original)
        try beginPreview()
        #expect(try e.renderRGBA().bytes == preview)
        s.commitTransform()
        #expect(try e.renderRGBA().bytes == preview)
        s.undo()
        #expect(try e.renderRGBA().bytes == original)
        s.redo()
        #expect(try e.renderRGBA().bytes == preview)
    }

    @Test(arguments: [false, true], [false, true])
    func selectedPixelsPreviewCancelCommitAndUndo(duplicate: Bool, masked: Bool) async throws {
        let e = try editor(masked: masked)
        let s = e.session
        let entry = Entry(editor: e)
        let selection = CGRect(x: 16, y: 8, width: 8, height: 8)
        s.setSelection(DocumentSelection(path: CGPath(rect: selection, transform: nil)), name: "Select")
        s.isMaskSelected = false
        let original = try e.renderRGBA().bytes
        let key = e.renderKey()
        #expect(s.beginPixelMove(duplicate: duplicate))
        s.movePixels(by: CGSize(width: 16, height: 0))
        entry.noteStrokeProgress()
        #expect(entry.strokeDirty != nil)
        #expect(e.renderKey() != key)
        let preview = try e.renderRGBA().bytes
        #expect(preview != original)
        #expect(pixel(preview, 34, 10) == pixel(original, 18, 10))
        #expect(pixel(preview, 18, 10) == (duplicate ? pixel(original, 18, 10) : [0, 0, 0, 0]))
        #expect(s.displayedSelection?.path.boundingBoxOfPath == selection.offsetBy(dx: 16, dy: 0))
        try checkRegion(e, whole: preview, rect: CGRect(x: 4, y: 4, width: 44, height: 24))
        // Another move must restore the old target while changing the next one.
        s.movePixels(by: CGSize(width: 24, height: 0))
        entry.noteStrokeProgress()
        let next = try e.renderRGBA().bytes
        #expect(next != preview)
        #expect(pixel(next, 34, 10) == pixel(original, 34, 10))
        try checkRegion(e, whole: next, rect: CGRect(x: 4, y: 4, width: 48, height: 24))
        s.cancelPixelMove()
        entry.noteStrokeProgress()
        #expect(entry.strokeDirty == nil)
        #expect(try e.renderRGBA().bytes == original)
        #expect(s.selection?.path.boundingBoxOfPath == selection)
        #expect(s.beginPixelMove(duplicate: duplicate))
        s.movePixels(by: CGSize(width: 16, height: 0))
        await s.finishPixelMove()
        #expect(try e.renderRGBA().bytes == preview)
        #expect(s.history.undoName == (duplicate ? "Duplicate Pixels" : "Move Pixels"))
        s.undo()
        #expect(try e.renderRGBA().bytes == original)
        #expect(s.selection?.path.boundingBoxOfPath == selection)
        s.redo()
        #expect(try e.renderRGBA().bytes == preview)
    }
}
