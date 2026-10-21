import Accelerate
import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct ChannelPackTests {
    private func solid(_ gray: CGFloat, width: Int = 8, height: Int = 4) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// The first pixel of a PNG as written: straight RGBA, without multiplying color by alpha on the way.
    private func firstPixel(_ data: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                                          colorSpace: Unmanaged.passUnretained(CGColorSpace(name: CGColorSpace.sRGB)!),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          version: 0, decode: nil, renderingIntent: .defaultIntent)
        var buffer = vImage_Buffer()
        #expect(vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError)
        defer { free(buffer.data) }
        let bytes = buffer.data.assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { bytes[$0] }
    }

    private func document(alpha: CGFloat) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 8, height: 4)
        for (name, gray) in [("Red", 0.2), ("Green", 0.6), ("Blue", 1.0), ("Alpha", alpha)] {
            session.addPixelLayer(try solid(gray), at: .zero, name: name, editName: "Add")
        }
        return session
    }

    /// Layers named for their channels fill them without being picked, and a fully transparent alpha keeps the color
    /// under it, which an ordinary PNG would lose.
    @Test func layersNamedForChannelsPackIntoThemAndKeepColorUnderTransparency() async throws {
        let snapshot = try #require(try document(alpha: 0).projectSnapshot())
        let sources = ChannelPack.Channel.allCases.map { ChannelPack.defaultSource(for: $0, in: snapshot.manifest.layers) }
        #expect(sources.allSatisfy { if case .layer = $0 { true } else { false } })
        let packed = try await ImageExporter.shared.channelPack(snapshot, sources: sources, width: 8, height: 4)
        let pixel = try firstPixel(packed.data)
        #expect(abs(Int(pixel[0]) - 51) <= 1 && abs(Int(pixel[1]) - 153) <= 1 && pixel[2] == 255, "\(pixel)")
        #expect(pixel[3] == 0)
    }

    /// Solid sources, a hidden layer still used when it's picked, and a smaller size.
    @Test func blackWhiteAndHiddenLayersAtAnotherSize() async throws {
        let session = try document(alpha: 0.5)
        session.document!.layers[0].isVisible = false
        let snapshot = try #require(session.projectSnapshot())
        let red = snapshot.manifest.layers[0].id
        let packed = try await ImageExporter.shared.channelPack(snapshot, sources: [.layer(red), .black, .white, .white],
                                                                width: 4, height: 2)
        #expect(packed.preview.width == 4 && packed.preview.height == 2)
        let pixel = try firstPixel(packed.data)
        #expect(abs(Int(pixel[0]) - 51) <= 1 && pixel[1] == 0 && pixel[2] == 255 && pixel[3] == 255, "\(pixel)")
    }

    @Test func unnamedLayersLeaveColorBlackAndAlphaWhite() {
        let layers = [ProjectLayerRecord(id: UUID(), name: "Layer 1", isVisible: true,
                                         transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)), imageFile: nil)]
        #expect(ChannelPack.defaultSource(for: .red, in: layers) == .black)
        #expect(ChannelPack.defaultSource(for: .alpha, in: layers) == .white)
    }
}
