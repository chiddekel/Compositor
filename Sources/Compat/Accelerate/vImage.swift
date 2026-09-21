// Accelerate (vImage subset) for Linux. Upstream uses vImage in three places: halving images with a Lanczos kernel
// (DownsampleCache), table lookups on 8-bit planes, and 4x4 matrix multiplies on premultiplied ARGB8888 (Invert).
// These are portable Swift implementations of exactly those entry points, with vImage's buffer/flag/error shapes.

import Foundation

public typealias vImagePixelCount = UInt
public typealias vImage_Error = Int
public typealias vImage_Flags = UInt32
public typealias Pixel_8 = UInt8

public let kvImageNoError: vImage_Error = 0
public let kvImageMemoryAllocationError: vImage_Error = -21771
public let kvImageInvalidParameter: vImage_Error = -21773
public let kvImageBufferSizeMismatch: vImage_Error = -21776
public let kvImageNoFlags: Int = 0
public let kvImageDoNotTile: Int = 16
public let kvImageHighQualityResampling: Int = 32

public struct vImage_Buffer {
    public var data: UnsafeMutableRawPointer!
    public var height: vImagePixelCount
    public var width: vImagePixelCount
    public var rowBytes: Int
    public init() { data = nil; height = 0; width = 0; rowBytes = 0 }
    public init(data: UnsafeMutableRawPointer!, height: vImagePixelCount, width: vImagePixelCount, rowBytes: Int) {
        self.data = data; self.height = height; self.width = width; self.rowBytes = rowBytes
    }
}

// MARK: - Scaling

/// Resamples an interleaved 8-bit image. `highQuality` selects a Lanczos-3 kernel; otherwise a tent (bilinear /
/// area-weighted when shrinking). Both are separable and scale their support with the shrink ratio, so downsampling
/// filters properly instead of aliasing.
public func vImageResample8(source: UnsafeRawPointer, sourceWidth: Int, sourceHeight: Int, sourceRowBytes: Int,
                            destination: UnsafeMutableRawPointer, destinationWidth: Int, destinationHeight: Int,
                            destinationRowBytes: Int, channels: Int, highQuality: Bool) {
    guard sourceWidth > 0, sourceHeight > 0, destinationWidth > 0, destinationHeight > 0 else { return }
    let src = source.assumingMemoryBound(to: UInt8.self)
    let dst = destination.assumingMemoryBound(to: UInt8.self)

    func kernel(_ x: Double) -> Double {
        let ax = abs(x)
        if highQuality {
            if ax >= 3 { return 0 }
            if ax < 1e-9 { return 1 }
            let px = Double.pi * ax
            return 3 * sin(px) * sin(px / 3) / (px * px)
        }
        return ax >= 1 ? 0 : 1 - ax
    }
    let support = highQuality ? 3.0 : 1.0

    /// For each destination index: first source index, and normalised weights.
    func weights(from srcCount: Int, to dstCount: Int) -> [(start: Int, w: [Float])] {
        let scale = Double(srcCount) / Double(dstCount)
        let stretch = max(1, scale)
        return (0..<dstCount).map { i in
            let center = (Double(i) + 0.5) * scale - 0.5
            let lo = Int((center - support * stretch).rounded(.up)), hi = Int((center + support * stretch).rounded(.down))
            var ws: [Double] = []
            var total = 0.0
            for j in lo...max(lo, hi) { let w = kernel((Double(j) - center) / stretch); ws.append(w); total += w }
            if total == 0 { ws = [1]; total = 1 }
            // Clamp taps to the image edge (replicate), merging duplicate edge indices.
            var merged: [Int: Double] = [:]
            for (k, w) in ws.enumerated() { merged[min(max(lo + k, 0), srcCount - 1), default: 0] += w / total }
            let start = merged.keys.min()!, end = merged.keys.max()!
            return (start, (start...end).map { Float(merged[$0] ?? 0) })
        }
    }

    let hw = weights(from: sourceWidth, to: destinationWidth)
    let vw = weights(from: sourceHeight, to: destinationHeight)
    // Horizontal pass into float rows (all source rows), then vertical pass.
    var mid = [Float](repeating: 0, count: sourceHeight * destinationWidth * channels)
    for y in 0..<sourceHeight {
        let row = src + y * sourceRowBytes
        for x in 0..<destinationWidth {
            let (start, ws) = hw[x]
            for c in 0..<channels {
                var acc: Float = 0
                for (k, w) in ws.enumerated() { acc += w * Float(row[(start + k) * channels + c]) }
                mid[(y * destinationWidth + x) * channels + c] = acc
            }
        }
    }
    for y in 0..<destinationHeight {
        let (start, ws) = vw[y]
        let out = dst + y * destinationRowBytes
        for x in 0..<destinationWidth {
            for c in 0..<channels {
                var acc: Float = 0
                for (k, w) in ws.enumerated() { acc += w * mid[((start + k) * destinationWidth + x) * channels + c] }
                out[x * channels + c] = UInt8(max(0, min(255, acc.rounded())))
            }
        }
    }
}

private func scale(_ src: UnsafePointer<vImage_Buffer>, _ dest: UnsafePointer<vImage_Buffer>, channels: Int,
                   flags: vImage_Flags) -> vImage_Error {
    let s = src.pointee, d = dest.pointee
    guard s.data != nil, d.data != nil else { return kvImageInvalidParameter }
    vImageResample8(source: s.data, sourceWidth: Int(s.width), sourceHeight: Int(s.height), sourceRowBytes: s.rowBytes,
                    destination: d.data, destinationWidth: Int(d.width), destinationHeight: Int(d.height),
                    destinationRowBytes: d.rowBytes, channels: channels,
                    highQuality: Int(flags) & kvImageHighQualityResampling != 0)
    return kvImageNoError
}

@discardableResult
public func vImageScale_ARGB8888(_ src: UnsafePointer<vImage_Buffer>, _ dest: UnsafePointer<vImage_Buffer>,
                                 _ tempBuffer: UnsafeMutableRawPointer?, _ flags: vImage_Flags) -> vImage_Error {
    scale(src, dest, channels: 4, flags: flags)
}

@discardableResult
public func vImageScale_Planar8(_ src: UnsafePointer<vImage_Buffer>, _ dest: UnsafePointer<vImage_Buffer>,
                                _ tempBuffer: UnsafeMutableRawPointer?, _ flags: vImage_Flags) -> vImage_Error {
    scale(src, dest, channels: 1, flags: flags)
}

// MARK: - Table lookup and matrix multiply

@discardableResult
public func vImageTableLookUp_Planar8(_ src: UnsafePointer<vImage_Buffer>, _ dest: UnsafePointer<vImage_Buffer>,
                                      _ table: UnsafePointer<Pixel_8>, _ flags: vImage_Flags) -> vImage_Error {
    let s = src.pointee, d = dest.pointee
    guard s.data != nil, d.data != nil else { return kvImageInvalidParameter }
    guard s.width == d.width, s.height == d.height else { return kvImageBufferSizeMismatch }
    for y in 0..<Int(s.height) {
        let from = (s.data + y * s.rowBytes).assumingMemoryBound(to: UInt8.self)
        let to = (d.data + y * d.rowBytes).assumingMemoryBound(to: UInt8.self)
        for x in 0..<Int(s.width) { to[x] = table[Int(from[x])] }
    }
    return kvImageNoError
}

/// `dest[j] = clamp((Σ_i (src[i] + preBias[i]) * matrix[i*4 + j]) / divisor + postBias[j] / divisor)`. The matrix is
/// row-major, applied as pixel × matrix over the four interleaved channels in memory order (vImage's convention).
@discardableResult
public func vImageMatrixMultiply_ARGB8888(_ src: UnsafePointer<vImage_Buffer>, _ dest: UnsafePointer<vImage_Buffer>,
                                          _ matrix: UnsafePointer<Int16>, _ divisor: Int32,
                                          _ preBias: UnsafePointer<Int16>?, _ postBias: UnsafePointer<Int32>?,
                                          _ flags: vImage_Flags) -> vImage_Error {
    let s = src.pointee, d = dest.pointee
    guard s.data != nil, d.data != nil, divisor != 0 else { return kvImageInvalidParameter }
    guard s.width == d.width, s.height == d.height else { return kvImageBufferSizeMismatch }
    var m = [Int32](repeating: 0, count: 16)
    for i in 0..<16 { m[i] = Int32(matrix[i]) }
    for y in 0..<Int(s.height) {
        let from = (s.data + y * s.rowBytes).assumingMemoryBound(to: UInt8.self)
        let to = (d.data + y * d.rowBytes).assumingMemoryBound(to: UInt8.self)
        for x in 0..<Int(s.width) {
            var px = [Int32](repeating: 0, count: 4)
            for i in 0..<4 { px[i] = Int32(from[x * 4 + i]) + (preBias.map { Int32($0[i]) } ?? 0) }
            for j in 0..<4 {
                let sum = px[0] * m[j] + px[1] * m[4 + j] + px[2] * m[8 + j] + px[3] * m[12 + j]
                let biased = sum + (postBias.map { $0[j] } ?? 0)
                // Round to nearest, ties away from zero like vImage's fixed-point path.
                let v = biased >= 0 ? (biased + divisor / 2) / divisor : -((-biased + divisor / 2) / divisor)
                to[x * 4 + j] = UInt8(max(0, min(255, v)))
            }
        }
    }
    return kvImageNoError
}
