// Portable port of Compositor/IO/ProjectStore.swift's persistence value types and
// manifest validation (file-map tier: "Keep logic; replace Apple operations").
// Ported verbatim: `ProjectManifest` (Codable, Sendable — the on-disk project
// header + layer records), `ProjectSnapshot` (the in-memory manifest + decoded
// images/masks), and `ProjectStore.validate(_:)` (the pure manifest invariants:
// format/version/colorSpace/resolution/dimensions/layer-count, per-layer
// mask-version/opacity/group rules, the duplicate-id/name/transform/imageFile
// checks, and the `LayerHierarchy.validate`/`LiveMaskGraph.validate` graph rules).
//
// Filesystem operations stay in the Qt host: QImageReader/QImageWriter replace
// ImageIO, QDir replaces FileWrapper, and the host stages a sibling directory
// before replacement. This Swift file remains the shared manifest validator and
// snapshot mapping surface used by the C ABI.
//
// SOLID: the value types and the validation keep their responsibilities and
// contracts (a serializable manifest and its invariants); the Apple API surface
// (ImageIO/FileWrapper/NSFileCoordinator) is exchanged. The macOS original stays
// the source of truth.

import Foundation

nonisolated struct ProjectManifest: Codable, Sendable {
    var format = "com.compositor.project"
    var version = 7
    var colorSpace = "sRGB"
    var resolution: Double? = nil // Older version-1 projects default to 72 pixels/inch.
    let documentID: UUID
    let width: Int
    let height: Int
    let activeLayerID: UUID?
    var layers: [ProjectLayerRecord]
}

nonisolated struct ProjectSnapshot: @unchecked Sendable {
    let manifest: ProjectManifest
    let images: [UUID: ImportedImage]
    var masks: [UUID: ImportedImage] = [:]
}

nonisolated enum ProjectStore {
    /// Pure invariants a project manifest must satisfy before its images are
    /// touched. Verbatim from the macOS `ProjectStore.validate(_:)`.
    static func validate(_ manifest: ProjectManifest) throws {
        guard manifest.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard (1...7).contains(manifest.version) else { throw ProjectError.version(manifest.version) }
        guard manifest.colorSpace == "sRGB" else { throw ProjectError.invalid }
        if let resolution = manifest.resolution {
            guard resolution.isFinite, (1...9600).contains(resolution) else { throw ProjectError.invalid }
        }
        guard (1...30_000).contains(manifest.width), (1...30_000).contains(manifest.height),
              manifest.layers.count <= 10_000 else { throw ProjectError.tooLarge }
        for layer in manifest.layers {
            if let adjustment = layer.adjustment {
                guard manifest.version >= 7, layer.isGroup != true, layer.imageFile == nil, adjustment.isValid else { throw ProjectError.invalid }
            }
            // Layer masks arrived in version 4, folder masks in version 6.
            guard layer.maskFile == nil || (manifest.version >= (layer.isGroup == true ? 6 : 4)
                && layer.maskFile == "\(layer.id.uuidString).mask.png"),
                layer.maskEnabled == nil || layer.maskFile != nil,
                layer.maskPlacement.map({ $0.isValid && layer.maskFile != nil }) ?? true else { throw ProjectError.invalid }
            let opacity = layer.opacity ?? 1
            let blend = layer.blendMode ?? .normal
            guard opacity.isFinite, (0...1).contains(opacity),
                  (manifest.version >= 3 || (opacity == 1 && blend == .normal)),
                  (layer.isGroup != true || (opacity == 1 && blend == .normal)) else { throw ProjectError.invalid }
        }
        try LayerHierarchy.validate(manifest.layers)
        try LiveMaskGraph.validate(manifest.layers)
        if manifest.version < 5, manifest.layers.contains(where: { $0.maskSourceID != nil }) { throw ProjectError.invalid }
        if manifest.version == 1, manifest.layers.contains(where: { $0.parentID != nil || $0.isGroup == true }) { throw ProjectError.invalid }
        var ids = Set<UUID>()
        for layer in manifest.layers {
            guard ids.insert(layer.id).inserted, layer.transform.isValid,
                  !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  layer.name.utf8.count <= 16_384,
                  layer.imageFile == nil || layer.imageFile == "\(layer.id.uuidString).png" else { throw ProjectError.invalid }
        }
        if let id = manifest.activeLayerID, !ids.contains(id) { throw ProjectError.invalid }
    }
}
