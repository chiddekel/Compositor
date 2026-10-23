import Foundation
import Testing
@testable import Compositor

/// Tool combinations as the Qt shell drives them: the same JSON commands, in the order a user's clicks produce them,
/// on upstream's unmodified `EditorSession`. A combination works on Linux when the bridge makes the session calls the
/// Mac `EditorCanvas` makes: the rail goes through `selectTool` (EditorSession.selectTool, which finishes text,
/// commits a transform, cancels a crop, applies a pending gradient, cancels lasso and shape drafts), and a canvas drag
/// starts the current tool (EditorCanvas.mouseDown → beginGradientDrag / beginBrush / beginText …).
///
/// Run one pair while debugging: `swift test --filter ToolCombinationTests` with `COMBO_PAIR=gradient>brush`.
@MainActor
struct ToolCombinationTests {
    private func send(_ e: UpstreamEditor, _ action: String, _ fields: [String: Any] = [:]) async -> Int32 {
        var command = fields
        command["version"] = 1; command["action"] = action
        return await e.commandAsync((try? JSONSerialization.data(withJSONObject: command)) ?? Data())
    }
    private func state(_ e: UpstreamEditor) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: (try? e.stateJSON()) ?? Data()) as? [String: Any]) ?? [:]
    }

    /// A 64×64 canvas with one transparent raster layer.
    private func canvas() -> UpstreamEditor {
        let e = UpstreamEditor()
        #expect(e.importRGBA([UInt8](repeating: 0, count: 64 * 64 * 4), width: 64, height: 64, name: "Canvas", replacing: true) == 0)
        return e
    }
    private func layerPixels(_ e: UpstreamEditor) throws -> [UInt8] { try e.renderRGBA().bytes }
    private func alpha(_ bytes: [UInt8], _ x: Int, _ y: Int) -> UInt8 { bytes[(y * 64 + x) * 4 + 3] }

    /// Drag a full gradient line and apply it (Return), as a gradient drag + Enter does.
    private func gradient(_ e: UpstreamEditor, apply: Bool = true) async -> [Int32] {
        var codes = [await send(e, "gradientBegin", ["x": 0, "y": 0]),
                     await send(e, "gradientMove", ["x": 63, "y": 63]),
                     await send(e, "gradientEndDrag")]
        if apply { codes.append(await send(e, "gradientCommit")) }
        return codes
    }

    /// Settles work upstream starts without waiting for it (`resolveGradient` applies the gradient in a `Task`).
    private func settle(_ e: UpstreamEditor) async {
        for _ in 0..<200 where e.session.gradientEdit != nil { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // Case 1: marquee selection, then a gradient: it paints only inside the selection.
    @Test func selectionThenGradientClipsToTheSelection() async throws {
        let e = canvas()
        #expect(await send(e, "selectRectangle", ["x": 16, "y": 16, "width": 16, "height": 16]) == 0)
        #expect(await gradient(e) == [0, 0, 0, 0])
        let bytes = try layerPixels(e)
        #expect(alpha(bytes, 24, 24) > 0, "inside the selection")
        #expect(alpha(bytes, 4, 4) == 0 && alpha(bytes, 60, 60) == 0 && alpha(bytes, 40, 20) == 0, "outside stays clear")
        #expect(e.session.canEditLayers)
    }

    // Case 2 (the reported one): editing text with a selection, then the Gradient tool. Upstream's `selectTool`
    // finishes the text first (EditorSession.selectTool → finishText); the gradient then starts on the text layer.
    @Test func editingTextThenGradientCommitsTheTextAndStartsTheGradient() async throws {
        let e = canvas()
        #expect(await send(e, "selectRectangle", ["x": 0, "y": 0, "width": 32, "height": 64]) == 0)
        #expect(await send(e, "textBegin", ["x": 4, "y": 4, "enabled": true]) == 0)
        #expect(await send(e, "textSetContent", ["name": "Hi"]) == 0)
        #expect(e.session.textDraft != nil)
        #expect(await gradient(e) == [0, 0, 0, 0])
        #expect(e.session.textDraft == nil, "text was finished")
        #expect(e.session.tool == .gradient)
        #expect(e.session.document?.layers.count == 2)
        #expect(e.session.canEditLayers)
        // One undo step each: the gradient, then the text layer.
        #expect(await send(e, "undo") == 0)
        #expect(e.session.document?.layers.count == 2)
        #expect(await send(e, "undo") == 0)
        #expect(e.session.document?.layers.count == 1)
    }

    // Case 3: a text layer selected, a selection, a gradient: pixel edits rasterize the layer (LayerText doc,
    // TypeTool.swift: "Pixel edits rasterize the layer"); one undo brings the editable text back.
    @Test func gradientOnATextLayerRasterizesItAndUndoRestoresTheText() async throws {
        let e = canvas()
        #expect(await send(e, "textBegin", ["x": 4, "y": 4, "enabled": true]) == 0)
        #expect(await send(e, "textSetContent", ["name": "Text"]) == 0)
        #expect(await send(e, "textFinish") == 0)
        #expect(e.session.activeLayer?.liveText != nil)
        #expect(await send(e, "selectRectangle", ["x": 0, "y": 0, "width": 32, "height": 32]) == 0)
        #expect(await gradient(e) == [0, 0, 0, 0])
        #expect(e.session.activeLayer?.liveText == nil, "rasterized by the pixel edit")
        #expect(await send(e, "undo") == 0)
        #expect(e.session.activeLayer?.liveText != nil, "undo restores editable text")
    }

    // Case 5: moving selected pixels, released, then a gradient.
    @Test func movedPixelsThenGradientWorks() async throws {
        let e = canvas()
        #expect(await gradient(e) == [0, 0, 0, 0])
        #expect(await send(e, "selectRectangle", ["x": 8, "y": 8, "width": 16, "height": 16]) == 0)
        #expect(await send(e, "selectTool", ["kind": "move"]) == 0)
        #expect(e.session.pixelMove == nil)
        #expect(await gradient(e) == [0, 0, 0, 0])
        #expect(e.session.canEditLayers)
    }

    // Case 6: Show Transform Controls is a display setting (TransformInspector): with it on, every other tool,
    // layer command and history step still works.
    @Test func showTransformControlsDoesNotBlockOtherTools() async throws {
        let e = canvas()
        #expect(await send(e, "setShowsTransformControls", ["enabled": true]) == 0)
        #expect(e.session.canEditLayers, "Show Controls alone must not arm a transform")
        #expect(await gradient(e) == [0, 0, 0, 0])
        #expect(await send(e, "brushBegin", ["x": 10, "y": 10]) == 0)
        #expect(await send(e, "brushEnd") == 0)
        #expect(await send(e, "addLayer") == 0)
        #expect(e.session.document?.layers.count == 2)
        #expect(await send(e, "setBlendMode", ["kind": "Multiply"]) == 0)
        #expect(await send(e, "undo") == 0)
        #expect(await send(e, "undo") == 0)
        #expect(e.session.document?.layers.count == 1)
        #expect(e.session.showsTransformControls)
    }

    // Case 7: a gradient left pending (no Return), then the brush: upstream applies the gradient on the tool change
    // (selectTool → resolveGradient) and the stroke then paints.
    @Test func pendingGradientThenBrushAppliesTheGradientAndPaints() async throws {
        let e = canvas()
        #expect(await gradient(e, apply: false) == [0, 0, 0])
        #expect(e.session.gradientEdit != nil)
        #expect(await send(e, "brushBegin", ["x": 10, "y": 10]) == 0, "\(e.error ?? "")")
        #expect(await send(e, "brushEnd") == 0)
        await settle(e)
        #expect(e.session.gradientEdit == nil)
        #expect(e.session.canEditLayers)
        #expect(alpha(try layerPixels(e), 60, 60) > 0, "the gradient was applied")
    }

    // Case 7b: the same through the rail (selectTool), then a gradient drag again.
    @Test func pendingGradientThenToolSwitchAndBackWorks() async throws {
        let e = canvas()
        #expect(await gradient(e, apply: false) == [0, 0, 0])
        #expect(await send(e, "selectTool", ["kind": "marquee"]) == 0)
        #expect(await send(e, "selectRectangle", ["x": 0, "y": 0, "width": 8, "height": 8]) == 0)
        #expect(await gradient(e) == [0, 0, 0, 0], "\(e.error ?? "")")
        #expect(e.session.canEditLayers)
    }

    // Case 8: a pending crop, then a gradient: the crop is cancelled and the gradient works.
    @Test func pendingCropThenGradientWorks() async throws {
        let e = canvas()
        #expect(await send(e, "selectTool", ["kind": "crop"]) == 0)
        #expect(e.session.cropRect != nil)
        #expect(await gradient(e) == [0, 0, 0, 0], "\(e.error ?? "")")
        #expect(e.session.cropRect == nil)
        #expect(e.session.canEditLayers)
    }

    // Case 9: a selection, then Crop: the crop starts at the selection's bounds (EditorSession.selectTool).
    @Test func selectionThenCropSeedsTheCropRect() async throws {
        let e = canvas()
        #expect(await send(e, "selectRectangle", ["x": 8, "y": 12, "width": 20, "height": 16]) == 0)
        #expect(await send(e, "selectTool", ["kind": "crop"]) == 0)
        #expect(e.session.cropRect == CGRect(x: 8, y: 12, width: 20, height: 16))
        #expect(await send(e, "selectTool", ["kind": "marquee"]) == 0)
        #expect(e.session.cropRect == nil)
        #expect(e.session.selection != nil, "cancelling the crop keeps the selection")
    }

    // Case 11: a target upstream refuses: the command reports upstream's reason, never a bare "could not start".
    @Test func refusedTargetReportsUpstreamsReason() async throws {
        let e = canvas()
        #expect(await send(e, "addGroup") == 0)
        #expect(e.session.activeLayer?.isGroup == true)
        let code = await send(e, "gradientBegin", ["x": 1, "y": 1])
        #expect(code != 0)
        let reason = e.error ?? ""
        #expect(reason.contains("folder"), "got: \(reason)")
        #expect(!reason.hasSuffix("could not start"))
    }

    // Choosing the tool that is already active is not a refusal.
    @Test func selectingTheActiveToolSucceeds() async throws {
        let e = canvas()
        #expect(await send(e, "selectTool", ["kind": "brush"]) == 0)
        #expect(await send(e, "selectTool", ["kind": "brush"]) == 0)
        #expect(e.session.tool == .brush)
    }

    // A handle drag on the Move tool, released, leaves no transform open: other tools and history work.
    @Test func releasedTransformDragLeavesToolsWorking() async throws {
        let e = canvas()
        #expect(await gradient(e) == [0, 0, 0, 0])
        #expect(await send(e, "transform", ["parameters": ["x": 5, "y": 3]]) == 0)
        #expect(e.session.transformEdit == nil, "an options-bar field edit applies when it isn't Free Transform")
        #expect(await send(e, "brushBegin", ["x": 10, "y": 10]) == 0, "\(e.error ?? "")")
        #expect(await send(e, "brushEnd") == 0)
        #expect(await send(e, "addLayer") == 0)
        #expect(e.session.canEditLayers)
    }

    /// Every ordered pair of tools from the rail: switching never leaves a pending draft of another tool behind
    /// (selectTool's resolution table), and once settled the editor accepts layer edits again.
    @Test func everyToolPairLeavesTheEditorUsable() async throws {
        let tools: [NavigationTool] = [.marquee, .lasso, .wand, .move, .brush, .cloneStamp, .spotHealing, .blur,
                                       .gradient, .shape, .type, .crop, .eyedropper, .hand, .zoom]
        let only = ProcessInfo.processInfo.environment["COMBO_PAIR"]
        let start = Date()
        for from in tools { for to in tools where to != from {
            if let only, only != "\(from.rawValue)>\(to.rawValue)" { continue }
            let e = canvas()
            #expect(await send(e, "selectRectangle", ["x": 16, "y": 16, "width": 16, "height": 16]) == 0)
            #expect(await send(e, "selectTool", ["kind": from.rawValue]) == 0, "\(from)")
            switch from {   // the draft a user typically leaves open with this tool
            case .gradient: _ = await gradient(e, apply: false)
            case .type: _ = await send(e, "textBegin", ["x": 2, "y": 2, "enabled": true]); _ = await send(e, "textSetContent", ["name": "x"])
            case .shape: _ = await send(e, "shapeBegin", ["x": 2, "y": 2]); _ = await send(e, "shapeDrag", ["x": 20, "y": 20])
            default: break
            }
            #expect(await send(e, "selectTool", ["kind": to.rawValue]) == 0, "\(from)>\(to): \(e.error ?? "")")
            await settle(e)
            let s = e.session
            #expect(s.tool == to, "\(from)>\(to)")
            #expect(s.textDraft == nil && s.gradientEdit == nil && s.shapeDraft == nil && s.lassoDraft == nil,
                    "\(from)>\(to) left a draft open")
            #expect(s.transformEdit == nil, "\(from)>\(to)")
            #expect((s.cropRect != nil) == (to == .crop), "\(from)>\(to) crop")
            #expect(s.selection != nil, "\(from)>\(to) kept the selection")
            #expect(s.canEditLayers || to == .crop, "\(from)>\(to) left the editor busy")
        } }
        #expect(Date().timeIntervalSince(start) < 60, "matrix took \(Date().timeIntervalSince(start)) s")
    }
}
