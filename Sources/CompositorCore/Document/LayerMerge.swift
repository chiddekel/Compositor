// Portable port of Compositor/Document/LayerMerge.swift's merge-planning logic
// (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim:
// `LayerMerge.mergePlan(layers:activeID:selectedIDs:)` — what Cmd-E merges, in
// stacking order, and where the result goes; nil when there is nothing to merge.
// One layer merges with the layer beneath it in the same folder; several
// selected layers merge together (with anything their folders hold); a folder
// merges its contents, and the folder goes. Plus `descendantIDs(of:in:)`, the
// pure parent→child tree walk the plan (and the macOS EditorSession) uses.
//
// On macOS `mergePlan`/`descendantIDs` are `EditorSession` methods reading
// `document.layers`/`selectedLayerIDs`/`activeLayer` and gating on `canEditLayers`;
// ported here as free functions over `(layers, activeID, selectedIDs)` so the
// plan logic is reachable without the app-state class. The `canEditLayers`
// editability gate is the Qt document controller's responsibility (it calls this
// only when editing is allowed).
//
// Omitted (raster + model milestone):
//   - `canMergeLayers`/`mergeTitle` — `EditorSession` computed properties over
//     `mergePlan()`; rebuilt on the Qt side.
//   - `mergeLayers()` — composites the merge set as the canvas shows it via
//     `drawLiveComposite`/`CGContext.makeImage`/`PixelFilter.trimmed`, then
//     reinserts the merged layer and rewires clipping; the Skia/CPU raster +
//     model milestone.
//
// SOLID: the plan logic keeps its responsibility and contract (which layers a
// merge touches and where the result lands); the Apple API surface (CGContext
// composite, EditorSession state) is exchanged. The macOS original stays the
// source of truth.

import Foundation

nonisolated enum LayerMerge {
    struct MergePlan: Equatable {
        let ids: [UUID]
        let removed: Set<UUID>
        let name: String
        let parent: UUID?
        let anchor: UUID
        let action: String
    }

    /// The descendant subtree of `id` (exclusive of `id` itself), walked over `layers`.
    static func descendantIDs(of id: UUID, in layers: [ImageLayer]) -> Set<UUID> {
        let children = Dictionary(grouping: layers, by: \.parentID)
        var result = Set<UUID>(), pending = [id]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where result.insert(child.id).inserted { pending.append(child.id) }
        }
        return result
    }

    /// What Cmd-E merges, in stacking order, and where the result goes; nil when
    /// there is nothing to merge. Verbatim from the macOS `EditorSession.mergePlan()`,
    /// lifted to a pure function over `(layers, activeID, selectedIDs)`.
    static func mergePlan(layers: [ImageLayer], activeID: UUID?, selectedIDs: Set<UUID>) -> MergePlan? {
        guard let active = layers.first(where: { $0.id == activeID }) else { return nil }
        if selectedIDs.count > 1 {
            var picked = selectedIDs
            for id in selectedIDs { picked.formUnion(descendantIDs(of: id, in: layers)) }
            let ordered = layers.filter { picked.contains($0.id) }
            guard ordered.contains(where: { !$0.isGroup }),
                  let top = ordered.last(where: { selectedIDs.contains($0.id) }) else { return nil }
            return MergePlan(ids: ordered.map(\.id), removed: picked, name: top.name,
                            parent: top.parentID, anchor: top.id, action: "Merge Layers")
        }
        if active.isGroup {
            let inside = descendantIDs(of: active.id, in: layers)
            guard layers.contains(where: { inside.contains($0.id) && !$0.isGroup }) else { return nil }
            let ids = layers.filter { inside.contains($0.id) || $0.id == active.id }.map(\.id)
            return MergePlan(ids: ids, removed: Set(ids), name: active.name,
                            parent: active.parentID, anchor: active.id, action: "Merge Group")
        }
        guard let index = layers.firstIndex(where: { $0.id == active.id }),
              let below = layers[..<index].last(where: { $0.parentID == active.parentID }), !below.isGroup else { return nil }
        return MergePlan(ids: [below.id, active.id], removed: [below.id, active.id], name: below.name,
                        parent: active.parentID, anchor: active.id, action: "Merge Down")
    }
}