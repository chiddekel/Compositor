// Portable port of Compositor/Document/LiveLayerMask.swift's mask-graph logic
// (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim:
// `LiveMaskGraph.validate(_ layers: [ProjectLayerRecord])` (cycle/depth/group
// invariants on the clipping-mask dependency graph), and the two rearrange-time
// helpers `adoptClipping(_:in:)` / `releaseDetachedClipping(in:)` that run over
// `inout [ImageLayer]` as layers are moved.
//
// Omitted (raster + model milestone):
//   - `LiveMaskBaker.bake` — composites a live mask into pixels via `BrushRaster`
//     `CGContext` + `LayerRenderer`; the Skia/CPU raster milestone.
//   - `drawLiveComposite` — the per-frame `CGContext` composite walk; raster milestone.
//   - The `EditorSession` helpers `canLinkMask`/`linkMask`/`removeLiveMask`/
//     `canToggleClippingMask`/`toggleClippingMask`/`deleteWithLiveMaskChoice`/
//     `finishDeletingLayer(s:)` — they mutate `EditorSession` document state and
//     drive `NSAlert`/`Task`; rebuilt on the Qt side.
//
// SOLID: the graph logic keeps its responsibility and contract (the clipping-mask
// dependency graph's validity and the sibling-stack adoption/release rules); the
// Apple API surface (CGContext composite, AppKit alerts, EditorSession state) is
// exchanged. The macOS original stays the source of truth.

import Foundation

nonisolated enum LiveMaskGraph {
    static func validate(_ layers: [ProjectLayerRecord]) throws {
        var records: [UUID: ProjectLayerRecord] = [:]
        for layer in layers {
            guard records.updateValue(layer, forKey: layer.id) == nil else { throw ProjectError.invalid }
        }
        for layer in layers {
            var path = Set<UUID>(), current: UUID? = layer.id
            while let id = current {
                guard path.count < 256, path.insert(id).inserted, let record = records[id] else { throw ProjectError.invalid }
                if let source = record.maskSourceID {
                    guard !((record.isGroup ?? false)), records[source] != nil, records[source]?.isGroup != true, records[source]?.adjustment == nil else { throw ProjectError.invalid }
                }
                current = record.maskSourceID
            }
        }
    }
}

extension LiveMaskGraph {
    /// A layer dropped into the middle of a clipping group joins it, as in Photoshop: dropped between a base and a
    /// layer clipped to it, it is clipped to that base too. Run while the layers are being rearranged, before
    /// `releaseDetachedClipping` — an unclipped layer left in the middle of a group breaks it up instead.
    static func adoptClipping(_ id: UUID, in layers: inout [ImageLayer]) {
        guard let layer = layers.first(where: { $0.id == id }), !layer.isGroup else { return }
        let siblings = layers.filter { $0.parentID == layer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == id }), index > 0, index + 1 < siblings.count,
              let source = siblings[index + 1].maskSourceID, source != id else { return }
        let below = siblings[index - 1]
        guard below.id == source || below.maskSourceID == source,
              let position = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[position].maskSourceID = source
    }

    /// A moved layer stops clipping when it no longer belongs to the contiguous stack above its base.
    static func releaseDetachedClipping(in layers: inout [ImageLayer]) {
        let siblings = Dictionary(grouping: layers, by: \.parentID)
        var release = Set<UUID>()
        for stack in siblings.values {
            var base: UUID?
            for layer in stack {
                if let source = layer.maskSourceID {
                    if source != base { release.insert(layer.id); base = layer.id }
                } else { base = layer.isGroup ? nil : layer.id }
            }
        }
        for i in layers.indices where release.contains(layers[i].id) { layers[i].maskSourceID = nil }
    }
}