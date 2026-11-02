import Foundation
import CoreGraphics
import CoreImage
import XCTest

final class NativeMotionAngularReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let width: Int
        let height: Int
        let cases: [Sample]
        let buffers: [String: Data]?
        struct Sample: Decodable {
            let fixture: String
            let radius: Double
            let degrees: Double
            let rgba: Data?
            let rgbaSHA256: String?
        }
    }

    func testMotionBlurMatchesNativeRotationSampling() throws {
        try check("coreimage-motion-angular-reference.json", count: 48)
    }

    func testSmallRadiiMatchNativeIdentityBoundaryAndRotation() throws {
        try check("coreimage-motion-small-radius-reference.json", count: 404)
    }

    func testSamplingOriginIsCapturedAndRestoredAfterGraphConstruction() throws {
        let width = 32, height = 24
        var pixels = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            pixels[x, y] = (UInt8((x * 37 + y * 13) % 256), UInt8(y * 10), 100, 255)
        } }
        let source = CIImage(cgImage: CGImage(pixels))
        let parameters: [String: Any] = [kCIInputRadiusKey: 2.0, kCIInputAngleKey: 0.47]
        let origin = CGPoint(x: 7, y: 5)
        let translation = CGAffineTransform(translationX: origin.x, y: origin.y)
        // An independently translated full-coordinate graph defines the sampling grid.
        let expected = source.transformed(by: translation).applyingFilter("CIMotionBlur", parameters: parameters)
            .transformed(by: translation.inverted())
        let ordinary = source.applyingFilter("CIMotionBlur", parameters: parameters)
        let scoped = CISpatialSampling.$origin.withValue(origin) {
            source.applyingFilter("CIMotionBlur", parameters: parameters)
        }
        XCTAssertEqual(CISpatialSampling.origin, .zero)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        func render(_ image: CIImage) throws -> [UInt8] {
            try XCTUnwrap(context.createCGImage(image, from: rect, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))).portableImage.bytes
        }
        let reference = try render(expected)
        XCTAssertNotEqual(try render(ordinary), reference)
        XCTAssertEqual(try render(scoped), reference)
        let later = try CISpatialSampling.$origin.withValue(CGPoint(x: -3, y: 11)) { try render(scoped) }
        XCTAssertEqual(later, reference, "Evaluation must retain the graph's origin, independent of its caller")
        XCTAssertEqual(try render(source.applyingFilter("CIMotionBlur", parameters: parameters)), try render(ordinary))
    }

    func testAngledFullHDMotionRemainsInteractive() throws {
        #if !DEBUG
        let width = 1920, height = 1080
        var pixels = PixelBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { pixels[x, y] = (UInt8(x % 251), UInt8(y % 251), 100, 255) } }
        let image = CIImage(cgImage: CGImage(pixels)).applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: 10 / sqrt(12.0), kCIInputAngleKey: Double.pi / 4,
        ])
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let start = Date()
        let result = try XCTUnwrap(context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.width, width)
        XCTAssertEqual(result.height, height)
        print("MOTION API 1920x1080 angle45: \(elapsed * 1000) ms")
        XCTAssertLessThan(elapsed, 0.5, "Angled Motion Blur must not monopolize the desktop for seconds")
        #endif
    }

    private func check(_ filename: String, count: Int) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(filename)
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, count)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let rect = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        for sample in reference.cases {
            var pixels = PixelBuffer(width: reference.width, height: reference.height)
            for y in 0..<reference.height { for x in 0..<reference.width {
                if sample.fixture == "opaque-gradient" {
                    pixels[x, y] = (UInt8(x * 255 / (reference.width - 1)), UInt8(y * 255 / (reference.height - 1)), 100, 255)
                } else {
                    XCTAssertEqual(sample.fixture, "impulse")
                    let value: UInt8 = x == reference.width / 2 && y == reference.height / 2 ? 255 : 0
                    pixels[x, y] = (value, value, value, value)
                }
            } }
            let image = CIImage(cgImage: CGImage(pixels)).applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: sample.radius, kCIInputAngleKey: sample.degrees * .pi / 180,
            ])
            let rendered = try XCTUnwrap(context.createCGImage(image, from: rect, format: .RGBA8,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
            let actual = rendered.portableImage.bytes
            let expected = [UInt8](try XCTUnwrap(sample.rgba ?? reference.buffers?[sample.rgbaSHA256 ?? ""]))
            XCTAssertEqual(actual.count, expected.count)
            let worst = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1, "Native \(sample.fixture), radius \(sample.radius), angle \(sample.degrees)")
        }
    }
}
