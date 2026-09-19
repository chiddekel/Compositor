// Portable port of Compositor/Document/FloatingSelection.swift and the
// Cmd-T-with-a-selection + Option-drag-duplicate paths of
// Compositor/Document/EditorSession.swift (`beginSelectionTransform`,
// `floatingSelectionTransform`, `mergeFloatingTransform`,
// `cancelFloatingTransform`, `FloatingMerge`, `renderSelectedPixels`,
// `beginDuplicateTransform`, and the duplicate clearing in commit/cancel).
// File-map tier: "Keep logic; replace Apple operations".
//
// The raster is the canonical PortableImage/PixelBuffer/MaskBuffer substrate:
// macOS renders with CGContext (clip-to-mask + CGImage draw); here the selection
// coverage already exists as a MaskBuffer (`rasterized(in:)`), the lifted layer
// pixels are drawn with LayerRenderer.draw/drawCoverage, and the coverage
// multiplies the buffer's alpha channel (premultiplied scaling), giving the same
// soft edges as the CG clip.
//
// Parity notes vs. the macOS original:
//   - macOS does not keep its own layer-blend mode when merging (the floating
//     layer composites with normal blend); this port matches it exactly.
//   - A *distorted* selection keeps `moved = nil` (the forward-looking path
//     leaves the selection on the document): the macOS `DistortWarp.mapPath`
//     (CGPath perspective mapping) is still deferred. The non-distorted move
//     carries the selection exactly, via `PortablePath.applying`.
//   - The macOS `tool = .move` switch during `beginSelectionTransform` and the
//     `NSSound.beep()` guard are UI-layer and omitted; the headless core holds
//     no tool state.
//   - `renderSelectedPixels(from:mask:)` uses the mask's own placement (its
//     `displayedMaskPlacement` preview path is canvas-tier) and keeps the
//     mask-case background fill math verbatim.
//
// SOLID: the value transforms keep their contracts; Apple graphics (CGImage/
// CGContext/CGPath) are exchanged. The macOS originals stay the source of truth.

import Foundation

extension EditorSession {
    /// macOS `canEditPixels` also blocks on UI modal state; the headless core has none.
    var canEditPixels: Bool { canEditLayers }

    var canTransformSelection: Bool {
        guard transformEdit == nil, canEditPixels, !isMaskSelected, let selection,
              !selection.isEmpty, activeLayer?.asset != nil else { return false }
        return true
    }

    /// Cmd-T: transforms the selected pixels when there is a selection, else the layer.
    func transformCommand() {
        if canTransformSelection { beginSelectionTransform() }
        else { beginTransform() }
    }

    func beginSelectionTransform() {
        guard canTransformSelection, let document, let source = activeLayer else { return }
        let lifted: (image: RasterImage, region: CGRect)
        do {
            guard let pixels = try renderSelectedPixels(from: source, mask: false) else { return }
            lifted = pixels
        } catch { brushError = error.localizedDescription; return }
        let before = document
        let beforeActive = activeLayerID
        // Outer edit: closed by commitTransform (merge) or cancelTransform (restore).
        beginEdit("Transform Selection")
        clearSelectedPixels()
        var next = self.document!
        guard next.layers.firstIndex(where: { $0.id == source.id }) != nil else {
            replaceCurrentDocument(before)
            endEdit()
            return
        }
        var floating = ImageLayer(asset: ImportedImage(image: lifted.image,
            thumbnail: RasterImage(PixelAdjust.thumbnail(of: lifted.image.pixels)), name: "Floating Selection"),
            origin: lifted.region.origin)
        floating.name = "Floating Selection"
        floating.parentID = source.parentID
        floating.opacity = source.opacity
        floating.blendMode = source.blendMode
        next.layers.insert(floating, at: next.layers.firstIndex(where: { $0.id == source.id })! + 1)
        replaceCurrentDocument(next)
        setActiveLayer(floating.id)
        transformEdit = TransformEdit(layerID: floating.id, draft: floating.transform, persistent: true,
            floating: FloatingTransform(sourceID: source.id, before: before, beforeActive: beforeActive,
                                        original: floating.transform, pixelSize: lifted.region.size))
    }

    /// Maps the original selection to where the floating pixels are now.
    func floatingSelectionTransform(_ edit: TransformEdit) -> CGAffineTransform? {
        guard let floating = edit.floating else { return nil }
        let width = Int(floating.pixelSize.width), height = Int(floating.pixelSize.height)
        return BrushRaster.pixelToDocument(floating.original, width: width, height: height).inverted()
            .concatenating(BrushRaster.pixelToDocument(edit.draft, width: width, height: height))
    }

    /// Composites the transformed pixels back into their layer, moves the selection with
    /// them, and closes the undo step. Synchronous so tool/layer switches and Save can call it.
    func mergeFloatingTransform(_ edit: TransformEdit, _ floating: FloatingTransform) {
        defer { endEdit() }
        do {
            guard edit.draft.isValid, let layers = document?.layers,
                  let pixels = layers.first(where: { $0.id == edit.layerID })?.asset?.image,
                  let source = layers.first(where: { $0.id == floating.sourceID }) else { throw ProjectError.invalid }
            // A distorted selection is warped into its new shape first, then merged like any other.
            let placed: (image: RasterImage, transform: LayerTransform)
            if let corners = edit.corners {
                let warped = try DistortWarp.warpTrimmed(pixels, transform: edit.draft, corners: corners)
                placed = (warped.image, warped.transform)
            } else {
                placed = (pixels, edit.draft)
            }
            let merged = try FloatingMerge.merge(placed.image, transform: placed.transform, into: source)
            // The non-distortion move carries the selection with the pixels; a distorted
            // one would need `DistortWarp.mapPath` (CGPath perspective mapping) — deferred.
            let moved: DocumentSelection?
            if edit.corners == nil {
                moved = floatingSelectionTransform(edit).flatMap { transform in
                    guard let selection else { return nil }
                    return DocumentSelection(path: selection.path.applying(transform), antialiased: selection.antialiased)
                }
            } else {
                moved = nil
            }
            var next = document!
            next.layers.removeAll { $0.id == edit.layerID }
            guard let index = next.layers.firstIndex(where: { $0.id == source.id }) else { throw ProjectError.invalid }
            next.layers[index] = ImageLayer(id: source.id, asset: merged.asset, name: source.name,
                isVisible: source.isVisible, transform: merged.transform, parentID: source.parentID, isGroup: false,
                opacity: source.opacity, blendMode: source.blendMode, mask: merged.mask, maskSourceID: source.maskSourceID)
            next.selection = moved
            replaceCurrentDocument(next)
            setActiveLayer(source.id)
        } catch {
            replaceCurrentDocument(floating.before)
            setActiveLayer(floating.beforeActive)
            brushError = error.localizedDescription
        }
    }

    func cancelFloatingTransform(_ floating: FloatingTransform) {
        replaceCurrentDocument(floating.before)
        setActiveLayer(floating.beforeActive)
        endEdit()
    }

    /// Pixels of just `layer` inside the selection, on the region's own grid. The
    /// region comes from `selectionCopyRegion`; `mask` renders a layer mask's
    /// coverage instead, with the mask's border tone filling its uncovered area.
    func renderSelectedPixels(from layer: ImageLayer, mask: Bool) throws -> (image: RasterImage, region: CGRect)? {
        guard let document else { return nil }
        let clip = document.selection?.clip(canvas: document.size)
        if clip != nil, clip?.coverage == nil { return nil }
        guard let region = selectionCopyRegion() else { return nil }
        let width = Int(region.width), height = Int(region.height)
        guard width > 0, height > 0, width * height <= 100_000_000 else { return nil }
        let shift = CGPoint(x: -region.minX, y: -region.minY)
        var buffer = PixelBuffer(width: width, height: height)
        if mask, let owned = layer.mask {
            let placement = owned.placement
            let tone: CGFloat = placement == nil ? 0 : LayerMask.background(of: owned.asset.thumbnail)
            var coverage = MaskBuffer(width: width, height: height)
            LayerRenderer.drawCoverage(owned.asset.image, transform: shifted(owned.placement ?? layer.transform, by: shift),
                                       into: &coverage)
            for y in 0..<height {
                for x in 0..<width {
                    let cov = UInt8(255 * tone + CGFloat(coverage[x, y]) * (1 - tone))
                    buffer[x, y] = (cov, cov, cov, 255)
                }
            }
        } else if !mask, let image = layer.asset?.image {
            let placed = shifted(displayedTransform(for: layer), by: shift)
            LayerRenderer.draw(image, transform: placed, center: placed.center, into: &buffer)
        } else { return nil }
        // The selection clip's soft edges scale the premultiplied alpha (and RGB with
        // it — a CG clip multiplies the alpha channel the same way). The coverage
        // grid is indexed over the clip rect, which hugs the selection one pixel
        // wider than the lifted region; index it at the matching document offset.
        if let coverage = clip?.coverage, let clipRect = clip?.rect {
            let ox = Int(region.minX - clipRect.minX), oy = Int(region.minY - clipRect.minY)
            for y in 0..<height {
                for x in 0..<width {
                    let cx = min(coverage.width - 1, max(0, x + ox)), cy = min(coverage.height - 1, max(0, y + oy))
                    let factor = Float(coverage[cx, cy]) / 255
                    let p = buffer[x, y]
                    buffer[x, y] = (scale(p.0, factor), scale(p.1, factor), scale(p.2, factor), scale(p.3, factor))
                }
            }
        }
        return (RasterImage(PortableImage(buffer)), region)
    }

    /// Option-drag duplicates a single layer; several selected, or a folder, just move.
    func beginDuplicateTransform() {
        guard transformDuplicate == nil, !transformsAsGroup, let source = activeLayerID else { return }
        commitTransform()
        guard canTransform else { return }
        beginEdit("Duplicate Layer")
        duplicateActiveLayer()
        guard let copy = activeLayerID, copy != source else { endEdit(); return }
        transformDuplicate = (copy, source)
        beginTransform(persistent: false)
    }

    /// The transform under the pending duplicate drag: the copy being moved, the source it came from.
    var transformDuplicate: (copy: UUID, source: UUID)? {
        get { transformDuplicateState }
        set { transformDuplicateState = newValue }
    }
}

private func shifted(_ transform: LayerTransform, by point: CGPoint) -> LayerTransform {
    var result = transform
    result.origin.x += point.x
    result.origin.y += point.y
    return result
}

private func scale(_ v: UInt8, _ factor: Float) -> UInt8 {
    UInt8(min(255, max(0, Float(v) * factor)))
}

nonisolated enum FloatingMerge {
    /// Draws the floating pixels (with their transform) onto the source layer's own pixel
    /// grid, growing the layer where they now extend past it. A mask grows with it, revealing
    /// the new area.
    static func merge(_ pixels: RasterImage, transform: LayerTransform, into source: ImageLayer)
        throws -> (asset: ImportedImage, transform: LayerTransform, mask: LayerMask?) {
        guard let sourceImage = source.asset?.image else { throw ProjectError.invalid }
        let width = sourceImage.pixels.width, height = sourceImage.pixels.height
        let toDocument = BrushRaster.pixelToDocument(source.transform, width: width, height: height)
        let toPixels = toDocument.inverted()
        let floatingBounds = CGRect(x: 0, y: 0, width: CGFloat(pixels.pixels.width), height: CGFloat(pixels.pixels.height))
            .applying(BrushRaster.pixelToDocument(transform, width: pixels.pixels.width, height: pixels.pixels.height))
            .applying(toPixels)
        let original = CGRect(x: 0, y: 0, width: width, height: height)
        let extent = original.union(floatingBounds).integral
        guard extent.width <= 30_000, extent.height <= 30_000, extent.width * extent.height <= 100_000_000
        else { throw ProjectError.tooLarge }
        var buffer = PixelBuffer(width: Int(extent.width), height: Int(extent.height))
        // The source layer's own pixels fill `placed` axis-aligned (its rotation lives in
        // its transform, not its pixels) — the same frame `BrushRaster.draw` used on macOS.
        let placed = original.offsetBy(dx: -extent.minX, dy: -extent.minY)
        let placedTransform = LayerTransform(origin: placed.origin, size: placed.size, sampling: .nearest)
        LayerRenderer.draw(sourceImage, transform: placedTransform, center: placedTransform.center, into: &buffer)
        let shift = CGPoint(x: -extent.minX, y: -extent.minY)
        let shiftedFloating = shifted(transform, by: shift)
        LayerRenderer.draw(pixels, transform: shiftedFloating, center: shiftedFloating.center, into: &buffer)
        let asset = ImportedImage(image: RasterImage(PortableImage(buffer)),
                                  thumbnail: RasterImage(PixelAdjust.thumbnail(of: PortableImage(buffer))), name: source.name)
        var merged = source.transform
        merged.size = CGSize(width: extent.width * source.size.width / CGFloat(width),
                             height: extent.height * source.size.height / CGFloat(height))
        let center = CGPoint(x: extent.midX, y: extent.midY).applying(toDocument)
        merged.origin = CGPoint(x: center.x - merged.size.width / 2, y: center.y - merged.size.height / 2)
        var mask = source.mask
        if let current = source.mask, current.placement == nil, extent != original {
            // White frame, then the mask drawn over it: pixels outside the old bounds are
            // revealed (255), exactly the CG fill+drawComposite the macOS context did.
            var grown = MaskBuffer(width: Int(extent.width), height: Int(extent.height), fill: 255)
            LayerRenderer.drawCoverage(current.asset.image, transform: placedTransform, into: &grown)
            mask = current.replacing(try LayerMask.asset(from: PortableImage(grown)))
        }
        return (asset, merged, mask)
    }
}