import AppKit
import Testing
@testable import Compositor

@MainActor
struct EllipseSelectionBooleanTests {
    @Test func subtractingAnInteriorEllipseCreatesAnUnselectedHole() throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64, emptyLayer: true)
        session.selectionAntialiased = false
        session.applySelection(CGPath(ellipseIn: CGRect(x: 12, y: 12, width: 32, height: 24), transform: nil), mode: .replace, name: "Base")
        session.applySelection(CGPath(ellipseIn: CGRect(x: 20, y: 20, width: 32, height: 24), transform: nil), mode: .add, name: "Add")
        session.applySelection(CGPath(ellipseIn: CGRect(x: 16, y: 16, width: 20, height: 16), transform: nil), mode: .subtract, name: "Subtract")
        let selection = try #require(session.selection)
        #expect(!selection.path.contains(CGPoint(x: 26, y: 24), using: .evenOdd))
        #expect(!selection.path.contains(CGPoint(x: 23.5, y: 17.5), using: .winding))
        #expect(!selection.path.contains(CGPoint(x: 26, y: 24), using: .winding))
        #expect(selection.path.contains(CGPoint(x: 42, y: 32), using: .winding))
        let image = try selection.coverage(width: 64, height: 64)
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[(17 * 64 + 23) * 4] == 0)
        #expect(bytes[(24 * 64 + 26) * 4] == 0)
        #expect(bytes[(32 * 64 + 42) * 4] == 255)
    }
}
