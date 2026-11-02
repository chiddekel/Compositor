import CZlib

public struct compression_algorithm: RawRepresentable, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public let COMPRESSION_ZLIB = compression_algorithm(rawValue: 0x205)

// The buffer API used by upstream Channel Pack. zlib owns its temporary workspace; callers may pass nil scratch.
// https://developer.apple.com/documentation/compression/compression_zlib
public func compression_encode_buffer(_ dst_buffer: UnsafeMutablePointer<UInt8>, _ dst_size: Int,
                                      _ src_buffer: UnsafePointer<UInt8>, _ src_size: Int,
                                      _ scratch_buffer: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm) -> Int {
    guard algorithm == COMPRESSION_ZLIB, dst_size > 0, src_size >= 0 else { return 0 }
    return compositor_zlib_encode_raw(dst_buffer, dst_size, src_buffer, src_size)
}

public func compression_decode_buffer(_ dst_buffer: UnsafeMutablePointer<UInt8>, _ dst_size: Int,
                                      _ src_buffer: UnsafePointer<UInt8>, _ src_size: Int,
                                      _ scratch_buffer: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm) -> Int {
    guard algorithm == COMPRESSION_ZLIB, dst_size > 0, src_size >= 0 else { return 0 }
    return compositor_zlib_decode_raw(dst_buffer, dst_size, src_buffer, src_size)
}
