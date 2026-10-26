#!/usr/bin/env python3
"""Compare every default native curve capture without relaxing the one-byte limit."""
import argparse
import base64
import ctypes as c
import gzip
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    library = c.CDLL(args.library)

    def function(name, result, arguments):
        value = getattr(library, 'compositor_' + name)
        value.restype, value.argtypes = result, arguments
        return value

    pointer, scalar, integer, size = c.c_void_p, c.c_float, c.c_int, c.c_size_t
    create = function('canvas_create', pointer, [pointer, size, size, size])
    destroy = function('canvas_destroy', None, [pointer])
    path = function('path_create', pointer, [])
    delete = function('path_destroy', None, [pointer])
    concat = function('canvas_concat', None, [pointer] + [scalar] * 6)
    fill = function('canvas_fill_path', None, [pointer, pointer, integer] + [scalar] * 4)
    blend = function('canvas_set_blend_mode', None, [pointer, integer])
    clip = function('canvas_clip_rect', None, [pointer] + [scalar] * 4 + [integer])
    verbs = {
        'move': function('path_move_to', None, [pointer, scalar, scalar]),
        'line': function('path_line_to', None, [pointer, scalar, scalar]),
        'quad': function('path_quad_to', None, [pointer] + [scalar] * 4),
        'cubic': function('path_cubic_to', None, [pointer] + [scalar] * 6),
        'close': function('path_close', None, [pointer]),
    }
    fixture = Path(__file__).resolve().parents[1] / 'Tests/Fixtures/coregraphics-curve-reference.json.gz'
    reference = json.loads(gzip.decompress(fixture.read_bytes()))
    assert reference['schema'] == 1 and reference['platform'] == 'macOS'
    assert reference['flatness'] == 'default' and len(reference['cases']) == 94
    rows = []
    for case in reference['cases']:
        item = case['output']
        expected = base64.b64decode(item['rgbaBase64'], validate=True)
        assert hashlib.sha256(expected).hexdigest() == item['sha256']
        width, height = item['width'], item['height']
        assert item['rowBytes'] == width * 4 and item['bitsPerComponent'] == 8
        assert len(expected) == width * height * 4
        pixels = (c.c_ubyte * len(expected))()
        canvas, shape = create(pixels, width, height, width * 4), path()
        assert canvas and shape
        try:
            concat(canvas, *case['transform'])
            for segment in case['path']:
                verbs[segment['verb']](shape, *[v for point in segment['points'] for v in point])
            fill(canvas, shape, 0, *case['rgba'])
        finally:
            destroy(canvas)
            delete(shape)
        differences = [abs(a - b) for a, b in zip(pixels, expected)]
        rows.append({
            'name': case['name'],
            'maxRGBA': max(differences),
            'pixelsAboveOne': sum(max(differences[i:i + 4]) > 1 for i in range(0, len(expected), 4)),
        })
    report = {
        'cases': len(rows),
        'withinOne': sum(row['maxRGBA'] <= 1 for row in rows),
        'maxRGBA': max(row['maxRGBA'] for row in rows),
        'fixtureSHA256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
        'librarySHA256': hashlib.sha256(Path(args.library).read_bytes()).hexdigest(),
        'rows': rows,
    }
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    # Exercise the fully covered tile optimization as well as fractional boundary
    # tiles. Copy/clear must not turn the entire bounding box into source pixels.
    ellipse = next(case for case in reference['cases'] if case['name'] == 'ellipse-size-3-phase-0.0-identity')
    for mode in [16, 17]:
        background = bytes([30, 60, 90, 128])
        pixels = (c.c_ubyte * (96 * 72 * 4)).from_buffer_copy(background * (96 * 72))
        canvas, shape = create(pixels, 96, 72, 96 * 4), path()
        assert canvas and shape
        try:
            clip(canvas, 0, 0, 48, 72, 0)
            blend(canvas, mode)
            for segment in ellipse['path']:
                verbs[segment['verb']](shape, *[v for point in segment['points'] for v in point])
            fill(canvas, shape, 0, 0, 0, 0, 1)
        finally:
            destroy(canvas)
            delete(shape)

        def pixel(x, y):
            offset = (y * 96 + x) * 4
            return bytes(pixels[offset:offset + 4])

        assert pixel(4, 64) == background, 'Curve coverage touched an exterior pixel'
        assert pixel(60, 36) == background, 'Curve coverage lost the device clip'
        assert pixel(40, 36) == bytes([0, 0, 0, 0 if mode == 16 else 255])
    print('Curve coverage preserves device clips and copy/clear compositing')
    print(f"Native curves: {report['withinOne']}/{report['cases']} within one byte; max {report['maxRGBA']}")
    for row in rows:
        if row['maxRGBA'] > 1:
            print(f"FAIL {row['name']}: max {row['maxRGBA']}, {row['pixelsAboveOne']} pixels above one")
    return 0 if report['withinOne'] == report['cases'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
