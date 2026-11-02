#!/usr/bin/env python3
"""Independent PDF fixtures exercise the native parser/render engine without Compositor's PDF writer."""
import ctypes
from pathlib import Path
import sys
import zlib


def fixture():
    first = zlib.compress(b"1 0 0 rg 0 50 50 50 re f\nBT /F1 18 Tf 75 25 Td (Hello PDF) Tj ET\n")
    second = zlib.compress(b"0 0 1 rg 0 25 25 25 re f\n")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F1 8 0 R >> >> /Contents 4 0 R >>",
        b"<< /Filter /FlateDecode /Length %d >>\nstream\n" % len(first) + first + b"\nendstream",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 50] /Rotate 90 /Contents 6 0 R >>",
        b"<< /Filter /FlateDecode /Length %d >>\nstream\n" % len(second) + second + b"\nendstream",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /CropBox [50 0 150 100] /Resources << /Font << /F1 8 0 R >> >> /Contents 4 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    data = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(b"%d 0 obj\n" % number + body + b"\nendobj\n")
    start = len(data)
    data.extend(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1))
    for offset in offsets:
        data.extend(b"%010d 00000 n \n" % offset)
    data.extend(b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, start))
    return bytes(data)


def main():
    backend = ctypes.CDLL(sys.argv[1])
    backend.compositor_pdf_open.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    backend.compositor_pdf_open.restype = ctypes.c_void_p
    for name in ["count", "locked"]:
        getattr(backend, "compositor_pdf_" + name).argtypes = [ctypes.c_void_p]
    backend.compositor_pdf_close.argtypes = [ctypes.c_void_p]
    backend.compositor_pdf_page.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_double), ctypes.POINTER(ctypes.c_double), ctypes.POINTER(ctypes.c_int)]
    backend.compositor_pdf_render.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    backend.compositor_pdf_render.restype = ctypes.c_void_p
    libc = ctypes.CDLL(None)
    libc.free.argtypes = [ctypes.c_void_p]

    data = fixture()
    document = backend.compositor_pdf_open(data, len(data))
    assert document
    try:
        assert backend.compositor_pdf_count(document) == 3
        assert backend.compositor_pdf_locked(document) == 0
        for index, expected in enumerate([(200, 100, 0), (100, 50, 90), (100, 100, 0)]):
            width, height, angle = ctypes.c_double(), ctypes.c_double(), ctypes.c_int()
            assert backend.compositor_pdf_page(document, index, ctypes.byref(width), ctypes.byref(height), ctypes.byref(angle)) == 0
            assert (width.value, height.value, angle.value) == expected
        pixels = backend.compositor_pdf_render(document, 0, 400, 200)
        assert pixels
        try:
            rgba = ctypes.string_at(pixels, 400 * 200 * 4)
            at = lambda x, y: rgba[(y * 400 + x) * 4:(y * 400 + x + 1) * 4]
            assert at(0, 0) == bytes([255, 0, 0, 255]), "the raster slice must start at the page origin"
            assert at(20, 20) == bytes([255, 0, 0, 255])
            assert at(350, 20)[3] == 0, "unpainted paper must remain transparent"
            assert any(at(x, y)[3] for y in range(120, 160) for x in range(150, 380)), "compressed font/text content must render"
        finally:
            libc.free(pixels)
        assert not backend.compositor_pdf_render(document, -1, 200, 100)
        assert not backend.compositor_pdf_render(document, 0, 0, 100)
    finally:
        backend.compositor_pdf_close(document)
    assert not backend.compositor_pdf_open(b"not PDF", 7)
    locked = Path(__file__).with_name("fixtures").joinpath("password-protected.pdf").read_bytes()
    document = backend.compositor_pdf_open(locked, len(locked))
    assert document
    try:
        assert backend.compositor_pdf_locked(document) == 1
        assert backend.compositor_pdf_count(document) == 0
        assert not backend.compositor_pdf_render(document, 0, 200, 100)
        width, height, angle = ctypes.c_double(), ctypes.c_double(), ctypes.c_int()
        assert backend.compositor_pdf_page(document, 0, ctypes.byref(width), ctypes.byref(height), ctypes.byref(angle)) == -1
    finally:
        backend.compositor_pdf_close(document)
    print("PDF backend: compressed vectors/text, crop, rotation, transparency, damaged input and password protection passed")


if __name__ == "__main__":
    main()
