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
    /// Native pixel bytes, top-left rows. Float textures contain four IEEE Float32 samples per texel.
    public var rgbaBytes: [UInt8]
    public var bytesPerPixel: Int { pixelFormat == .rgba32Float ? 16 : pixelFormat == .r8Unorm ? 1 : 4 }

    public init(descriptor: MTLTextureDescriptor) {
        width = descriptor.width
        height = descriptor.height
        pixelFormat = descriptor.pixelFormat
        usage = descriptor.usage
        let bpp = pixelFormat == .rgba32Float ? 16 : pixelFormat == .r8Unorm ? 1 : 4
        rgbaBytes = [UInt8](repeating: 0, count: max(1, width * height * bpp))
    }

    public init(proxyWidth: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba32Float, usage: MTLTextureUsage = []) {
        self.width = proxyWidth
        self.height = height
        self.pixelFormat = pixelFormat
        self.usage = usage
        self.rgbaBytes = []
    }

    public func getBytes(_ pointer: UnsafeMutableRawPointer, bytesPerRow: Int, from region: MTLRegion, mipmapLevel: Int) {
        _ = mipmapLevel
        let bpp = bytesPerPixel
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
        let bpp = bytesPerPixel
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

public final class MTLCompileOptions: @unchecked Sendable {
    public init() {}
}

public final class MTLFunction: @unchecked Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public final class MTLLibrary: @unchecked Sendable {
    public let source: String
    public init(source: String) { self.source = source }
    public func makeFunction(name: String) -> MTLFunction? { MTLFunction(name: name) }
}

public final class MTLComputePipelineState: @unchecked Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public final class MTLComputeCommandEncoder {
    public private(set) var pipeline: MTLComputePipelineState?
    public private(set) var textures: [Int: MTLTexture] = [:]
    public private(set) var bytes: [Int: Data] = [:]
    public private(set) var threadgroupsPerGrid: MTLSize?
    public private(set) var threadsPerThreadgroup: MTLSize?
    public private(set) var ended = false

    public init() {}
    public func setComputePipelineState(_ state: MTLComputePipelineState) { pipeline = state }
    public func setTexture(_ texture: MTLTexture?, index: Int) { textures[index] = texture }
    public func setBytes(_ pointer: UnsafeRawPointer, length: Int, index: Int) {
        bytes[index] = Data(bytes: pointer, count: max(0, length))
    }
    public func dispatchThreadgroups(_ threadgroupsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        self.threadgroupsPerGrid = threadgroupsPerGrid
        self.threadsPerThreadgroup = threadsPerThreadgroup
    }
    public func dispatchThreads(_ threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        dispatchThreadgroups(MTLSize(width: (threadsPerGrid.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                                    height: (threadsPerGrid.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
                                    depth: threadsPerGrid.depth), threadsPerThreadgroup: threadsPerThreadgroup)
    }
    public func endEncoding() { ended = true }
}

public enum MTLCommandBufferStatus { case notEnqueued, committed, completed, error }

public final class MTLCommandBuffer {
    public private(set) var computeEncoders: [MTLComputeCommandEncoder] = []
    public private(set) var status: MTLCommandBufferStatus = .notEnqueued
    public private(set) var error: Error?
    public init() {}
    public func makeComputeCommandEncoder() -> MTLComputeCommandEncoder? {
        let encoder = MTLComputeCommandEncoder()
        computeEncoders.append(encoder)
        return encoder
    }
    public func commit() {
        status = .committed
        do {
            for encoder in computeEncoders { try MetalCompute.execute(encoder) }
            status = .completed
        } catch {
            self.error = error
            status = .error
        }
    }
    public func waitUntilCompleted() {}
    public func waitUntilScheduled() {}
}

public final class MTLCommandQueue {
    public init() {}
    public func makeCommandBuffer() -> MTLCommandBuffer? { MTLCommandBuffer() }
}

public final class MTLDevice: @unchecked Sendable {
    public init() {}
    public func makeTexture(descriptor: MTLTextureDescriptor) -> MTLTexture? { MTLTexture(descriptor: descriptor) }
    public func makeCommandQueue() -> MTLCommandQueue? { MTLCommandQueue() }
    public func makeLibrary(source: String, options: MTLCompileOptions?) throws -> MTLLibrary {
        _ = options
        return MTLLibrary(source: source)
    }
    public func makeComputePipelineState(function: MTLFunction) throws -> MTLComputePipelineState {
        MTLComputePipelineState(name: function.name)
    }
}

public func MTLCreateSystemDefaultDevice() -> MTLDevice? { MTLDevice() }
