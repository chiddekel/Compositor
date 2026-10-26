import Foundation
import CoreGraphics
import CoreImage
import Testing
@testable import Compositor

/// Opt-in single-render profiling; the original upstream canvas benchmark remains unchanged.
@MainActor
struct StarburstPerformanceTests {
    @Test func profileLargeStarburst() throws {
        guard let value = ProcessInfo.processInfo.environment["COMPOSITOR_STARBURST_PROFILE_WIDTH"],
              let width = Int(value), (400...4000).contains(width) else { return }
        let height = width * 13 / 20
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let bitmap = try BrushRaster.context(width: width, height: height, mask: false)
        bitmap.setFillColor(CGColor(srgbRed: 0.05, green: 0.06, blue: 0.1, alpha: 1))
        bitmap.fill(bounds)
        bitmap.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: width / 2, y: height / 2, width: max(2, width / 100), height: max(2, height / 100)))
        let image = CIImage(cgImage: try #require(bitmap.makeImage()))
        var settings = LensEffectSettings()
        settings.effect = .starburst
        let context = CIContext(options: [.workingColorSpace: NSNull(), .hardwareCanvas: true])
        if ProcessInfo.processInfo.environment["REQUIRE_COREIMAGE_VULKAN"] == "1" {
            #expect(context.gpuAvailable)
        }
        let start = CFAbsoluteTimeGetCurrent()
        let graph = try settings.apply(to: image, side: CGFloat(width))
        let output = try #require(context.createCGImage(graph, from: bounds))
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        #expect(output.width == width && output.height == height)
        Attachment.record("\(width)x\(height): \(milliseconds) ms; single direct Starburst render, hardware canvas context",
                          named: "starburst-profile.txt")
    }
}
