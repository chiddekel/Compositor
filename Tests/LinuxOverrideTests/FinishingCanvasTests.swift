import CoreGraphics
import CoreImage
import Testing
@testable import Compositor

@MainActor struct FinishingCanvasTests {
    @Test func vignetteTilesKeepDocumentCoordinatesAndAlpha() throws {
        let extent = CGRect(x: 10, y: 20, width: 80, height: 60)
        let image = CIImage(color: CIColor(red: 0.7, green: 0.5, blue: 0.3, alpha: 0.5)).cropped(to: extent)
        var settings = VignetteLayerSettings()
        settings.amount = 90
        settings.color = AdjustmentColor(red: 0.1, green: 0.2, blue: 0.8)
        let changed = try #require(MetalFinishing.vignette(image, canvas: extent, settings))
        let context = PixelAdjust.ciContext
        func read(_ rectangle: CGRect) throws -> [UInt8] {
            let output = try #require(context.createCGImage(changed, from: rectangle, format: .RGBA8,
                                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            let copy = try BrushRaster.copy(output)
            let data = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
            return (0..<output.height).flatMap { y in
                Array(UnsafeBufferPointer(start: data.advanced(by: y * copy.bytesPerRow), count: output.width * 4))
            }
        }
        let whole = try read(extent)
        // An off-center tile catches an origin reset and an inverted processor row direction.
        let tile = CGRect(x: 17, y: 29, width: 21, height: 13)
        let part = try read(tile)
        for y in 0..<13 { for x in 0..<21 { for c in 0..<4 {
            let fullIndex = ((60 - 9 - 13 + y) * 80 + 7 + x) * 4 + c
            #expect(part[(y * 21 + x) * 4 + c] == whole[fullIndex])
        } } }
        #expect(stride(from: 3, to: whole.count, by: 4).allSatisfy { abs(Int(whole[$0]) - 128) <= 1 })
        #expect(whole[0] != whole[(30 * 80 + 40) * 4], "vignette executes rather than returning the input")
    }
}
