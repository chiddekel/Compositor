import Foundation
import Testing
@testable import Compositor

/// `UpstreamEditor` (the adapter the Qt shell calls) on upstream's unmodified `EditorSession`. These began as differential
/// tests against the forked bridge it replaced; the expectations below are what both agreed on, plus the behaviours where
/// upstream, the target, deliberately differs (history naming, cut, blur growth, mask strokes).
@MainActor
struct UpstreamEditorTests {
    private func cmd(_ action: String, _ fields: String = "") -> String {
        #"{"version":1,"action":"\#(action)"\#(fields.isEmpty ? "" : "," + fields)}"#
    }
    @discardableResult private func send(_ e: UpstreamEditor, _ steps: String...) async -> [Int32] {
        var codes: [Int32] = []
        for step in steps { codes.append(await e.commandAsync(Data(step.utf8))) }
        return codes
    }
    private func state(_ e: UpstreamEditor) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: (try? e.stateJSON()) ?? Data()) as? [String: Any]) ?? [:]
    }
    private func layers(_ e: UpstreamEditor) -> [[String: Any]] { (state(e)["layers"] as? [[String: Any]]) ?? [] }
    private func names(_ e: UpstreamEditor) -> [String] { layers(e).compactMap { $0["name"] as? String } }

    /// Premultiplied pattern: opaque left half, half-transparent right half, with a colour gradient.
    private func pattern(_ w: Int, _ h: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let a = UInt8(x < w / 2 ? 255 : 128), i = (y * w + x) * 4
            bytes[i] = UInt8(Int(a) * (x * 255 / w) / 255); bytes[i + 1] = UInt8(Int(a) * (y * 255 / h) / 255)
            bytes[i + 2] = UInt8(Int(a) * 90 / 255); bytes[i + 3] = a
        } }
        return bytes
    }
    private func loaded(_ w: Int = 40, _ h: Int = 30) -> UpstreamEditor {
        let e = UpstreamEditor()
        #expect(e.importRGBA(pattern(w, h), width: w, height: h, name: "Imported", replacing: true) == 0)
        return e
    }
    private func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int = 40) -> [UInt8] { Array(bytes[(y * width + x) * 4 ..< (y * width + x) * 4 + 4]) }

    @Test func documentAndLayers() async throws {
        let e = UpstreamEditor()
        #expect(await send(e, cmd("addLayer")) == [-2], "no document yet")
        #expect(await send(e, cmd("new", #""width":120,"height":80"#), cmd("addLayer"), cmd("addLayer"), cmd("addGroup")) == [0, 0, 0, 0])
        #expect(names(e) == ["Layer 1", "Layer 2", "Folder 1"])
        #expect(state(e)["width"] as? Int == 120 && state(e)["height"] as? Int == 80)
        await send(e, cmd("undo"), cmd("undo"))
        #expect(names(e) == ["Layer 1"])
        await send(e, cmd("redo"))
        #expect(names(e) == ["Layer 1", "Layer 2"])
    }

    @Test func layerProperties() async throws {
        let e = UpstreamEditor()
        await send(e, cmd("new", #""width":60,"height":40"#), cmd("addLayer"), cmd("addLayer"), cmd("renameLayer", #""name":"Sky""#),
                   cmd("setVisible", #""enabled":false"#), cmd("setOpacity", #""value":0.4"#), cmd("setBlendMode", #""kind":"Multiply""#))
        let top = try #require(layers(e).last)
        #expect(top["name"] as? String == "Sky" && top["visible"] as? Bool == false)
        #expect(top["opacity"] as? Double == 0.4 && top["blendMode"] as? String == "Multiply")
        await send(e, cmd("cycleBlendMode"), cmd("flipLayer"), cmd("flipCanvas", #""horizontally":false"#))
        #expect(layers(e).last?["blendMode"] as? String == "Screen")
        #expect(((layers(e).last?["transform"] as? [String: Any])?["flipY"] as? Int) == 1 || ((layers(e).last?["transform"] as? [String: Any])?["flipY"] as? Bool) == true)
        await send(e, cmd("deleteLayer"))
        #expect(layers(e).count == 1)
    }

    @Test func groupingAndSelectedOpacity() async throws {
        let e = UpstreamEditor()
        await send(e, cmd("new", #""width":60,"height":40"#), cmd("addLayer"), cmd("addLayer"), cmd("groupSelectedLayers"))
        let all = layers(e)
        #expect(all.filter { $0["isGroup"] as? Bool == true }.count == 1)
        #expect(all.contains { $0["parentID"] is String })
        await send(e, cmd("setSelectedOpacity", #""value":0.5"#))
        #expect(layers(e).contains { $0["opacity"] as? Double == 0.5 })
    }

    @Test func invalidInputIsRefused() async throws {
        let e = UpstreamEditor()
        #expect(await send(e, cmd("new", #""width":0,"height":10"#), cmd("new", #""width":40000,"height":10"#), #"{"version":2,"action":"new","width":10,"height":10}"#) == [-1, -1, -4])
        #expect(state(e)["width"] as? Int == 0)
        #expect(await send(e, cmd("resizeSomething")) == [-7], "unmapped commands are reported, not ignored")
    }

    @Test func importedPixelsRenderExactly() async throws {
        let e = loaded()
        let out = try e.renderRGBA()
        #expect(out.width == 40 && out.height == 30 && out.bytes == pattern(40, 30))
        #expect(e.importRGBA(pattern(16, 12), width: 16, height: 12, name: "Second", replacing: false) == 0)
        #expect(layers(e).count == 2)
        await send(e, cmd("setOpacity", #""value":0.5"#))
        let blended = try e.renderRGBA().bytes
        #expect(pixel(blended, 20, 15) != pixel(pattern(40, 30), 20, 15), "the centred second layer shows through")
        #expect(e.importRGBA([255, 0, 0, 10], width: 1, height: 1, name: "bad", replacing: false) == -1, "not premultiplied")
    }

    @Test func masksMoveAndSelection() async throws {
        let e = loaded()
        await send(e, cmd("addHideMask"))
        #expect(layers(e).first?["hasMask"] as? Bool == true)
        #expect(pixel(try e.renderRGBA().bytes, 5, 5)[3] == 0, "a hide mask hides everything")
        await send(e, cmd("setMaskEnabled", #""enabled":false"#))
        #expect(pixel(try e.renderRGBA().bytes, 5, 5)[3] == 255)
        await send(e, cmd("deleteMask"), cmd("moveLayer", #""x":5,"y":3"#))
        let moved = try e.renderRGBA().bytes
        #expect(pixel(moved, 2, 2)[3] == 0 && pixel(moved, 7, 5)[3] == 255)
    }

    @Test func fillsInvertAndClipboard() async throws {
        let e = loaded()
        let rect = cmd("selectRectangle", #""x":6,"y":5,"width":18,"height":14"#)
        await send(e, rect, cmd("fillForeground", #""parameters":{"red":1,"green":0.2,"blue":0}"#))
        var out = try e.renderRGBA().bytes
        #expect(pixel(out, 10, 10)[0] == 255 && pixel(out, 10, 10)[3] == 255, "filled inside the selection")
        #expect(pixel(out, 1, 1) == pixel(pattern(40, 30), 1, 1), "untouched outside")
        await send(e, cmd("clearSelection"))
        #expect(pixel(try e.renderRGBA().bytes, 10, 10)[3] == 0)
        await send(e, cmd("undo"), cmd("deselect"), cmd("invert"))
        out = try e.renderRGBA().bytes
        #expect(pixel(out, 1, 1)[3] == 255 && pixel(out, 1, 1) != pixel(pattern(40, 30), 1, 1), "inverted, alpha kept")
        await send(e, cmd("duplicateLayer"))
        #expect(layers(e).count == 2)
        await send(e, rect, cmd("layerViaCopy"))
        #expect(layers(e).count == 3)
    }

    @Test func brushEraseWandAndFilter() async throws {
        let e = loaded()
        await send(e, cmd("brushBegin", #""x":8,"y":8,"parameters":{"diameter":10,"hardness":1,"red":1,"green":0,"blue":0}"#),
                   cmd("brushMove", #""x":30,"y":22"#), cmd("brushEnd"))
        #expect(pixel(try e.renderRGBA().bytes, 19, 15)[0] > 200, "the stroke painted red along its path")
        await send(e, cmd("brushBegin", #""x":5,"y":25,"parameters":{"diameter":8,"erasing":1}"#), cmd("brushMove", #""x":30,"y":25"#), cmd("brushEnd"))
        #expect(pixel(try e.renderRGBA().bytes, 15, 25)[3] < 255, "erased")
        await send(e, cmd("undo"), cmd("undo"), cmd("magicWand", #""x":2,"y":2,"parameters":{"tolerance":200}"#))
        #expect(state(e)["canUndo"] as? Bool == true)
        await send(e, cmd("deselect"), cmd("filterBegin", #""kind":"Gaussian Blur","parameters":{"radius":2}"#), cmd("filterCancel"))
        #expect(state(e)["busy"] as? Bool == false)
    }

    @Test func cutIsCopyThenClear() async throws {
        let a = loaded(), b = loaded()
        let rect = cmd("selectRectangle", #""x":6,"y":5,"width":18,"height":14"#)
        await send(a, rect, cmd("cut"))
        await send(b, rect, cmd("copy"), cmd("clearSelection"))
        let left = try a.renderRGBA().bytes, right = try b.renderRGBA().bytes
        #expect(left == right)
    }

    @Test func historyFollowsUpstream() async throws {
        let e = UpstreamEditor()
        await send(e, cmd("new", #""width":50,"height":40"#), cmd("addLayer"), cmd("setOpacity", #""value":0.5"#))
        #expect(state(e)["undoName"] as? String == "Layer Opacity" && state(e)["canUndo"] as? Bool == true)
        await send(e, cmd("undo"), cmd("undo"), cmd("undo"))   // File > New is undoable upstream
        #expect(state(e)["canUndo"] as? Bool == false && state(e)["redoName"] as? String == "New Canvas")
    }

    @Test func gaussianBlurGrowsTheLayer() async throws {
        let e = loaded()
        #expect(await send(e, cmd("filterBegin", #""kind":"Gaussian Blur","parameters":{"radius":2}"#), cmd("filterCommit")) == [0, 0])
        let size = try #require(((layers(e).first?["transform"] as? [String: Any])?["size"]) as? [Double])
        #expect(size == [51, 42], "grows by 3 sigma each side")
        #expect(state(e)["width"] as? Int == 40 && state(e)["height"] as? Int == 30)
    }

    @Test func maskStrokeHidesOnlyTheStroke() async throws {
        let e = loaded()
        await send(e, cmd("addRevealMask"), cmd("brushBegin", #""x":10,"y":10,"parameters":{"diameter":14,"hardness":0.3,"mask":1}"#),
                   cmd("brushMove", #""x":26,"y":18"#), cmd("brushEnd"))
        let pixels = try e.renderRGBA().bytes
        let hidden = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] == 0 }.count
        #expect((100...450).contains(hidden), "\(hidden) pixels hidden")
        #expect(pixel(pixels, 38, 28)[3] != 0 && pixel(pixels, 18, 14)[3] == 0)
    }

    @Test func transformCanvasAndAdjustments() async throws {
        let e = loaded()
        await send(e, cmd("transform", #""parameters":{"x":4,"y":2,"width":20,"height":10}"#))
        let t = try #require((layers(e).first?["transform"] as? [String: Any]))
        #expect((t["size"] as? [Double]) == [20, 10] && (t["origin"] as? [Double]) == [4, 2])
        await send(e, cmd("resizeCanvas", #""width":60,"height":45"#))
        #expect(state(e)["width"] as? Int == 60 && state(e)["height"] as? Int == 45)
        await send(e, cmd("resizeImage", #""width":30,"height":22"#))
        #expect(state(e)["width"] as? Int == 30)
        await send(e, cmd("cropCanvas", #""x":2,"y":2,"width":20,"height":15"#))
        #expect(state(e)["width"] as? Int == 20 && state(e)["height"] as? Int == 15)
        await send(e, cmd("addAdjustment", #""kind":"Curves""#))
        #expect(layers(e).contains { $0["name"] as? String == "Curves" })
        await send(e, cmd("adjustmentCancel"))   // ends the editing session addAdjustment opens
        await send(e, cmd("addShape", #""kind":"Ellipse","x":1,"y":1,"width":8,"height":8,"parameters":{"red":0,"green":1,"blue":0}"#))
        #expect(layers(e).count >= 3)
    }

    @Test func projectManifestRoundTripsThroughLayerPixels() async throws {
        let a = loaded()
        await send(a, cmd("addRevealMask"), cmd("addLayer"))
        let manifest = try a.exportManifest()
        let b = UpstreamEditor()
        #expect(b.importManifest(manifest) == 0)
        #expect(layers(b).count == layers(a).count)
        for layer in layers(a) {
            let id = try #require(UUID(uuidString: layer["id"] as! String))
            if let image = a.layerPixels(id: id, mask: false) { #expect(b.installLayerAsset(image, id: id, mask: false) == 0) }
            if let mask = a.layerPixels(id: id, mask: true) { #expect(b.installLayerAsset(mask, id: id, mask: true) == 0) }
        }
        let left = try a.renderRGBA().bytes, right = try b.renderRGBA().bytes
        #expect(left == right)
    }
}
