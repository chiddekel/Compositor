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
//   - Distortion commit (`commitDistort`, `previewCorners`) — needs
//     `DistortWarp.warp[]`, the raster-ondep; a `corners != nil` commit is a
//     no-op here.
//   - Floating-selection merge (`mergeFloatingTransform`) — needs the
//     `renderSelectedPixels`/`FloatingMerge.merge` raster.
//   - `redrawShape(at:)` — re-rasters a scalable shape at its new size via
//     CGContext on macOS; deferred with the shape raster milestone. Shape layers
//     composite through their (unchanged) asset pixels under the new transform.
//   - `snapGuides`/`blendPreview`/`finishOpacityEdit` — macOS canvas-only.
//
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
        if edit.corners != nil { return } // distortion commit needs DistortWarp.warp raster; deferred.
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
}