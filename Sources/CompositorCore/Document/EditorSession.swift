import Foundation

/// Application state owned by the Swift core. The bridge serializes access to
/// each session; Qt owns presentation and receives immutable state/pixel copies.
final class EditorSession {
    enum Failure: Error { case noDocument, noLayer, busy, invalidArgument, dependentLayer }
    private(set) var document: CanvasDocument?
    private(set) var activeLayerID: UUID?
    let history = DocumentHistory()
    private(set) var brushStroke: BrushStroke?
    private(set) var filterEdit: FilterEdit?
    var activeLayer: ImageLayer? { document?.layers.first { $0.id == activeLayerID } }

    private func requireIdle() throws {
        guard brushStroke == nil, filterEdit == nil else { throw Failure.busy }
    }

    func createDocument(width: Int, height: Int) throws {
        try requireIdle()
        guard (1...30_000).contains(width), (1...30_000).contains(height), width * height <= 100_000_000 else {
            throw ProjectError.tooLarge
        }
        let layer = ImageLayer(name: "Layer 1", blankSize: CGSize(width: width, height: height))
        document = CanvasDocument(width: width, height: height, layers: [layer])
        activeLayerID = layer.id
        history.reset()
    }

    func install(_ snapshot: ProjectSnapshot) throws {
        try requireIdle()
        let loaded = try snapshot.document()
        guard loaded.width * loaded.height <= 100_000_000 else { throw ProjectError.tooLarge }
        document = loaded
        activeLayerID = snapshot.manifest.activeLayerID
        history.reset()
    }

    func importImage(_ pixels: PortableImage, name: String, replacing: Bool) throws {
        try requireIdle()
        guard pixels.kind == .rgba, (1...30_000).contains(pixels.width), (1...30_000).contains(pixels.height),
              pixels.width * pixels.height <= 100_000_000, !name.isEmpty else { throw Failure.invalidArgument }
        let asset = ImportedImage(image: RasterImage(pixels), thumbnail: RasterImage(PixelAdjust.thumbnail(of: pixels)), name: name)
        if replacing || document == nil {
            let layer = ImageLayer(asset: asset, origin: .zero)
            document = CanvasDocument(width: pixels.width, height: pixels.height, layers: [layer])
            activeLayerID = layer.id
            history.reset()
        } else {
            try edit("Import Image") { doc in
                guard doc.layers.count < 10_000 else { throw ProjectError.tooLarge }
                let used = doc.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) }
                guard pixels.width * pixels.height <= 100_000_000 - used else { throw ProjectError.tooLarge }
                let layer = ImageLayer(asset: asset, origin: CGPoint(x: floor((CGFloat(doc.width) - CGFloat(pixels.width)) / 2),
                                                                    y: floor((CGFloat(doc.height) - CGFloat(pixels.height)) / 2)))
                doc.layers.append(layer)
                activeLayerID = layer.id
            }
        }
    }

    private func edit(_ name: String, _ body: (inout CanvasDocument) throws -> Void) throws {
        try requireIdle()
        guard var next = document else { throw Failure.noDocument }
        let previousID = activeLayerID
        do { try body(&next) }
        catch { activeLayerID = previousID; throw error }
        history.begin(name, document: document, selection: previousID)
        document = next
        history.end(document: document, selection: activeLayerID)
    }

    func addBlankLayer() throws {
        try edit("New Layer") { doc in
            guard doc.layers.count < 10_000 else { throw ProjectError.tooLarge }
            var layer = ImageLayer(name: "Layer \(doc.layers.count + 1)", blankSize: doc.size)
            if let active = doc.layers.firstIndex(where: { $0.id == activeLayerID }) {
                layer.parentID = doc.layers[active].isGroup ? doc.layers[active].id : doc.layers[active].parentID
                doc.layers.insert(layer, at: active + 1)
            } else { doc.layers.append(layer) }
            activeLayerID = layer.id
        }
    }

    func selectLayer(_ id: UUID) throws {
        try requireIdle()
        guard document?.layers.contains(where: { $0.id == id }) == true else { throw Failure.noLayer }
        activeLayerID = id
    }

    func updateLayer(name: String? = nil, visible: Bool? = nil, opacity: Double? = nil,
                     blendMode: LayerBlendMode? = nil, transform: LayerTransform? = nil) throws {
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 16_384 { throw Failure.invalidArgument }
        if let opacity, !opacity.isFinite || !(0...1).contains(opacity) { throw Failure.invalidArgument }
        if let transform, !transform.isValid { throw Failure.invalidArgument }
        try edit(name != nil ? "Rename Layer" : transform != nil ? "Transform" : "Layer Appearance") { doc in
            guard let index = doc.layers.firstIndex(where: { $0.id == activeLayerID }) else { throw Failure.noLayer }
            if doc.layers[index].isGroup, opacity != nil || blendMode != nil { throw Failure.invalidArgument }
            if let name { doc.layers[index].name = name }
            if let visible { doc.layers[index].isVisible = visible }
            if let opacity { doc.layers[index].opacity = opacity }
            if let blendMode { doc.layers[index].blendMode = blendMode }
            if let transform {
                let old = doc.layers[index].transform
                if var mask = doc.layers[index].mask {
                    mask.placement = mask.placement(movingLayer: old, to: transform)
                    doc.layers[index].mask = mask
                }
                doc.layers[index].transform = transform
            }
        }
    }

    func deleteLayer() throws {
        try edit("Delete Layer") { doc in
            guard let id = activeLayerID, doc.layers.contains(where: { $0.id == id }) else { throw Failure.noLayer }
            var removed: Set<UUID> = [id]
            for _ in 0..<64 {
                let children = doc.layers.filter { $0.parentID.map { removed.contains($0) } ?? false }.map(\.id)
                let count = removed.count
                removed.formUnion(children)
                if count == removed.count { break }
            }
            guard !doc.layers.contains(where: { !removed.contains($0.id) && $0.maskSourceID.map { removed.contains($0) } == true }) else {
                throw Failure.dependentLayer
            }
            let index = doc.layers.firstIndex { $0.id == id }!
            doc.layers.removeAll { removed.contains($0.id) }
            activeLayerID = doc.layers.isEmpty ? nil : doc.layers[min(index, doc.layers.count - 1)].id
        }
    }

    func setSelection(_ selection: DocumentSelection?) throws {
        try edit("Selection") { $0.selection = selection }
    }

    func beginBrush(at point: CGPoint, settings: BrushSettings, mask: Bool = false) throws {
        try requireIdle()
        guard let doc = document, let layer = activeLayer, layer.isVisible, !layer.isGroup, layer.adjustment == nil,
              !mask || layer.mask != nil else { throw Failure.noLayer }
        guard [point.x, point.y, settings.red, settings.green, settings.blue].allSatisfy(\.isFinite),
              [settings.red, settings.green, settings.blue].allSatisfy({ (0...1).contains($0) }) else { throw Failure.invalidArgument }
        let stroke = try BrushStroke(layer: layer, mask: mask, settings: settings, canvas: doc.size)
        stroke.selectionClip = doc.selection?.clip(canvas: doc.size)
        try stroke.append(point)
        brushStroke = stroke
    }

    func continueBrush(at point: CGPoint) throws {
        guard let stroke = brushStroke else { throw Failure.busy }
        do { try stroke.append(point) }
        catch { brushStroke = nil; throw error }
    }

    func cancelBrush() { brushStroke = nil }

    func finishBrush() throws {
        guard let stroke = brushStroke, var doc = document,
              let index = doc.layers.firstIndex(where: { $0.id == stroke.layer.id }) else { throw Failure.busy }
        defer { brushStroke = nil }
        try stroke.flush()
        guard !stroke.patches.isEmpty else { return }
        let result = try stroke.paintSnapshot()
        guard result.transform.isValid else { throw ProjectError.invalid }
        var layer = doc.layers[index]
        if stroke.isMask {
            layer.mask = layer.mask?.replacing(result.asset) ?? LayerMask(asset: result.asset)
        } else {
            if let mask = layer.mask, mask.placement == nil, result.bounds != stroke.sourceRect {
                let raster = RasterSnapshot.replacing(source: mask.asset, sourceRect: stroke.sourceRect,
                    patches: [], crop: result.bounds, isMask: true)
                layer.mask = mask.replacing(ImportedImage(image: raster.makeImage(),
                    thumbnail: RasterImage(try raster.thumbnail()), name: mask.asset.name, raster: raster))
            }
            layer.asset = result.asset
            layer.transform = result.transform
            layer.shape = nil
        }
        history.begin(stroke.isMask ? "Paint Mask" : stroke.settings.erasing ? "Erase" : "Brush Stroke", document: document, selection: activeLayerID)
        doc.layers[index] = layer
        document = doc
        history.end(document: doc, selection: activeLayerID)
    }

    func beginFilter(_ kind: FilterKind, settings: FilterSettings) throws {
        try requireIdle()
        guard let doc = document, let layer = activeLayer else { throw Failure.noLayer }
        filterEdit = try FilterEdit(kind: kind, documentID: doc.id, layer: layer,
            selection: doc.selection?.clip(canvas: doc.size), settings: settings,
            growingTo: kind == .contentAwareFill ? doc.selection?.path.boundingBox : nil)
    }

    func updateFilter(_ settings: FilterSettings) throws {
        guard let edit = filterEdit else { throw Failure.busy }
        try edit.update(settings)
        let request = try edit.makePreviewRequest()
        edit.acceptPreview(try PixelFilter.run(request.job), for: request)
    }

    func commitFilter() throws {
        guard let edit = filterEdit, var doc = document else { throw Failure.busy }
        try edit.commit(document: &doc, activeLayerID: activeLayerID, history: history)
        document = doc
        filterEdit = nil
    }

    func cancelFilter() { filterEdit?.cancel(); filterEdit = nil }

    func invertPixels() throws {
        try edit("Invert") { doc in
            guard let index = doc.layers.firstIndex(where: { $0.id == activeLayerID }), let asset = doc.layers[index].asset else { throw Failure.noLayer }
            let layer = doc.layers[index]
            let image = try PixelInvert.run(.init(image: asset.image.pixels, isMask: false,
                pixelToDocument: BrushRaster.pixelToDocument(layer.transform, width: asset.image.width, height: asset.image.height),
                selection: doc.selection?.clip(canvas: doc.size)))
            doc.layers[index].asset = ImportedImage(image: RasterImage(image), thumbnail: RasterImage(PixelAdjust.thumbnail(of: image)), name: asset.name)
            doc.layers[index].shape = nil
        }
    }

    func undo() throws {
        try requireIdle()
        if let snapshot = history.undo() { document = snapshot.document; activeLayerID = snapshot.activeLayerID }
    }
    func redo() throws {
        try requireIdle()
        if let snapshot = history.redo() { document = snapshot.document; activeLayerID = snapshot.activeLayerID }
    }

    func render() throws -> PortableImage {
        guard var doc = document else { throw Failure.noDocument }
        if let stroke = brushStroke, let index = doc.layers.firstIndex(where: { $0.id == stroke.layer.id }) {
            let result = try stroke.paintSnapshot()
            if stroke.isMask { doc.layers[index].mask = doc.layers[index].mask?.replacing(result.asset) }
            else { doc.layers[index].asset = result.asset; doc.layers[index].transform = result.transform }
        }
        if let edit = filterEdit, let preview = edit.previewImage(for: edit.layerID),
           let index = doc.layers.firstIndex(where: { $0.id == edit.layerID }) {
            let image = RasterImage(preview)
            doc.layers[index].asset = ImportedImage(image: image, thumbnail: image, name: doc.layers[index].name)
            doc.layers[index].transform = edit.grownTransform ?? edit.transform
        }
        return try DocumentRenderer(doc).render()
    }
}
