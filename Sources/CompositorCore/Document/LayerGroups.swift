// Portable port of Compositor/Document/LayerGroups.swift's hierarchy logic
// (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim:
// `LayerHierarchy` (the layer-tree traversal over `[ProjectLayerRecord]` —
// `entries`/`visibleLayers`/`validate`) and `ImageLayer.hierarchyRecord` (the
// model→record projection the persistence layer serializes).
//
// Omitted (model/UI milestone — EditorSession app state):
//   - The `EditorSession` group/select/place/toggle extensions (`groupSelectedLayers`,
//     `addGroup`, `toggleGroupExpansion`, `placeLayer`, `moveActiveLayerOutOfGroup`,
//     `descendantIDs`, `layerRows`). These mutate `EditorSession` document/selection
//     state and are rebuilt on the Qt side.
//   - `CanvasDocument.hierarchyEntries`/`effectiveVisibleIDs`/`renderLayers` —
//     model-state conveniences that fold `LayerHierarchy` back onto `ImageLayer`s;
//     ported when the document controller exists.
//
// SOLID: the tree logic keeps its responsibility and contract (a depth-bounded
// parent/child traversal and its invariants); the Apple API surface (the
// EditorSession/AppKit state) is exchanged. The macOS original stays the source
// of truth.

import Foundation

nonisolated enum LayerHierarchy {
    struct Entry {
        let layer: ProjectLayerRecord
        let depth: Int
        let visible: Bool
    }
    static func entries(_ layers: [ProjectLayerRecord], topFirst: Bool = false,
                        collapsed: Set<UUID> = []) -> [Entry] {
        let children = Dictionary(grouping: layers, by: \.parentID)
        var result: [Entry] = []
        func visit(_ parent: UUID?, depth: Int, visible: Bool) {
            guard depth <= 64 else { return }
            let siblings = children[parent] ?? []
            for layer in topFirst ? Array(siblings.reversed()) : siblings {
                let effective = visible && layer.isVisible
                result.append(Entry(layer: layer, depth: depth, visible: effective))
                if layer.isGroup == true, !collapsed.contains(layer.id) {
                    visit(layer.id, depth: depth + 1, visible: effective)
                }
            }
        }
        visit(nil, depth: 0, visible: true)
        return result
    }
    static func visibleLayers(_ layers: [ProjectLayerRecord]) -> [ProjectLayerRecord] {
        entries(layers).filter { $0.visible && $0.layer.isGroup != true }.map(\.layer)
    }
    static func validate(_ layers: [ProjectLayerRecord]) throws {
        var byID: [UUID: ProjectLayerRecord] = [:]
        for layer in layers {
            guard byID.updateValue(layer, forKey: layer.id) == nil,
                  layer.isGroup != true || layer.imageFile == nil else { throw ProjectError.invalid }
        }
        for layer in layers {
            var seen: Set<UUID> = [layer.id]
            var parent = layer.parentID
            while let id = parent {
                guard seen.count <= 64, seen.insert(id).inserted,
                      let node = byID[id], node.isGroup == true else { throw ProjectError.invalid }
                parent = node.parentID
            }
            if layer.isGroup == true, seen.count > 64 { throw ProjectError.invalid }
        }
    }
}

extension ImageLayer {
    var hierarchyRecord: ProjectLayerRecord {
        ProjectLayerRecord(id: id, name: name, isVisible: isVisible, transform: transform,
            imageFile: asset == nil ? nil : "\(id.uuidString).png", parentID: parentID, isGroup: isGroup, opacity: opacity, blendMode: blendMode, maskFile: mask == nil ? nil : "\(id.uuidString).mask.png", maskEnabled: mask?.isEnabled, maskSourceID: maskSourceID, adjustment: adjustment, maskPlacement: mask?.placement, maskLinked: mask?.isLinked)
    }
}