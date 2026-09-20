import Foundation

extension EditorSession {
    func addLayerMask(revealing: Bool = true) {
        guard canEditLayers, let document, let index = document.layers.firstIndex(where: { $0.id == activeLayerID }),
              !document.layers[index].isGroup, document.layers[index].mask == nil else { return }
        beginEdit(revealing ? "Add Reveal Mask" : "Add Hide Mask")
        var next = document
        next.layers[index].mask = LayerMask.solid(revealing: revealing)
        replaceCurrentDocument(next)
        endEdit()
    }

    func deleteLayerMask() {
        guard canEditLayers, let document, let index = document.layers.firstIndex(where: { $0.id == activeLayerID }),
              document.layers[index].mask != nil else { return }
        beginEdit("Delete Mask")
        var next = document
        next.layers[index].mask = nil
        replaceCurrentDocument(next)
        endEdit()
    }

    func setLayerMaskEnabled(_ enabled: Bool) {
        guard canEditLayers, let document, let index = document.layers.firstIndex(where: { $0.id == activeLayerID }),
              document.layers[index].mask != nil else { return }
        beginEdit("Mask Appearance")
        var next = document
        next.layers[index].mask?.isEnabled = enabled
        replaceCurrentDocument(next)
        endEdit()
    }

    func setLayerMaskLinked(_ linked: Bool) {
        guard canEditLayers, let document, let index = document.layers.firstIndex(where: { $0.id == activeLayerID }),
              document.layers[index].mask != nil else { return }
        beginEdit("Mask Link")
        var next = document
        next.layers[index].mask?.isLinked = linked
        replaceCurrentDocument(next)
        endEdit()
    }

    func invertLayerMask() {
        guard canEditLayers, let document, let index = document.layers.firstIndex(where: { $0.id == activeLayerID }),
              let mask = document.layers[index].mask else { return }
        do {
            let image = try PixelInvert.run(.init(image: mask.asset.image.pixels, isMask: true,
                                                  pixelToDocument: .identity, selection: nil))
            beginEdit("Invert Mask")
            var next = document
            next.layers[index].mask = mask.replacing(try LayerMask.asset(from: image))
            replaceCurrentDocument(next)
            endEdit()
        } catch { }
    }
}
