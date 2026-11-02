// Color management follows upstream's importer (Core Image into sRGB).

import CoreGraphics
import XCTest
import ImageIO
@testable import ImageIO

final class ColourManagementTests: XCTestCase {
    /// 4 x 2 PNG of (200, 100, 50) tagged Display P3, written by Qt; in sRGB that color is (215, 93, 31).
    private static let displayP3 = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAABMWlDQ1BEaXNwbGF5IFAzAAAYlWNgYHzDAAQsDgwMuXklRUHuTgoRkVEKDEggMbm4gAEv+HaNgRFEX9YNLGHjxq8WA3AVAS0E0n+AWCQdzGYUALGTIGwVELu8pKAEyLYAsZMLikBsHyBbKTkjMQXIBrlPpygkyBnIngNkK6QjsZOQ2CmpxclA9h4g2wDhz+a7DAy2+/7//78bIea1n4FhoznQeTsRYhrWDAyCQP+dOI0Q++wP9juj2KHcnNJkqJ9AIjypeaHBQJoNiGUY/Bj0GRwZGIrTjI0gKngcGBhY7/7//1mLgYF9EgPD3/7//38v+v//72IGBuZbDAwH2gsSixLBapmBmCktjYHh03IGBt5IBgbhC0B3ReOwTwRsnwtDJkMxQwFDDkMiQyWDAkMAgzEAQVxSw3QowgcAAAAJcEhZcwAADsQAAA7EAZUrDhsAAAATSURBVAiZYzyRYvSfAQkwMaABAEqeAmFK1If7AAAAAElFTkSuQmCC")!

    private func requireHostCodecs() throws {
        guard ImageCodecRegistry.host != nil || ProcessInfo.processInfo.environment["COMPOSITOR_IMAGEIO_BACKEND"] != nil else {
            throw XCTSkip("no host image codecs (COMPOSITOR_IMAGEIO_BACKEND)")
        }
    }

    func testAFileInAnotherProfileComesInAsSRGB() throws {
        try requireHostCodecs()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Self.displayP3 as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = image.portableImage.bytes
        XCTAssertEqual(Int(bytes[0]), 215, accuracy: 2, "red")
        XCTAssertEqual(Int(bytes[1]), 93, accuracy: 2, "green")
        XCTAssertEqual(Int(bytes[2]), 31, accuracy: 2, "blue")
    }

    func testAnUntaggedFileIsTakenAsSRGB() throws {
        try requireHostCodecs()
        // Independently constructed PNG: only IHDR, IDAT and IEND, with no color metadata.
        let data = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGM4kWL0H4QZYAwAVEAJdaZokMIAAAAASUVORK5CYII="))
        let image = try XCTUnwrap(ImageCodecRegistry.decode(data))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(Array(image.portableImage.bytes.prefix(4)), [200, 100, 50, 255])
    }

    func testExportsAreTaggedSRGB() throws {
        try requireHostCodecs()
        var buffer = PixelBuffer(width: 2, height: 2)
        for y in 0..<2 { for x in 0..<2 { buffer[x, y] = (10, 20, 30, 255) } }
        for type in ["public.png", "public.jpeg"] {
            let data = try XCTUnwrap(ImageCodecRegistry.encode(CGImage(buffer), typeIdentifier: type), type)
            // PNG says so with an sRGB/iCCP/cICP chunk, JPEG with an ICC_PROFILE marker.
            let tagged = data.range(of: Data("sRGB".utf8)) != nil || data.range(of: Data("iCCP".utf8)) != nil
                || data.range(of: Data("cICP".utf8)) != nil || data.range(of: Data("ICC_PROFILE".utf8)) != nil
            XCTAssertTrue(tagged, "\(type) carries no color profile")
        }
    }
}
