import XCTest
import Compression

final class CompressionCompatTests: XCTestCase {
    private let hello = Array("hello".utf8)
    // Independently decodable RFC 1951 stream: no zlib header or Adler-32 trailer.
    private let deflatedHello: [UInt8] = [0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00]

    func testKnownRawDeflateInteroperability() {
        var encoded = [UInt8](repeating: 0, count: 64)
        let size = compression_encode_buffer(&encoded, encoded.count, hello, hello.count, nil, COMPRESSION_ZLIB)
        XCTAssertEqual(Array(encoded.prefix(size)), deflatedHello)
        var decoded = [UInt8](repeating: 0, count: 64)
        let count = compression_decode_buffer(&decoded, decoded.count, deflatedHello, deflatedHello.count, nil, COMPRESSION_ZLIB)
        XCTAssertEqual(Array(decoded.prefix(count)), hello)
    }

    func testMultipleDeflateBlocksRoundTrip() {
        let source = (0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: ($0 * 37) ^ ($0 >> 7)) }
        var encoded = [UInt8](repeating: 0, count: source.count + 4096)
        let size = compression_encode_buffer(&encoded, encoded.count, source, source.count, nil, COMPRESSION_ZLIB)
        XCTAssertGreaterThan(size, 0)
        var decoded = [UInt8](repeating: 0, count: source.count)
        let count = compression_decode_buffer(&decoded, decoded.count, encoded, size, nil, COMPRESSION_ZLIB)
        XCTAssertEqual(count, source.count)
        XCTAssertEqual(decoded, source)
    }

    func testBoundedDestinations() {
        var small = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(compression_encode_buffer(&small, small.count, hello, hello.count, nil, COMPRESSION_ZLIB), 0)
        XCTAssertEqual(compression_decode_buffer(&small, small.count, deflatedHello, deflatedHello.count, nil, COMPRESSION_ZLIB), 3)
        XCTAssertEqual(small, Array(hello.prefix(3)))
    }

    func testInvalidStreamsSizesAndAlgorithmsAreRefused() {
        var output = [UInt8](repeating: 0, count: 32)
        let invalid: [UInt8] = [0xff, 0xff, 0xff]
        XCTAssertEqual(compression_decode_buffer(&output, output.count, invalid, invalid.count, nil, COMPRESSION_ZLIB), 0)
        XCTAssertEqual(compression_encode_buffer(&output, -1, hello, hello.count, nil, COMPRESSION_ZLIB), 0)
        XCTAssertEqual(compression_decode_buffer(&output, output.count, hello, -1, nil, COMPRESSION_ZLIB), 0)
        XCTAssertEqual(compression_encode_buffer(&output, output.count, hello, hello.count, nil, compression_algorithm(rawValue: 0xffff)), 0)
    }
}
