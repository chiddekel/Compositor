#!/usr/bin/env python3
"""Validate a native PNG capture without relying on a premultiplying image decoder."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parent.parent


def source():
    return bytes(v for a in range(256) for x in range(256)
                 for v in (min(x, a), min(x * 73 % 256, a), min((x * 151 + 17) % 256, a), a))


def decode_png(raw):
    assert raw[:8] == b"\x89PNG\r\n\x1a\n", "PNG signature"
    offset, compressed, header, finished = 8, bytearray(), None, False
    while offset < len(raw):
        length, = struct.unpack_from(">I", raw, offset)
        kind = raw[offset + 4:offset + 8]
        data = raw[offset + 8:offset + 8 + length]
        crc, = struct.unpack_from(">I", raw, offset + 8 + length)
        assert zlib.crc32(kind + data) & 0xffffffff == crc, "PNG chunk CRC"
        if kind == b"IHDR":
            assert header is None
            header = struct.unpack(">IIBBBBB", data)
        elif kind == b"IDAT":
            compressed.extend(data)
        elif kind == b"IEND":
            finished = True
        offset += length + 12
        if finished:
            break
    assert finished and offset == len(raw), "Complete PNG chunks"
    assert header == (256, 256, 8, 6, 0, 0, 0), "PNG layout"
    filtered = zlib.decompress(compressed)
    stride = 256 * 4
    assert len(filtered) == 256 * (stride + 1), "PNG scanline size"
    previous, decoded = bytearray(stride), bytearray()
    for y in range(256):
        at = y * (stride + 1)
        mode = filtered[at]
        assert mode in range(5), "PNG filter"
        row = bytearray(filtered[at + 1:at + 1 + stride])
        for i in range(stride):
            a = row[i - 4] if i >= 4 else 0
            b = previous[i]
            c = previous[i - 4] if i >= 4 else 0
            if mode == 0:
                predictor = 0
            elif mode == 1:
                predictor = a
            elif mode == 2:
                predictor = b
            elif mode == 3:
                predictor = (a + b) // 2
            else:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                predictor = a if pa <= pb and pa <= pc else b if pb <= pc else c
            row[i] = (row[i] + predictor) & 255
        decoded.extend(row)
        previous = row
    return bytes(decoded)


def validate(report, png):
    assert report["schema"] == 1 and report["platform"] == "macOS"
    assert (report["width"], report["height"], report["validColorAlphaPairs"]) == (256, 256, 32896)
    assert report["sourceLayout"] == "RGBA8-premultipliedLast-byteOrder32Big-sRGB"
    assert report["scriptSHA256"] == hashlib.sha256((ROOT / "scripts/capture-native-png.swift").read_bytes()).hexdigest(), "Script provenance"
    original = source()
    assert report["sourceSHA256"] == hashlib.sha256(original).hexdigest(), "Source provenance"
    assert report["pngSHA256"] == hashlib.sha256(png).hexdigest(), "PNG provenance"
    decoded = decode_png(png)
    assert decoded[3::4] == original[3::4], "Alpha preservation"
    assert decoded[-1024:] == original[-1024:], "Opaque identity"
    assert decoded[:1024] == bytes(1024), "Transparent black"
    return dict(pixels=65536, validColorAlphaPairs=32896,
                straightRGBA8SHA256=hashlib.sha256(decoded).hexdigest())


if __name__ == "__main__":
    print(json.dumps(validate(json.loads(Path(sys.argv[1]).read_text()), Path(sys.argv[2]).read_bytes()), sort_keys=True))
