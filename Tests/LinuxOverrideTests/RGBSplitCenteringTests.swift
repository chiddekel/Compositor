import CoreGraphics
import Testing
@testable import Compositor

struct RGBSplitCenteringTests {
    @Test(arguments: [0.0, 90.0])
    func upstreamFilterBlursBothWaysWithoutMovingTheLight(angle: Double) throws {
        let size = 61
        let source = try BrushRaster.context(width: size, height: size, mask: false)
        source.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        source.fill(CGRect(x: 28, y: 28, width: 5, height: 5))
        var settings = FilterSettings()
        settings.rgbSplitDistance = 0
        settings.rgbSplitBlur = 16
        settings.rgbSplitAngle = angle
        let image = try PixelFilter.run(FilterJob(kind: .rgbSplit, image: #require(source.makeImage()),
            settings: settings, scale: 1, selection: nil, mapping: .identity))
        let rendered = try BrushRaster.context(width: size, height: size, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size), mask: false, context: rendered)
        let bytes = try #require(rendered.data).assumingMemoryBound(to: UInt8.self)
        let weights = (0..<size).map { position -> Double in
            let x = angle == 0 ? position : 30, y = angle == 0 ? 30 : position
            return Double(bytes[y * rendered.bytesPerRow + x * 4 + 3])
        }
        let total = weights.reduce(0, +)
        #expect(total > 0)
        let centroid = weights.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element } / max(1, total)
        #expect(abs(centroid - 30) < 1, "The light stays centered, not displaced along the blur")
        #expect(weights[20..<28].reduce(0, +) > 0)
        #expect(weights[33..<41].reduce(0, +) > 0)
        #expect(weights[44...48].reduce(0, +) == 0, "A centered 16-pixel blur does not have a 16-pixel trailing reach")
    }
}
