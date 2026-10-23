import Foundation
import Testing
@testable import Compositor

@MainActor
struct WarpTipCacheTests {
    @Test(arguments: [BlurToolMode.liquify, .smudge], [31.5, 256.0, 514.0])
    func cachedTipMatchesUpstreamStrokeExactly(mode: BlurToolMode, diameter: Double) throws {
        let width = 240, height = 180
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8(x % 64); bytes[offset + 1] = UInt8(y % 64)
            bytes[offset + 2] = UInt8((x + y) % 64); bytes[offset + 3] = UInt8(64 + (x * y) % 192)
        } }
        let editor = UpstreamEditor()
        #expect(editor.importRGBA(bytes, width: width, height: height, name: "Pattern", replacing: true) == 0)
        let layer = try #require(editor.session.activeLayer)
        let image = try #require(layer.asset?.image)
        for hardness in [0.0, 0.5, 0.98] {
            var settings = BrushSettings()
            settings.diameter = diameter; settings.hardness = hardness; settings.opacity = 0.7
            let canvas = CGSize(width: width, height: height)
            let actual = try WarpStroke(layer: layer, image: image, transform: layer.transform,
                canvas: canvas, mode: mode, settings: settings)
            let expected = try ReferenceWarpStroke(layer: layer, image: image, transform: layer.transform,
                canvas: canvas, mode: mode, settings: settings)
            for point in [CGPoint(x: 20, y: 20), CGPoint(x: 160, y: 95), CGPoint(x: 155, y: 120),
                          CGPoint(x: 250, y: 185), CGPoint(x: -12, y: -4)] {
                actual.append(point); expected.append(point)
                #expect(actual.points == expected.points)
                let left = try #require(actual.image).bytes, right = try #require(expected.image).bytes
                #expect(left == right)
            }
        }
    }
}
