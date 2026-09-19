// Portable port of Compositor/IO/ImageImporter.swift's value types (file-map tier:
// "Apple replacement/adaptation"). The macOS `ImportedImage` wraps two `CGImage`s
// (image + thumbnail) and an optional `RasterSnapshot`; the model layer relies on
// `CGImage` *reference identity* (`===`) to tell an untouched image from a changed
// one across edits. To keep that identity logic verbatim on Linux, the CGImage is
// exchanged for `RasterImage` — a reference-typed (`final class`) wrapper around
// the canonical `PortableImage` substrate. `===` on `RasterImage` mirrors `===`
// on `CGImage` exactly.
//
// Ported: `RasterImage` (CGImage stand-in), `ImportedImage` (struct, minus the
// `raster: RasterSnapshot?` field — `RasterSnapshot` is deeply CGImage/CGContext
// and is the Skia/CPU raster milestone; it was optional and defaulted nil, so
// dropping it changes no model invariant), and `ImageImportError` (pure enum).
//
// Omitted (IO/raster milestone): the `actor ImageImporter` — it decodes via
// `CGImageSource`/`CIContext`/`UTType`. The Linux decode pipeline (Qt image I/O or
// a vendored codec) is the IO milestone. The model only needs the value type.
//
// SOLID: the value type keeps its responsibility and contract; the Apple API
// surface (CGImage/RasterSnapshot) is exchanged. The macOS original stays the
// source of truth.

import Foundation

/// Reference-typed wrapper around the canonical `PortableImage`, standing in for
/// `CGImage` in the model layer so reference identity (`===`) works verbatim.
/// Two `RasterImage`s are the same image iff they are the same instance, exactly
/// as two `CGImage`s were on macOS.
nonisolated final class RasterImage: @unchecked Sendable {
    let pixels: PortableImage
    init(_ pixels: PortableImage) { self.pixels = pixels }
    var width: Int { pixels.width }
    var height: Int { pixels.height }
}

nonisolated struct ImportedImage: @unchecked Sendable {
    // Immutable rasters can be shared with the renderer.
    let image: RasterImage
    let thumbnail: RasterImage
    let name: String
    // macOS also carries an optional `RasterSnapshot` here (a tiled CGImage/CGContext
    // cache for fast redraw); that is the Skia/CPU raster milestone and is omitted.
}

nonisolated enum ImageImportError: LocalizedError {
    case unreadable, unsupported, tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be read. It may be damaged or unavailable."
        case .unsupported: "Choose a JPEG, PNG, HEIC, or TIFF image."
        case .tooLarge: "This import exceeds the current 100-megapixel document budget or 30,000-pixel side limit."
        }
    }
}