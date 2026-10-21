import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Game textures pack four grayscale maps into one image's red, green, blue and alpha (metallic, ambient occlusion,
/// detail and smoothness, say). Export As › Channel Pack writes one from layers, keeping a pixel's color where its
/// alpha is 0, which an ordinary image throws away (it stores color multiplied by alpha) but a packed texture needs.
nonisolated enum ChannelPack {
    enum Channel: String, CaseIterable, Sendable {
        case red = "Red", green = "Green", blue = "Blue", alpha = "Alpha"
        /// Layer names that pick a layer for this channel without being asked.
        var names: Set<String> {
            switch self {
            case .red: ["r", "red"]
            case .green: ["g", "green"]
            case .blue: ["b", "blue"]
            case .alpha: ["a", "alpha"]
            }
        }
    }

    /// What fills a channel: a layer or group, read as grayscale, or solid black or white.
    enum Source: Hashable, Sendable {
        case black, white
        case layer(UUID)
    }

    /// A channel's source when none has been chosen: a layer named for it (R, Red, …), otherwise black, or white for
    /// alpha, so an unused alpha leaves the texture opaque.
    static func defaultSource(for channel: Channel, in layers: [ProjectLayerRecord]) -> Source {
        let named = layers.last { channel.names.contains($0.name.trimmingCharacters(in: .whitespaces).lowercased()) }
        return named.map { .layer($0.id) } ?? (channel == .alpha ? .white : .black)
    }

    /// Four planes of `width` × `height` bytes as straight (not premultiplied) RGBA.
    static func interleave(_ planes: [[UInt8]], width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            for channel in 0..<4 { bytes[pixel * 4 + channel] = planes[channel][pixel] }
        }
        return bytes
    }

    /// Straight RGBA bytes as an image that keeps them as they are; `opaque` ignores the alpha, for showing the color
    /// channels on screen.
    static func image(_ bytes: [UInt8], width: Int, height: Int, opaque: Bool = false) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipLast : .last).rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ExportError.render }
        return image
    }

    /// A PNG of straight RGBA, so color under transparent pixels survives.
    static func png(_ image: CGImage, resolution: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.encode
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: resolution,
                                                        kCGImagePropertyDPIHeight: resolution] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }

    /// An image read as grayscale at `width` × `height`: drawn over black, so transparency counts as black, and weighed
    /// by how bright each color looks.
    static func gray(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw ExportError.render }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        var plane = [UInt8](repeating: 0, count: width * height)
        for pixel in 0..<(width * height) {
            let r = Double(data[pixel * 4]), g = Double(data[pixel * 4 + 1]), b = Double(data[pixel * 4 + 2])
            plane[pixel] = UInt8(min(255, (0.2126 * r + 0.7152 * g + 0.0722 * b).rounded()))
        }
        return plane
    }

    /// `snapshot` with only `id` showing: it and the groups it's in shown, the layers inside it as they are, every
    /// other layer hidden. A layer picked for a channel is used even when it's hidden in the document.
    static func isolating(_ id: UUID, in snapshot: ProjectSnapshot) -> ProjectSnapshot {
        let layers = snapshot.manifest.layers
        let parents = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0.parentID) })
        var ancestors: Set<UUID> = [id]
        var next = parents[id] ?? nil
        while let parent = next { ancestors.insert(parent); next = parents[parent] ?? nil }
        func isInside(_ layer: UUID) -> Bool {
            var next = parents[layer] ?? nil
            while let parent = next { if parent == id { return true }; next = parents[parent] ?? nil }
            return false
        }
        var manifest = snapshot.manifest
        for index in manifest.layers.indices {
            let layer = manifest.layers[index].id
            if ancestors.contains(layer) { manifest.layers[index].isVisible = true }
            else if !isInside(layer) { manifest.layers[index].isVisible = false }
        }
        return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
    }
}

extension ImageExporter {
    /// Export As › Channel Pack: each channel's source read as grayscale at `width` × `height`, packed into one PNG
    /// of straight RGBA, and its color channels to show (the alpha would hide them).
    func channelPack(_ snapshot: ProjectSnapshot, sources: [ChannelPack.Source], width: Int, height: Int)
        throws -> (data: Data, preview: CGImage) {
        guard sources.count == 4, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
        var planes: [[UInt8]] = []
        var rendered: [UUID: [UInt8]] = [:]
        for source in sources {
            try Task.checkCancellation()
            switch source {
            case .black: planes.append([UInt8](repeating: 0, count: width * height))
            case .white: planes.append([UInt8](repeating: 255, count: width * height))
            case .layer(let id):
                if let plane = rendered[id] { planes.append(plane); continue }
                let raster = try render(ChannelPack.isolating(id, in: snapshot))
                let plane = try ChannelPack.gray(raster.image, width: width, height: height)
                rendered[id] = plane
                planes.append(plane)
            }
        }
        let bytes = ChannelPack.interleave(planes, width: width, height: height)
        let resolution = snapshot.manifest.resolution ?? 72
        return (try ChannelPack.png(try ChannelPack.image(bytes, width: width, height: height), resolution: resolution),
                try ChannelPack.image(bytes, width: width, height: height, opaque: true))
    }
}
