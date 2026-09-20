import Foundation

extension EditorSession {
    func toggleGroupExpansion(_ id: UUID) {
        guard document?.layers.first(where: { $0.id == id })?.isGroup == true else { return }
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            if activeLayerID.map({ descendantIDs(of: id).contains($0) }) == true { selectLayer(id) }
            collapsedGroupIDs.insert(id)
        }
    }

    func canPlaceLayer(_ id: UUID, in parent: UUID?) -> Bool {
        guard canEditLayers, document?.layers.contains(where: { $0.id == id }) == true else { return false }
        guard let parent else { return true }
        return parent != id && !descendantIDs(of: id).contains(parent)
            && document?.layers.first(where: { $0.id == parent })?.isGroup == true
    }

    @discardableResult
    func placeLayer(_ id: UUID, in parent: UUID?, above target: UUID? = nil, atBottom: Bool = false) -> Bool {
        guard canPlaceLayer(id, in: parent), var layers = document?.layers,
              let index = layers.firstIndex(where: { $0.id == id }), target != id else { return false }
        var layer = layers.remove(at: index)
        layer.parentID = parent
        var insertion = atBottom ? 0 : layers.count
        if let target {
            guard let targetIndex = layers.firstIndex(where: { $0.id == target && $0.parentID == parent }) else { return false }
            insertion = targetIndex + 1
        }
        layers.insert(layer, at: min(insertion, layers.count))
        LiveMaskGraph.adoptClipping(id, in: &layers)
        LiveMaskGraph.releaseDetachedClipping(in: &layers)
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return false }
        beginEdit("Move Layer")
        var next = document!
        next.layers = layers
        replaceCurrentDocument(next)
        setActiveLayer(id)
        if let parent { collapsedGroupIDs.remove(parent) }
        endEdit()
        return true
    }

    func moveActiveLayerOutOfGroup() {
        guard let layer = activeLayer, let parent = layer.parentID,
              let group = document?.layers.first(where: { $0.id == parent }) else { return }
        _ = placeLayer(layer.id, in: group.parentID, above: group.id)
    }
}
