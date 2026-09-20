// Tests for the portable MaskTracing marching-squares outline algorithm. Pin the
// unchanged macOS logic on Linux (operating over a pre-extracted byte grid in
// place of the macOS CGContext rasterize). Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class MaskTracingTests: XCTestCase {

    // MARK: outline

    func testOutlineEmptyGridReturnsNoLoops() {
        let grid = [UInt8](repeating: 0, count: 9)
        XCTAssertTrue(MaskTracing.outline(grid: grid, width: 3, height: 3, channels: 1, offset: 0, test: { $0 >= 128 }).isEmpty)
    }

    func testOutlineSinglePixelIsUnitSquare() {
        // One selected pixel at (0,0); its outline is the 1×1 square, four corners.
        let grid: [UInt8] = [255, 0, 0,
                            0,   0, 0,
                            0,   0, 0]
        let loops = MaskTracing.outline(grid: grid, width: 3, height: 3, channels: 1, offset: 0, test: { $0 >= 128 })
        XCTAssertEqual(loops.count, 1)
        let corners = loops[0]
        XCTAssertEqual(corners.count, 4)
        let xs = Set(corners.map { $0.x }), ys = Set(corners.map { $0.y })
        XCTAssertEqual(xs, [0, 1])
        XCTAssertEqual(ys, [0, 1])
    }

    func testOutlineFullGridIsOneOuterLoop() {
        // Every pixel selected → one outer loop around the whole grid.
        let grid = [UInt8](repeating: 255, count: 9)
        let loops = MaskTracing.outline(grid: grid, width: 3, height: 3, channels: 1, offset: 0, test: { $0 >= 128 })
        XCTAssertEqual(loops.count, 1)
        let corners = loops[0]
        XCTAssertEqual(corners.count, 4)
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        XCTAssertEqual(minX, 0); XCTAssertEqual(maxX, 3)
        XCTAssertEqual(minY, 0); XCTAssertEqual(maxY, 3)
    }

    func testOutlineDropsStraightRunVertices() {
        // A 3×1 bar: the top and bottom edges run straight across three unit
        // segments; corner reduction keeps only the four rectangle corners.
        let grid: [UInt8] = [255, 255, 255,
                            0,   0,   0]
        let loops = MaskTracing.outline(grid: grid, width: 3, height: 2, channels: 1, offset: 0, test: { $0 >= 128 })
        XCTAssertEqual(loops.count, 1)
        let corners = loops[0]
        XCTAssertEqual(corners.count, 4)
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        XCTAssertEqual(minX, 0); XCTAssertEqual(maxX, 3)
        XCTAssertEqual(minY, 0); XCTAssertEqual(maxY, 1)
    }

    func testOutlineHoleProducesSeparateLoop() {
        // A 3×3 block with the center unselected: an outer loop plus a hole loop.
        let grid: [UInt8] = [255, 255, 255,
                            255, 0,   255,
                            255, 255, 255]
        let loops = MaskTracing.outline(grid: grid, width: 3, height: 3, channels: 1, offset: 0, test: { $0 >= 128 })
        XCTAssertEqual(loops.count, 2)
        // The hole is the 1×1 square around the center pixel: (1,1)-(2,1)-(2,2)-(1,2).
        let hole = loops.first { corners in
            Set(corners.map { $0.x }) == [1, 2] && Set(corners.map { $0.y }) == [1, 2]
        }
        XCTAssertNotNil(hole)
        XCTAssertEqual(hole?.count, 4)
    }

    func testOutlineReadsAlphaChannelOffset() {
        // RGBA grid: alpha is byte 3 of each pixel. A 3×1 row with opaque pixels at
        // the ends and a transparent pixel between them → two separate 1×1 loops.
        var grid = [UInt8](repeating: 0, count: 3 * 4) // 3 pixels × 4 channels
        grid[0 * 4 + 3] = 255  // pixel 0 alpha
        grid[2 * 4 + 3] = 255  // pixel 2 alpha
        let loops = MaskTracing.outline(grid: grid, width: 3, height: 1, channels: 4, offset: 3, test: { $0 >= 128 })
        XCTAssertEqual(loops.count, 2)
    }

    func testOutlineRejectsBadDimensions() {
        // Too-small buffer for the claimed dimensions → no loops, no crash.
        let grid: [UInt8] = [255, 0]
        XCTAssertTrue(MaskTracing.outline(grid: grid, width: 3, height: 3, channels: 1, offset: 0, test: { $0 >= 128 }).isEmpty)
    }

    // MARK: darkOutline / opaqueOutline

    func testDarkOutlineSelectsPixelsBelow128() {
        // 3×1 row: dark pixels (< 128) at the ends, a light pixel between → two loops.
        // 127 and 0 are dark; 128 is not (the threshold is strictly < 128).
        let grid: [UInt8] = [127, 128, 0]
        let loops = MaskTracing.darkOutline(grayGrid: grid, width: 3, height: 1)
        XCTAssertEqual(loops.count, 2)
    }

    func testOpaqueOutlineSelectsPixelsAtLeast128() {
        // 3×1 row: opaque pixels (>= 128) at the ends, a transparent pixel between → two loops.
        let grid: [UInt8] = [128, 127, 255]
        let loops = MaskTracing.opaqueOutline(alphaGrid: grid, width: 3, height: 1)
        XCTAssertEqual(loops.count, 2)
    }
}