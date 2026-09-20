// SessionJourneyTests — headless editor-session journey through the @_cdecl
// C ABI seam (ENG-1), driven from Swift. This mirrors the C++ integration test
// tests/test_session_journey.cpp, but runs under `swift test` where the Swift
// runtime *and* Foundation are properly bootstrapped by SwiftPM.
//
// Why a Swift test and not the C++ one: the Freedesktop Swift 6.3 SDK has no
// `swift_initSwiftRuntime` entry point, so a non-Swift `main` cannot
// self-initialize the Swift runtime. With the *static* stdlib embedded in a
// C++ binary, generic class metadata (`_DictionaryStorage`) is never
// initialized and the first `Dictionary` insertion SEGVs. With the *shared*
// stdlib, stdlib `Dictionary` works but Foundation's `JSONDecoder` /
// `Data.withUnsafeBytes` (`__DataStorage`) still traps
// (`UnsafeRawBufferPointer.swift:229`) even on pure-Swift `Data`, so the
// JSON command path used by `compositor_session_command` is unusable from a
// C++ `main`. The only supported way to use Foundation is a Swift entry point
// (the file-map's composition-root constraint; see docs/linux-port-file-map.md).
// This test exercises the real session logic + the JSON command path that the
// C ABI exposes, which is the host-verifiable slice of the file-map's "First
// packaged open/paint/undo/save/reopen/export journey" workstream.
//
// Journey: create -> new 4x4 -> addLayer -> brush stroke (red) -> state ->
// render (assert red) -> undo -> render (assert blank) -> redo -> render
// (assert red) -> close -> closed handle rejected.

import XCTest
@testable import CompositorCore

final class SessionJourneyTests: XCTestCase {

    /// Regression: the full JSON payload for every adjustment kind decodes and
    /// validates; CurvesSettings applies its table through the model.
    func testAdjustmentJSONDecodesValid() throws {
        let inverted = #"[{"x":0,"y":255},{"x":255,"y":0}]"#
        let darkCurves = #"{"channel":"RGB","channels":[\#(inverted),\#(inverted),\#(inverted),\#(inverted)]}"#
        let curves = try JSONDecoder().decode(CurvesSettings.self, from: Data(darkCurves.utf8))
        XCTAssertTrue(curves.isValid, "inverted curve validates")
        XCTAssertEqual(curves.value(255, channel: 0), 0, accuracy: 0.001, "inverted curve flips white")
        XCTAssertEqual(curves.value(205, channel: 0), 50, accuracy: 0.001, "inverted curve maps grey")

        let hsv = #"{"range":"Master","colorize":false,"invertRange":false,"adjustments":["Master",{"hue":0,"saturation":-100,"lightness":0}],"bands":["Master",{"falloffStart":0,"rangeStart":0,"rangeEnd":360,"falloffEnd":360},"Reds",{"falloffStart":315,"rangeStart":345,"rangeEnd":15,"falloffEnd":45},"Yellows",{"falloffStart":15,"rangeStart":45,"rangeEnd":75,"falloffEnd":105},"Greens",{"falloffStart":75,"rangeStart":105,"rangeEnd":135,"falloffEnd":165},"Cyans",{"falloffStart":135,"rangeStart":165,"rangeEnd":195,"falloffEnd":225},"Blues",{"falloffStart":195,"rangeStart":225,"rangeEnd":255,"falloffEnd":285},"Magentas",{"falloffStart":255,"rangeStart":285,"rangeEnd":315,"falloffEnd":345}]}"#
        let pts = #"[{"x":0,"y":0},{"x":255,"y":255}]"#
        let curvesJ = #"{"channel":"RGB","channels":[\#(pts),\#(pts),\#(pts),\#(pts)]}"#
        let range = #"{"black":0,"gamma":1,"white":255,"outputBlack":0,"outputWhite":255}"#
        let levels = #"{"channel":"RGB","ranges":[\#(range),\#(range),\#(range),\#(range)]}"#
        let full: String = #"{"kind":"Hue/Saturation","hue":0,"saturation":-100,"lightness":0,"colorize":false,"hsvSettings":\#(hsv),"levels":\#(levels),"curves":\#(curvesJ)}"#
        let decoder = JSONDecoder()
        XCTAssertTrue(try decoder.decode(LayerAdjustment.self, from: Data(full.utf8)).isValid, "decoded adjustment validates")

        let grainJ = #"{"amount":100,"size":5,"roughness":70,"seed":0}"#
        let grainAdjJ: String = #"{"kind":"Grain","hue":0,"saturation":0,"lightness":0,"colorize":false,"grainSettings":\#(grainJ),"levels":\#(levels),"curves":\#(curvesJ)}"#
        XCTAssertTrue(try decoder.decode(LayerAdjustment.self, from: Data(grainAdjJ.utf8)).isValid, "grain adjustment validates")
    }

    /// Wraps compositor_session_command with a Swift string payload.
    @discardableResult
    private func cmd(_ h: UInt64, _ json: String) -> Int32 {
        var bytes = Array(json.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            compositorSessionCommand(h, buf.baseAddress, buf.count)
        }
    }

    private func state(_ h: UInt64) -> String {
        let n = compositorSessionState(h, nil, 0)
        XCTAssertGreaterThan(n, 0, "state byte count positive")
        var bytes = [UInt8](repeating: 0, count: Int(n))
        bytes.withUnsafeMutableBufferPointer { buf in
            _ = compositorSessionState(h, buf.baseAddress, Int(n))
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func render(_ h: UInt64, expectedBytes: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expectedBytes)
        let n = out.withUnsafeMutableBufferPointer { buf in
            compositorSessionRender(h, buf.baseAddress, expectedBytes)
        }
        XCTAssertEqual(n, Int64(expectedBytes), "render byte count")
        return out
    }

    /// Extracts `"key":number` as Int, or nil if absent.
    private func jsonInt(_ s: String, _ key: String) -> Int? {
        guard let r = s.range(of: "\"\(key)\":") else { return nil }
        let after = s[r.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
        var digits = ""
        for ch in after {
            if ch.isNumber || ch == "-" { digits.append(ch) } else { break }
        }
        return Int(digits)
    }

    /// `busy`/`canUndo`/`canRedo` are Bool → JSON `true`/`false`.
    private func jsonBool(_ s: String, _ key: String) -> Bool? {
        guard let r = s.range(of: "\"\(key)\":") else { return nil }
        let after = s[r.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
        if after.hasPrefix("true") { return true }
        if after.hasPrefix("false") { return false }
        return nil
    }

    private func hasRed(_ px: [UInt8]) -> Bool {
        for i in stride(from: 0, to: px.count, by: 4) {
            // Solid red premultiplied: R>0, G==0, B==0, A>0.
            if px[i] > 0 && px[i + 1] == 0 && px[i + 2] == 0 && px[i + 3] > 0 { return true }
        }
        return false
    }

    private func isBlank(_ px: [UInt8]) -> Bool {
        for i in stride(from: 0, to: px.count, by: 4) {
            if px[i] != 0 || px[i + 1] != 0 || px[i + 2] != 0 || px[i + 3] != 0 { return false }
        }
        return true
    }

    func testCreateNewPaintUndoRedoClose() {
        let h = compositorSessionCreate()
        XCTAssertNotEqual(h, 0, "session create returned non-zero handle")

        XCTAssertEqual(cmd(h, #"{"version":1,"action":"new","width":4,"height":4}"#), 0, "new canvas")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"addLayer"}"#), 0, "add layer")

        // Paint a solid red stroke: diameter 3, hardness 1, opacity 1, red=1.
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"brushBegin","x":1,"y":1,"parameters":{"diameter":3,"hardness":1,"opacity":1,"red":1,"green":0,"blue":0,"erasing":0,"mask":0}}"#), 0, "brush begin")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"brushMove","x":2,"y":2}"#), 0, "brush move")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"brushEnd"}"#), 0, "brush end")

        let s1 = state(h)
        XCTAssertEqual(jsonInt(s1, "width"), 4, "state width")
        XCTAssertEqual(jsonInt(s1, "height"), 4, "state height")
        XCTAssertEqual(jsonBool(s1, "busy"), false, "state not busy after stroke")
        XCTAssertEqual(jsonBool(s1, "canUndo"), true, "state can undo after stroke")

        let after = render(h, expectedBytes: 64)
        XCTAssertTrue(hasRed(after), "render shows red paint after stroke")

        // Undo restores the blank layer.
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"undo"}"#), 0, "undo")
        let s2 = state(h)
        XCTAssertEqual(jsonBool(s2, "canRedo"), true, "state can redo after undo")
        let restored = render(h, expectedBytes: 64)
        XCTAssertTrue(isBlank(restored), "render is blank after undo")

        // Redo reapplies the stroke.
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"redo"}"#), 0, "redo")
        let redone = render(h, expectedBytes: 64)
        XCTAssertTrue(hasRed(redone), "render shows red paint after redo")

        compositorSessionClose(h)
        // A closed handle must reject commands (-6 invalid/closed handle).
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"undo"}"#), -6, "closed handle rejected")
    }

    /// Save/reopen leg of the first workstream, verifiable without Qt: flatten a
    /// painted document to composited RGBA (`compositor_session_render` = the
    /// "export"/"save" bytes), then reopen it in a *fresh* session via
    /// `compositor_session_import_rgba` (replacing) and render again. The two
    /// renders must be byte-identical: the import→render path is the round-trip
    /// foundation that the PNG/JPEG export (ImageExporter→QImageWriter) and the
    /// project-file save (ProjectStore Codable) legs both build on. Qt codecs and
    /// portal coordination layer on top of this; the ABI round-trip itself needs
    /// only Foundation + the C ABI, so it runs under `swift test`.
    func testRenderImportRoundTripReopensCompositedImage() {
        // Session A: build a painted document and flatten it to RGBA.
        let a = compositorSessionCreate()
        XCTAssertNotEqual(a, 0, "session A create")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"new","width":4,"height":4}"#), 0, "A new canvas")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"addLayer"}"#), 0, "A add layer")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"brushBegin","x":1,"y":1,"parameters":{"diameter":3,"hardness":1,"opacity":1,"red":1,"green":0,"blue":0,"erasing":0,"mask":0}}"#), 0, "A brush begin")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"brushMove","x":2,"y":2}"#), 0, "A brush move")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"brushEnd"}"#), 0, "A brush end")
        let saved = render(a, expectedBytes: 64)
        XCTAssertTrue(hasRed(saved), "A render has red paint to save")
        // Sanity: the saved buffer is a mix of painted red and transparent blank.
        XCTAssertTrue(isBlank(saved) == false, "A render is not fully blank")

        // Reopen: a brand-new session imports the flattened RGBA as its document.
        let b = compositorSessionCreate()
        XCTAssertNotEqual(b, 0, "session B create")
        XCTAssertNotEqual(b, a, "B is a distinct session handle")
        let nameBytes = Array("Reopened".utf8)
        let importRC = nameBytes.withUnsafeBufferPointer { nameBuf -> Int32 in
            saved.withUnsafeBufferPointer { pxBuf in
                compositorSessionImportRGBA(b, pxBuf.baseAddress, pxBuf.count, 4, 4,
                                            nameBuf.baseAddress, nameBuf.count, 1)
            }
        }
        XCTAssertEqual(importRC, 0, "B import RGBA (replacing) succeeds")

        // The reopened document reports the right canvas size and is not busy.
        let s = state(b)
        XCTAssertEqual(jsonInt(s, "width"), 4, "B state width")
        XCTAssertEqual(jsonInt(s, "height"), 4, "B state height")
        XCTAssertEqual(jsonBool(s, "busy"), false, "B not busy after import")
        XCTAssertTrue(s.contains("\"layers\":"), "B state has layers array")
        // One imported image layer.
        let layerCount = s.components(separatedBy: "\"id\":").count - 1
        XCTAssertEqual(layerCount, 1, "B has exactly one imported layer")

        // Round-trip equivalence: rendering the reopened image reproduces the
        // saved bytes exactly.
        let reopened = render(b, expectedBytes: 64)
        XCTAssertEqual(reopened, saved, "reopened render is byte-identical to saved render")
        XCTAssertTrue(hasRed(reopened), "reopened render still shows red paint")

        compositorSessionClose(a)
        compositorSessionClose(b)
    }

    /// Manifest export/import round-trip: serialize ProjectManifest to JSON,
    /// import into a fresh session, verify dimensions and layer count.
    func testManifestExportImportRoundTrip() {
        let a = compositorSessionCreate()
        XCTAssertNotEqual(a, 0, "session A create")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"new","width":8,"height":8}"#), 0, "A new canvas")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"addLayer"}"#), 0, "A add layer")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"brushBegin","x":1,"y":1,"parameters":{"diameter":3,"hardness":1,"opacity":1,"red":1,"green":0,"blue":0,"erasing":0,"mask":0}}"#), 0, "A brush begin")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"brushMove","x":2,"y":2}"#), 0, "A brush move")
        XCTAssertEqual(cmd(a, #"{"version":1,"action":"brushEnd"}"#), 0, "A brush end")

        // Export manifest from session A
        let manifestN = compositorSessionExportManifest(a, nil, 0)
        XCTAssertGreaterThan(manifestN, 0, "manifest byte count")
        var manifestBytes = [UInt8](repeating: 0, count: Int(manifestN))
        let n = manifestBytes.withUnsafeMutableBufferPointer { buf in
            compositorSessionExportManifest(a, buf.baseAddress, Int(manifestN))
        }
        XCTAssertEqual(n, manifestN, "export manifest byte count")

        // Debug: print manifest JSON
        let manifestJSON = String(bytes: manifestBytes, encoding: .utf8) ?? ""
        print("Exported manifest: \(manifestJSON)")

        // Import manifest into fresh session B
        let b = compositorSessionCreate()
        XCTAssertNotEqual(b, 0, "session B create")
        let importRC = manifestBytes.withUnsafeBufferPointer { buf in
            compositorSessionImportManifest(b, buf.baseAddress, buf.count)
        }
        XCTAssertEqual(importRC, 0, "B import manifest succeeds")

        // Verify B has correct canvas size
        let s = state(b)
        print("B state: \(s)")
        XCTAssertEqual(jsonInt(s, "width"), 8, "B state width")
        XCTAssertEqual(jsonInt(s, "height"), 8, "B state height")
        XCTAssertEqual(jsonBool(s, "busy"), false, "B not busy after import")

        // Verify layer structure (at least one layer)
        let layerCount = s.components(separatedBy: "\"id\":").count - 1
        XCTAssertGreaterThanOrEqual(layerCount, 1, "B has at least one layer")

        compositorSessionClose(a)
        compositorSessionClose(b)
    }

    /// Returns a freshly opened 4x4 session with one painted layer.
    private func paintedSession(_ red: Double = 1, _ green: Double = 1, _ blue: Double = 1) -> UInt64 {
        let h = compositorSessionCreate()
        XCTAssertNotEqual(h, 0, "session create")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"new","width":4,"height":4}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"addLayer"}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"brushBegin","x":0,"y":0,"parameters":{"diameter":4,"hardness":1,"opacity":1,"red":\#(red),"green":\#(green),"blue":\#(blue),"erasing":0,"mask":0}}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"brushEnd"}"#), 0)
        return h
    }

    private func activeLayer(_ h: UInt64) -> String {
        let s = state(h)
        guard let r = s.range(of: #""activeLayerID":""#) else { return "" }
        let after = s[r.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return "" }
        return String(after[..<end])
    }

    private func avgLight(_ px: [UInt8]) -> Double {
        var sum: Double = 0
        var count = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 {
            sum += Double(px[i]) + Double(px[i + 1]) + Double(px[i + 2])
            count += 1
        }
        return count == 0 ? 0 : sum / Double(3 * count)
    }

    private func meanSaturation(_ px: [UInt8]) -> Double {
        var sum: Double = 0
        var count = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 {
            let maxv = max(px[i], max(px[i + 1], px[i + 2]))
            let minv = min(px[i], min(px[i + 1], px[i + 2]))
            sum += Double(maxv - minv)
            count += 1
        }
        return count == 0 ? 0 : sum / Double(count)
    }

    private func identityLevels() -> String {
        let range = #"{"black":0,"gamma":1,"white":255,"outputBlack":0,"outputWhite":255}"#
        return #"{"channel":"RGB","ranges":[\#(range),\#(range),\#(range),\#(range)]}"#
    }

    private func identityCurves() -> String {
        let pts = #"[{"x":0,"y":0},{"x":255,"y":255}]"#
        return #"{"channel":"RGB","channels":[\#(pts),\#(pts),\#(pts),\#(pts)]}"#
    }

    /// AdjustDialog JSON contract for a new sheet: addAdjustment creates the
    /// adjustment layer and begins its edit, debounced adjustmentPreview live-
    /// updates the render, adjustmentCommit pins the committed values, and a
    /// follow-up re-edit cancel leaves the committed pixels untouched.
    func testAdjustLevelsJourney() {
        let h = paintedSession()
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"addAdjustment","kind":"Levels"}"#), 0, "add levels sheet")
        let range = #"{"black":0,"gamma":1,"white":255,"outputBlack":50,"outputWhite":200}"#
        let clipped = #"{"channel":"RGB","ranges":[\#(range),\#(range),\#(range),\#(range)]}"#
        let adjusted: String = #"{"kind":"Levels","hue":0,"saturation":0,"lightness":0,"colorize":false,"levels":\#(clipped),"curves":\#(identityCurves())}"#
        let before = avgLight(render(h, expectedBytes: 64))
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentPreview","adjustment":\#(adjusted)}"#), 0, "levels preview")
        let during = avgLight(render(h, expectedBytes: 64))
        XCTAssertLessThan(during, before, "output range 50..200 darkens the paint")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentCommit","adjustment":\#(adjusted)}"#), 0, "levels commit")
        XCTAssertEqual(jsonBool(state(h), "busy"), false)
        XCTAssertEqual(avgLight(render(h, expectedBytes: 64)), during, accuracy: 1, "committed levels keep the preview mapping")

        // Re-edit the committed sheet: a canceled change keeps committed pixels.
        let id = activeLayer(h)
        XCTAssertFalse(id.isEmpty, "sheet layer id present")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentBegin","layerID":"\#(id)"}"#), 0, "re-edit sheet")
        let lighter: String = #"{"kind":"Levels","hue":0,"saturation":0,"lightness":0,"colorize":false,"levels":\#(identityLevels()),"curves":\#(identityCurves())}"#
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentPreview","adjustment":\#(lighter)}"#), 0, "re-edit preview")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentCancel"}"#), 0, "re-edit cancel")
        XCTAssertEqual(avgLight(render(h, expectedBytes: 64)), during, accuracy: 1, "cancel restores committed mapping")
        compositorSessionClose(h)
    }

    /// Hue/Saturation through the same lifecycle: saturating the master range
    /// to -100 desaturates the red paint (RGB channels converge).
    func testAdjustHsvJourney() {
        let h = paintedSession(1, 0, 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"addAdjustment","kind":"Hue/Saturation"}"#), 0, "add hsv sheet")
        let hsv = #"{"range":"Master","colorize":false,"invertRange":false,"adjustments":["Master",{"hue":0,"saturation":-100,"lightness":0}],"bands":["Master",{"falloffStart":0,"rangeStart":0,"rangeEnd":360,"falloffEnd":360},"Reds",{"falloffStart":315,"rangeStart":345,"rangeEnd":15,"falloffEnd":45},"Yellows",{"falloffStart":15,"rangeStart":45,"rangeEnd":75,"falloffEnd":105},"Greens",{"falloffStart":75,"rangeStart":105,"rangeEnd":135,"falloffEnd":165},"Cyans",{"falloffStart":135,"rangeStart":165,"rangeEnd":195,"falloffEnd":225},"Blues",{"falloffStart":195,"rangeStart":225,"rangeEnd":255,"falloffEnd":285},"Magentas",{"falloffStart":255,"rangeStart":285,"rangeEnd":315,"falloffEnd":345}]}"#
        let adjusted: String = #"{"kind":"Hue/Saturation","hue":0,"saturation":-100,"lightness":0,"colorize":false,"hsvSettings":\#(hsv),"levels":\#(identityLevels()),"curves":\#(identityCurves())}"#
        XCTAssertGreaterThan(meanSaturation(render(h, expectedBytes: 64)), 150, "red paint is saturated")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentPreview","adjustment":\#(adjusted)}"#), 0, "hsv preview")
        XCTAssertLessThan(meanSaturation(render(h, expectedBytes: 64)), 10, "saturation -100 desaturates red to gray")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentCommit","adjustment":\#(adjusted)}"#), 0, "hsv commit")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentCancel"}"#), -5, "cancel is a no-op when idle")
        compositorSessionClose(h)
    }

    /// Curves, Exposure, Gradient Map, and Grain each preview and commit; a
    /// rejected dialog (cancel) leaves pixels unchanged.
    func testAdjustRemainingKindsJourney() {
        let h = paintedSession()

        let inverted = #"[{"x":0,"y":255},{"x":255,"y":0}]"#
        let id = #"[{"x":0,"y":0},{"x":255,"y":255}]"#
        let darkCurves = #"{"channel":"RGB","channels":[\#(inverted),\#(id),\#(id),\#(id)]}"#
        let curvesAdj: String = #"{"kind":"Curves","hue":0,"saturation":0,"lightness":0,"colorize":false,"levels":\#(identityLevels()),"curves":\#(darkCurves)}"#
        let before = avgLight(render(h, expectedBytes: 64))
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"addAdjustment","kind":"Curves"}"#), 0, "add curves sheet")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentPreview","adjustment":\#(curvesAdj)}"#), 0, "curves preview")
        XCTAssertLessThan(avgLight(render(h, expectedBytes: 64)), before - 50, "inverted curve darkens white")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentCancel"}"#), 0, "cancel rolls back")
        // The canceled sheet is an identity layer: the base pixels are untouched.
        XCTAssertEqual(avgLight(render(h, expectedBytes: 64)), before, accuracy: 0.001, "cancel keeps original pixels")

        XCTAssertEqual(cmd(h, #"{"version":1,"action":"addAdjustment","kind":"Exposure"}"#), 0, "add exposure sheet")
        let exposure = #"{"exposure":-20,"offset":0,"gamma":1}"#
        let exposureAdj: String = #"{"kind":"Exposure","hue":0,"saturation":0,"lightness":0,"colorize":false,"exposureSettings":\#(exposure),"levels":\#(identityLevels()),"curves":\#(identityCurves())}"#
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentPreview","adjustment":\#(exposureAdj)}"#), 0, "exposure preview")
        XCTAssertLessThan(avgLight(render(h, expectedBytes: 64)), before, "exposure -20 darkens")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentCommit","adjustment":\#(exposureAdj)}"#), 0, "exposure commit")

        XCTAssertEqual(cmd(h, #"{"version":1,"action":"addAdjustment","kind":"Gradient Map"}"#), 0, "add gradient map sheet")
        let gradient = #"{"shadows":{"red":1,"green":0,"blue":0},"highlights":{"red":1,"green":0,"blue":0},"reversed":false}"#
        let gradientAdj: String = #"{"kind":"Gradient Map","hue":0,"saturation":0,"lightness":0,"colorize":false,"gradientMapSettings":\#(gradient),"levels":\#(identityLevels()),"curves":\#(identityCurves())}"#
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentPreview","adjustment":\#(gradientAdj)}"#), 0, "gradient map preview")
        let red = render(h, expectedBytes: 64)
        var isRed = true
        for i in stride(from: 0, to: red.count, by: 4) where red[i + 3] > 0 {
            if !(red[i] > 0 && red[i + 1] == 0 && red[i + 2] == 0) { isRed = false }
        }
        XCTAssertTrue(isRed, "red gradient map recolors paint red")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentCommit","adjustment":\#(gradientAdj)}"#), 0, "gradient map commit")

        XCTAssertEqual(cmd(h, #"{"version":1,"action":"addAdjustment","kind":"Grain"}"#), 0, "add grain sheet")
        let grain = #"{"amount":100,"size":5,"roughness":70,"seed":0}"#
        let grainAdj: String = #"{"kind":"Grain","hue":0,"saturation":0,"lightness":0,"colorize":false,"grainSettings":\#(grain),"levels":\#(identityLevels()),"curves":\#(identityCurves())}"#
        let quiet = render(h, expectedBytes: 64)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentPreview","adjustment":\#(grainAdj)}"#), 0, "grain preview")
        let noisy = render(h, expectedBytes: 64)
        XCTAssertNotEqual(noisy, quiet, "grain perturbs pixels")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"adjustmentCommit","adjustment":\#(grainAdj)}"#), 0, "grain commit")
        XCTAssertEqual(jsonBool(state(h), "busy"), false)
        compositorSessionClose(h)
    }

    /// Stage 9: Complete Editing Tools Parity (Move, Marquee, Lasso, Magic Wand, Clone Stamp, Healing, Crop, Distort)
    func testStage9EditingToolsJourney() throws {
        let h = compositorSessionCreate()
        XCTAssertNotEqual(h, 0)
        defer { compositorSessionClose(h) }

        // 1. Create 10x10 canvas and add a layer
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"new","width":10,"height":10}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"addLayer"}"#), 0)

        // 2. Paint initial pixel block
        let paintCmd = #"{"version":1,"action":"brushBegin","x":2,"y":2,"parameters":{"diameter":3,"hardness":1,"opacity":1,"red":1,"green":0,"blue":0,"erasing":0,"mask":0}}"#
        XCTAssertEqual(cmd(h, paintCmd), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"brushMove","x":3,"y":3}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"brushEnd"}"#), 0)
        XCTAssertEqual(jsonBool(state(h), "canUndo"), true)

        // 3. Move Tool: moveLayer dx=2, dy=3
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"moveLayer","x":2,"y":3}"#), 0)
        let st1 = state(h)
        XCTAssertTrue(st1.contains("\"origin\":[2,3]"), "layer origin moved to [2,3]")
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"undo"}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"redo"}"#), 0)

        // 4. Marquee Selection
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"selectRectangle","x":1,"y":1,"width":4,"height":4}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"deselect"}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"selectEllipse","x":2,"y":2,"width":5,"height":5}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"deselect"}"#), 0)

        // 5. Lasso Selection (polygon)
        let lassoCmd = #"{"version":1,"action":"selectLasso","points":[[1,1],[6,1],[6,6],[1,6]]}"#
        XCTAssertEqual(cmd(h, lassoCmd), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"deselect"}"#), 0)

        // 6. Magic Wand
        let wandCmd = #"{"version":1,"action":"magicWand","x":3,"y":3,"kind":"New","parameters":{"tolerance":32,"contiguous":1,"sampleAllLayers":0}}"#
        XCTAssertEqual(cmd(h, wandCmd), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"deselect"}"#), 0)

        // 7. Clone Stamp (brushBegin with cloneOffsetX/Y)
        let cloneCmd = #"{"version":1,"action":"brushBegin","x":5,"y":5,"parameters":{"diameter":3,"hardness":1,"opacity":1,"red":0,"green":0,"blue":0,"cloneOffsetX":-2,"cloneOffsetY":-2,"sampleAllLayers":0}}"#
        XCTAssertEqual(cmd(h, cloneCmd), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"brushEnd"}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"undo"}"#), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"redo"}"#), 0)

        // 8. Spot Healing (brushBegin with healing: 1)
        let healCmd = #"{"version":1,"action":"brushBegin","x":3,"y":3,"parameters":{"diameter":2,"hardness":1,"opacity":1,"red":0,"green":0,"blue":0,"healing":1,"healingMode":0}}"#
        XCTAssertEqual(cmd(h, healCmd), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"brushEnd"}"#), 0)

        // 9. Crop Canvas
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"cropCanvas","x":0,"y":0,"width":8,"height":8}"#), 0)
        XCTAssertEqual(jsonInt(state(h), "width"), 8)
        XCTAssertEqual(jsonInt(state(h), "height"), 8)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"undo"}"#), 0)
        XCTAssertEqual(jsonInt(state(h), "width"), 10)
        XCTAssertEqual(jsonInt(state(h), "height"), 10)

        // 10. Distort
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"distortBegin"}"#), 0)
        let distortCorners = #"{"version":1,"action":"distortCommit","points":[[1,1],[8,2],[7,8],[2,7]]}"#
        XCTAssertEqual(cmd(h, distortCorners), 0)
        XCTAssertEqual(cmd(h, #"{"version":1,"action":"undo"}"#), 0)
    }
}