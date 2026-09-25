// OVERRIDE for `Compositor/UI/NativeLayerList.swift`'s public entry point (`NativeLayerList(session:)`). The real
// file (1101 lines) is genuinely blocked, not by missing compat coverage: it uses `#selector`/`@objc` throughout
// (32 occurrences) for its `NSTableView` delegate/data-source/drag machinery, which needs an Objective-C runtime
// Linux Swift does not have (confirmed: the frontend runs with `-disable-objc-interop`, and there is no `libobjc`
// on this platform to emulate one onto — a from-scratch message-dispatch layer is a separate, large, uncertain
// sub-project, not a SwiftUI-compat gap).
//
// This is deliberately NOT a lossy stand-in. `EditorSession` already exposes exactly the operations a layers list
// needs as plain, list-shaped APIs — `layerRows` (display order + depth + visibility, top-first), `reorderLayers
// (from: IndexSet, to: Int)` (the *exact* signature SwiftUI's own `ForEach.onMove(perform:)` expects), `selectLayer`
// /`selectLayers`, `toggleLayerVisibility`. A generic `List`/`ForEach` reimplementation on top of those is a real
// backend swap (native `NSTableView` drag-and-drop → Qt/SwiftUI-compat list interaction), the same category as the
// existing Metal→Vulkan override: view, select, multi-select, show/hide, and thumbnails (via the already-wired
// `CanvasThumbnail.swift`) are all preserved. Drag-and-drop goes through the compat-only
// `compatListDrop` (the Qt renderer drags the rows) into the same placement the real list's drop performs.

import SwiftUI

struct NativeLayerList: View {
    let session: EditorSession

    private var depths: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: session.layerRows.map { ($0.layer.id, $0.depth) })
    }

    private var dragLayerIdentifiers: [String] {
        let rows = session.layerRows
        let selected = session.selectedLayerIDs
        let descendants = selected.reduce(into: Set<UUID>()) { $0.formUnion(session.descendantIDs(of: $1)) }
        let selectedRoots = rows.map(\.layer.id).filter { selected.contains($0) && !descendants.contains($0) }
        return rows.map { row in
            let identifiers = selected.contains(row.layer.id) ? selectedRoots : [row.layer.id]
            return identifiers.map(\.uuidString).joined(separator: "\n")
        }
    }

    var body: some View {
        List(session.layerRows, id: \.layer.id) { entry in
            row(for: entry.layer.id)
        }
        // Drag to reorder, into a folder, or (Alt) duplicate — what the real list's NSTableView drop does.
        .compatListDrop(folders: session.layerRows.map { $0.layer.isGroup == true },
                        layerIdentifiers: dragLayerIdentifiers) { source, row, fraction, copying in
            drop(from: source, on: row, at: fraction, copying: copying)
        }
        .compatListMaskDrop(
            // Rows hold hierarchy records; the masks are on the document's layers.
            dragIdentifiers: session.layerRows.map { row in
                session.document?.layers.first(where: { $0.id == row.layer.id })?.mask == nil ? "" : row.layer.id.uuidString
            },
            dropTargetIdentifiers: session.layerRows.map { $0.layer.isGroup == true ? "" : $0.layer.id.uuidString }
        ) { source, target in
            guard let sourceID = UUID(uuidString: source), let targetID = UUID(uuidString: target),
                  session.canCopyMask(from: sourceID, to: targetID) else { return }
            session.copyMask(from: sourceID, to: targetID)
        }
        .accessibilityIdentifier("layersList")
    }

    /// NativeLayerList's `validateDrop` + `acceptDrop` + `place`, from list rows: the middle of a folder row drops into
    /// it, otherwise above the nearer edge's row; the selection travels together when the dragged row is part of it.
    private func drop(from source: Int, on row: Int, at fraction: Double, copying: Bool) {
        let rows = session.layerRows
        guard session.canEditLayers, rows.indices.contains(source) else { return }
        let intoFolder = rows.indices.contains(row) && rows[row].layer.isGroup == true && (0.25...0.75).contains(fraction)
        let target = intoFolder ? row : min(rows.count, max(0, fraction < 0.5 ? row : row + 1))
        // The dragged layers, as the list shows them, leaving out anything inside a dragged folder.
        let pressed = rows[source].layer.id
        let dragged: Set<UUID> = session.selectedLayerIDs.contains(pressed) ? session.selectedLayerIDs : [pressed]
        let carried = dragged.reduce(into: Set<UUID>()) { $0.formUnion(session.descendantIDs(of: $1)) }
        let ids = rows.map(\.layer.id).filter { dragged.contains($0) && !carried.contains($0) }
        guard !ids.isEmpty else { return }
        let parent: UUID?, above: UUID?, atBottom: Bool
        if intoFolder {
            parent = rows[target].layer.id; above = nil; atBottom = false
        } else if target >= rows.count {
            parent = nil; above = nil; atBottom = true
        } else {
            parent = rows[target].layer.parentID; above = rows[target].layer.id; atBottom = false
        }
        guard ids.allSatisfy({ session.canPlaceLayer($0, in: parent) }), !(above.map(ids.contains) ?? false) || copying else { return }
        let order = intoFolder ? Array(ids.reversed()) : ids
        session.beginEdit(copying ? (ids.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
                                  : (ids.count > 1 ? "Move Layers" : "Move Layer"))
        var placed = false
        for id in order {
            let done = copying ? session.duplicateLayer(id, in: parent, above: above, atBottom: atBottom)
                               : session.placeLayer(id, in: parent, above: above, atBottom: atBottom)
            placed = done || placed
        }
        if placed, !copying { session.selectLayers(Set(ids), primary: ids.first) }
        session.endEdit()
    }

    /// LayerCell's layout (NativeLayerList.swift), constraint for constraint: a 52-point row with the eye 8 in and
    /// 20 wide, folders and clipping masks stepping in by 24, a 36-point thumbnail slot, the mask slot (30) behind its
    /// link, the name (13 pt) 9 from the top with the size (10 pt, secondary) 3 below, a 6% hairline along the bottom;
    /// a row hidden by its folder at 35%. Rows are 2 apart (the table's intercell spacing).
    private func row(for id: UUID) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: (session.document?.layers ?? []).map { ($0.id, $0) })
        guard let layer = byID[id] else { return AnyView(EmptyView()) }
        let entry = session.layerRows.first { $0.layer.id == id }
        let isSelected = session.selectedLayerIDs.contains(layer.id)
        let indent = Double(min(entry?.depth ?? 0, 8)) * 24 + (layer.maskSourceID == nil ? 0 : 24)
        let linkable = layer.mask != nil && layer.adjustment == nil && !layer.isGroup
        let name = (layer.maskSourceID == nil ? "" : "↳ ") + layer.name
        let details = layer.maskSourceID.map { source in
            "Clipped to \(session.document?.layers.first(where: { $0.id == source })?.name ?? "Missing source")"
        } ?? (layer.liveText != nil ? "Text · Double-click to edit" : layer.adjustment != nil ? "Adjustment · Double-click to edit"
              : layer.isGroup ? "Folder" : "\(Int(layer.size.width.rounded())) × \(Int(layer.size.height.rounded())) px")
        return AnyView(
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    // EyeSwipeButton: press shows or hides this layer, dragging over other eyes gives them the same
                    // state, one undo step for the lot.
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .frame(width: 20, height: 51)
                    .compatSwipe(group: "layerEyes",
                                 began: { EyeSwipe.visible = session.beginVisibilitySwipe(layer.id) },
                                 entered: { if let visible = EyeSwipe.visible { session.setVisibilityInSwipe(layer.id, visible: visible) } },
                                 ended: { if EyeSwipe.visible != nil { EyeSwipe.visible = nil; session.endVisibilitySwipe() } })
                    .accessibilityLabel("\(layer.isVisible ? "Hide" : "Show") \(layer.name)")
                    .padding(.leading, 8)
                    Spacer().frame(width: indent)
                    Group {
                        if layer.isGroup {
                            Button { session.toggleGroupExpansion(layer.id) } label: {
                                Image(systemName: session.collapsedGroupIDs.contains(layer.id) ? "chevron.right" : "chevron.down")
                            }.buttonStyle(.plain)
                        } else { Spacer() }
                    }.frame(width: 14, height: 51)
                    HStack {
                        thumbnailView(for: layer, active: session.activeLayerID == layer.id && session.selectedLayerIDs.count == 1)
                    }.frame(width: 36, height: 51)
                    if let mask = layer.mask {
                        let canvas = session.document?.size ?? layer.size
                        let maskSize = CanvasThumbnail.fittedSize(canvas: canvas, box: 30)
                        Group {
                            if linkable, mask.isLinked {
                                Image(systemName: "link").font(.system(size: 10)).foregroundStyle(.secondary)
                            } else { Spacer() }
                        }.frame(width: linkable ? 13 : 5, height: 51)
                        HStack {
                            Image(nsImage: LayerThumbnails.mask(mask, transform: layer.maskTransform, layerID: layer.id, canvas: canvas))
                                .frame(width: maskSize.width, height: maskSize.height)
                                .border(session.activeLayerID == layer.id && session.isMaskSelected ? Color.accentColor : Color.clear, width: 2)
                        }
                        .frame(width: 30, height: 51)
                        .accessibilityIdentifier("layerMaskThumb:\(layer.id.uuidString)")
                        .onTapGesture { maskThumbnailTapped(layer.id, modifiers: CompatInput.clickModifiers) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 13)).lineLimit(1)
                        Text(details).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.leading, 5).padding(.top, 9).padding(.trailing, 8)
                    Spacer()
                }
                .frame(height: 51)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            }
            .frame(height: 52)
            .background(isSelected ? Color(red: 0, green: 0.345, blue: 0.816) : Color.clear)
            .opacity(entry?.visible == false ? 0.35 : 1)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                click(layer.id, modifiers: CompatInput.clickModifiers)
            }
            .contextMenu { contextMenu(for: layer.id) }
        )
    }

    /// NSTableView's selection, then tableViewSelectionDidChange: Command (Ctrl) toggles a row, Shift extends from the
    /// active row, a plain click selects just the row — keeping a multi-selection when it lands inside it.
    private func click(_ id: UUID, modifiers: Int) {
        let rows = session.layerRows.map(\.layer.id)
        if modifiers & 1 != 0 {
            var ids = session.selectedLayerIDs
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            let primary = ids.contains(id) ? id : (session.activeLayerID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first)
            session.selectLayers(ids, primary: primary)
        } else if modifiers & 8 != 0, let anchor = session.activeLayerID, let from = rows.firstIndex(of: anchor),
                  let to = rows.firstIndex(of: id) {
            session.selectLayers(Set(rows[min(from, to)...max(from, to)]), primary: id)
        } else if session.selectedLayerIDs.contains(id), session.selectedLayerIDs.count > 1 {
            session.selectLayers(session.selectedLayerIDs, primary: id)
        } else {
            session.selectLayer(id)
        }
    }

    private func maskThumbnailTapped(_ id: UUID, modifiers: Int) {
        if modifiers & 1 != 0 {
            let mode: SelectionMode = modifiers & 2 != 0 ? .subtract : modifiers & 8 != 0 ? .add : .replace
            session.loadMaskSelection(layerID: id, mode: mode)
            return
        }
        session.selectLayerTarget(id, mask: true)
        if modifiers & 8 != 0 { session.toggleLayerMask() }
    }

    /// The real list's right-click menu (NativeLayerList.contextMenu(for:) and validateMenuItem), item for item.
    @ViewBuilder private func contextMenu(for id: UUID) -> some View {
        let active = session.activeLayer
        let prepare = { if session.selectedLayerIDs.isEmpty { session.selectLayer(id) } }
        Button("Duplicate Layer") { prepare(); session.duplicateActiveLayer() }
            .disabled(!(session.canEditLayers && active != nil))
        Button("Rename…") { prepare(); if session.canEditLayers, let id = session.activeLayerID { session.renamingLayerID = id } }
            .disabled(!(session.canEditLayers && active != nil && session.selectedLayerIDs.count == 1))
        Button(session.isMaskSelected && active?.mask != nil ? "Delete Mask"
               : session.selectedLayerIDs.count > 1 ? "Delete Selected Layers" : "Delete Layer") { prepare(); session.deleteLayerOrMask() }
            .disabled(!(session.canEditLayers && active != nil))
        Divider()
        Button(active?.maskSourceID != nil ? "Release Clipping Mask" : "Create Clipping Mask") {
            prepare(); if let id = session.activeLayerID { session.toggleClippingMask(id) }
        }.disabled(!(session.activeLayerID.map { session.canToggleClippingMask($0) } ?? false))
        Button("Group Selected Layers") { prepare(); session.groupSelectedLayers() }
            .disabled(!(session.canEditLayers && session.document != nil && (session.document?.layers.count ?? 0) < 10_000
                        && !session.selectedLayerIDs.isEmpty))
        Button("Move Out of Folder") { prepare(); session.moveActiveLayerOutOfGroup() }
            .disabled(!(session.canEditLayers && active?.parentID != nil))
        Button(session.mergeTitle) { prepare(); session.mergeLayers() }
            .disabled(!session.canMergeLayers)
        Divider()
        Menu("Add Mask") {
            Button("Reveal All (White)") { prepare(); addMask(revealing: true) }
            Button("Hide All (Black)") { prepare(); addMask(revealing: false) }
        }.disabled(!(session.canEditMask && active?.mask == nil))
        Button(active?.mask?.isEnabled == false ? "Enable Mask" : "Disable Mask") {
            prepare(); if let id = session.activeLayerID { session.selectLayerTarget(id, mask: false); session.toggleLayerMask() }
        }.disabled(!(session.canEditMask && active?.mask != nil))
        Button("Delete Mask") {
            prepare(); if let id = session.activeLayerID { session.selectLayerTarget(id, mask: false); session.deleteLayerMask() }
        }.disabled(!(session.canEditMask && active?.mask != nil))
        Button(active?.mask?.isLinked == false ? "Link Mask" : "Unlink Mask") {
            prepare(); if let id = session.activeLayerID { session.toggleMaskLink(id) }
        }.disabled(!(session.canEditLayers && active?.mask != nil && active?.isGroup == false && active?.adjustment == nil))
        Divider()
        Button(active?.isVisible == false ? "Show Layer" : "Hide Layer") {
            prepare(); if let id = session.activeLayerID { session.toggleLayerVisibility(id) }
        }.disabled(!(session.canEditLayers && active != nil))
    }

    private func addMask(revealing: Bool) {
        guard let id = session.activeLayerID else { return }
        session.selectLayerTarget(id, mask: false)
        session.addMask(revealing: revealing)
    }

    /// The thumbnail slot's picture: canvas-framed pixels, or upstream's square icons for folders, adjustments and live
    /// text; the target being edited has a 2-point accent border.
    @ViewBuilder
    private func thumbnailView(for layer: ImageLayer, active: Bool) -> some View {
        let border = active && !session.isMaskSelected ? Color.accentColor : Color.clear
        if layer.isGroup || layer.adjustment != nil || layer.liveText != nil {
            Image(systemName: layer.isGroup ? "folder" : layer.adjustment?.kind.symbol ?? "textformat")
                .font(.system(size: 22))
                .frame(width: 36, height: 36)
                .border(border, width: 2)
        } else {
            // Upstream's own canvas-framed thumbnails (CanvasThumbnail), cached like its table's ThumbnailKey so an
            // unchanged layer keeps the same picture — and the panel isn't rebuilt for it.
            let canvas = session.document?.size ?? layer.size
            let size = CanvasThumbnail.fittedSize(canvas: canvas, box: 36)
            Image(nsImage: LayerThumbnails.layer(layer, canvas: canvas))
                .frame(width: size.width, height: size.height)
                .border(border, width: 2)
        }
    }

    @ViewBuilder
    private func subtitleView(for layer: ImageLayer) -> some View {
        if layer.isGroup {
            Text("Folder").font(.system(size: 10)).foregroundStyle(.secondary)
        } else if layer.adjustment != nil {
            Text("Adjustment · Double-click to edit").font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
            Text("\(Int(layer.size.width)) × \(Int(layer.size.height)) px")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// The AppKit side of the layers list, as `NSHostingView(rootView: LayersPanel(...))` holds it on macOS: upstream's
/// `LayerTableView` (the `UIStandIns.swift` stand-in) as the hosted subview a user can focus. The Qt renderer never
/// asks for this — it draws the `List` above — so it only matters to AppKit-level callers (upstream's own
/// `BrushTests` focuses it to check that the brush keys still reach the brush from the layers panel).
extension NativeLayerList: HostedNativeContent {
    func makeNativeView() -> NSView? {
        let table = LayerTableView(frame: .zero)
        table.session = session
        return table
    }
}

/// The state an eye swipe gives the layers it passes over (nil when no swipe is in progress).
@MainActor enum EyeSwipe { static var visible: Bool? }

/// The thumbnails the rows show, made once per (picture, placement, canvas) — the same key upstream's LayerCell keeps.
@MainActor enum LayerThumbnails {
    private struct Key: Equatable {
        let image: ObjectIdentifier?
        let transform: LayerTransform
        let width: CGFloat, height: CGFloat
        let mask: Bool
    }
    private static var cache: [UUID: (key: Key, image: NSImage)] = [:]
    private static var maskCache: [UUID: (key: Key, image: NSImage)] = [:]

    static func layer(_ layer: ImageLayer, canvas: CGSize) -> NSImage {
        let key = Key(image: layer.asset.map { ObjectIdentifier($0.thumbnail) }, transform: layer.transform,
                      width: canvas.width, height: canvas.height, mask: false)
        if let cached = cache[layer.id], cached.key == key { return cached.image }
        let image = CanvasThumbnail.layer(layer.asset?.thumbnail, transform: layer.transform, canvas: canvas, box: 36)
        cache[layer.id] = (key, image)
        return image
    }

    static func mask(_ mask: LayerMask, transform: LayerTransform, layerID: UUID, canvas: CGSize) -> NSImage {
        let key = Key(image: ObjectIdentifier(mask.asset.thumbnail), transform: transform,
                      width: canvas.width, height: canvas.height, mask: true)
        if let cached = maskCache[layerID], cached.key == key { return cached.image }
        let image = CanvasThumbnail.mask(mask.asset.thumbnail, transform: transform, canvas: canvas, box: 30)
        maskCache[layerID] = (key, image)
        return image
    }
}
