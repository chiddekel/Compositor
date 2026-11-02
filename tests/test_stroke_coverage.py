#!/usr/bin/env python3
"""Compare supported straight-stroke coverage with independent macOS bitmap captures."""
import base64
import ctypes as c
import gzip
import hashlib
import json
import math
from pathlib import Path
import sys


def main():
    library = c.CDLL(sys.argv[1])

    def function(name, result, arguments):
        value = getattr(library, 'compositor_' + name)
        value.restype, value.argtypes = result, arguments
        return value

    pointer, scalar, integer, size = c.c_void_p, c.c_float, c.c_int, c.c_size_t
    create = function('canvas_create', pointer, [pointer, size, size, size])
    destroy = function('canvas_destroy', None, [pointer])
    path = function('path_create', pointer, [])
    delete = function('path_destroy', None, [pointer])
    move = function('path_move_to', None, [pointer, scalar, scalar])
    line = function('path_line_to', None, [pointer, scalar, scalar])
    concat = function('canvas_concat', None, [pointer] + [scalar] * 6)
    stroke = function('canvas_stroke_path', None,
                      [pointer, pointer, scalar, integer, integer] + [scalar] * 5)
    blend = function('canvas_set_blend_mode', None, [pointer, integer])
    clip = function('canvas_clip_rect', None, [pointer] + [scalar] * 4 + [integer])
    fixture = Path(__file__).resolve().parents[1] / 'Tests/Fixtures/coregraphics-stroke-reference.json.gz'
    reference = json.loads(gzip.decompress(fixture.read_bytes()))
    assert reference['schema'] == 1 and reference['platform'] == 'macOS'
    assert len(reference['cases']) == 91
    checked = pixels_checked = 0
    for case in reference['cases']:
        item = case['output']
        expected = base64.b64decode(item['rgbaBase64'], validate=True)
        assert hashlib.sha256(expected).hexdigest() == item['sha256']
        assert len(expected) == item['rowBytes'] * item['height']
        a, b, skew, d, tx, ty = case['transform']
        dx, dy = [case['end'][i] - case['start'][i] for i in range(2)]
        device_length = math.hypot(a * dx + skew * dy, b * dx + d * dy)
        device_width = case['width'] * abs(a * d - b * skew) * math.hypot(dx, dy) / device_length
        # Narrow strokes and round caps have separate native rules; their captures
        # remain in the fixture for subsequent work, without weakening this limit.
        if device_width < 2 or case['cap'] == 'round':
            continue
        width, height = item['width'], item['height']
        assert item['rowBytes'] == width * 4 and item['bitsPerComponent'] == 8
        pixels = (c.c_ubyte * len(expected))()
        canvas, shape = create(pixels, width, height, width * 4), path()
        assert canvas and shape
        try:
            concat(canvas, a, b, skew, d, tx, ty)
            move(shape, *case['start'])
            line(shape, *case['end'])
            stroke(canvas, shape, case['width'], ['butt', 'round', 'square'].index(case['cap']),
                   0, 10, *case['rgba'])
        finally:
            destroy(canvas)
            delete(shape)
        maximum = max(abs(actual - native) for actual, native in zip(pixels, expected))
        assert maximum <= 1, f"{case['name']}: native RGBA maximum error {maximum}, limit 1"
        checked += 1
        pixels_checked += width * height
    assert checked == 52
    print(f'Native straight-stroke coverage: {checked} cases, {pixels_checked} pixels within one byte')

    # Coverage is a clip, not source transparency: copy and clear must preserve
    # destination pixels outside the footprint, including within its bounding box.
    for mode in [16, 17]:
        background = bytes([30, 60, 90, 128])
        pixels = (c.c_ubyte * (96 * 72 * 4)).from_buffer_copy(background * (96 * 72))
        canvas, shape = create(pixels, 96, 72, 96 * 4), path()
        assert canvas and shape
        try:
            clip(canvas, 0, 0, 48, 72, 0)
            blend(canvas, mode)
            move(shape, 8, 8)
            line(shape, 72, 56)
            stroke(canvas, shape, 3, 0, 0, 10, 0, 0, 0, 1)
        finally:
            destroy(canvas)
            delete(shape)

        def pixel(x, y):
            start = (y * 96 + x) * 4
            return bytes(pixels[start:start + 4])

        assert pixel(8, 55) == background, 'Coverage cleared pixels outside the stroke'
        assert pixel(60, 47) == background, 'Device clip was lost'
        assert pixel(40, 32) == bytes([0, 0, 0, 0 if mode == 16 else 255])
        edge = pixel(9, 7)
        assert 0 < edge[0] < background[0] and 0 < edge[3] < 255
    print('Straight-stroke coverage preserves device clips and copy/clear edge compositing')


if __name__ == '__main__':
    main()
