// A native decoder preflight for the shared synthetic DNG fixtures, before the expensive app build.
import CoreImage
import CoreGraphics
import Foundation
import Metal

if #available(macOS 26.0, *) {
    print("RAW fixture device: \(MTLCreateSystemDefaultDevice()?.name ?? "none")")
    let context = CIContext(options: [.useSoftwareRenderer: false, .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    var failures = 0
    for path in CommandLine.arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        guard let filter = CIRAWFilter(imageURL: url) else {
            print("RAW fixture metadata rejected: \(url.lastPathComponent)")
            failures += 1
            continue
        }
        let temperature = filter.neutralTemperature, tint = filter.neutralTint
        print("RAW fixture \(url.lastPathComponent): native=\(filter.nativeSize) temperature=\(temperature) tint=\(tint)")
        filter.exposure = 0
        filter.neutralTemperature = temperature
        filter.neutralTint = tint
        filter.boostAmount = 1
        guard let output = filter.outputImage,
              let image = context.createCGImage(output, from: output.extent.integral, format: .RGBA16,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              image.width > 0, image.height > 0 else {
            print("RAW fixture development rejected: \(url.lastPathComponent)")
            failures += 1
            continue
        }
        print("RAW fixture development OK: \(url.lastPathComponent) \(image.width)x\(image.height)")
    }
    exit(CommandLine.arguments.count > 1 && failures == 0 ? 0 : 1)
} else {
    print("The parity oracle requires macOS 26, matching the upstream app deployment target.")
    exit(1)
}
