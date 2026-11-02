import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Compositor

/// `.comp` interchange on Linux alone (T-10 without a Mac): a corpus covering what a project can hold — layers in
/// every blend mode, masks linked and not, folders with opacity and masks, clipping stacks, every adjustment and
/// every layer effect, live text and shapes, guides and grid, 16-bit and HDR layers — each saved through upstream's
/// ProjectStore, reopened into a fresh session and saved again. The two packages must hold the same manifest and the
/// same pixels, and flatten to the same image. What this cannot show is that macOS reads them the same way: that
/// stays unverified until the corpus is opened on a Mac (docs/mac-verification-plan.md).
@MainActor
@Suite(.serialized)
struct ProjectCorpusRoundTripTests {
    enum Case: String, CaseIterable {
        case layersAndBlendModes, masksAndFolders, clippingStack, adjustments, effects, textAndShapes, guidesAndGrid, deepLayers
    }

    // MARK: Building

    private func command(_ e: UpstreamEditor, _ action: String, _ fields: [String: Any] = [:]) async throws {
        var body = fields
        body["version"] = 1
        body["action"] = action
        let code = await e.commandAsync(try JSONSerialization.data(withJSONObject: body))
        try #require(code == 0, "\(action) failed: \(e.error ?? "code \(code)")")
    }

    private func pattern(_ w: Int, _ h: Int, seed: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let a = UInt8(x < w * 3 / 4 ? 255 : 160)
            bytes[i] = UInt8(Int(a) * ((x * 255 / w + seed * 40) % 256) / 255)
            bytes[i + 1] = UInt8(Int(a) * ((y * 255 / h + seed * 70) % 256) / 255)
            bytes[i + 2] = UInt8(Int(a) * ((seed * 90 + 30) % 256) / 255)
            bytes[i + 3] = a
        } }
        return bytes
    }

    private func stroke(_ e: UpstreamEditor, from a: CGPoint, to b: CGPoint, mask: Bool = false, color: (Double, Double, Double) = (0.9, 0.3, 0.1)) async throws {
        let brush: [String: Any] = ["diameter": 18.0, "hardness": 0.7, "opacity": 1.0, "red": color.0, "green": color.1, "blue": color.2,
                                    "erasing": 0, "mask": mask ? 1 : 0]
        // JSON numbers as Double: CGFloat does not bridge to JSONSerialization on Linux.
        try await command(e, "brushBegin", ["x": Double(a.x), "y": Double(a.y), "parameters": brush])
        try await command(e, "brushMove", ["x": Double((a.x + b.x) / 2), "y": Double((a.y + b.y) / 2 + 9)])
        try await command(e, "brushMove", ["x": Double(b.x), "y": Double(b.y)])
        try await command(e, "brushEnd")
    }

    private func newDocument(_ e: UpstreamEditor) {
        #expect(e.importRGBA(pattern(96, 64, seed: 1), width: 96, height: 64, name: "Base", replacing: true) == 0)
    }

    private func paintedLayer(_ e: UpstreamEditor, _ index: Int) async throws {
        try await command(e, "addLayer")
        try await stroke(e, from: CGPoint(x: 8 + index % 5, y: 10 + index * 2 % 40), to: CGPoint(x: 80, y: 50 - index % 30),
                         color: (Double(index % 4) / 3, 0.5, 1 - Double(index % 3) / 2))
    }

    private func build(_ which: Case, _ e: UpstreamEditor) async throws {
        let s = e.session
        newDocument(e)
        switch which {
        case .layersAndBlendModes:
            for (index, mode) in LayerBlendMode.allCases.enumerated() {
                try await paintedLayer(e, index)
                try await command(e, "setBlendMode", ["kind": mode.rawValue])
                if index % 3 == 1 { try await command(e, "setOpacity", ["value": 0.55]) }
            }
            let id = try #require(s.activeLayerID)
            s.renameLayer(id, to: "Ünïcode 🌤 layer")
            try await command(e, "setVisible", ["enabled": false])
            try await command(e, "flipLayer", ["horizontally": true])
        case .masksAndFolders:
            try await paintedLayer(e, 1)
            try await command(e, "addRevealMask")
            try await stroke(e, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40), mask: true, color: (0, 0, 0))
            try await paintedLayer(e, 2)
            try await command(e, "addHideMask")
            try await command(e, "setMaskLinked", ["enabled": false])
            try await command(e, "moveLayer", ["x": 7.0, "y": -3.0])
            try await paintedLayer(e, 3)
            let top = try #require(s.activeLayerID)
            let below = try #require(s.document?.layers.dropLast().last?.id)
            try await command(e, "selectLayer", ["layerID": below.uuidString])
            try await command(e, "selectLayer", ["layerID": top.uuidString, "enabled": true])
            try await command(e, "groupSelectedLayers")
            try await command(e, "setOpacity", ["value": 0.7])
            try await command(e, "addRevealMask")
            try #require(s.document?.layers.contains { $0.isGroup && $0.mask != nil } == true, "a folder with a mask")
        case .clippingStack:
            try await paintedLayer(e, 1)
            try await paintedLayer(e, 2)
            try await command(e, "toggleClippingMask")
            try await paintedLayer(e, 3)
            try await command(e, "toggleClippingMask")
        case .adjustments:
            for kind in AdjustmentKind.allCases {
                // As Layer › New Adjustment Layer does: the layer, its editor opened, then OK.
                try await command(e, "addAdjustment", ["kind": kind.rawValue])
                if s.adjustmentEditingID != nil { #expect(s.finishAdjustmentEditing(commit: true), "\(kind) editor did not close") }
            }
            #expect(s.document?.layers.filter { $0.adjustment != nil }.count == AdjustmentKind.allCases.count)
        case .effects:
            try await paintedLayer(e, 1)
            for kind in LayerEffectKind.allCases {
                s.addEffect(kind)
                s.finishEffectsEditing(commit: true)
            }
            #expect(s.activeLayer?.effects?.visible.isEmpty == false)
        case .textAndShapes:
            try await command(e, "textBegin", ["x": 6.0, "y": 30.0])
            try await command(e, "textSetContent", ["name": "Ab Ωé 😀"])
            try await command(e, "textFinish")
            #expect(s.document?.layers.contains { $0.text != nil } == true)
            for (index, kind) in ShapeKind.allCases.enumerated() {
                try await command(e, "addShape", ["kind": kind.rawValue, "x": 4.0 + Double(index * 9), "y": 40.0, "width": 18.0, "height": 14.0,
                                                  "parameters": ["red": 0.2, "green": 0.6, "blue": Double(index) / 6]])
            }
        case .guidesAndGrid:
            for (axis, value) in [("vertical", 12.0), ("horizontal", 33.5), ("vertical", 70.0)] {
                try await command(e, "guideCreate", ["kind": axis, "value": value])
                try await command(e, "guideFinish")
            }
            try await paintedLayer(e, 4)
        case .deepLayers:
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-deep-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let sixteen = folder.appendingPathComponent("sixteen.png"), hdr = folder.appendingPathComponent("bright.exr")
            try writeSixteenBitPNG(to: sixteen)
            try writeHDR(to: hdr)
            await s.importImages([sixteen, hdr])
            try #require(s.document?.layers.contains { $0.asset?.deep != nil } == true, "16-bit layer imported")
            try #require(s.document?.layers.contains { $0.asset?.isHDR == true } == true, "HDR layer imported")
        }
        try #require(s.projectSnapshot() != nil)
    }

    private func writeSixteenBitPNG(to url: URL) throws {
        let w = 40, h = 24
        var words = [UInt16](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            words[i] = UInt16(x * 65535 / (w - 1)); words[i + 1] = UInt16(y * 65535 / (h - 1)); words[i + 2] = 31000; words[i + 3] = 65535
        } }
        let context = try #require(CGContext(data: &words, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func writeHDR(to url: URL) throws {
        // Half floats in extended sRGB, brighter than white on the left: what an HDR layer holds.
        let w = 32, h = 20
        var halves = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            halves[i] = Float16(Float(x) / Float(w) * 3); halves[i + 1] = 0.5; halves[i + 2] = Float16(Float(y) / Float(h)); halves[i + 3] = 1
        } }
        let context = try #require(CGContext(data: &halves, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
            space: CGColorSpace(name: CGColorSpace.extendedSRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.ilm.openexr-image" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    // MARK: Comparing

    private func files(in package: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            found[String(url.path.dropFirst(package.path.count + 1))] = try Data(contentsOf: url)
        }
        return found
    }

    private func pixels(_ data: Data) throws -> (width: Int, height: Int, depth: Int, bytes: [UInt8]) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height, image.bitsPerComponent, image.nativeImage.bytes)
    }

    /// Upstream encodes a dictionary keyed by an enum (Hue/Saturation's `bands`) as Swift does: a flat array of
    /// alternating keys and values, in the dictionary's unspecified order, which can differ between two saves of the
    /// same settings (on macOS too). Such pair lists are compared as the dictionaries they are.
    private func normalized(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(normalized) as NSDictionary }
        guard let array = value as? [Any] else { return value }
        let items = array.map(normalized)
        if items.count >= 2, items.count % 2 == 0,
           stride(from: 0, to: items.count, by: 2).allSatisfy({ items[$0] is String && !(items[$0 + 1] is String) }) {
            var pairs: [String: Any] = [:]
            for index in stride(from: 0, to: items.count, by: 2) { pairs[items[index] as! String] = items[index + 1] }
            if pairs.count == items.count / 2 { return pairs as NSDictionary }
        }
        return items as NSArray
    }

    /// Where two JSON values first differ, as a path with both values.
    private func difference(_ a: Any?, _ b: Any?, at path: String = "") -> String? {
        if let a = a as? NSDictionary, let b = b as? NSDictionary {
            for key in Set((a.allKeys + b.allKeys).compactMap { $0 as? String }).sorted() {
                if let found = difference(a[key], b[key], at: "\(path)/\(key)") { return found }
            }
            return nil
        }
        if let a = a as? NSArray, let b = b as? NSArray {
            guard a.count == b.count else { return "\(path): \(a.count) items, then \(b.count)" }
            for index in 0..<a.count { if let found = difference(a[index], b[index], at: "\(path)/\(index)") { return found } }
            return nil
        }
        if let a = a as? NSObject, let b = b as? NSObject, a == b { return nil }
        if a == nil && b == nil { return nil }
        return "\(path): \(a.map { "\($0)" } ?? "nil") then \(b.map { "\($0)" } ?? "nil")"
    }

    private func flattened(_ snapshot: ProjectSnapshot) async throws -> [UInt8] {
        try await ImageExporter.shared.render(snapshot).image.nativeImage.bytes
    }

    @Test(arguments: Case.allCases)
    func savesReopensAndSavesTheSame(_ which: Case) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(which.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = UpstreamEditor()
        try await build(which, editor)
        let first = try #require(editor.session.projectSnapshot())
        let saved = root.appendingPathComponent("\(which.rawValue).comp")
        try await ProjectStore.shared.save(first, to: saved)

        let loaded = try await ProjectStore.shared.load(from: saved)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: saved)
        #expect(!reopened.isModified)
        let second = try #require(reopened.projectSnapshot())
        let resaved = root.appendingPathComponent("\(which.rawValue)-resaved.comp")
        try await ProjectStore.shared.save(second, to: resaved)

        // Same manifest, field for field.
        let a = try files(in: saved), b = try files(in: resaved)
        let manifestA = normalized(try JSONSerialization.jsonObject(with: try #require(a["manifest.json"]))) as? NSDictionary
        let manifestB = normalized(try JSONSerialization.jsonObject(with: try #require(b["manifest.json"]))) as? NSDictionary
        #expect(manifestA == manifestB, "the manifest changed on the second save: \(difference(manifestA, manifestB) ?? "")")
        #expect(manifestA?["version"] as? Int == ProjectManifest.current)
        // Same assets, decoded pixel for pixel (the preview is a JPEG of the flattened image, made again).
        let assets = Set(a.keys.filter { !$0.hasPrefix("QuickLook/") && $0 != "manifest.json" })
        #expect(assets == Set(b.keys.filter { !$0.hasPrefix("QuickLook/") && $0 != "manifest.json" }))
        #expect(!assets.isEmpty)
        for name in assets.sorted() {
            let pa = try pixels(try #require(a[name])), pb = try pixels(try #require(b[name]))
            #expect(pa.width == pb.width && pa.height == pb.height && pa.depth == pb.depth, "\(name) changed size or depth")
            #expect(pa.bytes == pb.bytes, "\(name) changed pixels")
        }
        // And the document flattens to the same image before and after.
        #expect(try await flattened(first) == flattened(loaded), "the reopened document renders differently")
    }
}
