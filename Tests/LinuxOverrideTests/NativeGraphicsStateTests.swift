import AppKit
import CoreGraphics
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
