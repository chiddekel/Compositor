import Foundation

extension EditorSession {
    var canEditAppearance: Bool {
        canEditLayers && selectedLayerIDs.count == 1 && activeLayer?.isGroup == false
    }

    func setLayerOpacity(_ opacity: Double) {
        guard opacity.isFinite, canEditAppearance else { return }
        try? updateLayer(opacity: min(1, max(0, opacity)))
    }

    func setSelectedLayersOpacity(_ opacity: Double) {
        guard opacity.isFinite, canEditLayers, let document else { return }
        let value = min(1, max(0, opacity))
        let ids = Set(document.layers.filter { selectedLayerIDs.contains($0.id) && !$0.isGroup }.map(\.id))
        guard !ids.isEmpty else { return }
        beginEdit("Layer Opacity")
        var next = document
        for index in next.layers.indices where ids.contains(next.layers[index].id) {
            next.layers[index].opacity = value
        }
        replaceCurrentDocument(next)
        endEdit()
    }

    func cycleBlendMode(forward: Bool) {
        guard canEditAppearance, let layer = activeLayer else { return }
        let modes = LayerBlendMode.allCases
        let index = modes.firstIndex(of: layer.blendMode) ?? 0
        let next = (index + (forward ? 1 : modes.count - 1)) % modes.count
        setLayerBlendMode(modes[next])
    }

    func setLayerBlendMode(_ mode: LayerBlendMode) {
        guard canEditAppearance else { return }
        try? updateLayer(blendMode: mode)
    }
}
