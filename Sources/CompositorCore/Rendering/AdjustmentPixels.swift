import Foundation
import CompositorKernels

extension LayerAdjustment {
    func apply(_ image: PortableImage) throws -> PortableImage {
        guard isValid, image.kind == .rgba else { throw ProjectError.invalid }
        switch kind {
        case .curves: return try curves.apply(image)
        case .exposure: return try exposure.apply(image)
        case .gradientMap: return try gradientMap.apply(image)
        case .grain: return try grain.apply(image)
        case .levels:
            let channels: [LevelsChannel] = [.red, .green, .blue]
            let table = channels.flatMap { channel in (0...255).map { Float(levels.apply(Double($0) / 255, channel: channel)) } }
            var bytes = image.bytes
            bytes.withUnsafeMutableBufferPointer { levels_apply($0.baseAddress!, image.width * image.height, table) }
            return PortableImage(PixelBuffer(width: image.width, height: image.height, bytes: bytes))
        case .hsv:
            if resolvedHSV.isIdentity { return image }
            let settings = resolvedHSV
            let response = HueSaturationFilter.hueResponse(settings)
            var pixels = image.bytes
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Double(pixels[i + 3])
                guard alpha > 0 else { continue }
                let adjusted = HueSaturationFilter.adjust(red: Double(pixels[i]) / alpha,
                    green: Double(pixels[i + 1]) / alpha, blue: Double(pixels[i + 2]) / alpha,
                    settings: settings, response: response)
                pixels[i] = UInt8(min(alpha, max(0, adjusted.red * alpha)).rounded())
                pixels[i + 1] = UInt8(min(alpha, max(0, adjusted.green * alpha)).rounded())
                pixels[i + 2] = UInt8(min(alpha, max(0, adjusted.blue * alpha)).rounded())
            }
            return PortableImage(PixelBuffer(width: image.width, height: image.height, bytes: pixels))
        }
    }
}
