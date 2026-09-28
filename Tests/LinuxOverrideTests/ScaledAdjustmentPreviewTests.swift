import Foundation
import CoreGraphics
import Testing
@testable import Compositor

@MainActor
struct ScaledAdjustmentPreviewTests {
    private let width = 256, height = 192

    private func fixture(_ kind: AdjustmentKind, layout: Int = 0) throws -> UpstreamEditor {
        let e = UpstreamEditor()
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let bright = (64..<192).contains(x) && (48..<144).contains(y)
            let i = (y * width + x) * 4
            bytes[i] = bright ? 232 : 24; bytes[i + 1] = bright ? 180 : 48; bytes[i + 2] = bright ? 120 : 72
        } }
        #expect(e.importRGBA(bytes, width: width, height: height, name: "Edges", replacing: true) == 0)
        let s = e.session
        let base = try #require(s.activeLayerID)
        var folder: UUID?
        if layout == 2 {
            s.groupSelectedLayers()
            folder = s.activeLayerID
            s.selectLayer(base)
        }
        s.addAdjustment(kind)
        let id = try #require(s.activeLayerID)
        var adjustment = try #require(s.activeLayer?.adjustment)
        adjustment.gaussianRadius = 12
        adjustment.resolvedMotionDistance = 48
        adjustment.resolvedMotionAngle = 27
        s.updateAdjustment(id, value: adjustment)
        s.adjustmentEditingID = nil
        if layout != 0 {
            let ctx = try BrushRaster.context(width: width, height: height, mask: true)
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
            let mask = try LayerMask.asset(from: #require(ctx.makeImage()))
            let index = try #require(s.document?.layers.firstIndex { $0.id == (folder ?? id) })
            s.document?.layers[index].mask = LayerMask(asset: mask)
        }
        return e
    }

    /// Independent area average of the full-resolution composite, not the preview
    /// renderer or its resampling implementation.
    private func downsample(_ bytes: [UInt8], factor: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width / factor * height / factor * 4)
        for y in 0..<height / factor { for x in 0..<width / factor { for c in 0..<4 {
            var sum = 0
            for dy in 0..<factor { for dx in 0..<factor {
                sum += Int(bytes[((y * factor + dy) * width + x * factor + dx) * 4 + c])
            } }
            result[(y * (width / factor) + x) * 4 + c] = UInt8((sum + factor * factor / 2) / (factor * factor))
        } } }
        return result
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> (maximum: Int, mean: Double) {
        #expect(a.count == b.count)
        var maximum = 0, total = 0
        for (x, y) in zip(a, b) {
            let d = abs(Int(x) - Int(y))
            maximum = max(maximum, d); total += d
        }
        return (maximum, Double(total) / Double(max(1, a.count)))
    }

    @Test(arguments: [AdjustmentKind.gaussianBlur, .motionBlur], 0..<3)
    func previewMatchesDownsampledFullResolution(kind: AdjustmentKind, layout: Int) async throws {
        let e = try fixture(kind, layout: layout)
        let saved = try JSONSerialization.jsonObject(with: e.exportManifest()) as? NSDictionary
        let full = try e.renderRGBA().bytes
        for factor in [2, 4] {
            let small = try e.renderRegionRGBA(CGRect(x: 0, y: 0, width: width, height: height), scale: 1 / CGFloat(factor))
            #expect(small.width == width / factor && small.height == height / factor)
            let reference = downsample(full, factor: factor)
            let error = difference(small.bytes, reference)
            // Blur and reduction do not commute at hard mask or canvas edges.
            // Bound the whole-image error against area averaging, and independently
            // require exact pixels from upstream at explicit reduced distances.
            let prepared = try e.regionSnapshot(CGRect(x: 0, y: 0, width: width, height: height), scale: 1 / CGFloat(factor))
            var manifest = prepared.snapshot.manifest
            for i in manifest.layers.indices {
                guard var adjustment = manifest.layers[i].adjustment else { continue }
                adjustment.gaussianRadius /= Double(factor)
                adjustment.resolvedMotionDistance /= Double(factor)
                manifest.layers[i].adjustment = adjustment
            }
            let explicit = ProjectSnapshot(manifest: manifest, images: prepared.snapshot.images, masks: prepared.snapshot.masks)
            let expected = try await ImageExporter.shared.render(explicit).image
            let context = try BrushRaster.context(width: small.width, height: small.height, mask: false)
            BrushRaster.draw(expected, in: CGRect(x: 0, y: 0, width: small.width, height: small.height), mask: false, context: context)
            let expectedBytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: small.width * small.height * 4))
            #expect(small.bytes == expectedBytes)
            #expect(error.mean <= 2)
        }
        #expect(try JSONSerialization.jsonObject(with: e.exportManifest()) as? NSDictionary == saved)
    }

    @Test(arguments: [AdjustmentKind.gaussianBlur, .motionBlur], [CGFloat(1), 0.5, 0.25])
    func partialBlurHasSamplingHalo(kind: AdjustmentKind, scale: CGFloat) throws {
        let e = try fixture(kind, layout: 1)
        // Two sequential adjustments need the sum of their sampling supports.
        e.session.addAdjustment(kind)
        e.session.adjustmentEditingID = nil
        let full = try e.renderRegionRGBA(CGRect(x: 0, y: 0, width: width, height: height), scale: scale)
        for requested in [CGRect(x: 151, y: 41, width: 50, height: 57), CGRect(x: 0, y: 0, width: 43, height: 37)] {
            let part = try e.renderRegionRGBA(requested, scale: scale)
            let x0 = Int((part.rect.minX * scale).rounded()), y0 = Int((part.rect.minY * scale).rounded())
            var reference = [UInt8]()
            for y in 0..<part.height {
                let start = ((y0 + y) * full.width + x0) * 4
                reference.append(contentsOf: full.bytes[start..<start + part.width * 4])
            }
            #expect(difference(part.bytes, reference).maximum <= 1)
        }
    }

    @Test func fractionalRadiusAndSettingsSurviveRendering() async throws {
        let e = try fixture(.gaussianBlur)
        let s = e.session
        let id = try #require(s.activeLayerID)
        var adjustment = try #require(s.activeLayer?.adjustment)
        adjustment.gaussianRadius = 0.1
        s.updateAdjustment(id, value: adjustment)
        let prepared = try e.regionSnapshot(CGRect(x: 0, y: 0, width: width, height: height), scale: 0.25)
        #expect(prepared.snapshot.manifest.layers.last?.adjustment == adjustment)
        #expect(prepared.scale == 0.25)
        let foreground = try e.renderRegionRGBA(CGRect(x: 0, y: 0, width: width, height: height), scale: prepared.scale)
        let background = try await UpstreamEditor.renderInBackground(prepared.snapshot, scale: prepared.scale)
        #expect(background.bytes == foreground.bytes)
        // At sigma 0.025 the blur is subpixel and preserves this area-downsampled
        // step. Rendering must not round the requested radius up to one pixel.
        s.document?.layers.removeLast()
        let unblurred = try e.renderRegionRGBA(CGRect(x: 0, y: 0, width: width, height: height), scale: 0.25)
        #expect(difference(foreground.bytes, unblurred.bytes).maximum <= 1)
    }

    @Test(arguments: [AdjustmentKind.gaussianBlur, .motionBlur])
    func regressionRejectsTheOldUnscaledRadius(kind: AdjustmentKind) async throws {
        let e = try fixture(kind)
        let reference = downsample(try e.renderRGBA().bytes, factor: 4)
        let prepared = try e.regionSnapshot(CGRect(x: 0, y: 0, width: width, height: height), scale: 0.25)
        let corrected = try await UpstreamEditor.renderInBackground(prepared.snapshot, scale: prepared.scale)
        // This reproduces the old Linux behavior: geometry was quarter-sized,
        // but the exporter still applied adjustment distances at scale 1.
        let old = try await UpstreamEditor.renderInBackground(prepared.snapshot, scale: 1)
        let correctError = difference(corrected.bytes, reference)
        let oldError = difference(old.bytes, reference)
        #expect(oldError.maximum > 12 && oldError.mean > 2)
        #expect(correctError.maximum < oldError.maximum && correctError.mean < oldError.mean)
        let snapshot = try #require(e.session.projectSnapshot())
        let upstream = try await ImageExporter.shared.render(snapshot).image
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(upstream, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        #expect(try e.renderRGBA().bytes == bytes, "Full resolution must still match the protected upstream exporter")
    }

    @Test func dirtyPixelsIncludeBlurInfluence() throws {
        let e = UpstreamEditor()
        #expect(e.importRGBA([UInt8](repeating: 255, count: 512 * 512 * 4), width: 512, height: 512,
                             name: "Large canvas", replacing: true) == 0)
        let s = e.session
        s.addAdjustment(.gaussianBlur)
        s.adjustmentEditingID = nil
        let base = try #require(s.document?.layers.first?.id)
        s.selectLayer(base)
        s.selectTool(.brush)
        s.brushSettings.diameter = 8
        s.beginBrush(at: CGPoint(x: 128, y: 96))
        let raw = try #require(s.brushStroke?.dirtyDocumentRect)
        let entry = Entry(editor: e)
        entry.noteStrokeProgress()
        let expanded = try #require(entry.strokeDirty)
        #expect(expanded.minX <= max(0, raw.minX - e.spatialAdjustmentMargin))
        #expect(expanded.maxX >= min(CGFloat(512), raw.maxX + e.spatialAdjustmentMargin))
        #expect(expanded.width > raw.width)
        s.cancelBrush()
    }
}
