import Foundation

/// A filter panel's transaction, independent of its Qt controls and worker queue.
/// Preparation and rendering never mutate the document. Only commit writes a
/// result, after checking the original document, layer, pixels, and placement.
final class FilterEdit {
    struct PreviewRequest {
        fileprivate let editID: UUID
        fileprivate let revision: UInt64
        let job: FilterJob
    }

    enum Failure: Error { case closed, staleTarget }

    let kind: FilterKind
    let documentID: UUID
    let layerID: UUID
    let original: ImportedImage
    let transform: LayerTransform
    let selection: SelectionClip?
    let seed: UInt32
    private let id = UUID()
    private var revision: UInt64 = 0
    private(set) var isClosed = false
    private(set) var settings: FilterSettings
    private(set) var grownImage: PortableImage?
    private(set) var grownTransform: LayerTransform?
    private(set) var grownMargin: CGFloat = 0
    private(set) var preparedPreview: PortableImage?
    var preview = true
    static let previewLimit = 2048

    init(kind: FilterKind, documentID: UUID, layer: ImageLayer, selection: SelectionClip?,
         settings: FilterSettings, growingTo area: CGRect? = nil,
         seed: UInt32 = UInt32.random(in: .min ... .max)) throws {
        guard let asset = layer.asset, !layer.isGroup, layer.adjustment == nil,
              asset.image.pixels.kind == .rgba, layer.transform.isValid else { throw ProjectError.invalid }
        self.kind = kind
        self.documentID = documentID
        self.layerID = layer.id
        self.original = asset
        self.transform = layer.transform
        self.selection = selection
        self.settings = settings.normalized
        self.seed = seed
        if let area {
            guard [area.minX, area.minY, area.width, area.height].allSatisfy(\.isFinite) else { throw ProjectError.invalid }
            let inverse = BrushRaster.pixelToDocument(transform, width: asset.image.width, height: asset.image.height).inverted()
            try grow(to: area.applying(inverse).integral)
        }
        try growForBlur(self.settings)
    }

    static func blurMargin(_ kind: FilterKind, _ settings: FilterSettings) -> CGFloat {
        switch kind {
        case .gaussianBlur: return settings.radius * 3 + 2
        case .motionBlur: return settings.distance / 2 + 2
        default: return 0
        }
    }

    func update(_ settings: FilterSettings) throws {
        guard !isClosed else { throw Failure.closed }
        let normalized = settings.normalized
        // A failed growth leaves both the previous settings and preview valid.
        try growForBlur(normalized)
        self.settings = normalized
        revision &+= 1
        preparedPreview = nil
    }

    private func growForBlur(_ settings: FilterSettings) throws {
        let margin = Self.blurMargin(kind, settings).rounded(.up)
        guard margin > grownMargin else { return }
        try grow(to: CGRect(x: 0, y: 0, width: original.image.width, height: original.image.height)
            .insetBy(dx: -margin, dy: -margin))
    }

    private func grow(to extent: CGRect) throws {
        let bounds = CGRect(x: 0, y: 0, width: original.image.width, height: original.image.height)
        let target = bounds.union(extent).integral
        guard target != bounds else { return }
        guard target.width <= 30_000, target.height <= 30_000,
              target.width * target.height <= 100_000_000 else { throw ProjectError.tooLarge }
        let w = Int(target.width), h = Int(target.height)
        let offsetX = Int(-target.minX), offsetY = Int(-target.minY)
        let source = original.image.pixels
        var pixels = PixelBuffer(width: w, height: h)
        for y in 0..<source.height {
            let from = y * source.bytesPerRow
            let to = ((y + offsetY) * w + offsetX) * 4
            pixels.bytes.replaceSubrange(to..<(to + source.width * 4),
                                         with: source.bytes[from..<(from + source.width * 4)])
        }
        let mapping = BrushRaster.pixelToDocument(transform, width: source.width, height: source.height)
        var expanded = transform
        expanded.size = CGSize(width: target.width * transform.size.width / bounds.width,
                               height: target.height * transform.size.height / bounds.height)
        let center = CGPoint(x: target.midX, y: target.midY).applying(mapping)
        expanded.origin = CGPoint(x: center.x - expanded.size.width / 2, y: center.y - expanded.size.height / 2)
        grownImage = PortableImage(pixels)
        grownTransform = expanded
        grownMargin = min(-target.minX, -target.minY, target.maxX - bounds.maxX, target.maxY - bounds.maxY)
    }

    func makePreviewRequest() throws -> PreviewRequest {
        guard !isClosed else { throw Failure.closed }
        let source = grownImage ?? original.image.pixels
        let placed = grownTransform ?? transform
        // Full-size noise/grain keeps its spatial frequency when previewing.
        let fullSize: Set<FilterKind> = [.addNoise, .grain, .contentAwareFill, .removeBackground]
        let small = fullSize.contains(kind) || max(source.width, source.height) <= Self.previewLimit
            ? source : RasterSample.thumbnail(source, maxSide: Self.previewLimit)
        let job = FilterJob(kind: kind, image: small, settings: settings,
            scale: CGFloat(small.width) / CGFloat(source.width), selection: selection,
            mapping: BrushRaster.pixelToDocument(placed, width: small.width, height: small.height), seed: seed)
        return PreviewRequest(editID: id, revision: revision, job: job)
    }

    /// Call on the owning thread after a worker finishes. Older settings and
    /// callbacks from a dismissed or different panel cannot replace this preview.
    @discardableResult
    func acceptPreview(_ image: PortableImage, for request: PreviewRequest) -> Bool {
        guard !isClosed, request.editID == id, request.revision == revision,
              image.kind == .rgba, image.width == request.job.image.width,
              image.height == request.job.image.height else { return false }
        preparedPreview = image
        return true
    }

    func previewImage(for layerID: UUID) -> PortableImage? {
        !isClosed && preview && self.layerID == layerID ? preparedPreview : nil
    }

    func cancel() {
        isClosed = true
        preparedPreview = nil
        grownImage = nil
    }

    /// Returns whether pixels changed. No-op, failure, and stale-target paths
    /// preserve undo/redo history. Call on the document's owning thread.
    @discardableResult
    func commit(document: inout CanvasDocument, activeLayerID: UUID?, history: DocumentHistory) throws -> Bool {
        guard !isClosed else { throw Failure.closed }
        guard document.id == documentID,
              let index = document.layers.firstIndex(where: { $0.id == layerID }),
              document.layers[index].asset?.image === original.image,
              document.layers[index].transform == transform else { throw Failure.staleTarget }
        if (kind == .lensCorrection && settings.distortion == 0)
            || (kind == .exposure && settings.exposure == ExposureSettings())
            || (kind == .grain && settings.grain.amount == 0) {
            cancel()
            return false
        }
        let source = grownImage ?? original.image.pixels
        var placed = grownTransform ?? transform
        let job = FilterJob(kind: kind, image: source, settings: settings, scale: 1, selection: selection,
            mapping: BrushRaster.pixelToDocument(placed, width: source.width, height: source.height), seed: seed)
        var result = try PixelFilter.run(job)
        if kind == .gaussianBlur || kind == .motionBlur {
            let trimmed = try PixelFilter.trimmed(result, placed: placed)
            result = trimmed.image
            placed = trimmed.transform
        }
        if result == original.image.pixels, placed == transform {
            cancel()
            return false
        }
        var layer = document.layers[index]
        if kind == .removeBackground {
            let maskBuffer = try SubjectRemoval.subjectMask(
                image: original.image.pixels,
                under: layer.mask?.enabledImage?.pixels,
                selection: selection,
                pixelToDocument: BrushRaster.pixelToDocument(placed, width: source.width, height: source.height),
                settings: settings,
                requireModel: true
            )
            let maskAsset = try LayerMask.asset(from: PortableImage(maskBuffer))
            layer.mask = LayerMask(asset: maskAsset)
            history.begin(kind.rawValue, document: document, selection: activeLayerID)
            document.layers[index] = layer
            history.end(document: document, selection: activeLayerID)
            cancel()
            return true
        }
        if let owned = layer.mask, owned.placement == nil,
           owned.asset.image.width > 1 || owned.asset.image.height > 1, placed != transform {
            // Carry onto the FINAL trimmed grid, including a disabled mask so
            // re-enabling it after the edit restores the same document coverage.
            var enabled = owned
            enabled.isEnabled = true
            guard let carried = enabled.clipImage(placement: transform, over: placed,
                width: result.width, height: result.height) else { throw ProjectError.invalid }
            layer.mask = owned.replacing(try LayerMask.asset(from: carried.pixels))
        }
        layer.asset = ImportedImage(image: RasterImage(result),
            thumbnail: RasterImage(PixelAdjust.thumbnail(of: result)), name: kind.rawValue)
        layer.transform = placed
        layer.shape = nil
        history.begin(kind.rawValue, document: document, selection: activeLayerID)
        document.layers[index] = layer
        history.end(document: document, selection: activeLayerID)
        cancel()
        return true
    }
}
