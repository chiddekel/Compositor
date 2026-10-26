#!/usr/bin/env python3
"""Validate independent native unsharp/blur precision controls without image tolerances."""
import argparse
import base64
import hashlib
import itertools
import json
import math
from pathlib import Path
import struct


def validate(reference, script):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    def raw(item, key, size):
        data = base64.b64decode(item[key + 'Base64'], validate=True)
        require(len(data) == size, key + ' byte count')
        require(hashlib.sha256(data).hexdigest() == item[key + 'SHA256'], key + ' SHA256')
        return data

    def output(item):
        floats = raw(item, 'float', 24 * 16 * 16)
        require(all(math.isfinite(v[0]) for v in struct.iter_unpack('<f', floats)), 'Nonfinite native output')
        bytes_ = raw(item, 'rgba', 24 * 16 * 4)
        require(any(floats) and any(bytes_), 'Empty native output')
        require(isinstance(item['description'], str) and 0 < len(item['description']) <= 65536,
                'Missing/truncated native graph')

    def f32(value):
        return struct.unpack('<f', struct.pack('<f', value))[0]

    require(reference['schema'] == 1 and reference['platform'] == 'macOS', 'Native schema/platform')
    require(reference['scriptSHA256'] == hashlib.sha256(script.read_bytes()).hexdigest(), 'Capture script SHA256')
    require(bool(reference['device']) and bool(reference['os']), 'Native device/OS')
    require((reference['width'], reference['height']) == (24, 16), 'Geometry')
    require(reference['radii'] == [1, 2, 5] and reference['intensities'] == [0, 0.5, 1, 2], 'Recipes')
    fixtures = ['opaque-gradient', 'overlay-gradient', 'float-hdr', 'impulse']
    formats = ['RGBAh', 'RGBAf']
    inputs = reference['inputs']
    require(len(inputs) == 8 and {(s['fixture'], s['workingFormat']) for s in inputs}
            == set(itertools.product(fixtures, formats)), 'Complete input matrix')
    controls = {}
    for sample in inputs:
        name = sample['fixture']
        require(sample['sourceFormat'] == ('RGBAf' if name == 'float-hdr' else 'RGBA8'), 'Input format')
        data = raw(sample, 'source', 24 * 16 * (16 if name == 'float-hdr' else 4))
        expected = bytearray()
        for y in range(16):
            for x in range(24):
                if name == 'impulse':
                    expected.extend([255 if x == 12 and y == 8 else 0] * 4)
                elif name == 'float-hdr':
                    alpha = [0, 0.25, 0.5, 1][(x // 6 + y // 4) % 4]
                    expected.extend(struct.pack('<4f', f32(f32(f32(x / 23) * 3) - 0.5) * alpha,
                                                f32(y / 15) * alpha, 1.25 * alpha, alpha))
                else:
                    alpha = (0 if x < 3 or y < 3 or x > 20 or y > 12 else 160) if name == 'overlay-gradient' else 255
                    expected.extend([(x * 255 // 23) * alpha // 255, (y * 255 // 15) * alpha // 255,
                                     (220 if name == 'overlay-gradient' else 100) * alpha // 255, alpha])
        require(data == expected, 'Procedural source pixels')
        output(sample['output'])
        controls[name, sample['workingFormat']] = sample['output']
    expected = {(fixture, format_, clamped, 'CIGaussianBlur', radius, None)
                for fixture, format_, clamped, radius in itertools.product(fixtures, formats, [False, True], [1, 2, 5])}
    expected |= {(fixture, format_, clamped, 'CIUnsharpMask', radius, intensity)
                 for fixture, format_, clamped, radius, intensity in
                 itertools.product(fixtures, formats, [False, True], [1, 2, 5], [0, 0.5, 1, 2])}
    cases = reference['cases']
    keys = [(s['fixture'], s['workingFormat'], s['clamped'], s['filter'], s['radius'], s.get('intensity')) for s in cases]
    require(len(cases) == 240 and len(set(keys)) == 240 and set(keys) == expected, 'Complete unique filter matrix')
    for sample in cases:
        require(type(sample['clamped']) is bool, 'Clamp flag')
        output(sample['output'])
        if sample['filter'] == 'CIUnsharpMask' and sample['intensity'] == 0:
            control = controls[sample['fixture'], sample['workingFormat']]
            require(all(sample['output'][key] == control[key] for key in ['floatSHA256', 'rgbaSHA256']),
                    'Zero-intensity identity')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    args = parser.parse_args()
    validate(json.loads(args.capture.read_text()), Path(__file__).with_name('capture-coreimage-unsharp.swift'))
    print('Validated 8 source controls and 240 native filter/format/coverage recipes, including every identity')


if __name__ == '__main__':
    main()
