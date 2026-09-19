// Portable port of Compositor/IO/ImageImporter.swift's value types (file-map tier:
// "Apple replacement/adaptation"). The macOS `ImportedImage` wraps two `CGImage`s
// (image + thumbnail) and an optional `RasterSnapshot`; the model layer relies on
// `CGImage` *reference identity* (`===`) to tell an untouched image from a changed
// one across edits. To keep that identity logic verbatim on Linux, the CGImage is
// exchanged for `RasterImage` — a reference-typed (`final class`) wrapper around
// the canonical `PortableImage` substrate. `===` on `RasterImage` mirrors `===`
// on `CGImage` exactly.
//
// Ported: `RasterImage` (CGImage stand-in), `ImportedImage` (struct, including
// the optional `raster: RasterSnapshot?` tile cache now that the portable
// `RasterSnapshot` exists in Rendering/), and `ImageImportError` (pure enum).
//
// Omitted (IO milestone): the `actor ImageImporter` — it decodes via
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
///
/// Like `CGImage` wrapping a lazy `CGDataProvider`, a `RasterImage` can defer its
/// bytes: `pixels` materializes at most once, on first read (the RasterSnapshot
/// mouse-up invariant — a commit never flattens the document). Dimensions are
/// known without materializing.
nonisolated final class RasterImage: @unchecked Sendable {
    private enum Source {
        case concrete(PortableImage)
        case deferred(() -> PortableImage)
    }
    private let source: Source
    private let storedWidth: Int
    private let storedHeight: Int
    private let storedBytesPerRow: Int
    private let lock = NSLock()
    private var cache: PortableImage?

    init(_ pixels: PortableImage) {
        self.source = .concrete(pixels)
        self.storedWidth = pixels.width
        self.storedHeight = pixels.height
        self.storedBytesPerRow = pixels.bytesPerRow
    }
    init(width: Int, height: Int, bytesPerRow: Int, deferred: @escaping () -> PortableImage) {
        self.source = .deferred(deferred)
        self.storedWidth = width
        self.storedHeight = height
        self.storedBytesPerRow = bytesPerRow
    }
    var pixels: PortableImage {
        switch source {
        case .concrete(let pixels): return pixels
        case .deferred:
            lock.lock()
            defer { lock.unlock() }
            if let cache { return cache }
            let pixels: PortableImage
            if case .deferred(let make) = source { pixels = make() } else { fatalError("unreachable") }
            cache = pixels
            return pixels
        }
    }
    var width: Int { storedWidth }
    var height: Int { storedHeight }
    var bytesPerRow: Int { storedBytesPerRow }
}

nonisolated struct ImportedImage: @unchecked Sendable {
    // Immutable rasters can be shared with the renderer.
    let image: RasterImage
    let thumbnail: RasterImage
    let name: String
    /// Sparse tile cache for fast redraw (see `RasterSnapshot`); nil when the
    /// image was imported rather than painted (macOS parity: optional, nil default).
    var raster: RasterSnapshot? = nil
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