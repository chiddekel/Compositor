#!/usr/bin/env python3
"""Compare pixel-aligned high-quality minification with independent native bitmap captures."""
import argparse
import base64
import ctypes as c
import gzip
import hashlib
import json
import math
from pathlib import Path
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library')
    parser.add_argument('--baseline-library', help='Compare legacy geometry with the preceding renderer byte for byte')
    parser.add_argument('--characterize-legacy', action='store_true',
                        help='Report native differences for fractional/nearest controls separately from supported cases')
    parser.add_argument('--characterize-geometry', action='store_true',
                        help='Report the additional alpha, fractional and aligned native geometry controls')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    library = c.CDLL(args.library)

    def function(name, result, arguments, loaded=library):
        value = getattr(loaded, 'compositor_' + name)
        value.restype, value.argtypes = result, arguments
        return value

    pointer, scalar, integer, size = c.c_void_p, c.c_float, c.c_int, c.c_size_t
    create = function('canvas_create_ex', pointer, [pointer, size, size, size, integer])
    destroy = function('canvas_destroy', None, [pointer])
    draw = function('canvas_draw_image_rect_ex', None,
                    [pointer, pointer, size, size, size, integer] + [scalar] * 5 + [integer, integer])
    fixture = Path(__file__).resolve().parents[1] / 'Tests/Fixtures/coregraphics-sampling-reference.json.gz'
    reference = json.loads(gzip.decompress(fixture.read_bytes()))
    assert reference['schema'] == 1 and reference['platform'] == 'macOS'
    assert reference['quality'] == 'high' and len(reference['cases']) == 24
    assert len(reference['samplingLinearity']) == 104
    assert len(reference['samplingCorners']) == 80
    assert len(reference['samplingSignals']) == 2

    def unpack(item):
        raw = base64.b64decode(item['rgbaBase64'], validate=True)
        assert hashlib.sha256(raw).hexdigest() == item['sha256']
        assert len(raw) == item['rowBytes'] * item['height']
        assert item['bitsPerComponent'] in [8, 32]
        assert item['rowBytes'] == item['width'] * (16 if item['bitsPerComponent'] == 32 else 4)
        return raw

    rows = []

    def render(block, source, output, quality=4, renderer=None, draw_size=None):
        make, dispose, paint = renderer or (create, destroy, draw)
        source_bytes = unpack(source)
        floating = source['bitsPerComponent'] == 32
        assert output['bitsPerComponent'] == source['bitsPerComponent']
        source_pixels = c.create_string_buffer(source_bytes)
        pixels = (c.c_ubyte * (output['rowBytes'] * output['height']))()
        format_code = 4 if floating else 0
        canvas = make(pixels, output['width'], output['height'], output['rowBytes'], format_code)
        assert canvas
        try:
            # The bitmap and image-space flips cancel, including fractional
            # extents. The backend receives a direct top-to-bottom draw.
            width, height = draw_size or (source['width'] / block, source['height'] / block)
            paint(canvas, source_pixels, source['width'], source['height'], source['rowBytes'], format_code,
                  0, 0, width, height, 1, 17, quality)
        finally:
            dispose(canvas)
        return bytes(pixels)

    def compare(name, block, source, output, quality=4, draw_size=None):
        expected_bytes = unpack(output)
        pixels = render(block, source, output, quality, draw_size=draw_size)
        floating = source['bitsPerComponent'] == 32
        if floating:
            actual = struct.unpack('<' + 'f' * (len(pixels) // 4), bytes(pixels))
            expected = struct.unpack('<' + 'f' * (len(expected_bytes) // 4), expected_bytes)
            assert all(math.isfinite(value) for value in actual)
            differences = [abs(a - b) * 255 for a, b in zip(actual, expected)]
        else:
            differences = [abs(a - b) for a, b in zip(pixels, expected_bytes)]
        return {'name': name, 'format': 'float' if floating else 'byte', 'block': block,
                'maxByteError': max(differences), 'channelsAboveOne': sum(d > 1 for d in differences)}

    def check(name, block, source, output, draw_size=None):
        rows.append(compare(name, block, source, output, draw_size=draw_size))

    for case in reference['cases']:
        check(case['fixture'], case['block'], case['input'], case['output'])
        check(case['fixture'], case['block'], case['floating']['input'], case['floating']['output'])
    for case in reference['samplingLinearity']:
        name = f"{case['mode']}-axis-{case['axis']}-at-{case['position']}-base-{case['base']}-amp-{case['amplitude']}"
        check(name, case['block'], case['input'], case['output'])
    for case in reference['samplingSignals']:
        check(f"{case['fixture']}-alpha-{case['alpha']}", case['block'], case['input'], case['output'])
    legacy = []
    for case in reference['samplingCorners']:
        width, height, block = case['sourceWidth'], case['sourceHeight'], case['block']
        if case['quality'] == 'high' and width % block == 0 and height % block == 0:
            check(f'corner-{width}x{height}', block, case['input'], case['output'])
        else:
            # Fractional/nearest draws retain the existing backend. Their native
            # references remain available for subsequent geometry work.
            legacy.append(case)
    assert len(rows) == 172 and len(legacy) == 62
    scales_fixture = fixture.with_name('coregraphics-sampling-scales-reference.json.gz')
    scales = json.loads(gzip.decompress(scales_fixture.read_bytes()))
    assert scales['schema'] == 1 and scales['platform'] == 'macOS' and len(scales['cases']) == 256
    scale_legacy = []
    for case in scales['cases']:
        source, output = case['input'], case['output']
        width, height = output['width'], output['height']
        # This is the adapter's currently supported whole-pixel minification
        # range. Minor reductions and mixed magnification remain explicit controls.
        supported = case['quality'] == 'high' and all(
            original == target or original >= 2 * target
            for original, target in [(source['width'], width), (source['height'], height)])
        if supported:
            check(f"scale-{case['mode']}-{source['width']}x{source['height']}-to-{width}x{height}",
                  1, source, output, draw_size=(width, height))
        else:
            scale_legacy.append(case)
    assert len(rows) == 204 and len(scale_legacy) == 224
    fallback_identical = None
    scale_fallback_identical = None
    if args.baseline_library:
        baseline = c.CDLL(args.baseline_library)
        renderer = (
            function('canvas_create_ex', pointer, [pointer, size, size, size, integer], baseline),
            function('canvas_destroy', None, [pointer], baseline),
            function('canvas_draw_image_rect_ex', None,
                     [pointer, pointer, size, size, size, integer] + [scalar] * 5 + [integer, integer], baseline),
        )
        fallback_identical = 0
        for case in legacy:
            quality = 4 if case['quality'] == 'high' else 1
            actual = render(case['block'], case['input'], case['output'], quality)
            before = render(case['block'], case['input'], case['output'], quality, renderer)
            key = (case['sourceWidth'], case['sourceHeight'], case['block'], case['floating'], case['quality'])
            assert actual == before, f'Legacy sampling changed: {key}'
            fallback_identical += 1
        scale_fallback_identical = 0
        for case in scale_legacy:
            source, output = case['input'], case['output']
            quality = 4 if case['quality'] == 'high' else 1
            draw_size = (output['width'], output['height'])
            actual = render(1, source, output, quality, draw_size=draw_size)
            before = render(1, source, output, quality, renderer, draw_size)
            key = (case['mode'], source['width'], source['height'], draw_size, case['floating'], case['quality'])
            assert actual == before, f'Legacy scale sampling changed: {key}'
            scale_fallback_identical += 1
    report = {'cases': len(rows), 'withinOne': sum(row['maxByteError'] <= 1 for row in rows),
              'maxByteError': max(row['maxByteError'] for row in rows),
              'fixtureSHA256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
              'librarySHA256': hashlib.sha256(Path(args.library).read_bytes()).hexdigest(),
              'legacyControls': len(legacy), 'legacyByteIdentical': fallback_identical,
              'scaleFixtureSHA256': hashlib.sha256(scales_fixture.read_bytes()).hexdigest(),
              'scaleLegacyControls': len(scale_legacy), 'scaleLegacyByteIdentical': scale_fallback_identical,
              'rows': rows}
    if args.characterize_legacy:
        legacy_rows = []
        for case in legacy:
            quality = case['quality']
            row = compare(f"corner-{case['sourceWidth']}x{case['sourceHeight']}", case['block'],
                          case['input'], case['output'], 4 if quality == 'high' else 1)
            row['quality'] = quality
            legacy_rows.append(row)
        report['legacyNativeComparison'] = {
            'cases': len(legacy_rows),
            'withinOne': sum(row['maxByteError'] <= 1 for row in legacy_rows),
            'maxByteError': max(row['maxByteError'] for row in legacy_rows),
            'rows': legacy_rows,
        }
    if args.characterize_geometry:
        geometry_fixture = fixture.with_name('coregraphics-sampling-geometry-reference.json.gz')
        geometry = json.loads(gzip.decompress(geometry_fixture.read_bytes()))
        assert geometry['schema'] == 1 and geometry['platform'] == 'macOS'
        geometry_rows = []
        for section, count in [('samplingGeometry', 144), ('samplingAlphaGeometry', 432),
                               ('samplingPeriodicGeometry', 24)]:
            assert len(geometry[section]) == count
            for case in geometry[section]:
                quality = case['quality']
                assert quality in ['none', 'high']
                for key in ['output', 'alignedOutput']:
                    output = case[key]
                    draw_size = (output['width'], output['height']) if key == 'alignedOutput' else None
                    row = compare(f"{case['mode']}-{case['sourceWidth']}x{case['sourceHeight']}",
                                  case['block'], case['input'], output, 4 if quality == 'high' else 1,
                                  draw_size=draw_size)
                    row.update(quality=quality, bounds='aligned' if draw_size else 'fractional',
                               alphaMode=case.get('alphaMode', 'ramp' if section == 'samplingPeriodicGeometry' else 'opaque'))
                    geometry_rows.append(row)
        assert len(geometry_rows) == 1200
        report['geometryNativeComparison'] = {
            'cases': len(geometry_rows),
            'withinOne': sum(row['maxByteError'] <= 1 for row in geometry_rows),
            'maxByteError': max(row['maxByteError'] for row in geometry_rows),
            'fixtureSHA256': hashlib.sha256(geometry_fixture.read_bytes()).hexdigest(),
            'rows': geometry_rows,
        }
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Native image sampling: {report['withinOne']}/{report['cases']} within one byte; max {report['maxByteError']:.6g}")
    print(f'Legacy geometry: {fallback_identical}/62 byte-identical' if args.baseline_library
          else 'Legacy geometry: baseline comparison not requested (62 controls)')
    print(f'Legacy scale controls: {scale_fallback_identical}/224 byte-identical' if args.baseline_library
          else 'Legacy scale controls: baseline comparison not requested (224 controls)')
    if args.characterize_legacy:
        comparison = report['legacyNativeComparison']
        print(f"Legacy native differences (diagnostic): {comparison['withinOne']}/{comparison['cases']} "
              f"within one byte; max {comparison['maxByteError']:.6g}")
    if args.characterize_geometry:
        comparison = report['geometryNativeComparison']
        print(f"Additional geometry (diagnostic): {comparison['withinOne']}/{comparison['cases']} "
              f"within one byte; max {comparison['maxByteError']:.6g}")
    for row in rows:
        if row['maxByteError'] > 1:
            print(f"FAIL {row['name']} {row['format']} block {row['block']}: {row['maxByteError']:.6g}")
    return 0 if report['withinOne'] == report['cases'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
