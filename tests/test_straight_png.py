#!/usr/bin/env python3
"""Check native straight-alpha PNG callbacks against PNG's independently decoded file bytes."""
import ctypes as C
import struct
import sys
import zlib

Byte = C.c_uint8
Pointer = C.POINTER(Byte)
Decode = C.CFUNCTYPE(C.c_int32, Pointer, C.c_size_t, C.POINTER(Pointer), C.POINTER(C.c_int32),
                    C.POINTER(C.c_int32), C.POINTER(C.c_int32), C.POINTER(C.c_double),
                    C.POINTER(C.c_int32), C.c_char_p, C.c_size_t)
Encode = C.CFUNCTYPE(C.c_int32, Pointer, C.c_int32, C.c_int32, C.c_int32, C.c_char_p, C.c_double,
                    C.c_double, C.c_int32, C.POINTER(Pointer), C.POINTER(C.c_size_t))


def callbacks(library, name):
    getter = getattr(library, name)
    getter.argtypes = [C.POINTER(C.c_void_p), C.POINTER(C.c_void_p)]
    decode, encode = C.c_void_p(), C.c_void_p()
    assert getter(C.byref(decode), C.byref(encode)) == 1
    return Decode(decode.value), Encode(encode.value)


def png_samples(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    offset, packed, width, height = 8, bytearray(), 0, 0
    while offset < len(data):
        length, = struct.unpack_from(">I", data, offset)
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        crc, = struct.unpack_from(">I", data, offset + 8 + length)
        assert zlib.crc32(kind + body) == crc
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", body)
            assert (depth, color, compression, filtering, interlace) == (8, 6, 0, 0, 0)
        if kind == b"IDAT":
            packed.extend(body)
        offset += length + 12
    rows, stride, result = zlib.decompress(packed), width * 4, bytearray()
    for y in range(height):
        method = rows[y * (stride + 1)]
        assert method in range(5)
        for x in range(stride):
            left = result[-4] if x >= 4 else 0
            above = result[(y - 1) * stride + x] if y else 0
            corner = result[(y - 1) * stride + x - 4] if y and x >= 4 else 0
            estimate = left + above - corner
            distances = [abs(estimate - candidate) for candidate in (left, above, corner)]
            paeth = (left, above, corner)[distances.index(min(distances))]
            predictor = (0, left, above, (left + above) // 2, paeth)[method]
            result.append((rows[y * (stride + 1) + x + 1] + predictor) & 255)
    return width, height, bytes(result)


def main(path):
    library = C.CDLL(path)
    libc = C.CDLL(None)
    libc.free.argtypes = [C.c_void_p]
    straight_decode, encode = callbacks(library, "compositor_qt_imageio_straight_functions")
    legacy_decode, _ = callbacks(library, "compositor_qt_imageio_functions")
    samples = bytes([51, 153, 255, 0, 90, 60, 30, 128, 21, 67, 191, 1, 255, 255, 0, 255])
    source = (Byte * len(samples)).from_buffer_copy(samples)
    output, count = Pointer(), C.c_size_t()
    assert encode(source, 2, 2, 4, b"public.png", -1, 144, 1, C.byref(output), C.byref(count)) == 0
    try:
        png = C.string_at(output, count.value)
    finally:
        libc.free(output)
    assert png_samples(png) == (2, 2, samples), "PNG file lost straight RGB samples"
    compressed = (Byte * len(png)).from_buffer_copy(png)
    for decoder, straight in ((straight_decode, True), (legacy_decode, False)):
        pixels, width, height, channels, orientation = Pointer(), C.c_int32(), C.c_int32(), C.c_int32(), C.c_int32()
        dpi, uti = C.c_double(), C.create_string_buffer(96)
        assert decoder(compressed, len(png), C.byref(pixels), C.byref(width), C.byref(height), C.byref(channels),
                       C.byref(dpi), C.byref(orientation), uti, len(uti)) == 0
        try:
            actual = C.string_at(pixels, width.value * height.value * channels.value)
        finally:
            libc.free(pixels)
        expected = samples if straight else bytes(
            value if index % 4 == 3 else (value * samples[index // 4 * 4 + 3] + 127) // 255
            for index, value in enumerate(samples))
        assert actual == expected, (straight, actual, expected)
        assert (width.value, height.value, channels.value, orientation.value, uti.value) == (2, 2, 4, 1, b"public.png")
        assert abs(dpi.value - 144) < 0.03
    print("Native straight PNG OK: independent file samples, zero/partial alpha, DPI and legacy premultiplied decoding")


if __name__ == "__main__":
    main(sys.argv[1])
