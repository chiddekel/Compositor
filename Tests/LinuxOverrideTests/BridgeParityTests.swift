import Foundation
import Testing
@testable import Compositor
import CompositorCore

/// Differential tests for retiring the forked CompositorCore: the same command sequence goes to the fork's bridge (the
/// current spec) and to `UpstreamEditor` (the adapter over upstream's unmodified `EditorSession`), and the resulting
/// state and return codes must match. Layer ids are random per session, so they are compared by layer index.
@MainActor
struct BridgeParityTests {
    private struct Side {
        var importPixels: ([UInt8], Int, Int, Bool) -> Int32
        var render: () -> [UInt8]
        var send: (String) async -> Int32
        var state: () -> [String: Any]
        var layerIDs: () -> [String]
    }

    private func forkSide() -> Side {
        let handle = compositorSessionCreate()
        func state() -> [String: Any] {
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            let n = compositorSessionState(handle, &buffer, buffer.count)
            return (try? JSONSerialization.jsonObject(with: Data(buffer[0..<Int(n)])) as? [String: Any]) ?? [:]
        }
        func importPixels(_ pixels: [UInt8], _ w: Int, _ h: Int, _ replacing: Bool) -> Int32 {
            let name = Array("Imported".utf8)
            return pixels.withUnsafeBufferPointer { p in name.withUnsafeBufferPointer { n in
                compositorSessionImportRGBA(handle, p.baseAddress, p.count, w, h, n.baseAddress, n.count, replacing ? 1 : 0) } }
        }
        func render() -> [UInt8] {
            let size = Int(compositorSessionRender(handle, nil, 0))
            var out = [UInt8](repeating: 0, count: max(0, size))
            _ = compositorSessionRender(handle, &out, out.count)
            return out
        }
        return Side(importPixels: importPixels, render: render,
                    send: { json in Array(json.utf8).withUnsafeBufferPointer { compositorSessionCommand(handle, $0.baseAddress, $0.count) } },
                    state: state, layerIDs: { ((state()["layers"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String } })
    }

    private func upstreamSide() -> Side {
        let editor = UpstreamEditor()
        func state() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: (try? editor.stateJSON()) ?? Data()) as? [String: Any]) ?? [:]
        }
        return Side(importPixels: { editor.importRGBA($0, width: $1, height: $2, name: "Imported", replacing: $3) },
                    render: { (try? editor.renderRGBA().bytes) ?? [] },
                    send: { await editor.commandAsync(Data($0.utf8)) }, state: state,
                    layerIDs: { ((state()["layers"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String } })
    }

    /// "select:N" is resolved to the Nth layer's id on each side; anything else is sent as is.
    private func run(_ steps: [String], on side: Side) async -> [Int32] {
        var codes: [Int32] = []
        for step in steps {
            if step.hasPrefix("select:"), let index = Int(step.dropFirst(7)), side.layerIDs().indices.contains(index) {
                codes.append(await side.send(#"{"version":1,"action":"selectLayer","layerID":"\#(side.layerIDs()[index])"}"#))
            } else {
                codes.append(await side.send(step))
            }
        }
        return codes
    }

    /// The state with layer ids replaced by their index, so two sessions can be compared.
    private func normalized(_ side: Side) -> [String: Any] {
        var state = side.state()
        let ids = side.layerIDs()
        func token(_ id: Any?) -> Any { (id as? String).flatMap { ids.firstIndex(of: $0) }.map { "layer#\($0)" } ?? NSNull() }
        state["activeLayerID"] = token(state["activeLayerID"])
        state["layers"] = ((state["layers"] as? [[String: Any]]) ?? []).map { layer in
            var layer = layer
            layer["id"] = token(layer["id"]); layer["parentID"] = token(layer["parentID"])
            return layer
        }
        state["error"] = nil
        // History bookkeeping is where upstream deliberately differs from the fork, and upstream is the target (it is what
        // the Mac app shows): finer undo names ("Hide Layer", "Layer Opacity", "New Blank Layer"), and File > New is itself
        // an undoable step. See `historyFollowsUpstream`.
        for key in ["undoName", "redoName", "canUndo", "canRedo", "modified"] { state[key] = nil }
        return state
    }

    /// Canonical text of a state, for comparison (NSDictionary equality does not see through Swift-bridged nested values).
    private func canonical(_ state: [String: Any]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), encoding: .utf8)) ?? "?"
    }

    private func check(_ name: String, _ steps: [String]) async {
        let fork = forkSide(), upstream = upstreamSide()
        let forkCodes = await run(steps, on: fork), upstreamCodes = await run(steps, on: upstream)
        #expect(forkCodes == upstreamCodes, "\(name): return codes \(forkCodes) vs \(upstreamCodes)")
        let a = normalized(fork), b = normalized(upstream)
        #expect(canonical(a) == canonical(b), "\(name):\n fork:     \(canonical(a))\n upstream: \(canonical(b))")
    }

    private func cmd(_ action: String, _ fields: String = "") -> String {
        #"{"version":1,"action":"\#(action)"\#(fields.isEmpty ? "" : "," + fields)}"#
    }

    @Test func newDocumentAndLayers() async {
        await check("new", [cmd("new", #""width":120,"height":80"#)])
        await check("layers", [cmd("new", #""width":120,"height":80"#), cmd("addLayer"), cmd("addLayer"), cmd("addGroup")])
        await check("undo redo", [cmd("new", #""width":50,"height":40"#), cmd("addLayer"), cmd("addLayer"), cmd("undo"), cmd("redo"), cmd("undo")])
        await check("no document", [cmd("addLayer"), cmd("undo")])
    }

    @Test func layerProperties() async {
        let base = [cmd("new", #""width":60,"height":40"#), cmd("addLayer"), cmd("addLayer")]
        await check("rename", base + [cmd("renameLayer", #""name":"Sky""#)])
        await check("visible", base + [cmd("setVisible", #""enabled":false"#), cmd("setVisible", #""enabled":true"#), cmd("setVisible", #""enabled":false"#)])
        await check("opacity", base + [cmd("setOpacity", #""value":0.4"#)])
        await check("blend", base + [cmd("setBlendMode", #""kind":"Multiply""#), cmd("cycleBlendMode"), cmd("cycleBlendMode", #""forward":false"#)])
        await check("select and delete", base + ["select:0", cmd("deleteLayer")])
        await check("flip", base + [cmd("flipLayer"), cmd("flipCanvas", #""horizontally":false"#)])
    }

    @Test func groupingAndSelectedOpacity() async {
        let base = [cmd("new", #""width":60,"height":40"#), cmd("addLayer"), cmd("addLayer")]
        await check("group selected", base + ["select:0", cmd("groupSelectedLayers")])
        await check("selected opacity", base + [cmd("setSelectedOpacity", #""value":0.5"#)])
    }

    /// Premultiplied test pattern: opaque left half, half-transparent right half, with a colour gradient.
    private func pattern(_ w: Int, _ h: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let a = UInt8(x < w / 2 ? 255 : 128), i = (y * w + x) * 4
            bytes[i] = UInt8(Int(a) * (x * 255 / w) / 255); bytes[i + 1] = UInt8(Int(a) * (y * 255 / h) / 255)
            bytes[i + 2] = UInt8(Int(a) * 90 / 255); bytes[i + 3] = a
        } }
        return bytes
    }

    @Test func importedPixelsRenderTheSame() async {
        let w = 32, h = 24
        let fork = forkSide(), upstream = upstreamSide()
        #expect(fork.importPixels(pattern(w, h), w, h, true) == 0)
        #expect(upstream.importPixels(pattern(w, h), w, h, true) == 0)
        #expect(canonical(normalized(fork)) == canonical(normalized(upstream)))
        let a = fork.render(), b = upstream.render()
        #expect(a.count == w * h * 4 && b.count == a.count)
        var largest = 0
        for i in a.indices where i < b.count { largest = max(largest, abs(Int(a[i]) - Int(b[i]))) }
        #expect(largest <= 1, "renders differ by up to \(largest)")
        // A second import adds a centred layer, and opacity/blend/visibility change the composite the same way.
        for side in [fork, upstream] {
            _ = side.importPixels(pattern(16, 12), 16, 12, false)
            _ = await side.send(cmd("setOpacity", #""value":0.5"#))
            _ = await side.send(cmd("setBlendMode", #""kind":"Multiply""#))
        }
        #expect(canonical(normalized(fork)) == canonical(normalized(upstream)))
        let c = fork.render(), d = upstream.render()
        var second = 0
        for i in c.indices where i < d.count { second = max(second, abs(Int(c[i]) - Int(d[i]))) }
        #expect(c.count == d.count && second <= 1, "renders differ by up to \(second)")
    }

    /// Runs `steps` on both bridges after importing the same pattern, then compares state and rendered pixels.
    private func checkRendered(_ name: String, _ steps: [String], tolerance: Int = 1) async {
        let w = 40, h = 30
        let fork = forkSide(), upstream = upstreamSide()
        for side in [fork, upstream] { _ = side.importPixels(pattern(w, h), w, h, true) }
        let forkCodes = await run(steps, on: fork), upstreamCodes = await run(steps, on: upstream)
        #expect(forkCodes == upstreamCodes, "\(name): return codes \(forkCodes) vs \(upstreamCodes)")
        #expect(canonical(normalized(fork)) == canonical(normalized(upstream)), "\(name): state differs\n fork: \(canonical(normalized(fork)))\n upstream: \(canonical(normalized(upstream)))")
        let a = fork.render(), b = upstream.render()
        var largest = 0
        for i in a.indices where i < b.count { largest = max(largest, abs(Int(a[i]) - Int(b[i]))) }
        #expect(a.count == b.count && largest <= tolerance, "\(name): renders differ by up to \(largest) (sizes \(a.count)/\(b.count))")
    }

    @Test func masksMoveAndSelection() async {
        await checkRendered("hide mask", [cmd("addHideMask")])
        await checkRendered("reveal mask off", [cmd("addRevealMask"), cmd("setMaskEnabled", #""enabled":false"#)])
        await checkRendered("delete mask", [cmd("addHideMask"), cmd("deleteMask")])
        await checkRendered("move", [cmd("moveLayer", #""x":5,"y":-3"#)])
        await checkRendered("select rect", [cmd("selectRectangle", #""x":4,"y":4,"width":20,"height":12"#)])
        await checkRendered("select ellipse add", [cmd("selectRectangle", #""x":2,"y":2,"width":16,"height":16"#),
                                                   cmd("selectEllipse", #""x":10,"y":8,"width":20,"height":16,"kind":"Add""#)])
        await checkRendered("lasso", [cmd("selectLasso", #""points":[[2,2],[30,4],[20,26]]"#), cmd("deselect")])
    }

    @Test func fillsInvertCopyPaste() async {
        let rect = cmd("selectRectangle", #""x":6,"y":5,"width":18,"height":14"#)
        await checkRendered("fill", [rect, cmd("fillForeground", #""parameters":{"red":1,"green":0.2,"blue":0}"#)])
        await checkRendered("clear", [rect, cmd("clearSelection")])
        await checkRendered("invert whole", [cmd("invert")])
        await checkRendered("invert selected", [rect, cmd("invert")])
        await checkRendered("duplicate", [cmd("duplicateLayer"), cmd("moveLayer", #""x":7,"y":4"#)])
        await checkRendered("layer via copy", [rect, cmd("layerViaCopy"), cmd("moveLayer", #""x":9,"y":2"#)])
        await checkRendered("copy paste", [rect, cmd("copy"), cmd("paste")])
    }

    @Test func brushWandAndFilters() async {
        let stroke = [cmd("brushBegin", #""x":8,"y":8,"parameters":{"diameter":10,"hardness":1,"red":1,"green":0,"blue":0}"#),
                      cmd("brushMove", #""x":20,"y":14"#), cmd("brushMove", #""x":30,"y":22"#), cmd("brushEnd")]
        await checkRendered("brush", stroke, tolerance: 2)
        await checkRendered("erase", [cmd("brushBegin", #""x":5,"y":15,"parameters":{"diameter":12,"erasing":1}"#), cmd("brushMove", #""x":30,"y":15"#), cmd("brushEnd")], tolerance: 2)
        await checkRendered("brush cancel", [cmd("brushBegin", #""x":8,"y":8,"parameters":{"diameter":10}"#), cmd("brushMove", #""x":20,"y":14"#), cmd("brushCancel")])
        await checkRendered("wand", [cmd("magicWand", #""x":5,"y":5,"parameters":{"tolerance":40}"#), cmd("fillForeground", #""parameters":{"red":0,"green":1,"blue":0}"#)])
        await checkRendered("filter cancel", [cmd("filterBegin", #""kind":"Gaussian Blur","parameters":{"radius":3}"#), cmd("filterCancel")])
    }

    /// Painting black on a reveal mask hides only the stroke. (The fork's soft mask stroke hid about 80% of the image, so
    /// this is checked against upstream alone: transparent pixels near the stroke, the far corner untouched.)
    @Test func maskStrokeHidesOnlyTheStroke() async throws {
        let w = 40, h = 30
        let side = upstreamSide()
        _ = side.importPixels(pattern(w, h), w, h, true)
        for step in [cmd("addRevealMask"), cmd("brushBegin", #""x":10,"y":10,"parameters":{"diameter":14,"hardness":0.3,"mask":1}"#),
                     cmd("brushMove", #""x":26,"y":18"#), cmd("brushEnd")] { #expect(await side.send(step) == 0) }
        let pixels = side.render()
        let hidden = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] == 0 }.count
        #expect((100...450).contains(hidden), "\(hidden) pixels hidden")
        #expect(pixels[((28 * w) + 38) * 4 + 3] != 0, "the far corner is untouched")
        #expect(pixels[((14 * w) + 18) * 4 + 3] == 0, "the middle of the stroke is hidden")
    }

    /// Gaussian blur grows the layer by the blur's reach. The fork grew it by less (4 px at radius 2), upstream by 3 sigma
    /// (6 px), and upstream is the target, so this checks upstream on its own: the layer grew, the canvas did not, and
    /// pixels changed.
    @Test func gaussianBlurFollowsUpstream() async throws {
        let w = 40, h = 30
        let side = upstreamSide(), untouched = upstreamSide()
        for s in [side, untouched] { _ = s.importPixels(pattern(w, h), w, h, true) }
        for step in [cmd("filterBegin", #""kind":"Gaussian Blur","parameters":{"radius":2}"#), cmd("filterCommit")] { #expect(await side.send(step) == 0) }
        let layer = try #require((side.state()["layers"] as? [[String: Any]])?.first)
        let size = try #require((layer["transform"] as? [String: Any])?["size"] as? [Double])
        #expect(size == [51, 42], "layer grows by 3 sigma each side")
        #expect(side.state()["width"] as? Int == w && side.state()["height"] as? Int == h)
        #expect(side.render() != untouched.render())
    }

    /// Upstream's cut is copy then clear (Cmd-X). The fork's differed (it cropped the layer to the selection), so cut is
    /// checked against upstream's own copy + clear rather than against the fork.
    @Test func cutIsCopyThenClear() async throws {
        let w = 40, h = 30
        let cut = upstreamSide(), reference = upstreamSide()
        for side in [cut, reference] { _ = side.importPixels(pattern(w, h), w, h, true) }
        let rect = cmd("selectRectangle", #""x":6,"y":5,"width":18,"height":14"#)
        for step in [rect, cmd("cut")] { _ = await cut.send(step) }
        for step in [rect, cmd("copy"), cmd("clearSelection")] { _ = await reference.send(step) }
        #expect(cut.render() == reference.render())
        #expect(canonical(normalized(cut)) == canonical(normalized(reference)))
    }

    @Test func invalidInputIsRefusedTheSameWay() async {
        // Same document state (none). The code differs on purpose: upstream reports "invalid argument" (-1) where the
        // fork's generic failure was -5.
        let fork = forkSide(), upstream = upstreamSide()
        let steps = [cmd("new", #""width":0,"height":10"#), cmd("new", #""width":40000,"height":10"#)]
        #expect(await run(steps, on: fork).allSatisfy { $0 != 0 })
        #expect(await run(steps, on: upstream) == [-1, -1])
        #expect(canonical(normalized(fork)) == canonical(normalized(upstream)))
        await check("bad version", [#"{"version":2,"action":"new","width":10,"height":10}"#])
    }

    /// Documented divergences from the fork: upstream's history is what the shell should show.
    @Test func historyFollowsUpstream() async throws {
        let editor = UpstreamEditor()
        _ = await editor.commandAsync(Data(cmd("new", #""width":50,"height":40"#).utf8))
        _ = await editor.commandAsync(Data(cmd("addLayer").utf8))
        _ = await editor.commandAsync(Data(cmd("setOpacity", #""value":0.5"#).utf8))
        var state = try #require(JSONSerialization.jsonObject(with: try editor.stateJSON()) as? [String: Any])
        #expect(state["undoName"] as? String == "Layer Opacity")
        #expect(state["canUndo"] as? Bool == true)
        _ = await editor.commandAsync(Data(cmd("undo").utf8))
        _ = await editor.commandAsync(Data(cmd("undo").utf8))
        _ = await editor.commandAsync(Data(cmd("undo").utf8))   // File > New is undoable upstream
        state = try #require(JSONSerialization.jsonObject(with: try editor.stateJSON()) as? [String: Any])
        #expect(state["canUndo"] as? Bool == false && state["redoName"] as? String == "New Canvas")
    }

    @Test func unsupportedCommandsAreReportedNotIgnored() async {
        let editor = UpstreamEditor()
        #expect(await editor.commandAsync(Data(cmd("resizeCanvas", #""width":10,"height":10"#).utf8)) == -7)
    }
}

