// Renderer integration for the document compositor: folder masks and live-mask
// clipping stacks through `DocumentRenderer.render()` (checkpoint row 20 "Layer-mask
// raster adapters — Folder/live-mask renderer integration"). Pin the macOS
// LiveMaskRenderer semantics on Linux:
//   • a folder's enabled mask clips every child's content (parent-chain coverage);
//   • a live-mask stack shares the base layer's alpha instead of painting it over
//     itself, so soft edges are not double-thickened;
//   • source coverage is independent of the source layer's visibility.
// (The placement caches listed alongside remain display-tier DFS — deferred.)

import XCTest
@testable import CompositorCore

final class RendererIntegrationTests: XCTestCase {

    private func makeImage(_ fill: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), width: Int, height: Int) -> ImportedImage {
        var pixels = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { pixels[x, y] = fill } }
        let image = RasterImage(PortableImage(pixels))
        return ImportedImage(image: image, thumbnail: image, name: "Layer")
    }

    private func makeMask(_ tone: (Int, Int) -> UInt8, width: Int, height: Int) -> LayerMask {
        var pixels = MaskBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { pixels[x, y] = tone(x, y) } }
        return LayerMask(asset: ImportedImage(mask: PortableImage(pixels), name: "Mask"))
    }

    private func rgba(_ out: PortableImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let at = (y * out.width + x) * 4
        return (out.bytes[at], out.bytes[at + 1], out.bytes[at + 2], out.bytes[at + 3])
    }

    func testFolderChildrenRenderAndSiblingsStayVisible() throws {
        let base = makeImage((r: 200, g: 100, b: 50, a: 255), width: 4, height: 4)
        let folder = ImageLayer(id: UUID(), asset: nil, name: "Folder", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)),
            parentID: nil, isGroup: true)
        let child = ImageLayer(id: UUID(), asset: makeImage((r: 0, g: 255, b: 0, a: 255), width: 2, height: 2),
            name: "Child", isVisible: true, transform: LayerTransform(origin: .zero, size: CGSize(width: 2, height: 2)),
            parentID: folder.id)
        let doc = CanvasDocument(width: 4, height: 4, layers: [ImageLayer(asset: base, origin: .zero), folder, child])
        let out = try DocumentRenderer(doc).render()
        // The folder itself contributes nothing, so its empty pixels must not erase
        // the child: green wherever the child sits, base red elsewhere.
        XCTAssertEqual(rgba(out, 0, 0).1, 255, "child renders through the folder")
        XCTAssertEqual(rgba(out, 3, 3).0, 200, "sibling/background untouched")
    }

    func testFolderMaskClipsChildrenNotSiblings() throws {
        let base = makeImage((r: 200, g: 100, b: 50, a: 255), width: 4, height: 4)
        let folderMask = makeMask({ x, _ in x < 2 ? 255 : 0 }, width: 4, height: 4)
        let folder = ImageLayer(id: UUID(), asset: nil, name: "Folder", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)),
            parentID: nil, isGroup: true, mask: folderMask)
        let child = ImageLayer(id: UUID(), asset: makeImage((r: 0, g: 255, b: 0, a: 255), width: 4, height: 4),
            name: "Child", isVisible: true, transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)),
            parentID: folder.id)
        let doc = CanvasDocument(width: 4, height: 4, layers: [ImageLayer(asset: base, origin: .zero), folder, child])
        let out = try DocumentRenderer(doc).render()
        XCTAssertEqual(rgba(out, 0, 0).1, 255, "masked half of the child shows through")
        XCTAssertEqual(rgba(out, 3, 3).0, 200, "masked-out half falls back to the background")
    }

    func testLiveMaskStackSharesBaseAlpha() throws {
        // The base's own alpha clips the whole stack: a semi-transparent base makes
        // the child's coverage exactly 128, never 128 * 128/255 (double-thickened).
        let base = makeImage((r: 255, g: 255, b: 255, a: 128), width: 2, height: 2)
        let child = makeImage((r: 0, g: 255, b: 0, a: 255), width: 2, height: 2)
        let baseLayer = ImageLayer(id: UUID(), asset: base, name: "Base", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 2, height: 2)))
        let clipped = ImageLayer(id: UUID(), asset: child, name: "Clipped", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 2, height: 2)),
            parentID: baseLayer.parentID, maskSourceID: baseLayer.id)
        let doc = CanvasDocument(width: 4, height: 4, layers: [baseLayer, clipped])
        let out = try DocumentRenderer(doc).render()
        let pixel = rgba(out, 0, 0)
        XCTAssertEqual(pixel.3, 128, "stack alpha shared, not re-multiplied")
        XCTAssertGreaterThan(pixel.1, 100, "green carries the base alpha")
        XCTAssertEqual(rgba(out, 3, 3).3, 0, "outside the base stays transparent")
    }

    func testLiveMaskCoverageIgnoresSourceVisibility() throws {
        // A hidden base still clips its stack (the macOS LiveMaskRenderer applies
        // coverage independently of source visibility).
        let base = makeImage((r: 255, g: 255, b: 255, a: 255), width: 2, height: 2)
        let child = makeImage((r: 0, g: 255, b: 0, a: 255), width: 4, height: 4)
        let baseLayer = ImageLayer(id: UUID(), asset: base, name: "Base", isVisible: false,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 2, height: 2)))
        let clipped = ImageLayer(id: UUID(), asset: child, name: "Clipped", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)),
            parentID: baseLayer.parentID, maskSourceID: baseLayer.id)
        let doc = CanvasDocument(width: 4, height: 4, layers: [baseLayer, clipped])
        let out = try DocumentRenderer(doc).render()
        XCTAssertEqual(rgba(out, 0, 0).1, 255, "clipped child shows where the hidden base covers")
        XCTAssertEqual(rgba(out, 3, 3).3, 0, "hidden base's coverage stops the child")
        XCTAssertEqual(rgba(out, 3, 3).0, 0, "hidden base never paints its own pixels")
    }
}