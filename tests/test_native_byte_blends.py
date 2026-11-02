#!/usr/bin/env python3
"""Compare actual byte canvas outputs against independent native buffer hashes."""
import ctypes as C
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('blend_validator', ROOT / 'scripts/validate-native-byte-blends.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def main(library):
    reference = json.loads((ROOT / 'Tests/Fixtures/coregraphics-separable-byte-reference.json').read_text())
    assert reference['schema'] == 1 and reference['platform'] == 'macOS'
    assert (reference['width'], reference['height']) == (256, 256)
    assert reference['scriptSHA256'] == hashlib.sha256((ROOT / 'scripts/capture-native-byte-blends.swift').read_bytes()).hexdigest()
    modes = (1, 2, 3, 4, 5, 10)
    expected = {(m, d, o) for m in modes for d in (1, 2, 4) for o in (True, False)}
    lib = C.CDLL(library)
    pixels, size, floating = C.POINTER(C.c_uint8), C.c_size_t, C.c_float
    lib.compositor_canvas_create.argtypes = [pixels, size, size, size]
    lib.compositor_canvas_create.restype = C.c_void_p
    lib.compositor_canvas_draw_image_rect.argtypes = [C.c_void_p, pixels, size, size, size,
                                                     floating, floating, floating, floating, floating, C.c_int, C.c_int]
    lib.compositor_canvas_draw_image_rect.restype = None
    lib.compositor_canvas_destroy.argtypes = [C.c_void_p]
    lib.compositor_canvas_destroy.restype = None
    seen = set()
    for case in reference['cases']:
        mode, divisor, opaque = key = (case['mode'], case['divisor'], case['opaqueBackdrop'])
        if mode not in modes:
            continue
        assert key in expected and key not in seen
        seen.add(key)
        source, backdrop = validator.inputs(opaque)
        assert hashlib.sha256(source).hexdigest() == case['sourceSHA256']
        assert hashlib.sha256(backdrop).hexdigest() == case['backdropSHA256']
        src = (C.c_uint8 * len(source)).from_buffer_copy(source)
        dst = (C.c_uint8 * len(backdrop)).from_buffer_copy(backdrop)
        canvas = lib.compositor_canvas_create(dst, 256, 256, 1024)
        assert canvas, 'Real byte canvas must be available'
        try:
            lib.compositor_canvas_draw_image_rect(canvas, src, 256, 256, 1024,
                0, 0, 256, 256, 1 / divisor, mode, 1)
        finally:
            lib.compositor_canvas_destroy(canvas)
        assert hashlib.sha256(bytes(dst)).hexdigest() == case['outputSHA256'], key
    assert seen == expected
    print('Native Multiply/Screen/Overlay/Darken/Lighten/Difference: 36 buffers, 2359296 pixels match exactly')

    color_reference = json.loads((ROOT / 'Tests/Fixtures/coregraphics-color-corpus-reference.json').read_text())
    assert color_reference['schema'] == 1 and color_reference['platform'] == 'macOS'
    assert color_reference['blendModeRawValue'] == 14
    width, height = color_reference['width'], color_reference['height']
    assert (width, height) == (96, 72)
    base, foreground = bytearray(), bytearray()
    for y in range(height):
        for x in range(width):
            red, green = x * 255 // 95, y * 255 // 71
            base.extend((red, green, 100, 255))
            alpha = 0 if x < 12 or y < 12 or x > 80 or y > 58 else 160
            foreground.extend((red * alpha // 255, green * alpha // 255,
                               220 * alpha // 255, alpha))
    for case in color_reference['cases']:
        expected_bytes = (ROOT / 'Tests/Fixtures' / case['rawRGBA']).read_bytes()
        assert len(expected_bytes) == case['bytes']
        assert hashlib.sha256(expected_bytes).hexdigest() == case['rawRGBA_SHA256']
        dst = (C.c_uint8 * len(base)).from_buffer_copy(base)
        src = (C.c_uint8 * len(foreground)).from_buffer_copy(foreground)
        canvas = lib.compositor_canvas_create(dst, width, height, width * 4)
        assert canvas, 'Real byte canvas must be available'
        try:
            lib.compositor_canvas_draw_image_rect(
                canvas, src, width, height, width * 4,
                0, 0, width, height, case['opacityPercent'] / 100,
                color_reference['blendModeRawValue'], 1)
        finally:
            lib.compositor_canvas_destroy(canvas)
        assert bytes(dst) == expected_bytes, case['macPNG']
    print('Native Core Graphics corpus Color: 2 buffers, 13824 pixels match exactly')

    separable_reference = json.loads((ROOT / 'Tests/Fixtures/coregraphics-byte-blend-corpus-reference.json').read_text())
    assert separable_reference['schema'] == 1 and separable_reference['platform'] == 'macOS'
    assert separable_reference['upstream'] == color_reference['upstream']
    assert (separable_reference['width'], separable_reference['height']) == (width, height)
    seen_corpus_modes = set()
    for case in separable_reference['cases']:
        mode, opacity = case['blendModeRawValue'], case['opacityPercent']
        assert mode in (6, 7, 9) and opacity in (50, 100)
        assert (mode, opacity) not in seen_corpus_modes
        seen_corpus_modes.add((mode, opacity))
        expected_bytes = (ROOT / 'Tests/Fixtures' / case['rawRGBA']).read_bytes()
        assert len(expected_bytes) == case['bytes']
        assert hashlib.sha256(expected_bytes).hexdigest() == case['rawRGBA_SHA256']
        dst = (C.c_uint8 * len(base)).from_buffer_copy(base)
        src = (C.c_uint8 * len(foreground)).from_buffer_copy(foreground)
        canvas = lib.compositor_canvas_create(dst, width, height, width * 4)
        assert canvas, 'Real byte canvas must be available'
        try:
            lib.compositor_canvas_draw_image_rect(
                canvas, src, width, height, width * 4,
                0, 0, width, height, opacity / 100,
                mode, 1)
        finally:
            lib.compositor_canvas_destroy(canvas)
        assert bytes(dst) == expected_bytes, case['macPNG']
    assert seen_corpus_modes == {
        (mode, opacity) for mode in (6, 7, 9) for opacity in (50, 100)
    }
    print('Native Core Graphics corpus Color Dodge/Burn/Hard Light: 6 buffers, 41472 pixels match exactly')


if __name__ == '__main__':
    main(sys.argv[1])
