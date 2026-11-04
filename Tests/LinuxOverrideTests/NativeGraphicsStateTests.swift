import CoreGraphics
@testable import AppKit
@testable import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct NativeGraphicsStateTests {
    private final class Block: NSView {
        var color = NSColor.red
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: CGRect) {
            color.setFill()
            NSGraphicsContext.current?.cgContext.fill(bounds)
        }
    }

    @Test func switchingCurrentContextsRestoresOnlyTheSavedContextsState() {
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        let first = CGContext(width: 20, height: 20), second = CGContext(width: 20, height: 20)
        first.translateBy(x: 3, y: 4)
        second.saveGState(); second.translateBy(x: 8, y: 9)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: first, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        first.translateBy(x: 5, y: 6)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: second, flipped: true)
        NSGraphicsContext.restoreGraphicsState()
        #expect(NSGraphicsContext.current?.cgContext === first)
        #expect(first.ctm.tx == 3 && first.ctm.ty == 4)
        #expect(second.ctm.tx == 8 && second.ctm.ty == 9)
        second.restoreGState()
        #expect(second.ctm.tx == 0 && second.ctm.ty == 0)
        NSGraphicsContext.current = nil
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: second, flipped: true)
        second.saveGState(); second.translateBy(x: 7, y: 2)
        NSGraphicsContext.restoreGraphicsState()
        #expect(NSGraphicsContext.current == nil && second.ctm.tx == 7 && second.ctm.ty == 2)
        second.restoreGState()
    }

    @Test func withTopDownSpaceMarksUnflippedDrawingAsFlipped() {
        // Unflipped NSTextField / labels invert the CTM in withTopDownSpace; isFlipped must follow so
        // TextBackend glyph images (keyed off the flag) stay upright — layer names were upside down.
        final class Probe: NSView {
            var sawFlipped: Bool?
            override func draw(_ dirtyRect: CGRect) {
                withTopDownSpace { _ in sawFlipped = NSGraphicsContext.current?.isFlipped }
            }
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nil
        defer { NSGraphicsContext.current = previous }
        let probe = Probe(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        #expect(probe.isFlipped == false)
        _ = NativeLowering.picture(of: probe, size: probe.frame.size)
        #expect(probe.sawFlipped == true)
    }

    @Test func unflippedLabelKeepsGlyphImageTopAtTop() throws {
        // Layer-name path: unflipped NSTextField → withTopDownSpace → NSString/NSLayoutManager draws a
        // TextBackend CGImage, flipping only when isFlipped. A top-heavy glyph image must stay top-heavy
        // in the NativeLowering bitmap; upside-down names put that ink in the bottom half.
        final class GlyphLabel: NSView {
            override func draw(_ dirtyRect: CGRect) {
                withTopDownSpace { context in
                    let width = 24, height = 24
                    guard let bitmap = CGContext(
                        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ), let data = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return }
                    // PortableImage / makeImage rows are top-down: row 0 is the top of the glyph.
                    // Mark only the top third opaque (low y in the pixel buffer).
                    for y in 0..<height {
                        for x in 0..<width {
                            let i = (y * width + x) * 4
                            let topThird = y < height / 3
                            let a: UInt8 = topThird ? 255 : 0
                            data[i] = a; data[i + 1] = a; data[i + 2] = a; data[i + 3] = a
                        }
                    }
                    guard let picture = bitmap.makeImage() else { return }
                    let rect = CGRect(x: 8, y: 8, width: 24, height: 24)
                    context.saveGState()
                    if NSGraphicsContext.current?.isFlipped == true {
                        context.translateBy(x: 0, y: rect.minY + rect.maxY)
                        context.scaleBy(x: 1, y: -1)
                    }
                    context.draw(picture, in: rect)
                    context.restoreGState()
                }
            }
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nil
        defer { NSGraphicsContext.current = previous }
        let label = GlyphLabel(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        #expect(label.isFlipped == false)
        let image = try #require(NativeLowering.picture(of: label, size: label.frame.size))
        let bytes = [UInt8](try #require(image.dataProvider?.data) as Data)
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            bytes[y * image.bytesPerRow + x * 4 + 3]
        }
        // NativeLowering.picture is top-left based: small y is the top of the label.
        var topInk = 0, bottomInk = 0
        for y in 0..<image.height {
            for x in 0..<image.width where alpha(x, y) > 128 {
                if y < image.height / 2 { topInk += 1 } else { bottomInk += 1 }
            }
        }
        #expect(topInk > 0, "glyph ink missing from the painted label")
        #expect(topInk > bottomInk * 2, "layer-name glyph image painted upside down (top=\(topInk) bottom=\(bottomInk))")
        #expect(NSGraphicsContext.current == nil)
    }

    @Test func nestedViewDrawingPreservesDistinctRowPositionsAndClips() throws {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nil
        defer { NSGraphicsContext.current = previous }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        let upper = Block(frame: CGRect(x: 5, y: 45, width: 20, height: 20))
        let lower = Block(frame: CGRect(x: 40, y: 10, width: 20, height: 20)); lower.color = .blue
        root.addSubview(upper); root.addSubview(lower)
        let image = try #require(NativeLowering.picture(of: root, size: root.frame.size))
        let data = try #require(image.dataProvider?.data) as Data
        let bytes = [UInt8](data)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let start = y * image.bytesPerRow + x * 4
            return Array(bytes[start..<start + 4])
        }
        #expect(pixel(10, 20) == [255, 0, 0, 255])
        #expect(pixel(45, 55) == [0, 0, 255, 255])
        #expect(pixel(10, 55)[3] == 0 && pixel(45, 20)[3] == 0)
        #expect(pixel(2, 20)[3] == 0 && pixel(63, 55)[3] == 0)
        #expect(NSGraphicsContext.current == nil)
    }
}
