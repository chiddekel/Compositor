import Foundation

/// Application state owned by the Swift core. The bridge serializes access to
/// each session; Qt owns presentation and receives immutable state/pixel copies.
final class EditorSession {
    private let coverageFactory: () -> BrushCoverageComputing
    init(coverageFactory: @escaping () -> BrushCoverageComputing = BrushCoverageBackends.cpu) {
        self.coverageFactory = coverageFactory
    }
    enum Failure: Error { case noDocument, noLayer, busy, invalidArgument, dependentLayer }
    private(set) var document: CanvasDocument?
    var selectedLayerIDs: Set<UUID> = []
    private(set) var activeLayerID: UUID? {
        didSet {
            if activeLayerID != oldValue { isMaskSelected = false }
            selectedLayerIDs = activeLayerID.map { [$0] } ?? []
        }
    }
    var collapsedGroupIDs: Set<UUID> = []
    let history = DocumentHistory()
    private var pendingShapeStyles: [UUID: LayerShapeStyle] = [:]
    private(set) var brushStroke: BrushStroke?
    private(set) var warpStroke: WarpStroke?
    private(set) var filterEdit: FilterEdit?
    private(set) var pixelClipboard: PixelClipboard?
    // Port of Compositor/Document/AdjustmentEditing.swift's state machine. Editing
    // an adjustment never replaces layer pixels: preview writes the edited
    // LayerAdjustment to layer metadata, and render() applies it live (the macOS
    // "source only for histogram/sampling" rule). The edit objects macOS holds
    // (LevelsEdit/HueSaturationEdit/@Observable) are SwiftUI-bound and replaced
    // here by the invalidated draft value the Qt dialog submits.
    private(set) var adjustmentEditingID: UUID?
    private(set) var adjustmentOriginal: LayerAdjustment?
    private var adjustmentDraft: LayerAdjustment?
    /// The pending interactive transform, if any. Dragging transform handles writes
    /// the draft here; `commitTransform` writes it to the model in one undo step.
    var transformEdit: TransformEdit?
    /// Option-drag duplicate in progress: the copy being moved and the source it came from
    /// (Backing storage — the public surface lives in SelectionTransform.swift).
    var transformDuplicateState: (copy: UUID, source: UUID)?
    var isMaskSelected = false
    /// The last raster command's failure, if any (macOS parity: `brushError` surfaces
    /// Distort/paint failures to the host as a dismissible message).
    var brushError: String?
    var activeLayer: ImageLayer? { document?.layers.first { $0.id == activeLayerID } }
    var selection: DocumentSelection? { document?.selection }

    func replaceCurrentDocument(_ document: CanvasDocument) {
        self.document = document
    }

    func storePixelClipboard(_ clipboard: PixelClipboard?) {
        pixelClipboard = clipboard
    }

    func performEdit(_ name: String, _ body: (inout CanvasDocument) throws -> Void) throws {
        try edit(name, body)
    }

    func setActiveLayer(_ id: UUID?) {
        activeLayerID = id
    }

    private func requireIdle() throws {
        guard brushStroke == nil, filterEdit == nil, warpStroke == nil, adjustmentEditingID == nil,
              transformEdit == nil else { throw Failure.busy }
    }

    // MARK: - Adjustment editing (port of Compositor/Document/AdjustmentEditing.swift)

    /// Creates a new adjustment layer and immediately begins editing it, matching
    /// the macOS `addAdjustment` (which also sets `adjustmentEditingID` so the
    /// sheet opens over the fresh layer).
    func addAdjustment(_ kind: AdjustmentKind) throws {
        guard canEditLayers, let doc = document, doc.layers.count < 10_000 else { throw Failure.noLayer }
        var layer = ImageLayer(name: kind.rawValue, blankSize: doc.size)
        var adjustment = LayerAdjustment(kind: kind)
        if kind == .gradientMap {
            adjustment.gradientMap = GradientMapSettings(shadows: AdjustmentColor(red: 0, green: 0, blue: 0),
                highlights: AdjustmentColor(red: 1, green: 1, blue: 1))
        }
        if kind == .grain { adjustment.grain.seed = .random(in: .min ... .max) }
        layer.adjustment = adjustment
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        var next = doc
        let index = next.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? next.layers.count
        next.layers.insert(layer, at: index)
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        beginEdit("New \(kind.rawValue) Adjustment")
        document = next
        activeLayerID = layer.id
        endEdit()
        adjustmentEditingID = layer.id
        adjustmentOriginal = adjustment
        adjustmentDraft = nil
    }

    /// Begins editing an existing adjustment layer. The adjustment metadata stays
    /// readable for render; only preview/commit change it. Mirrors the macOS
    /// gating (id, original nil, no concurrent filter edits).
    func beginAdjustmentEditing(_ id: UUID) throws {
        try requireIdle()
        guard adjustmentEditingID == nil, adjustmentOriginal == nil,
              let doc = document,
              let index = doc.layers.firstIndex(where: { $0.id == id }),
              doc.layers[index].adjustment != nil,
              !doc.layers[index].isGroup else { throw Failure.noLayer }
        adjustmentEditingID = id
        adjustmentOriginal = doc.layers[index].adjustment
        adjustmentDraft = nil
        beginEdit("Edit \(doc.layers[index].adjustment?.kind.rawValue ?? "Adjustment") Adjustment")
    }

    /// Live preview: validate against the original kind, then write the draft to
    /// layer metadata. Render applies it without touching layer pixels.
    @discardableResult
    func previewAdjustmentEditing(_ value: LayerAdjustment) throws -> Bool {
        guard let id = adjustmentEditingID, let original = adjustmentOriginal else { return false }
        guard value.isValid, value.kind == original.kind else { throw Failure.invalidArgument }
        try updateAdjustment(id, value: value)
        adjustmentDraft = value
        return true
    }

    /// OK persists the edited draft; Cancel (commit: false) restores the original.
    /// Both close the transaction opened by beginAdjustmentEditing.
    func finishAdjustmentEditing(commit: Bool) throws {
        guard let id = adjustmentEditingID, let original = adjustmentOriginal else { throw Failure.noLayer }
        try updateAdjustment(id, value: commit ? (adjustmentDraft ?? original) : original)
        endEdit()
        filterEdit = nil
        adjustmentDraft = nil
        adjustmentOriginal = nil
        adjustmentEditingID = nil
    }

    private func updateAdjustment(_ id: UUID, value: LayerAdjustment) throws {
        guard value.isValid, let doc = document, let index = doc.layers.firstIndex(where: { $0.id == id }) else {
            throw Failure.invalidArgument
        }
        var next = doc
        next.layers[index].adjustment = value
        document = next
    }

    func createDocument(width: Int, height: Int, emptyLayer: Bool = false) throws {
        try requireIdle()
        guard (1...30_000).contains(width), (1...30_000).contains(height), width * height <= 100_000_000 else {
            throw ProjectError.tooLarge
        }
        var doc = CanvasDocument(width: width, height: height)
        let layer = emptyLayer ? ImageLayer(name: "Layer 1", blankSize: doc.size) : nil
        if let layer { doc.layers = [layer] }
        document = doc
        activeLayerID = layer?.id
        pendingShapeStyles.removeAll()
        history.reset()
    }

    func resizeCanvas(width: Int, height: Int, anchor: Int = 4, fill: CanvasExtensionColor? = nil) throws {
        try requireIdle()
        guard let document else { throw Failure.noDocument }
        guard width > 0, height > 0, width <= 30_000, height <= 30_000,
              width * height <= 100_000_000 else { throw ProjectError.tooLarge }
        let options = CanvasSizeOptions(width: width, height: height, anchor: anchor, fill: fill)
        let snapshot = try ProjectSnapshot(document: document, activeLayerID: activeLayerID)
        let resized = try CanvasResizer.resizeSnapshot(snapshot, to: options)
        guard width != document.width || height != document.height else { return }
        var next = try resized.document()
        let offset = options.offset(fromWidth: document.width, height: document.height)
        if let selection = document.selection {
            next.selection = DocumentSelection(path: selection.path.applying(CGAffineTransform(translationX: offset.x, y: offset.y)),
                                                antialiased: selection.antialiased)
        }
        history.begin("Canvas Size", document: document, selection: activeLayerID)
        replaceCurrentDocument(next)
        history.end(document: next, selection: activeLayerID)
    }

    func cropCanvas(to rect: CGRect) throws {
        try requireIdle()
        guard let document, CropGeometry.valid(rect), rect.maxX <= CGFloat(document.width), rect.maxY <= CGFloat(document.height),
              rect.minX >= 0, rect.minY >= 0 else { throw ProjectError.invalid }
        let offset = CGPoint(x: -rect.minX, y: -rect.minY)
        var next = CanvasDocument(id: document.id, width: Int(rect.width), height: Int(rect.height),
                                  layers: document.layers, resolution: document.resolution)
        for index in next.layers.indices {
            next.layers[index].transform.origin.x += offset.x
            next.layers[index].transform.origin.y += offset.y
            if let placement = next.layers[index].mask?.placement {
                var moved = placement
                moved.origin.x += offset.x
                moved.origin.y += offset.y
                next.layers[index].mask?.placement = moved
            }
        }
        history.begin("Crop", document: self.document, selection: activeLayerID)
        replaceCurrentDocument(next)
        history.end(document: next, selection: activeLayerID)
    }

    func install(_ snapshot: ProjectSnapshot) throws {
        try requireIdle()
        let loaded = try snapshot.document()
        guard loaded.width * loaded.height <= 100_000_000 else { throw ProjectError.tooLarge }
        document = loaded
        activeLayerID = snapshot.manifest.activeLayerID
        pendingShapeStyles.removeAll()
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

    /// Reconstructs document structure from a ProjectManifest (without images/masks).
    /// Images/masks must be loaded separately via importImage/import_rgba.
    func importManifest(_ manifest: ProjectManifest) throws {
        try requireIdle()
        try ProjectStore.validate(manifest)
        guard manifest.width * manifest.height <= 100_000_000 else { throw ProjectError.tooLarge }
        var doc = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height)
        doc.resolution = manifest.resolution ?? 72
        doc.layers = manifest.layers.map { record -> ImageLayer in
            ImageLayer(id: record.id, asset: nil, name: record.name,
                       isVisible: record.isVisible, transform: record.transform,
                       parentID: record.parentID, isGroup: record.isGroup == true,
                       opacity: record.opacity ?? 1, blendMode: record.blendMode ?? .normal,
                       mask: record.maskFile == nil ? nil : LayerMask(asset: LayerMask.solid(revealing: true).asset,
                           isEnabled: record.maskEnabled ?? true, placement: record.maskPlacement,
                           isLinked: record.maskLinked ?? true), maskSourceID: record.maskSourceID,
                       adjustment: record.adjustment, shape: nil)
        }
        document = doc
        activeLayerID = manifest.activeLayerID
        pendingShapeStyles = Dictionary(uniqueKeysWithValues: manifest.layers.compactMap { record in
            record.shape.map { (record.id, $0) }
        })
        history.reset()
    }

    func layerAsset(id: UUID, mask: Bool) throws -> PortableImage {
        guard let layer = document?.layers.first(where: { $0.id == id }) else { throw Failure.noLayer }
        if mask {
            guard let asset = layer.mask?.asset.image.pixels else { throw ProjectError.missingImage }
            return asset
        }
        guard let asset = layer.asset?.image.pixels else { throw ProjectError.missingImage }
        return asset
    }

    func installLayerAsset(_ pixels: PortableImage, id: UUID, mask: Bool) throws {
        try requireIdle()
        guard var doc = document, let index = doc.layers.firstIndex(where: { $0.id == id }) else {
            throw Failure.noLayer
        }
        if mask {
            let asset = try LayerMask.asset(from: pixels)
            guard doc.layers[index].mask != nil else { throw ProjectError.invalid }
            doc.layers[index].mask = doc.layers[index].mask?.replacing(asset)
        } else {
            guard pixels.kind == .rgba, pixels.width > 0, pixels.height > 0 else { throw ProjectError.invalid }
            let image = RasterImage(pixels)
            doc.layers[index].asset = ImportedImage(image: image, thumbnail: RasterImage(PixelAdjust.thumbnail(of: pixels)), name: doc.layers[index].name)
            doc.layers[index].shape = LayerShape.loaded(pendingShapeStyles[id] ?? doc.layers[index].shape?.style, image: image)
            pendingShapeStyles.removeValue(forKey: id)
        }
        document = doc
        history.reset()
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

    func selectLayer(_ id: UUID?) {
        guard brushStroke == nil, filterEdit == nil else { return }
        if id != activeLayerID { commitTransform(); resolveGradient() }
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

    func moveLayer(dx: CGFloat, dy: CGFloat) throws {
        try requireIdle()
        guard let layer = activeLayer else { throw Failure.noLayer }
        var t = layer.transform
        t.origin.x += dx
        t.origin.y += dy
        try updateLayer(transform: t)
    }

    func beginBrush(at point: CGPoint, settings: BrushSettings, mask: Bool = false,
                    cloneOffset: CGSize? = nil, sampleAllLayers: Bool = false) throws {
        try requireIdle()
        guard let doc = document, let layer = activeLayer, layer.isVisible, !layer.isGroup, layer.adjustment == nil,
              !mask || layer.mask != nil else { throw Failure.noLayer }
        guard [point.x, point.y, settings.red, settings.green, settings.blue].allSatisfy(\.isFinite),
              [settings.red, settings.green, settings.blue].allSatisfy({ (0...1).contains($0) }) else { throw Failure.invalidArgument }
        let stroke = try BrushStroke(layer: layer, mask: mask, settings: settings, canvas: doc.size, coverageComputer: coverageFactory())
        stroke.selectionClip = doc.selection?.clip(canvas: doc.size)
        if let offset = cloneOffset {
            let sampleImage: PortableImage? = sampleAllLayers
                ? (try? DocumentRenderer(doc).render())
                : (layer.asset?.image.pixels)
            if let sampleImage {
                stroke.clone = (image: sampleImage, offset: offset)
            }
        }
        try stroke.append(point)
        brushStroke = stroke
    }

    func continueBrush(at point: CGPoint) throws {
        guard let stroke = brushStroke else { throw Failure.busy }
        do { try stroke.append(point) }
        catch { brushStroke = nil; throw error }
    }

    func cancelBrush() { brushStroke = nil }

    func beginWarp(at point: CGPoint, mode: BlurToolMode, settings: BrushSettings) throws {
        try requireIdle()
        guard let doc = document, let layer = activeLayer, !layer.isGroup, let asset = layer.asset else { throw Failure.noLayer }
        let stroke = try WarpStroke(layer: layer, image: asset.image, transform: layer.transform,
                                    canvas: doc.size, mode: mode, settings: settings)
        stroke.append(point)
        warpStroke = stroke
    }

    func continueWarp(at point: CGPoint) throws {
        guard let warpStroke else { throw Failure.busy }
        warpStroke.append(point)
    }

    func cancelWarp() { warpStroke = nil }

    func finishWarp() throws {
        guard let warp = warpStroke, var doc = document,
              let index = doc.layers.firstIndex(where: { $0.id == warp.layer.id }),
              let asset = doc.layers[index].asset else { throw Failure.busy }
        defer { warpStroke = nil }
        guard !warp.points.isEmpty else { return }
        let bounds = CGRect(x: floor(warp.layer.transform.origin.x), y: floor(warp.layer.transform.origin.y),
                            width: CGFloat(asset.image.width), height: CGFloat(asset.image.height))
        guard let cropped = warp.image.cropping(to: bounds) else { return }
        let raster = RasterImage(cropped)
        doc.layers[index].asset = ImportedImage(image: raster, thumbnail: RasterImage(PixelAdjust.thumbnail(of: cropped)), name: asset.name)
        doc.layers[index].transform.origin = bounds.origin
        doc.layers[index].transform.size = CGSize(width: cropped.width, height: cropped.height)
        history.begin(warp.mode.rawValue, document: document, selection: activeLayerID)
        document = doc
        history.end(document: doc, selection: activeLayerID)
    }

    func finishBrush() throws {
        guard let stroke = brushStroke, var doc = document,
              let index = doc.layers.firstIndex(where: { $0.id == stroke.layer.id }) else { throw Failure.busy }
        defer { brushStroke = nil }
        try stroke.flush()
        if stroke.settings.healing { try stroke.heal() }
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
        let actionName = stroke.isMask ? "Paint Mask" : stroke.settings.erasing ? "Erase" : stroke.settings.healing ? "Spot Healing" : stroke.clone != nil ? "Clone Stamp" : "Brush Stroke"
        history.begin(actionName, document: document, selection: activeLayerID)
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
        if let warpStroke { return warpStroke.image }
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
        if let edit = transformEdit, edit.corners == nil {
            for index in doc.layers.indices {
                if edit.mask {
                    guard edit.layerID == doc.layers[index].id, doc.layers[index].mask != nil else { continue }
                    let placed = doc.layers[index].transform
                    doc.layers[index].mask?.placement = edit.draft.samePlacement(as: placed) ? nil : edit.draft
                    continue
                }
                let layer = doc.layers[index]
                guard let pending = pendingTransform(for: layer), pending != layer.transform else { continue }
                if let mask = doc.layers[index].mask {
                    doc.layers[index].mask?.placement = mask.placement(movingLayer: layer.transform, to: pending)
                }
                doc.layers[index].transform = pending
            }
        }
        return try DocumentRenderer(doc).render()
    }

    // MARK: - Grouping & selection (port of Compositor/Document/LayerGroups.swift's
    // EditorSession extensions; file-map "Keep/adapt" tier). Pure hierarchy/selection
    // logic — no pixels, no Apple API. The macOS original stays the source of truth;
    // selection state (`selectedLayerIDs`) is restored on undo/redo via the
    // `activeLayerID` didSet (history stores only `activeLayerID`, as on macOS).

    /// True when layers can be added/removed/grouped. Faithful subset of the macOS
    /// gate (which also blocks on UI modal state); the core has no UI modal state.
    var canEditLayers: Bool { document != nil && brushStroke == nil && filterEdit == nil && adjustmentEditingID == nil }

    /// Nestable transaction boundary matching macOS `beginEdit`/`endEdit`, for the
    /// grouping methods that set several fields between the two calls. `edit(_:_:)`
    /// above wraps the same pair for the throwing single-body edits.
    func beginEdit(_ name: String) { history.begin(name, document: document, selection: activeLayerID) }
    func endEdit() { history.end(document: document, selection: activeLayerID) }

    /// No-ops in the headless core: resolveGradient cancels a pending gradient —
    /// a UI-layer construct not present here. Kept as a hook so selection changes
    /// match the macOS call sequence.
    func resolveGradient() {}

    var transformsAsGroup: Bool { selectedLayerIDs.count > 1 || (selectedLayerIDs.count == 1 && activeLayer?.isGroup == true) }
    var groupTransformMembers: [ImageLayer] {
        guard transformsAsGroup, let document else { return [] }
        let parents = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0.parentID) })
        let visible = document.effectiveVisibleIDs
        return document.layers.filter { layer in
            guard layer.asset != nil, !layer.isGroup, visible.contains(layer.id) else { return false }
            var current: UUID? = layer.id
            for _ in 0..<64 {
                guard let id = current else { return false }
                if selectedLayerIDs.contains(id) { return true }
                current = parents[id] ?? nil
            }
            return false
        }
    }
    var canTransform: Bool {
        guard canEditLayers else { return false }
        if transformsAsGroup { return !groupTransformMembers.isEmpty }
        return activeLayer?.asset != nil && activeLayer?.isGroup == false
            && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
    }

    func selectLayers(_ ids: Set<UUID>, primary: UUID?) {
        guard brushStroke == nil else { return }
        let valid = ids.intersection(Set(document?.layers.map(\.id) ?? []))
        if valid != selectedLayerIDs { commitTransform(); resolveGradient() }
        activeLayerID = primary.flatMap { valid.contains($0) ? $0 : nil } ?? valid.first
        selectedLayerIDs = valid
    }

    func descendantIDs(of id: UUID) -> Set<UUID> {
        let children = Dictionary(grouping: document?.layers ?? [], by: \.parentID)
        var result = Set<UUID>(), pending = [id]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where result.insert(child.id).inserted { pending.append(child.id) }
        }
        return result
    }

    var layerRows: [LayerHierarchy.Entry] {
        LayerHierarchy.entries(document?.layers.map(\.hierarchyRecord) ?? [], topFirst: true, collapsed: collapsedGroupIDs)
    }

    func groupSelectedLayers() {
        guard canEditLayers, let doc = document, doc.layers.count < 10_000 else { return }
        let byID = Dictionary(uniqueKeysWithValues: doc.layers.map { ($0.id, $0) })
        let selected = selectedLayerIDs.intersection(Set(byID.keys))
        func ancestors(_ id: UUID) -> [UUID?] {
            var result: [UUID?] = []
            var parent = byID[id]?.parentID
            while let id = parent { result.append(id); parent = byID[id]?.parentID }
            result.append(nil)
            return result
        }
        // A selected folder carries its subtree; selected descendants must not be pulled out of it.
        let rootIDs = selected.filter { id in !ancestors(id).contains { $0.map(selected.contains) ?? false } }
        let ordered = doc.hierarchyEntries.map { $0.layer.id }.filter(rootIDs.contains)
        let parent: UUID? = ordered.first.flatMap { first in
            ancestors(first).first { candidate in ordered.allSatisfy { ancestors($0).contains(candidate) } } ?? nil
        }
        let names = Set(doc.layers.map(\.name))
        var number = 1
        while names.contains("Folder \(number)") { number += 1 }
        var group = ImageLayer(name: "Folder \(number)", blankSize: doc.size)
        group.isGroup = true
        group.parentID = parent
        // Put the wrapper at the topmost selected branch in the common parent.
        let branches = ordered.map { id -> UUID in
            var branch = id
            while let next = byID[branch]?.parentID, next != parent { branch = next }
            return branch
        }
        let highest = doc.layers.lastIndex { branches.contains($0.id) }
        let insertion = highest.map { doc.layers.prefix($0 + 1).filter { !rootIDs.contains($0.id) }.count }
            ?? doc.layers.count
        var layers = doc.layers.filter { !rootIDs.contains($0.id) }
        layers.insert(group, at: min(insertion, layers.count))
        for id in ordered {
            guard var child = byID[id] else { continue }
            child.parentID = group.id
            layers.append(child)
        }
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return }
        beginEdit("Group Layers")
        var next = doc
        next.layers = layers
        document = next
        activeLayerID = group.id
        if let parent { collapsedGroupIDs.remove(parent) }
        endEdit()
    }

    func addGroup() {
        guard canEditLayers, let doc = document, doc.layers.count < 10_000 else { return }
        let names = Set(doc.layers.map(\.name))
        var number = 1
        while names.contains("Folder \(number)") { number += 1 }
        var group = ImageLayer(name: "Folder \(number)", blankSize: doc.size)
        group.isGroup = true
        group.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        var layers = doc.layers
        let insertion = layers.firstIndex(where: { $0.id == activeLayerID }).map { $0 + 1 } ?? layers.count
        layers.insert(group, at: insertion)
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return }
        beginEdit("New Folder")
        var next = doc
        next.layers = layers
        document = next
        activeLayerID = group.id
        if let parent = group.parentID { collapsedGroupIDs.remove(parent) }
        endEdit()
    }

    func removeBackground(settings: FilterSettings = FilterSettings()) throws {
        guard canEditLayers, let doc = document,
              let index = doc.layers.firstIndex(where: { $0.id == activeLayerID }),
              !doc.layers[index].isGroup, let layerAsset = doc.layers[index].asset else {
            throw Failure.noLayer
        }
        let layer = doc.layers[index]
        let guide = layerAsset.image.pixels
        let maskBuffer = try SubjectRemoval.subjectMask(
            image: guide,
            under: layer.mask?.enabledImage?.pixels,
            selection: doc.selection?.clip(canvas: doc.size),
            pixelToDocument: BrushRaster.pixelToDocument(layer.transform, width: guide.width, height: guide.height),
            settings: settings,
            requireModel: false
        )
        let maskImage = PortableImage(maskBuffer)
        let maskAsset = try LayerMask.asset(from: maskImage)
        beginEdit("Remove Background")
        var next = doc
        next.layers[index].mask = LayerMask(asset: maskAsset)
        replaceCurrentDocument(next)
        endEdit()
    }
}
