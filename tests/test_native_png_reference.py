#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
from pathlib import Path
import struct
import unittest
import zlib

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("validator", ROOT / "scripts/validate-native-png.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def png(pixels):
    filtered = bytearray()
    previous = bytes(1024)
    for y in range(256):
        row = pixels[y * 1024:(y + 1) * 1024]
        mode = y % 5
        filtered.append(mode)
        for i, value in enumerate(row):
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
                predictor = min((abs(p - a), 0, a), (abs(p - b), 1, b), (abs(p - c), 2, c))[2]
            filtered.append((value - predictor) % 256)
        previous = row
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 256, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(filtered)) + chunk(b"IEND", b""))


class NativePNGReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw = MODULE.source()
        straight = bytearray(raw)
        for i in range(0, len(raw), 4):
            a = raw[i + 3]
            for c in range(3):
                straight[i + c] = (raw[i + c] * 255 + a // 2) // a if a else 0
        cls.straight = bytes(straight)
        cls.png = png(cls.straight)
        cls.report = dict(schema=1, platform="macOS", width=256, height=256, validColorAlphaPairs=32896,
            sourceLayout="RGBA8-premultipliedLast-byteOrder32Big-sRGB", sourceSHA256=hashlib.sha256(raw).hexdigest(),
            pngSHA256=hashlib.sha256(cls.png).hexdigest(),
            scriptSHA256=hashlib.sha256((ROOT / "scripts/capture-native-png.swift").read_bytes()).hexdigest())

    def test_every_png_filter_and_complete_capture(self):
        self.assertEqual(MODULE.decode_png(self.png), self.straight)
        self.assertEqual(MODULE.validate(self.report, self.png)["validColorAlphaPairs"], 32896)

    def test_crc_and_complete_chunks(self):
        damaged = bytearray(self.png)
        damaged[-5] ^= 1
        with self.assertRaisesRegex(AssertionError, "CRC"):
            MODULE.decode_png(damaged)
        with self.assertRaises(AssertionError):
            MODULE.decode_png(self.png + b"extra")

    def test_provenance(self):
        for key in ("sourceSHA256", "pngSHA256", "scriptSHA256"):
            report = copy.deepcopy(self.report)
            report[key] = "0" * 64
            with self.assertRaises(AssertionError):
                MODULE.validate(report, self.png)

    def test_rehashed_wrong_alpha(self):
        straight = bytearray(self.straight)
        straight[1024 + 3] = 0
        encoded = png(straight)
        report = copy.deepcopy(self.report)
        report["pngSHA256"] = hashlib.sha256(encoded).hexdigest()
        with self.assertRaisesRegex(AssertionError, "Alpha preservation"):
            MODULE.validate(report, encoded)


if __name__ == "__main__":
    unittest.main()
