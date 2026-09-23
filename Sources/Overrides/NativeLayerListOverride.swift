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
        } else {
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(white: 0.22))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    Image(systemName: "rectangle.inset.filled")
                }
                .frame(width: 32, height: 32)
                if layer.mask != nil {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(white: 0.22))
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    }
                    .frame(width: 32, height: 32)
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
