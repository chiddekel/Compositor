// Tests for the guided-matte refinement raster (port of Compositor/Document/
// GuidedMatte.swift): the running-sum box mean, the He/Sun/Tang guided filter over
// synthetic edges, gray-level extraction from the canonical raster, the gray image
// round trip, and the scaled refine pipeline (shrink-filter-grow). Pin the unchanged
// macOS kernel math on Linux. Run in-sandbox: swift test.

import XCTest
@testable import CompositorCore

final class GuidedMatteTests: XCTestCase {

    private func naiveBox(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0, count = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let px = min(width - 1, max(0, x + dx)), py = min(height - 1, max(0, y + dy))
                        sum += source[py * width + px]
                        count += 1
                    }
                }
                out[y * width + x] = sum / Float(count)
            }
        }
        return out
    }

    func testBoxMatchesNaiveMean() {
        var source = [Float](repeating: 0, count: 7 * 5)
        for i in 0..<source.count { source[i] = Float((i * 37) % 101) / 100 }
        for radius in [0, 1, 2, 5] {
            let fast = GuidedMatte.box(source, width: 7, height: 5, radius: radius)
            let slow = naiveBox(source, width: 7, height: 5, radius: radius)
            for i in 0..<source.count {
                XCTAssertEqual(fast[i], slow[i], accuracy: 0.0001, "radius \(radius) differs at \(i)")
            }
        }
    }

    func testBoxClampsAtEdges() {
        // The running sum (macOS C semantics) pre-fills the radius window at the row
        // start and slides one column at a time, so the clamped edge pattern is
        // asymmetric: window x=0 reads (0, 0, 0, 1, 2) → 0.2 and the tail slides in
        // src[clamp(3)] once more. Pin the exact profile.
        let source: [Float] = [0, 1, 0, 1, 0]
        let out = GuidedMatte.box(source, width: 5, height: 1, radius: 2)
        XCTAssertEqual(out.count, 5)
        for (i, v) in out.enumerated() {
            XCTAssertEqual(v, [0.2, 0.4, 0.4, 0.4, 0.2][i], accuracy: 0.0001, "column \(i)")
        }
    }

    func testFilterIsIdentityOnFlatGuide() {
        // Slope 0 wherever the guide is flat, so a flat mask comes back unchanged.
        let mask = [Float](repeating: 0.6, count: 9)
        let guide = [Float](repeating: 0.4, count: 9)
        let out = GuidedMatte.filter(mask: mask, guide: guide, width: 3, height: 3, radius: 1, epsilon: 1e-4)
        for v in out { XCTAssertEqual(v, 0.6, accuracy: 0.001) }
    }

    func testFilterPreservesMaskAlignedWithGuide() {
        // With the mask equal to the guide, covariance equals variance, so the filter
        // reproduces the guide: both flat plateaus stay put and the transition keeps a
        // smooth edge rather than a hard clip.
        let width = 16, height = 1
        var mask = [Float](repeating: 0, count: width)
        for x in 0..<width { mask[x] = x < 8 ? 0.1 : 0.9 }
        let out = GuidedMatte.filter(mask: mask, guide: mask, width: width, height: height, radius: 2, epsilon: 1e-4)
        for x in 0..<width {
            if x < 6 { XCTAssertEqual(out[x], 0.1, accuracy: 0.01, "left plateau at \(x)") }
            if x > 9 { XCTAssertEqual(out[x], 0.9, accuracy: 0.01, "right plateau at \(x)") }
            XCTAssertGreaterThanOrEqual(out[x], 0)
            XCTAssertLessThanOrEqual(out[x], 1)
        }
        // The transition stays monotonic and keeps slope: a guided edge pulls the
        // mask along it instead of snapping.
        XCTAssertGreaterThan(out[7], out[6])
        XCTAssertGreaterThan(out[8], out[7])
    }

    func testFlatMaskStaysFlatAwayFromGuideEdge() {
        // A flat mask only moves near the guide's edge (where variance is nonzero);
        // the plateaus keep the mask's own level.
        let width = 16, height = 1
        let mask = [Float](repeating: 0.5, count: width)
        var guide = [Float](repeating: 0, count: width)
        for x in 0..<width { guide[x] = x < 8 ? 0.1 : 0.9 }
        let out = GuidedMatte.filter(mask: mask, guide: guide, width: width, height: height, radius: 1, epsilon: 1e-4)
        for x in [0, 2, 5, 7, 10, 13, 15] {
            XCTAssertEqual(out[x], 0.5, accuracy: 0.05, "mask level kept at \(x)")
        }
    }

    func testLevelsExtractLumaAndPremultiply() throws {
        // Opaque pure red → Rec.709 luma 0.2126. Opaque pure green → 0.7152.
        let red = RasterImage(PortableImage(PixelBuffer(width: 1, height: 1, bytes: [255, 0, 0, 255])))
        let green = RasterImage(PortableImage(PixelBuffer(width: 1, height: 1, bytes: [0, 255, 0, 255])))
        let redLevel = try XCTUnwrap(try GuidedMatte.levels(of: red, width: 1, height: 1).first)
        let greenLevel = try XCTUnwrap(try GuidedMatte.levels(of: green, width: 1, height: 1).first)
        XCTAssertEqual(redLevel, 0.2126, accuracy: 0.01)
        XCTAssertEqual(greenLevel, 0.7152, accuracy: 0.01)
    }

    func testLevelsDownsampleAverages() throws {
        // 2×2 of two whites and two blacks averages to 0.5 gray at 1×1.
        let img = RasterImage(PortableImage(PixelBuffer(width: 2, height: 2, bytes: [
            255, 255, 255, 255, 0, 0, 0, 255,
            0, 0, 0, 255, 255, 255, 255, 255])))
        let level = try XCTUnwrap(try GuidedMatte.levels(of: img, width: 1, height: 1).first)
        XCTAssertEqual(level, 0.5, accuracy: 0.01)
    }

    func testImageRoundTrip() throws {
        let levels: [Float] = [0, 0.5, 1]
        let img = try GuidedMatte.image(levels, width: 3, height: 1)
        XCTAssertEqual(img.kind, .rgba)
        XCTAssertEqual(Int(img.bytes[0]), 0)
        XCTAssertEqual(Int(img.bytes[4]), 128)   // 0.5 * 255 + 0.5 = 128.0 → 128
        XCTAssertEqual(Int(img.bytes[8]), 255)
        XCTAssertEqual(Int(img.bytes[3]), 255)   // opaque
    }

    func testRefineAtFullSizeMatchesSmallGuide() throws {
        // limit ≥ full size: no scaling, so every output pixel is the guided-filtered
        // level, clamped to 0–1 with the guide's structure intact.
        let width = 8, height = 8
        var maskBytes = [UInt8](repeating: 128, count: width * height * 4)
        for i in stride(from: 3, to: maskBytes.count, by: 4) { maskBytes[i] = 255 }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let at = (y * width + x) * 4
            let v = UInt8(x * 255 / (width - 1))
            bytes[at] = v; bytes[at + 1] = v; bytes[at + 2] = v; bytes[at + 3] = 255
        } }
        // The mask equals the guide, so refinement reproduces the ramp's own levels.
        let mask = RasterImage(PortableImage(PixelBuffer(width: width, height: height, bytes: bytes)))
        let guide = RasterImage(PortableImage(PixelBuffer(width: width, height: height, bytes: bytes)))
        let out = try GuidedMatte.refine(mask: mask, guide: guide, radius: 2, limit: 1000)
        let pixels = out.pixels
        XCTAssertEqual(pixels.width, width)
        XCTAssertEqual(pixels.height, height)
        // Both ends keep the guide's levels and the middle tracks the ramp.
        XCTAssertEqual(Int(pixels.bytes[0]), 0, accuracy: 8)
        XCTAssertEqual(Int(pixels.bytes[(7 * width + 7) * 4]), 255, accuracy: 8)
        let midY = 3, midX = 4
        let expected = midX * 255 / (width - 1)
        XCTAssertEqual(Int(pixels.bytes[(midY * width + midX) * 4]), expected, accuracy: 24)
    }

    func testRefineShrinkGrowKeepsFullSize() throws {
        // limit smaller than the mask: the pipeline refines a small copy and draws it
        // back up at full resolution, still returning a full-size mask.
        let width = 12, height = 8
        func solid(_ gray: UInt8) -> RasterImage {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i] = gray; bytes[i + 1] = gray; bytes[i + 2] = gray; bytes[i + 3] = 255 }
            return RasterImage(PortableImage(PixelBuffer(width: width, height: height, bytes: bytes)))
        }
        var gb = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let at = (y * width + x) * 4
            let v = UInt8(x < 6 ? 32 : 224)
            gb[at] = v; gb[at + 1] = v; gb[at + 2] = v; gb[at + 3] = 255
        } }
        let mask = RasterImage(PortableImage(PixelBuffer(width: width, height: height, bytes: gb)))
        let guide = RasterImage(PortableImage(PixelBuffer(width: width, height: height, bytes: gb)))
        let out = try GuidedMatte.refine(mask: mask, guide: guide, radius: 3, limit: 4)
        XCTAssertEqual(out.pixels.width, width)
        XCTAssertEqual(out.pixels.height, height)
        // Left and right halves split along the guide edge.
        let left = Int(out.pixels.bytes[(3 * width + 1) * 4])
        let right = Int(out.pixels.bytes[(3 * width + 10) * 4])
        XCTAssertLessThan(left, 96)
        XCTAssertGreaterThan(right, 160)
    }
}