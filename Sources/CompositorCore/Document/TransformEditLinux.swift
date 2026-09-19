// Portable port of Compositor/Document/EditorSession.swift's transform editing
// (file-map tier: "Keep logic; replace Apple operations"): the `transformEdit`
// state machine — `beginTransform`, `previewTransform`, `commitTransform`,
// `cancelTransform`, the mask-alone and group cases, and the preview accessors
// (`pendingTransform`/`editedTransform`/`displayedTransform`/`transformTargetsMask`).
// `TransformEdit`/`FloatingTransform`/`TransformGroup` live in LayerTransform.swift.
//
// Omitted (raster milestone — Skia/CPU drawing backend, deferred):
//   - `beginDuplicateTransform` (Option-drag duplicate) and its
//     `transformDuplicate` clearing in commit/cancel.
//   - Floating-selection merge (`mergeFloatingTransform`, floating+distort) — needs the
//     `renderSelectedPixels`/`FloatingMerge.merge` raster.
//   - `redrawShape(at:)` — re-rasters a scalable shape at its new size via
//     CGContext on macOS; deferred with the shape raster milestone. Shape layers
//     composite through their (unchanged) asset pixels under the new transform.
//   - `snapGuides`/`blendPreview`/`finishOpacityEdit` — macOS canvas-only.
//   - Distortion *preview* (`distortPreview`, `DistortPreviewCache`) — canvas-tier: warps at
//     preview size (limit 2048) and clips masks for the live stroke; the commit-time warp is
//     implemented below (`beginDistort`/`previewCorners`/`commitDistort`/`distort`).
// The Apple API surface is exchanged (no AppKit); the macOS original stays the
// source of truth. `render()` applies the pending draft to a document copy so
// the commit happens only when the user is done (macOS keeps the draft in
// `transformEdit` and never writes it to the model mid-drag).

import Foundation

extension EditorSession {
    // MARK: - Transform editing (port of macOS EditorSession.transformEdit lifecycle)

    /// Whether transforming places only the active layer's mask (an unlinked mask selected in the Layers panel).
    var transformTargetsMask: Bool { transformEdit.map(\.mask) ?? (isMaskSelected && activeLayer?.mask?.isLinked == false) }

    /// Where `layer`'s transform handles sit: the pending edit's draft — the layer's or its mask's — else the layer.
    func editedTransform(for layer: ImageLayer) -> LayerTransform {
        if transformEdit?.layerID == layer.id { return transformEdit!.draft }
        if transformEdit == nil, layer.id == activeLayerID, transformsAsGroup, let box = groupTransformBox { return box }
        return layer.id == activeLayerID && transformTargetsMask ? layer.maskTransform : layer.transform
    }

    /// A layer's transform under the pending edit: the draft for the edited layer, carried along with the box for
    /// each layer of a group; nil when the edit doesn't move it.
    func pendingTransform(for layer: ImageLayer) -> LayerTransform? {
        guard let edit = transformEdit, !edit.mask else { return nil }
        if let group = edit.group { return group.originals[layer.id].map { $0.following(from: group.box, to: edit.draft) } }
        return edit.layerID == layer.id ? edit.draft : nil
    }

    func displayedTransform(for layer: ImageLayer) -> LayerTransform {
        if let pending = pendingTransform(for: layer) { return pending }
        return layer.transform
    }

    /// The upright box around `groupTransformMembers`.
    var groupTransformBox: LayerTransform? {
        let points = groupTransformMembers.flatMap { DistortWarp.corners(of: $0.transform) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return LayerTransform(origin: CGPoint(x: minX, y: minY), size: CGSize(width: max(1, maxX - minX), height: max(1, maxY - minY)))
    }

    func beginTransform(persistent: Bool = true) {
        guard transformEdit == nil, canTransform, let layer = activeLayer else { return }
        if transformsAsGroup {
            let members = groupTransformMembers
            guard let box = groupTransformBox else { return }
            transformEdit = TransformEdit(layerID: layer.id, draft: box, persistent: persistent,
                group: TransformGroup(box: box, originals: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.transform) })))
            return
        }
        // An unlinked mask, when selected, transforms on its own; linked, layer and mask move together.
        let maskAlone = isMaskSelected && layer.mask?.isLinked == false
        transformEdit = TransformEdit(layerID: layer.id, draft: maskAlone ? layer.maskTransform : layer.transform,
                                      persistent: persistent, mask: maskAlone)
    }

    func previewTransform(_ value: LayerTransform) {
        guard value.isValid, transformEdit != nil else { return }
        transformEdit?.draft = value
    }

    /// Apply for an unlinked mask transformed on its own: it takes the new placement (its pixels untouched).
    func commitMaskTransform(_ edit: TransformEdit) {
        guard edit.draft.isValid, let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
              let layer = document?.layers[index], let mask = layer.mask, edit.corners == nil else { return }
        let placement = edit.draft.samePlacement(as: layer.transform) ? nil : edit.draft
        guard placement != mask.placement else { return }
        beginEdit("Transform Layer Mask")
        var next = document!
        next.layers[index].mask?.placement = placement
        replaceCurrentDocument(next)
        endEdit()
    }

    func commitTransform() {
        guard let edit = transformEdit else { return }
        transformEdit = nil
        guard edit.draft.isValid else { return }
        if edit.floating != nil {
            // FloatingSelection merge needs the lift/merge raster milestone; commit
            // without it is deferred, so the pending edit simply closes.
            return
        }
        if edit.mask { commitMaskTransform(edit); return }
        if let corners = edit.corners { commitDistort(edit, corners: corners); return }
        if let group = edit.group {
            beginEdit("Transform Layers")
            var next = document!
            for (id, original) in group.originals {
                guard let index = next.layers.firstIndex(where: { $0.id == id }) else { continue }
                let moved = original.following(from: group.box, to: edit.draft)
                guard moved.isValid else { continue }
                if let mask = next.layers[index].mask {
                    next.layers[index].mask?.placement = mask.placement(movingLayer: original, to: moved)
                }
                next.layers[index].transform = moved
            }
            replaceCurrentDocument(next)
            endEdit()
            return
        }
        guard let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }) else { return }
        beginEdit("Transform Layer")
        var next = document!
        if let mask = next.layers[index].mask {
            let old = next.layers[index].transform
            next.layers[index].mask?.placement = mask.placement(movingLayer: old, to: edit.draft)
        }
        next.layers[index].transform = edit.draft
        replaceCurrentDocument(next)
        endEdit()
    }

    func cancelTransform() {
        // The draft never touched the model; discarding it is enough.
        transformEdit = nil
    }

    // MARK: - Distortion (port of macOS EditorSession beginDistort/previewCorners/commitDistort/distort)

    /// Cmd-drag on a transform handle: the corners start moving freely. Each distortion resamples
    /// the pixels, so the edit then waits for Apply rather than applying on mouse-up.
    func beginDistort() {
        guard let edit = transformEdit, edit.corners == nil, edit.draft.isValid else { return }
        transformEdit = TransformEdit(layerID: edit.layerID, draft: edit.draft, persistent: true, floating: edit.floating,
                                      corners: DistortWarp.corners(of: edit.draft), mask: edit.mask, group: edit.group)
    }

    /// Moves the distortion's corners; a twisted or collapsed shape is ignored.
    func previewCorners(_ corners: [CGPoint]) {
        guard transformEdit?.corners != nil, DistortWarp.isUsable(corners) else { return }
        transformEdit?.corners = corners
    }

    /// Where a distortion takes `layer`: its transform under the edit and the corners that transform moves to —
    /// for a group, each layer by the same perspective as the box.
    private func distortTarget(for layer: ImageLayer, edit: TransformEdit, shape: [CGPoint])
        -> (transform: LayerTransform, corners: [CGPoint])? {
        guard let group = edit.group else { return edit.layerID == layer.id ? (edit.draft, shape) : nil }
        guard let original = group.originals[layer.id] else { return nil }
        let transform = original.following(from: group.box, to: edit.draft)
        let corners = DistortWarp.carried(transform, by: edit.draft, to: shape)
        return DistortWarp.isUsable(corners) ? (transform, corners) : nil
    }

    /// Apply for a distortion: each distorted layer's pixels and mask are resampled into its shape, as one undo step.
    func commitDistort(_ edit: TransformEdit, corners shape: [CGPoint]) {
        guard document != nil else { return }
        let ids = edit.group.map { Array($0.originals.keys) } ?? [edit.layerID]
        beginEdit(edit.group == nil ? "Distort" : "Distort Layers")
        var next = document!
        for id in ids {
            guard let index = next.layers.firstIndex(where: { $0.id == id }),
                  let target = distortTarget(for: next.layers[index], edit: edit, shape: shape) else { continue }
            do { next.layers[index] = try distort(next.layers[index], transform: target.transform, corners: target.corners) }
            catch { brushError = error.localizedDescription }
        }
        replaceCurrentDocument(next)
        endEdit()
    }

    /// The layer shown by `transform`, resampled so its corners land on `corners` — pixels trimmed to what is
    /// actually there, and a linked mask taking the same perspective (while an unlinked one keeps its place).
    private func distort(_ layer: ImageLayer, transform: LayerTransform, corners: [CGPoint]) throws -> ImageLayer {
        guard let image = layer.asset?.image else { return layer }
        let warped = try DistortWarp.warpTrimmed(image, transform: transform, corners: corners)
        let asset = ImportedImage(image: warped.image,
                                  thumbnail: RasterImage(PixelAdjust.thumbnail(of: warped.image.pixels)), name: layer.name)
        var mask = layer.mask
        if let original = layer.mask, original.placement == nil, original.isLinked {
            let warpedMask = try DistortWarp.warp(original.asset.image, transform: transform, corners: corners, isMask: true)
            // A uniform mask passes through; any other is cropped with the pixels.
            let maskAsset: ImportedImage
            if warpedMask.image === original.asset.image {
                maskAsset = original.asset
            } else {
                guard let cropped = warpedMask.image.pixels.cropped(to: warped.crop) else { throw ProjectError.invalid }
                maskAsset = try LayerMask.asset(from: cropped)
            }
            mask = original.replacing(maskAsset)
        } else if let original = layer.mask, original.isLinked, let placed = original.placement,
                  case let placement = placed.following(from: layer.transform, to: transform),
                  case let carried = DistortWarp.carried(placement, by: transform, to: corners), DistortWarp.isUsable(carried) {
            // A linked mask placed apart takes the same perspective over its own bounds.
            let moved = try DistortWarp.warpMask(original.asset.image, transform: placement, corners: carried,
                                                 background: LayerMask.background(of: original.asset.thumbnail))
            mask = LayerMask(asset: moved.image === original.asset.image ? original.asset : try LayerMask.asset(from: moved.image.pixels),
                             isEnabled: original.isEnabled, placement: moved.transform, isLinked: true)
        } else if let original = layer.mask {
            // An unlinked mask keeps its place on the document.
            mask?.placement = original.placement ?? layer.transform
        }
        var result = layer
        result.asset = asset
        result.transform = warped.transform
        result.mask = mask
        return result
    }
}