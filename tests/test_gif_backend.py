#!/usr/bin/env python3
"""Decode an independently encoded GIF, checking frame composition and disposal.

gif-disposal.gif was encoded with Pillow: a 3x2 indexed canvas, a transparent
background, red and blue frames, then five transparent pixels and one red pixel.
Each frame uses restore-background disposal; delays are 40, 160 and 80 ms.
The fixture is retained so running this check needs no Pillow installation.
"""
import ctypes as C
from pathlib import Path
import sys
import struct


def main():
    library = C.CDLL(sys.argv[1])
    decode = library.compositor_qt_imageio_decode_frame
    decode.argtypes = [C.c_void_p, C.c_size_t, C.c_int32, C.POINTER(C.c_void_p),
                       C.POINTER(C.c_int32), C.POINTER(C.c_int32)]
    decode.restype = C.c_int32
    release = C.CDLL(None).free
    release.argtypes = [C.c_void_p]
    data = (Path(__file__).parent / "fixtures/gif-disposal.gif").read_bytes()
    expected = [bytes([255, 0, 0, 255]) * 6, bytes([0, 0, 255, 255]) * 6,
                bytes(20) + bytes([255, 0, 0, 255])]
    for index, pixels in enumerate(expected):
        output, width, height = C.c_void_p(), C.c_int32(), C.c_int32()
        result = decode(data, len(data), index, C.byref(output), C.byref(width), C.byref(height))
        try:
            assert result == 0, (index, result)
            assert (width.value, height.value) == (3, 2)
            assert C.string_at(output, 24) == pixels, index
        finally:
            release(output)
    for index in [-1, 3]:
        output, width, height = C.c_void_p(), C.c_int32(), C.c_int32()
        result = decode(data, len(data), index, C.byref(output), C.byref(width), C.byref(height))
        try:
            assert result != 0 and not output.value, index
        finally:
            release(output)
    open_source = library.compositor_qt_imageio_animation_open
    open_source.argtypes = [C.c_void_p, C.c_size_t]
    open_source.restype = C.c_void_p
    read = library.compositor_qt_imageio_animation_read
    read.argtypes = [C.c_void_p, C.c_int32, C.POINTER(C.c_void_p), C.POINTER(C.c_int32), C.POINTER(C.c_int32)]
    read.restype = C.c_int32
    close = library.compositor_qt_imageio_animation_close
    close.argtypes = [C.c_void_p]
    reads = library.compositor_qt_imageio_animation_reads
    reads.argtypes = [C.c_void_p]
    reads.restype = C.c_uint64

    def frame(left, indices, disposal=2):
        # Literal LZW with a clear between pixels keeps the code width fixed at three bits.
        codes = [code for pixel in indices for code in (4, pixel)] + [5]
        packed = sum(code << (3 * i) for i, code in enumerate(codes)).to_bytes((len(codes) * 3 + 7) // 8, "little")
        return (bytes([0x21, 0xf9, 4, disposal << 2, 1, 0, 0, 0, 0x2c])
                + struct.pack("<HHHHB", left, 0, len(indices), 1, 0)
                + bytes([2, len(packed)]) + packed + bytes([0]))

    def animation(width, frames):
        return b"GIF89a" + struct.pack("<HHBBB", width, 1, 0x80, 0, 0) + bytes([255, 0, 0, 0, 0, 255]) + b"".join(frames) + b";"

    def fetch(handle, index):
        output, width, height = C.c_void_p(), C.c_int32(), C.c_int32()
        result = read(handle, index, C.byref(output), C.byref(width), C.byref(height))
        try:
            assert result == 0, (index, result)
            return C.string_at(output, width.value * height.value * 4)
        finally:
            release(output)

    # The retained third-party fixture must compose identically after backward and repeated seeks.
    handle = open_source(data, len(data))
    assert handle
    try:
        for index in [0, 1, 2, 2, 0, 2, 1]:
            assert fetch(handle, index) == expected[index]
    finally:
        close(handle)
    # Partial frames and restore-previous disposal must restore the prior composed canvas.
    offset = animation(3, [frame(0, [0, 0, 0], 1), frame(1, [1], 3), frame(2, [1], 1)])
    red, blue = bytes([255, 0, 0, 255]), bytes([0, 0, 255, 255])
    composed = [red * 3, red + blue + red, red * 2 + blue]
    handle = open_source(offset, len(offset))
    assert handle
    try:
        for index in [0, 1, 2, 0, 2, 1]:
            assert fetch(handle, index) == composed[index]
    finally:
        close(handle)
    for count in [128, 256, 512]:
        encoded = animation(1, [frame(0, [i % 2]) for i in range(count)])
        handle = open_source(encoded, len(encoded))
        assert handle
        try:
            for index in range(count):
                assert fetch(handle, index) == (red if index % 2 == 0 else blue)
            assert reads(handle) == count, (count, reads(handle))
        finally:
            close(handle)
    print("GIF backend: pixels, offsets, disposal 2/3, backward seeks and linear 128/256/512-frame decoding pass")


if __name__ == "__main__":
    main()
