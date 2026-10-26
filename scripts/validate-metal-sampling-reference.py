#!/usr/bin/env python3
"""Validate direct Metal sampler provenance, source storage and the complete recipe matrix."""
import base64
import hashlib
import itertools
import json
import math
from pathlib import Path
import struct
import sys


def validate(capture, reference, script):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    def raw(item, size):
        data = base64.b64decode(item['base64'], validate=True)
        require(len(data) == size, 'Bitmap size')
        require(hashlib.sha256(data).hexdigest() == item['sha256'], 'Bitmap hash')
        return data

    def f32(value):
        return struct.unpack('<f', struct.pack('<f', value))[0]

    require(capture['schema'] == 1 and capture['platform'] == 'macOS', 'Native schema/platform')
    require(bool(capture['device']) and bool(capture['os']), 'Native device/OS')
    require(capture['scriptSHA256'] == hashlib.sha256(script.read_bytes()).hexdigest(), 'Capture script hash')
    require(capture['sourceReferenceSHA256'] == hashlib.sha256(reference.read_bytes()).hexdigest(), 'Source reference hash')
    require((capture['width'], capture['height']) == (24, 16), 'Geometry')
    offsets = [(0, 0), (1 / 256, 1 / 256), (3 / 256, 3 / 256), (24 / 256, 24 / 256),
               (54 / 256, 54 / 256), (-54 / 256, -54 / 256), (0.409254816, 0),
               (1.409254816, 0), (0, 1.409254816), (3.29831846, 0),
               (0.09558051079511642, 0.09558051079511642)]
    offsets = [tuple(map(f32, offset)) for offset in offsets]
    require([tuple(o) for o in capture['offsets']] == offsets, 'Sampling offsets')
    fixtures = ['opaque-gradient', 'float-hdr', 'impulse']
    storage = ['RGBA8', 'RGBAh', 'RGBAf', 'RGBAhGPU']
    controls = {(c['fixture'], c['workingFormat']): c for c in json.loads(reference.read_text())['inputs']}
    inputs = capture['inputs']
    require(len(inputs) == 12 and {(i['fixture'], i['storage']) for i in inputs}
            == set(itertools.product(fixtures, storage)), 'Complete unique source matrix')
    float_sources = {}
    for item in inputs:
        source = base64.b64decode(controls[item['fixture'], 'RGBAf']['output']['floatBase64'], validate=True)
        values = [v[0] for v in struct.iter_unpack('<f', source)]
        if item['storage'] == 'RGBA8':
            expected = bytes(max(0, min(255, math.floor(f32(v * 255) + 0.5))) for v in values)
        elif item['storage'] == 'RGBAhGPU':
            gpu_data = raw(item['pixels'], 24 * 16 * 8)
            for value, (bits,) in zip(values, struct.iter_unpack('<H', gpu_data)):
                nearest = struct.unpack('<H', struct.pack('<e', value))[0]
                rounded = struct.unpack('<e', struct.pack('<H', nearest))[0]
                zero = nearest - 1 if abs(rounded) > abs(value) else nearest
                require(bits in [nearest, zero], 'GPU half-store conversion bounds')
            expected = gpu_data
        elif item['storage'] == 'RGBAh':
            expected = struct.pack('<' + 'e' * len(values), *values)
        else:
            expected = source
            float_sources[item['fixture']] = source
        require(raw(item['pixels'], len(expected)) == expected, 'Source storage conversion')
    keys = [(c['fixture'], c['storage'], c['resultType'], c['clamped'], c['operation'], tuple(c['offset'])) for c in capture['cases']]
    expected = set(itertools.product(fixtures, storage, ['float', 'half'], [False, True], ['sample'], offsets))
    expected |= set(itertools.product(fixtures, storage, ['float', 'half'], [False, True], ['compact'], offsets[1:5] + [offsets[10]]))
    require(len(keys) == 768 and len(set(keys)) == 768 and set(keys) == expected, 'Complete unique sampler matrix')
    for case in capture['cases']:
        require(type(case['clamped']) is bool, 'Clamp flag')
        data = raw(case['output'], 24 * 16 * 16)
        require(any(data) and all(math.isfinite(v[0]) for v in struct.iter_unpack('<f', data)), 'Empty/nonfinite sample')
        if case['operation'] == 'sample' and case['storage'] == 'RGBAf' and case['resultType'] == 'float' and case['offset'] == [0, 0]:
            require(data == float_sources[case['fixture']], 'Float point-sampling identity')


if __name__ == '__main__':
    capture_path, reference_path = map(Path, sys.argv[1:])
    validate(json.loads(capture_path.read_text()), reference_path,
             Path(__file__).with_name('capture-metal-sampling.swift'))
    print('Validated 12 texture sources and 768 direct Metal sampler/compact recipes, including native-coordinate replay, GPU half-store bounds and point identities')
