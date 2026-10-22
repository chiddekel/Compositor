// CryptoKit's SHA256 on Linux: the same incremental API (init, update(data:), update(bufferPointer:), finalize(),
// hash(data:)) over a portable FIPS 180-4 implementation. Upstream fingerprints project packages with it
// (Compositor/IO/ProjectDigest.swift).
import Foundation

public struct SHA256Digest: Sequence, Equatable, Hashable, Sendable, CustomStringConvertible {
    let bytes: [UInt8]
    public static let byteCount = 32
    public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try bytes.withUnsafeBytes(body) }
    public var description: String { "SHA256 digest: " + bytes.map { String(format: "%02x", $0) }.joined() }
}

public struct SHA256: Sendable {
    public typealias Digest = SHA256Digest
    public static let byteCount = 32
    public static let blockByteCount = 64

    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public static func hash<D: DataProtocol>(data: D) -> SHA256Digest {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }

    public mutating func update<D: DataProtocol>(data: D) {
        for region in data.regions { region.withUnsafeBytes { update(bufferPointer: $0) } }
    }

    public mutating func update(bufferPointer: UnsafeRawBufferPointer) {
        length &+= UInt64(bufferPointer.count)
        buffer.append(contentsOf: bufferPointer)
        var offset = 0
        while buffer.count - offset >= 64 {
            compress(buffer[offset..<offset + 64])
            offset += 64
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    public func finalize() -> SHA256Digest {
        var copy = self
        let bitLength = length &* 8
        var tail = copy.buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        var offset = 0
        while offset < tail.count { copy.compress(tail[offset..<offset + 64]); offset += 64 }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in copy.state { for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: word >> UInt32(shift))) } }
        return SHA256Digest(bytes: out)
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    private mutating func compress(_ block: ArraySlice<UInt8>) {
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for i in 0..<16 {
            w[i] = UInt32(block[base + i * 4]) << 24 | UInt32(block[base + i * 4 + 1]) << 16
                 | UInt32(block[base + i * 4 + 2]) << 8 | UInt32(block[base + i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ SHA256.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}
