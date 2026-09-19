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
}