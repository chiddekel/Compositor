// Portable port of Compositor/IO/ProjectStore.swift's persistence value types
// (file-map tier: "Keep logic; replace Apple operations"). Ported verbatim:
// `ProjectLayerRecord` (the Codable per-layer record written into a project file)
// and `ProjectError` (the project load/save error enum). Both are pure value
// types with no IO: `imageFile`/`maskFile` are String paths, not `CGImage` bytes.
//
// The IO itself — reading `imageFile` bytes into an `ImportedImage`, writing them
// back, encoding the record array to a project archive — is the persistence
// milestone (ProjectStore + ProjectSnapshot + the save/load pipeline). The record
// and the error type are the portable surface those read and write, and the
// surface the document-model `hierarchyRecord`/`LiveMaskGraph.validate`/
// `LayerHierarchy.validate` logic operates on.
//
// SOLID: the value types keep their responsibilities and contracts (a serializable
// layer + project-level errors); the Apple API surface (the file IO) is exchanged.
// The macOS original stays the source of truth.

import Foundation

nonisolated struct ProjectLayerRecord: Codable, Sendable {
    let id: UUID
    let name: String
    var isVisible: Bool
    let transform: LayerTransform
    let imageFile: String?
    var parentID: UUID? = nil
    var isGroup: Bool? = nil
    var opacity: Double? = nil
    var blendMode: LayerBlendMode? = nil
    var maskFile: String? = nil
    var maskEnabled: Bool? = nil
    var maskSourceID: UUID? = nil
    var adjustment: LayerAdjustment? = nil
    /// A mask moved apart from its layer: where it sits on the document.
    var maskPlacement: LayerTransform? = nil
    /// Nil (older projects) is linked.
    var maskLinked: Bool? = nil
    /// A shape layer's shape, drawn again when the layer is scaled. Older versions ignore it and keep the pixels.
    var shape: LayerShapeStyle? = nil
}

nonisolated enum ProjectError: LocalizedError {
    case invalid, version(Int), missingImage, tooLarge, encode
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid Compositor project, or its metadata is damaged."
        case .version(let version): "This project uses format version \(version). This app supports versions 1–7."
        case .missingImage: "An image inside the project is missing or damaged. The current document has not been replaced."
        case .tooLarge: "This project exceeds the supported canvas, layer, file-size, or 100-megapixel image limit."
        case .encode: "An image could not be saved. The previous project has not been replaced."
        }
    }
}