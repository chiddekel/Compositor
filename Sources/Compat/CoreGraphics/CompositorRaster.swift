// CompositorRaster — portable canonical pixel buffers for the Linux core.
//
// The macOS app stores pixels in CGImage / CGContext. Foundation on Linux has no
// raster image types, so this file provides the storage substrate the file-map
// "Keep logic; replace Apple operations" and "Apple replacement/adaptation" tiers
// build on: an immutable image value (`PortableImage`) backed by the canonical
// tile contract, and the mutable buffers it is built from.
//
// Canonical contract (see docs/linux-port-plan.md and include/CompositorCore.h):
//   - 8-bit premultiplied RGBA, channel byte order R,G,B,A
//   - stride == width * 4 (no padding)
//   - separate 8-bit grayscale coverage/mask buffer, stride == width
//   - immutable committed tiles; mutation produces a new buffer
//
// Scope: storage and rectangular cropping only. The full 2D drawing API
// (fill/stroke/paths/gradients/blend modes/transparency layers that CGContext
// provides) is a later, Skia-backed milestone — it is not reimplemented here. The
// pixel-math and document-model layers that use an image as storage (width,
// height, bytesPerRow, bytes, cropping) are unblocked by this substrate.
//
// SOLID: buffers are value types with a single responsibility (owning pixels); the
// immutable `PortableImage` surface (ISP) lets higher layers depend on the
// contract, not the backing (DIP). Foundation-only; builds on Linux via SwiftPM.

import Foundation

/// Mutable 8-bit premultiplied RGBA buffer, canonical contract (stride == width*4,
/// channel order R,G,B,A). Used to build tiles; committed tiles become an immutable
/// `PortableImage`.
public struct PixelBuffer {
    public let width: Int
    public let height: Int
    /// Owned pixel storage; mutable until the buffer is committed as an
    /// immutable `PortableImage` (value semantics make every assignment a copy).
    public var bytes: [UInt8]

    public var bytesPerRow: Int { width * 4 }

    public init(width: Int, height: Int, fill: UInt32 = 0) {
        precondition(width > 0 && height > 0, "PixelBuffer must be positive-sized")
        self.width = width
        self.height = height
        self.bytes = [UInt8](repeating: 0, count: width * height * 4)
        if fill != 0 {
            let r = UInt8((fill >> 24) & 0xFF), g = UInt8((fill >> 16) & 0xFF)
            let b = UInt8((fill >> 8) & 0xFF), a = UInt8(fill & 0xFF)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = a
            }
        }
    }

    /// Wrap an existing packed RGBA byte array (no copy semantics issues: owned).
    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(width > 0 && height > 0)
        precondition(bytes.count == width * height * 4, "PixelBuffer byte count must equal width*height*4")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        get {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            bytes[i] = newValue.r; bytes[i + 1] = newValue.g
            bytes[i + 2] = newValue.b; bytes[i + 3] = newValue.a
        }
    }

    public func withUnsafeBytes<R>(_ body: (UnsafePointer<UInt8>) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { ptr in try body(ptr.baseAddress!) }
    }
    public mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutablePointer<UInt8>) throws -> R) rethrows -> R {
        try bytes.withUnsafeMutableBufferPointer { ptr in try body(ptr.baseAddress!) }
    }
}

/// Mutable 8-bit grayscale coverage/mask buffer (stride == width). The canonical
/// separate-coverage half of the tile contract.
public struct MaskBuffer {
    public let width: Int
    public let height: Int
    /// Owned pixel storage; mutable until committed into a `PortableImage`.
    public var bytes: [UInt8]

    public var bytesPerRow: Int { width }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.bytes = [UInt8](repeating: fill, count: width * height)
    }
    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(width > 0 && height > 0)
        precondition(bytes.count == width * height)
        self.width = width; self.height = height; self.bytes = bytes
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { bytes[y * width + x] }
        set { bytes[y * width + x] = newValue }
    }

    public func withUnsafeBytes<R>(_ body: (UnsafePointer<UInt8>) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { ptr in try body(ptr.baseAddress!) }
    }
}

/// Immutable image value backed by a canonical pixel buffer. Replaces `CGImage` as
/// *storage* (width, height, bytesPerRow, bytes, cropping) for the Linux core. The
/// macOS `CGImage` drawing/decode surface is not reimplemented; compositing and
/// drawing land on Skia in a later milestone. This is the storage surface the
/// document model and pixel-math layers hold.
public struct PortableImage: Equatable {
    public enum Kind: Equatable { case rgba, mask }
    /// Bits a color channel holds (RGBA only): 8, 16 (native-endian unsigned, 0...65535), half floats (16-bit IEEE,
    /// unclamped — an HDR layer's light brighter than white, sRGB-encoded) or 32-bit floats (linear light, as EXR and
    /// Radiance HDR files hold it). Masks are always 8-bit.
    public enum Depth: Equatable, Sendable { case uint8, uint16, half, float32 }
    public let width: Int
    public let height: Int
    public let kind: Kind
    public let depth: Depth
    public let bytesPerRow: Int
    public let bytes: [UInt8]

    public var bytesPerPixel: Int {
        guard kind == .rgba else { return 1 }
        switch depth { case .uint8: return 4; case .uint16, .half: return 8; case .float32: return 16 }
    }

    public init(_ buffer: PixelBuffer) {
        self.width = buffer.width
        self.height = buffer.height
        self.kind = .rgba
        self.depth = .uint8
        self.bytesPerRow = buffer.bytesPerRow
        self.bytes = buffer.bytes
    }
    public init(_ buffer: MaskBuffer) {
        self.width = buffer.width
        self.height = buffer.height
        self.kind = .mask
        self.depth = .uint8
        self.bytesPerRow = buffer.bytesPerRow
        self.bytes = buffer.bytes
    }

    /// Cropping returns the sub-image for the intersection of `rect` and the image
    /// bounds; nil if disjoint. Matches the `CGImage.cropping(to:)` contract the
    /// macOS raster layer relies on (nil on no overlap).
    public func cropping(to rect: CGRect) -> PortableImage? {
        if rect.isNull || rect.isEmpty { return nil }
        let ix = Int(floor(rect.minX)), iy = Int(floor(rect.minY))
        let iw = Int(ceil(rect.maxX)) - ix, ih = Int(ceil(rect.maxY)) - iy
        // Intersect with image bounds in integer pixels.
        let bx = max(0, ix), by = max(0, iy)
        let ex = min(width, ix + iw), ey = min(height, iy + ih)
        let cw = ex - bx, ch = ey - by
        guard cw > 0, ch > 0 else { return nil }
        let rowLength = cw * bytesPerPixel
        let out = [UInt8](unsafeUninitializedCapacity: rowLength * ch) { buffer, initialized in
            bytes.withUnsafeBufferPointer { source in
                for y in 0..<ch {
                    memcpy(buffer.baseAddress! + y * rowLength, source.baseAddress! + (by + y) * bytesPerRow + bx * bytesPerPixel, rowLength)
                }
            }
            initialized = rowLength * ch
        }
        return PortableImage(width: cw, height: ch, kind: kind, depth: depth,
                             bytesPerRow: cw * bytesPerPixel, bytes: out)
    }

    public init(width: Int, height: Int, kind: Kind, depth: Depth = .uint8, bytesPerRow: Int, bytes: [UInt8]) {
        self.width = width; self.height = height; self.kind = kind
        self.depth = kind == .mask ? .uint8 : depth
        self.bytesPerRow = bytesPerRow; self.bytes = bytes
    }

    /// Channel `i` (0...width*4-1) of row `y`, as a float: 0...1 for 8 and 16 bits, as stored for floats.
    @inline(__always)
    private func component(_ raw: UnsafeRawBufferPointer, row y: Int, _ i: Int) -> Float {
        let base = y * bytesPerRow
        switch depth {
        case .uint8: return Float(raw[base + i]) / 255
        case .uint16: return Float(raw.loadUnaligned(fromByteOffset: base + i * 2, as: UInt16.self)) / 65535
        case .half: return Float(raw.loadUnaligned(fromByteOffset: base + i * 2, as: Float16.self))
        case .float32: return raw.loadUnaligned(fromByteOffset: base + i * 4, as: Float.self)
        }
    }

    /// The same pixels at 8 bits a channel (premultiplied sRGB RGBA, tightly packed): 16-bit values rounded, half floats
    /// clipped to 0...1, 32-bit floats (linear light) encoded to sRGB first. An 8-bit image comes back as it is.
    public var eightBit: PortableImage {
        guard kind == .rgba, depth != .uint8 else { return self }
        let linear = premultipliedSRGB()
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<out.count { let v = linear[i]; out[i] = UInt8(max(0, min(255, (v.isFinite ? v : 0) * 255 + 0.5))) }
        return PortableImage(width: width, height: height, kind: .rgba, bytesPerRow: width * 4, bytes: out)
    }

    /// A 32-bit-float (linear light) image re-encoded as sRGB half floats (extended past white), the space every compat
    /// context draws in; any other image as it is.
    public var drawable: PortableImage {
        guard kind == .rgba, depth == .float32 else { return self }
        let halves = premultipliedSRGB().map { Float16($0.isFinite ? $0 : 0) }
        return PortableImage(width: width, height: height, kind: .rgba, depth: .half, bytesPerRow: width * 8,
                             bytes: halves.withUnsafeBytes { Array($0) })
    }

    /// Premultiplied RGBA as floats in sRGB encoding (extended past 0...1 for half floats; 32-bit floats, being linear,
    /// encoded), tightly packed.
    public func premultipliedSRGB() -> [Float] {
        var out = [Float](repeating: 0, count: width * height * 4)
        bytes.withUnsafeBytes { raw in
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    for c in 0..<4 { out[o + c] = component(raw, row: y, x * 4 + c) }
                    if depth == .float32 { PortableImage.recode(&out, at: o, toLinear: false) }
                }
            }
        }
        return out
    }

    /// Premultiplied RGBA as linear-light floats (sRGB-encoded depths decoded, extended past 0...1 keeping sign; 32-bit
    /// floats as they are), tightly packed — what an EXR holds.
    public func premultipliedLinear() -> [Float] {
        var out = [Float](repeating: 0, count: width * height * 4)
        bytes.withUnsafeBytes { raw in
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    for c in 0..<4 { out[o + c] = component(raw, row: y, x * 4 + c) }
                    if depth != .float32 { PortableImage.recode(&out, at: o, toLinear: true) }
                }
            }
        }
        return out
    }

    /// Re-encodes the premultiplied pixel at `o` between sRGB and linear light (unpremultiplied for the curve, which is
    /// mirrored for negative values, as extended sRGB is).
    private static func recode(_ px: inout [Float], at o: Int, toLinear: Bool) {
        let a = px[o + 3]
        guard a > 0 else { px[o] = 0; px[o + 1] = 0; px[o + 2] = 0; return }
        for c in 0..<3 {
            let v = px[o + c] / a, m = abs(v)
            let r: Float = toLinear ? (m <= 0.04045 ? m / 12.92 : pow((m + 0.055) / 1.055, 2.4))
                                    : (m <= 0.0031308 ? m * 12.92 : 1.055 * pow(m, 1 / 2.4) - 0.055)
            px[o + c] = (v < 0 ? -r : r) * a
        }
    }
}