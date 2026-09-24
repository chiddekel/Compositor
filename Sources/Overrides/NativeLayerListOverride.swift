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
// `CanvasThumbnail.swift`) are all preserved. Reorder is the one capability NOT wired yet in this pass: `.onMove`
// on `ForEach` (see `ViewBuilder.swift`) is a documented no-op placeholder until the Qt renderer grows list
// drag-and-drop, and `EditorSession.reorderLayers(from:to:)` already has the exact `(IndexSet, Int)` shape it
// needs — the data-side is ready, only the interaction isn't connected yet.

import SwiftUI

struct NativeLayerList: View {
    let session: EditorSession

    private var depths: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: session.layerRows.map { ($0.layer.id, $0.depth) })
    }

    var body: some View {
        List(session.layerRows, id: \.layer.id) { entry in
            row(for: entry.layer.id)
        }
        .accessibilityIdentifier("layersList")
    }

    private func row(for id: UUID) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: (session.document?.layers ?? []).map { ($0.id, $0) })
        guard let layer = byID[id] else { return AnyView(EmptyView()) }
        let isSelected = session.selectedLayerIDs.contains(layer.id)
        return AnyView(
            HStack(spacing: 8) {
                Spacer().frame(width: Double(depths[id] ?? 0) * 14)
                Button {
                    session.toggleLayerVisibility(layer.id)
                } label: {
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(layer.isVisible ? "Hide layer" : "Show layer")
                
                thumbnailView(for: layer)
                    .fixedSize()

                VStack(alignment: .leading, spacing: 2) {
                    Text(layer.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(layer.isVisible ? .primary : .secondary)
                    subtitleView(for: layer)
                }
                Spacer()
            }
            .frame(height: 40)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
            .cornerRadius(4)
            .onTapGesture {
                if session.selectedLayerIDs.contains(layer.id), session.selectedLayerIDs.count > 1 {
                    session.selectLayers(session.selectedLayerIDs, primary: layer.id)
                } else {
                    session.selectLayer(layer.id)
                }
            }
        )
    }

    @ViewBuilder
    private func thumbnailView(for layer: ImageLayer) -> some View {
        if layer.isGroup {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: 0.18))
                Image(systemName: "folder")
            }
            .frame(width: 32, height: 32)
            .fixedSize()
        } else if let adj = layer.adjustment {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: 0.18))
                Image(systemName: adj.kind.symbol)
            }
            .frame(width: 32, height: 32)
            .fixedSize()
        } else if layer.liveText != nil {
            // Editable text shows the text symbol, as upstream's table does.
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: 0.18))
                Image(systemName: "textformat")
            }
            .frame(width: 32, height: 32)
            .fixedSize()
        } else {
            // Upstream's own canvas-framed thumbnails (CanvasThumbnail), cached like its table's ThumbnailKey so an
            // unchanged layer keeps the same picture — and the panel isn't rebuilt for it.
            let canvas = session.document?.size ?? layer.size
            let size = CanvasThumbnail.fittedSize(canvas: canvas, box: 36)
            HStack(spacing: 4) {
                Image(nsImage: LayerThumbnails.layer(layer, canvas: canvas))
                    .frame(width: size.width, height: size.height)
                if let mask = layer.mask {
                    let maskSize = CanvasThumbnail.fittedSize(canvas: canvas, box: 30)
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Image(nsImage: LayerThumbnails.mask(mask, transform: layer.maskTransform, layerID: layer.id, canvas: canvas))
                        .frame(width: maskSize.width, height: maskSize.height)
                }
            }
            .fixedSize()
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
