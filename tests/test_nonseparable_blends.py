#!/usr/bin/env python3
"""Compare byte canvas blends with independent native Core Graphics captures."""
import base64
import ctypes as C
import gzip
import hashlib
import json
from pathlib import Path
import sys


def main(library):
    root = Path(__file__).resolve().parent.parent
    reference = json.loads(gzip.decompress(
        (root / 'Tests/Fixtures/coregraphics-nonseparable-reference.json.gz').read_bytes()))
    assert reference['schema'] == 1 and reference['platform'] == 'macOS'
    assert len(reference['cases']) == 18
    assert len(reference['paired']['cases']) == 6

    def decode(item, width=256, height=256):
        assert (item['width'], item['height'], item['rowBytes'], item['bitsPerComponent']) == (width, height, width * 4, 8)
        raw = base64.b64decode(item['rgbaBase64'], validate=True)
        assert len(raw) == item['rowBytes'] * item['height']
        assert hashlib.sha256(raw).hexdigest() == item['sha256']
        return raw

    lib = C.CDLL(library)
    pixels, size, floating = C.POINTER(C.c_uint8), C.c_size_t, C.c_float
    lib.compositor_canvas_create.argtypes = [pixels, size, size, size]
    lib.compositor_canvas_create.restype = C.c_void_p
    lib.compositor_canvas_draw_image_rect.argtypes = [C.c_void_p, pixels, size, size, size,
                                                     floating, floating, floating, floating, floating, C.c_int, C.c_int]
    lib.compositor_canvas_draw_image_rect.restype = None
    lib.compositor_canvas_destroy.argtypes = [C.c_void_p]
    lib.compositor_canvas_destroy.restype = None
    raw = decode(reference['source'])
    source = (C.c_uint8 * len(raw)).from_buffer_copy(raw)
    backdrops = {name: decode(item) for name, item in reference['backdrops'].items()}
    worst = 0

    def compare(case, source, original, expected, width, height, label, tolerance=1):
        nonlocal worst
        destination = (C.c_uint8 * len(original)).from_buffer_copy(original)
        mode = {'sourceOver': 0, 'exclusion': 11, 'hue': 12, 'saturation': 13}[case['mode']]
        canvas = lib.compositor_canvas_create(destination, width, height, width * 4)
        assert canvas, 'Cannot create the real Skia byte canvas'
        try:
            lib.compositor_canvas_draw_image_rect(canvas, source, width, height, width * 4,
                                                  0, 0, width, height, case['opacity'], mode, 1)
        finally:
            lib.compositor_canvas_destroy(canvas)
        for index, (actual, native) in enumerate(zip(destination, expected)):
            delta = abs(actual - native)
            worst = max(worst, delta)
            assert delta <= tolerance, (case['mode'], label, case['opacity'],
                                'pixel', index // 4, 'channel', index % 4, actual, native)

    for case in reference['cases']:
        compare(case, source, backdrops[case['background']], decode(case['output']), 256, 256, case['background'])
    paired = reference['paired']
    assert len(paired['labels']) == 8
    raw = decode(paired['source'], 8, 1)
    source = (C.c_uint8 * len(raw)).from_buffer_copy(raw)
    for case in paired['cases']:
        compare(case, source, decode(case['input'], 8, 1), decode(case['output'], 8, 1), 8, 1, 'paired controls')
    print(f'Native Hue/Saturation OK (24 cases, 1179696 pixels, maximum {worst}/255)')

    blends = json.loads(gzip.decompress(
        (root / 'Tests/Fixtures/coregraphics-byte-blend-reference.json.gz').read_bytes()))
    assert blends['schema'] == 1 and blends['platform'] == 'macOS'
    assert set(blends['modes']) == {'sourceOver', 'exclusion'}
    matrix = {(background, opacity) for background in ['opaque', 'translucent', 'clear']
              for opacity in [1.0, 0.5, 0.25]}
    for name, mode in blends['modes'].items():
        assert len(mode['cases']) == 9
        assert {(case['background'], case['opacity']) for case in mode['cases']} == matrix
        raw = decode(mode['source'])
        source = (C.c_uint8 * len(raw)).from_buffer_copy(raw)
        for case in mode['cases']:
            compare(dict(case, mode=name), source, decode(case['input']), decode(case['output']),
                    256, 256, case['background'], tolerance=0)
    print('Native Source Over/Exclusion OK (18 cases, 1179648 pixels, exact bytes)')


if __name__ == '__main__':
    main(sys.argv[1])
