// Metal API surface for Linux: enough for GPUCanvasTests and tip-shaped GPU canvas code that still
// references MTL types. Backed by CPU buffers (Metal → Vulkan/CI path; no real MTLDevice).

import Foundation
import CoreGraphics

public enum MTLPixelFormat: Int {
    case rgba8Unorm = 70
    case bgra8Unorm = 80
    case r8Unorm = 10
    case rgba32Float = 125
}

public struct MTLRegion {
    public var origin: (x: Int, y: Int, z: Int)
    public var size: (width: Int, height: Int, depth: Int)
}

public func MTLRegionMake2D(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> MTLRegion {
    MTLRegion(origin: (x, y, 0), size: (w, h, 1))
}

public struct MTLOrigin {
    public var x: Int, y: Int, z: Int
    public init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }
}
public struct MTLSize {
    public var width: Int, height: Int, depth: Int
    public init(width: Int, height: Int, depth: Int) { self.width = width; self.height = height; self.depth = depth }
}

public final class MTLTextureDescriptor {
    public var pixelFormat: MTLPixelFormat = .rgba8Unorm
    public var width = 1
    public var height = 1
    public var usage: MTLTextureUsage = []
    public var storageMode: MTLStorageMode = .shared
    public static func texture2DDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int, mipmapped: Bool) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor()
        d.pixelFormat = pixelFormat; d.width = width; d.height = height
        _ = mipmapped
        return d
    }
}

public struct MTLTextureUsage: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let shaderRead = MTLTextureUsage(rawValue: 1)
    public static let shaderWrite = MTLTextureUsage(rawValue: 2)
    public static let renderTarget = MTLTextureUsage(rawValue: 4)
}

public enum MTLStorageMode: Int { case shared = 0, `private` = 1 }

public final class MTLTexture {
    public let width: Int
    public let height: Int
    public let pixelFormat: MTLPixelFormat
    public var usage: MTLTextureUsage
    /// Premultiplied RGBA8 (or R8), top-left rows — writable by CIContext.render on Linux.
    public var rgbaBytes: [UInt8]

    public init(descriptor: MTLTextureDescriptor) {
        width = descriptor.width
        height = descriptor.height
        pixelFormat = descriptor.pixelFormat
        usage = descriptor.usage
        let bpp = pixelFormat == .r8Unorm ? 1 : 4
        rgbaBytes = [UInt8](repeating: 0, count: max(1, width * height * bpp))
    }

    public func getBytes(_ pointer: UnsafeMutableRawPointer, bytesPerRow: Int, from region: MTLRegion, mipmapLevel: Int) {
        _ = mipmapLevel
        let bpp = pixelFormat == .r8Unorm ? 1 : 4
        let srcRow = width * bpp
        rgbaBytes.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            for row in 0..<region.size.height {
                let s = (region.origin.y + row) * srcRow + region.origin.x * bpp
                let d = row * bytesPerRow
                memcpy(pointer.advanced(by: d), base.advanced(by: s), region.size.width * bpp)
            }
        }
    }

    public func replace(region: MTLRegion, mipmapLevel: Int, withBytes pointer: UnsafeRawPointer, bytesPerRow: Int) {
        _ = mipmapLevel
        let bpp = pixelFormat == .r8Unorm ? 1 : 4
        let dstRow = width * bpp
        rgbaBytes.withUnsafeMutableBytes { dest in
            guard let base = dest.baseAddress else { return }
            for row in 0..<region.size.height {
                let d = (region.origin.y + row) * dstRow + region.origin.x * bpp
                let s = row * bytesPerRow
                memcpy(base.advanced(by: d), pointer.advanced(by: s), region.size.width * bpp)
            }
        }
    }
}

public final class MTLCommandBuffer {
    public init() {}
    public func commit() {}
    public func waitUntilCompleted() {}
    public func waitUntilScheduled() {}
}

public final class MTLCommandQueue {
    public init() {}
    public func makeCommandBuffer() -> MTLCommandBuffer? { MTLCommandBuffer() }
}

public final class MTLDevice {
    public init() {}
    public func makeTexture(descriptor: MTLTextureDescriptor) -> MTLTexture? { MTLTexture(descriptor: descriptor) }
    public func makeCommandQueue() -> MTLCommandQueue? { MTLCommandQueue() }
}

public func MTLCreateSystemDefaultDevice() -> MTLDevice? { MTLDevice() }
