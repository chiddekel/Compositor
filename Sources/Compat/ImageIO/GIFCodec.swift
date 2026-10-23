// GIFCodec.swift — portable GIF89a writer. Qt reads GIF but cannot write it, and ImageIO can, so this
// covers `CGImageDestination` for "com.compuserve.gif". Colours are quantised to a fixed 3-3-2 palette (transparent
// pixels use index 0 as the transparent colour) and LZW is emitted with a clear code every 254 symbols, which keeps
// every code 9 bits wide: valid GIF, no dictionary, no compression.

import Foundation
import CoreGraphics

final class PortableGIFEncoder: ImageCodecBackend {
    func identify(_ data: Data) -> ImageInfo? { nil }
    func decode(_ data: Data) -> CGImage? { nil }

    func encode(_ image: CGImage, typeIdentifier: String, quality: Double?, dpi: Double?) -> Data? {
        guard typeIdentifier == "com.compuserve.gif", image.width <= 65535, image.height <= 65535 else { return nil }
        let w = image.width, h = image.height
        let px = image.portableImage.bytes, stride = image.bytesPerRow
        let gray = image.isGrayPlane
        var out = Data("GIF89a".utf8)
        func le16(_ v: Int) { out.append(UInt8(v & 255)); out.append(UInt8(v >> 8 & 255)) }
        le16(w); le16(h)
        out.append(contentsOf: [0xF7, 0, 0])                       // global 256-entry palette, 8 bits
        for i in 0..<256 {                                           // 3-3-2 palette; index 0 doubles as transparent
            let r = i == 1 ? 0 : (i >> 5) * 255 / 7
            let g = i == 1 ? 0 : ((i >> 2) & 7) * 255 / 7
            let b = i == 1 ? 0 : (i & 3) * 255 / 3
            out.append(UInt8(r)); out.append(UInt8(g)); out.append(UInt8(b))
        }
        out.append(contentsOf: [0x21, 0xF9, 4, 1, 0, 0, 0, 0])      // graphic control: transparent index 0
        out.append(0x2C); le16(0); le16(0); le16(w); le16(h); out.append(0)
        out.append(8)                                                // LZW minimum code size

        func index(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
            let red: Int = (r >> 5) * 32
            let green: Int = (g >> 5) * 4
            let blue: Int = b >> 6
            return UInt8(max(1, red + green + blue))
        }
        var indices = [UInt8](); indices.reserveCapacity(w * h)
        for y in 0..<h {
            for x in 0..<w {
                if gray { let v = Int(px[y * stride + x]); indices.append(index(v, v, v)); continue }
                let o = y * stride + x * 4, a = Int(px[o + 3])
                if a < 128 { indices.append(0); continue }
                func straight(_ c: Int) -> Int { min(255, (Int(px[o + c]) * 255 + a / 2) / a) }
                indices.append(index(straight(0), straight(1), straight(2)))
            }
        }
        // 9-bit codes: 256 = clear, 257 = end. A clear every 254 symbols stops the code width from growing.
        var bits = 0, bitCount = 0
        var block = [UInt8]()
        func emit(_ code: Int) {
            bits |= code << bitCount; bitCount += 9
            while bitCount >= 8 { block.append(UInt8(bits & 255)); bits >>= 8; bitCount -= 8 }
        }
        var i = 0
        emit(256)
        while i < indices.count {
            let n = min(254, indices.count - i)
            for k in 0..<n { emit(Int(indices[i + k])) }
            i += n
            if i < indices.count { emit(256) }
        }
        emit(257)
        if bitCount > 0 { block.append(UInt8(bits & 255)) }
        var offset = 0
        while offset < block.count {
            let n = min(255, block.count - offset)
            out.append(UInt8(n)); out.append(contentsOf: block[offset..<(offset + n)]); offset += n
        }
        out.append(0); out.append(0x3B)
        return out
    }
}


/// Walk block boundaries without decompressing pixels, so count and timing stay cheap for large timelines.
struct GIFMetadata {
    let width: Int
    let height: Int
    let delays: [Double]
    let loopCount: Int?

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, ["GIF87a", "GIF89a"].contains(String(decoding: bytes.prefix(6), as: UTF8.self)) else { return nil }
        func word(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        width = word(6); height = word(8)
        guard width > 0, height > 0 else { return nil }
        var cursor = 13 + (bytes[10] & 128 != 0 ? 3 * (1 << (Int(bytes[10] & 7) + 1)) : 0)
        var durations: [Double] = [], delay = 0.0, loops: Int?
        func skipBlocks() -> Bool {
            while cursor < bytes.count {
                let count = Int(bytes[cursor]); cursor += 1
                if count == 0 { return true }
                guard count <= bytes.count - cursor else { return false }
                cursor += count
            }
            return false
        }
        while cursor < bytes.count {
            let marker = bytes[cursor]; cursor += 1
            if marker == 0x3b {
                guard !durations.isEmpty else { return nil }
                delays = durations; loopCount = loops; return
            }
            if marker == 0x21 {
                guard cursor < bytes.count else { return nil }
                let label = bytes[cursor]; cursor += 1
                if label == 0xf9 {
                    guard cursor + 6 <= bytes.count, bytes[cursor] == 4, bytes[cursor + 5] == 0 else { return nil }
                    delay = Double(word(cursor + 2)) / 100
                    cursor += 6
                } else {
                    if label == 0xff, cursor + 17 <= bytes.count, bytes[cursor] == 11,
                       String(decoding: bytes[(cursor + 1)..<(cursor + 12)], as: UTF8.self) == "NETSCAPE2.0",
                       bytes[cursor + 12] == 3, bytes[cursor + 13] == 1 {
                        loops = word(cursor + 14)
                    }
                    guard skipBlocks() else { return nil }
                }
            } else if marker == 0x2c {
                guard cursor + 9 <= bytes.count else { return nil }
                let packed = bytes[cursor + 8]
                cursor += 9 + (packed & 128 != 0 ? 3 * (1 << (Int(packed & 7) + 1)) : 0)
                guard cursor < bytes.count else { return nil }
                cursor += 1 // LZW minimum code size
                guard skipBlocks() else { return nil }
                durations.append(delay); delay = 0
            } else { return nil }
        }
        return nil
    }
}

extension PortableGIFEncoder {
    /// Full-canvas frames with local palettes and restore-background disposal keep transparent frames independent.
    func encodeFrames(_ frames: [(CGImage, Double)], loopCount: Int?) -> Data? {
        guard let first = frames.first else { return nil }
        var result = Data()
        for (position, frame) in frames.enumerated() {
            guard frame.0.width == first.0.width, frame.0.height == first.0.height,
                  frame.1.isFinite, frame.1 >= 0,
                  let encoded = encode(frame.0, typeIdentifier: "com.compuserve.gif", quality: nil, dpi: nil) else { return nil }
            let bytes = [UInt8](encoded)
            if position == 0 {
                result.append(contentsOf: bytes[0..<13])
                result[10] = 0x70 // no global palette
                if let loopCount {
                    result.append(contentsOf: [0x21, 0xff, 11])
                    result.append(Data("NETSCAPE2.0".utf8))
                    result.append(contentsOf: [3, 1, UInt8(clamping: loopCount & 255), UInt8(clamping: loopCount >> 8), 0])
                }
            }
            let delay = Int(min(65535, (frame.1 * 100).rounded()))
            result.append(contentsOf: [0x21, 0xf9, 4, 9, UInt8(delay & 255), UInt8(delay >> 8), 0, 0])
            result.append(contentsOf: bytes[789..<798]) // image separator, offset and dimensions
            result.append(0x87) // local 256-entry palette
            result.append(contentsOf: bytes[13..<781])
            result.append(contentsOf: bytes[799..<(bytes.count - 1)]) // LZW stream
        }
        result.append(0x3b)
        return result
    }
}
