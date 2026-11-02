// NSData compression as upstream uses it (CameraRawTables.swift: `decompressed(using: .lzma)`). swift-corelibs
// Foundation has no compression API; Apple's `.lzma` reads and writes an XZ container, which liblzma decodes.

import Foundation
import CLZMA

extension NSData {
    public enum CompressionAlgorithm: Int, Sendable {
        case lzfse = 0, lz4 = 1, lzma = 2, zlib = 3
    }

    public struct CompressionError: Error, CustomStringConvertible {
        public let description: String
    }

    public func decompressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        guard algorithm == .lzma else {
            throw CompressionError(description: "NSData.decompressed(using: \(algorithm)) is not available on Linux")
        }
        var stream = lzma_stream()
        guard lzma_stream_decoder(&stream, UInt64.max, 0) == LZMA_OK else {
            throw CompressionError(description: "could not start the XZ decoder")
        }
        defer { lzma_end(&stream) }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let input = Data(referencing: self)
        return try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> NSData in
            stream.next_in = raw.bindMemory(to: UInt8.self).baseAddress
            stream.avail_in = raw.count
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> lzma_ret in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = buffer.count
                    let status = lzma_code(&stream, stream.avail_in == 0 ? LZMA_FINISH : LZMA_RUN)
                    output.append(buffer.baseAddress!, count: buffer.count - stream.avail_out)
                    return status
                }
                if status == LZMA_STREAM_END { return output as NSData }
                guard status == LZMA_OK else { throw CompressionError(description: "XZ data is damaged (\(status))") }
                if stream.avail_in == 0, stream.avail_out != 0 {
                    // Input fully consumed without a stream end: ask the decoder to finish.
                    let end = chunk.withUnsafeMutableBufferPointer { buffer -> lzma_ret in
                        stream.next_out = buffer.baseAddress
                        stream.avail_out = buffer.count
                        let status = lzma_code(&stream, LZMA_FINISH)
                        output.append(buffer.baseAddress!, count: buffer.count - stream.avail_out)
                        return status
                    }
                    if end == LZMA_STREAM_END { return output as NSData }
                    guard end == LZMA_OK || end == LZMA_BUF_ERROR else {
                        throw CompressionError(description: "XZ data is damaged (\(end))")
                    }
                    throw CompressionError(description: "XZ data ends early")
                }
            }
        }
    }
}
