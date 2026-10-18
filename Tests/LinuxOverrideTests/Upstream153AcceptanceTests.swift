import Foundation
import CoreGraphics
import AppKit
import CompositorKernels
import Testing
@testable import Compositor

@MainActor
struct Upstream153AcceptanceTests {
    @Test func smoothedShapeDraftMatchesTheCommittedPixels() throws {
        let editor = UpstreamEditor()
        #expect(editor.importRGBA([UInt8](repeating: 0, count: 64 * 64 * 4), width: 64, height: 64,
                                  name: "Blank", replacing: true) == 0)
        let session = editor.session
        session.selectTool(.shape)
        session.shapeKind = .rectangle
        session.shapeCornerRadius = 12
        session.shapeSmoothing = true
        session.setPaletteColor(PaletteColor(red: 0, green: 0, blue: 1), background: false)
        let revision = session.history.currentRevision
        session.beginShape(at: CGPoint(x: 8, y: 8))
        session.dragShape(to: CGPoint(x: 56, y: 56), square: false, fromCenter: false)
        let preview = try editor.renderRGBA().bytes
        #expect(session.history.currentRevision == revision)
        session.finishShape()
        #expect(session.activeLayer?.shape?.style.smoothing == true)
        let committed = try editor.renderRGBA().bytes
        let difference = zip(preview, committed).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(difference <= 1, "The Linux live draft must use the same smoothed path as upstream's committed layer")
        session.undo()
        #expect(try editor.renderRGBA().bytes.allSatisfy { $0 == 0 })
        session.redo()
        #expect(try editor.renderRGBA().bytes == committed)
    }

    @Test func cameraRawSubmitsToHardwareWithOddPaddedRowsAndRecreatesDiscardedBuffers() throws {
        let lookup = try #require(MetalCameraRawLookup.shared)
        let table = try #require(CameraRawTables.identity())
        let width = 37, height = 19, stride = width * 4 + 3
        var initial = [UInt8](repeating: 173, count: stride * height)
        for y in 0..<height { for x in 0..<width {
            let at = y * stride + x * 4, alpha = (y * width + x) % 256
            initial[at] = UInt8(alpha); initial[at + 1] = UInt8(alpha / 2)
            initial[at + 2] = UInt8(alpha / 3); initial[at + 3] = UInt8(alpha)
        } }
        var expected = initial
        expected.withUnsafeMutableBufferPointer {
            adjust_camera_raw($0.baseAddress!, width, height, stride, table, 33, 0)
        }
        let before = lookup.submissions
        for _ in 0..<2 {
            var actual = initial
            #expect(actual.withUnsafeMutableBufferPointer {
                lookup.apply($0.baseAddress!, width: width, height: height, rowBytes: stride, table: table, grid: 33)
            })
            #expect(actual == expected)
            lookup.discardBuffers()
        }
        #expect(lookup.submissions == before + 2)
        print("Camera Raw Vulkan \(lookup.deviceName): two verified submissions, odd padded rows and buffer recreation")
    }

    @Test func clipConstraintUsesTheProposedViewportWithoutMutatingTheClip() {
        let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        clip.documentView = NSView(frame: CGRect(x: 10, y: 20, width: 300, height: 400))
        let original = clip.bounds
        #expect(clip.constrainBoundsRect(CGRect(x: -50, y: 900, width: 80, height: 60))
                == CGRect(x: 10, y: 360, width: 80, height: 60))
        #expect(clip.constrainBoundsRect(CGRect(x: 800, y: -50, width: 500, height: 500))
                == CGRect(x: 10, y: 20, width: 500, height: 500))
        #expect(clip.bounds == original)
    }
}
