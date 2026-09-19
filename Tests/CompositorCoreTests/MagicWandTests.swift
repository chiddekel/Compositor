// Tests for the Magic Wand flood selection: `MagicWand.select` (the Swift port of the
// C `wand_mask` matching kernel + `MaskTracing.outline` tracing) and the
// `EditorSession.magicWand` composite-read/combine path (`applySelection` union and
// subtraction by coverage). Pin the unchanged macOS behavior on Linux.
// Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class MagicWandTests: XCTestCase {

    private func image(_ width: Int, _ height: Int, _ fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> RasterImage {
        var p = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { p[x, y] = fill(x, y) } }
        return RasterImage(PortableImage(p))
    }

    private func makeTwoToneDocument() -> EditorSession {
        let layer = image(60, 30) { (x, _) in x < 30 ? (255, 0, 0, 255) : (0, 0, 255, 255) }
        let imageLayer = ImageLayer(asset: ImportedImage(image: layer, thumbnail: layer, name: "Split"), origin: .zero)
        var doc = CanvasDocument(width: 100, height: 60)
        doc.layers = [imageLayer]
        let session = EditorSession()
        session.replaceCurrentDocument(doc)
        session.setActiveLayer(imageLayer.id)
        return session
    }

    private func fillSelection(in doc: CanvasDocument, _ selection: DocumentSelection) -> Int {
        let mask = selection.rasterized(in: CGRect(origin: .zero, size: doc.size))
        return mask.bytes.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
    }

    // MARK: MagicWand.select

    func testWandContiguousSelectsOnlyConnectedIsland() throws {
        // A red island inside a blue sea, with a second red pixel disconnected at the
        // edge. Contiguous matches only the island; non-contiguous catches both.
        let img = image(8, 5) { (x, y) in
            if x == 1 && y == 1 { return (255, 0, 0, 255) }
            if x == 7 && y == 0 { return (255, 0, 0, 255) }
            return (0, 0, 255, 255)
        }
        var settings = WandSettings()
        settings.tolerance = 2
        let contiguous = try MagicWand.select(in: img, at: CGPoint(x: 1, y: 1), settings: settings)
        let box = try XCTUnwrap(contiguous).boundingBox
        XCTAssertEqual(box, CGRect(x: 1, y: 1, width: 1, height: 1))

        settings.contiguous = false
        let global = try XCTUnwrap(MagicWand.select(in: img, at: CGPoint(x: 1, y: 1), settings: settings))
        XCTAssertEqual(global.boundingBox, CGRect(x: 1, y: 0, width: 7, height: 2))
    }

    func testWandToleranceClampsPerChannel() throws {
        // Left half gray 100, right half gray 200. A tolerance of 50 joins the halves;
        // 20 keeps them apart. The match is per channel, alpha included, so a tolerance
        // of 0 selects only the exact clicked color.
        let img = image(6, 1) { (x, _) in (UInt8(x < 3 ? 100 : 200), 0, 0, 255) }
        var settings = WandSettings()

        settings.tolerance = 20
        settings.contiguous = false
        var path = try XCTUnwrap(MagicWand.select(in: img, at: CGPoint(x: 1, y: 0), settings: settings))
        XCTAssertEqual(path.boundingBox, CGRect(x: 0, y: 0, width: 3, height: 1))

        settings.tolerance = 120
        path = try XCTUnwrap(MagicWand.select(in: img, at: CGPoint(x: 1, y: 0), settings: settings))
        XCTAssertEqual(path.boundingBox, CGRect(x: 0, y: 0, width: 6, height: 1))

        settings.tolerance = 0
        path = try XCTUnwrap(MagicWand.select(in: img, at: CGPoint(x: 1, y: 0), settings: settings))
        XCTAssertEqual(path.boundingBox, CGRect(x: 0, y: 0, width: 3, height: 1))
    }

    func testWandSampleSizeAveragesNeighborhood() throws {
        // A 5×5 red square with a lone blue pixel in the middle. A point sample on the
        // blue pixel matches only itself (tolerance 40 keeps the red 200 away); a 3-by-3
        // average pulls the reference toward red and selects the whole square.
        var settings = WandSettings()
        settings.tolerance = 0
        settings.contiguous = false

        let img = image(5, 5) { (x, y) in (x == 2 && y == 2) ? (0, 0, 255, 255) : (200, 0, 0, 255) }

        settings.sampleSize = .point
        settings.tolerance = 40
        let point = try XCTUnwrap(MagicWand.select(in: img, at: CGPoint(x: 2, y: 2), settings: settings))
        XCTAssertEqual(point.boundingBox, CGRect(x: 2, y: 2, width: 1, height: 1))

        settings.sampleSize = .threeByThree
        settings.tolerance = 40
        let averaged = try XCTUnwrap(MagicWand.select(in: img, at: CGPoint(x: 2, y: 2), settings: settings))
        XCTAssertEqual(averaged.boundingBox.width, 5)
        XCTAssertEqual(averaged.boundingBox.height, 5)
    }

    func testWandUniformTransparentSelectsAll() throws {
        // On a fully transparent canvas the wand's tolerance 32 samples a (0,0,0,0)
        // reference and everything matches, exactly as the C kernel would on macOS.
        let blank = image(4, 4) { _, _ in (0, 0, 0, 0) }
        let path = try XCTUnwrap(MagicWand.select(in: blank, at: CGPoint(x: 2, y: 2), settings: WandSettings()))
        XCTAssertEqual(path.boundingBox, CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    func testWandOutOfBoundsAndFiniteGuard() throws {
        let img = image(4, 4) { _, _ in (255, 0, 0, 255) }
        XCTAssertNil(try MagicWand.select(in: img, at: CGPoint(x: 4, y: 2), settings: WandSettings()))
        XCTAssertNil(try MagicWand.select(in: img, at: CGPoint(x: -1, y: 2), settings: WandSettings()))
        XCTAssertNil(try MagicWand.select(in: img, at: CGPoint(x: CGFloat.infinity, y: 2), settings: WandSettings()))
    }

    func testWandRoundedReferenceMatchesCKernel() throws {
        // The reference color rounds with `(sum + samples / 2) / samples`. The 2×1
        // block sums to 21, so `(21 + 2/2) / 2 = 11` picks the right pixel, not 10.
        let img = image(2, 1) { (x, _) in (UInt8(10 + x), UInt8(10 + x), 0, 255) }
        var settings = WandSettings()
        settings.sampleSize = .threeByThree
        settings.tolerance = 0
        settings.contiguous = false
        let path = try XCTUnwrap(MagicWand.select(in: img, at: CGPoint(x: 1, y: 0), settings: settings))
        // (10+11+1)/2 = 11 → reference 11 matches only x=1 at zero tolerance.
        XCTAssertEqual(path.boundingBox, CGRect(x: 1, y: 0, width: 1, height: 1))
    }

    // MARK: EditorSession.magicWand

    func testMagicWandReplaceSetsSelection() throws {
        let session = makeTwoToneDocument()
        let made = try session.magicWand(at: CGPoint(x: 10, y: 15), settings: WandSettings(),
                                         mode: .replace, antialiased: true)
        XCTAssertTrue(made)
        let box = try XCTUnwrap(session.document?.selection?.path.boundingBox)
        XCTAssertEqual(box.width, 30)
        XCTAssertEqual(box.height, 30)
    }

    func testMagicWandAddUnionsAndSubtractCarves() throws {
        let session = makeTwoToneDocument()
        let settings = WandSettings()

        try session.magicWand(at: CGPoint(x: 10, y: 15), settings: settings, mode: .replace, antialiased: false)
        let red = try XCTUnwrap(session.document?.selection)
        XCTAssertEqual(red.path.boundingBox.width, 30, accuracy: 2)

        try session.magicWand(at: CGPoint(x: 40, y: 15), settings: settings, mode: .add, antialiased: false)
        let union = try XCTUnwrap(session.document?.selection)
        XCTAssertEqual(union.path.boundingBox.width, 60, accuracy: 2)

        // Subtracting the red half from the union leaves the blue half.
        try session.magicWand(at: CGPoint(x: 10, y: 15), settings: settings, mode: .subtract, antialiased: false)
        let carved = try XCTUnwrap(session.document?.selection)
        XCTAssertEqual(carved.path.boundingBox.minX, 30, accuracy: 2)
        XCTAssertEqual(carved.path.boundingBox.width, 30, accuracy: 4)
    }

    func testMagicWandEmptyClickClearsNewSelection() throws {
        let session = makeTwoToneDocument()
        try session.magicWand(at: CGPoint(x: 10, y: 15), settings: WandSettings(), mode: .replace, antialiased: false)
        XCTAssertNotNil(session.document?.selection)
        // A click outside the canvas matches nothing; in New mode it clears the selection.
        try session.magicWand(at: CGPoint(x: 200, y: 200), settings: WandSettings(), mode: .replace, antialiased: false)
        XCTAssertNil(session.document?.selection)
    }

    func testMagicWandReplacesIsOneUndoStep() throws {
        let session = makeTwoToneDocument()
        session.beginEdit("Scratch")
        try session.magicWand(at: CGPoint(x: 10, y: 15), settings: WandSettings(), mode: .replace, antialiased: true)
        session.endEdit()
        XCTAssertNotNil(session.document?.selection)
        try session.undo()
        XCTAssertNil(session.document?.selection)
    }
}