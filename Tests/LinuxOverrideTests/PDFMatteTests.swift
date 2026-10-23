import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct PDFMatteTests {
    @Test(arguments: [72.0, 150.0], [false, true])
    func drawingExportedPagePreservesMatteAndAlpha(resolution: Double, hasMatte: Bool) async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let source = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 1, height: 4))
        source.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        source.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        let image = try #require(source.makeImage())
        let original = NSBitmapImageRep(cgImage: image)
        let partialY = try #require((0..<4).first { (original.colorAt(x: 1, y: $0)?.blueComponent ?? 0) > 0.99 })
        let sourceAlpha = try #require(original.colorAt(x: 1, y: partialY)).alphaComponent
        #expect(sourceAlpha > 0 && sourceAlpha < 1)
        let background = hasMatte ? CGColor(red: 0, green: 1, blue: 0, alpha: 1) : nil
        let data = try await ImageExporter.shared.pdfData(ExportRaster(image: image, resolution: resolution), background: background)
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let page = try #require(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width - 4 * 72 / resolution) < 0.000001)
        let rendered = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        rendered.interpolationQuality = .none
        rendered.scaleBy(x: 4 / box.width, y: 4 / box.height)
        rendered.drawPDFPage(page)
        let bitmap = NSBitmapImageRep(cgImage: try #require(rendered.makeImage()))
        let red = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(red.redComponent > 0.99 && red.alphaComponent == 1)
        let exterior = try #require(bitmap.colorAt(x: 3, y: 3))
        #expect(exterior.alphaComponent == (hasMatte ? 1 : 0))
        if hasMatte { #expect(exterior.greenComponent > 0.99 && exterior.redComponent == 0 && exterior.blueComponent == 0) }
        let partial = try #require(bitmap.colorAt(x: 1, y: partialY))
        #expect(abs(partial.alphaComponent - (hasMatte ? 1 : sourceAlpha)) <= 2 / 255.0)
        #expect(abs(partial.blueComponent - (hasMatte ? sourceAlpha : 1)) <= 2 / 255.0)
        #expect(abs(partial.greenComponent - (hasMatte ? 1 - sourceAlpha : 0)) <= 2 / 255.0)
    }
}
