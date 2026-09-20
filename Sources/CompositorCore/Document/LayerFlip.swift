import Foundation

extension EditorSession {
    func flipLayers(horizontally: Bool) {
        guard canTransform, let document else { return }
        let members = transformsAsGroup ? groupTransformMembers : (activeLayer.map { [$0] } ?? [])
        guard !members.isEmpty else { return }
        let points = members.flatMap { layer in
            [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(layer.transform.point)
        }
        let axis = horizontally
            ? (points.map(\.x).min()! + points.map(\.x).max()!) / 2
            : (points.map(\.y).min()! + points.map(\.y).max()!) / 2
        let ids = Set(members.map(\.id))
        beginEdit(horizontally ? "Flip Horizontal" : "Flip Vertical")
        var next = document
        for index in next.layers.indices where ids.contains(next.layers[index].id) {
            let layer = next.layers[index]
            let flipped = layer.transform.mirrored(horizontally: horizontally, across: axis)
            next.layers[index].mask?.placement = layer.mask?.placement(movingLayer: layer.transform, to: flipped)
            next.layers[index].transform = flipped
        }
        replaceCurrentDocument(next)
        endEdit()
    }

    func flipCanvas(horizontally: Bool) {
        guard canEditLayers, let document else { return }
        let axis = horizontally ? document.size.width / 2 : document.size.height / 2
        beginEdit(horizontally ? "Flip Canvas Horizontal" : "Flip Canvas Vertical")
        var next = document
        for index in next.layers.indices {
            let layer = next.layers[index]
            next.layers[index].transform = layer.transform.mirrored(horizontally: horizontally, across: axis)
            if let placement = layer.mask?.placement {
                next.layers[index].mask?.placement = placement.mirrored(horizontally: horizontally, across: axis)
            }
        }
        if let selection = document.selection {
            let transform = horizontally
                ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: document.size.width, ty: 0)
                : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: document.size.height)
            next.selection = DocumentSelection(path: selection.path.applying(transform), antialiased: selection.antialiased)
        }
        replaceCurrentDocument(next)
        endEdit()
    }
}
