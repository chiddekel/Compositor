#!/usr/bin/env python3
"""Validate native RAW diagnostic buffers and their exact generated input files."""
import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import struct


def validate(reference, folder):
    assert reference['schema'] in (1, 2) and reference['platform'] == 'macOS'
    assert reference['workingFormat'] == 'RGBAh'
    assert reference['workingColorSpace'] == 'extendedLinearSRGB'
    expected_inputs = {f'sensor-{i}.dng' for i in range(5)} | {'precision-ramp.dng'}
    assert len(reference['inputs']) == 6
    assert {item['file'] for item in reference['inputs']} == expected_inputs
    controls = {'decoder-default': None, 'boost-0': (0, 0), 'boost-0.5': (0, 0.5), 'boost-1': (0, 1),
                'exposure-minus-1-boost-0': (-1, 0), 'exposure-plus-1-boost-0': (1, 0),
                'exposure-minus-1-boost-1': (-1, 1), 'exposure-plus-1-boost-1': (1, 1)}
    white_balance = {}
    if reference['schema'] == 2:
        for boost in (0, 1):
            for name, field, value in [('temperature-3000', 'temperature', 3000),
                                       ('temperature-8000', 'temperature', 8000),
                                       ('tint-minus-50', 'tint', -50), ('tint-plus-50', 'tint', 50)]:
                key = f'{name}-boost-{boost}'
                controls[key] = (0, boost)
                white_balance[key] = (field, value)
    buffer_count = 0
    for item in reference['inputs']:
        assert hashlib.sha256((folder / item['file']).read_bytes()).hexdigest() == item['sha256']
        assert len(item['cases']) == len(controls)
        assert {case['name'] for case in item['cases']} == set(controls)
        expected_size = (1024, 128) if item['file'] == 'precision-ramp.dng' else (512, 512)
        for case in item['cases']:
            x, y, width, height = case['extent']
            assert all(math.isfinite(v) for v in case['extent'])
            assert (width, height) == expected_size
            assert case['sampleBounds'] == [x + 16, math.floor(y + height / 2), width - 32, 1]
            defaults, settings = case['defaults'], case['settings']
            for values in [defaults, settings]:
                assert all(math.isfinite(values[k]) for k in ['exposure', 'boost', 'temperature', 'tint', 'scale'])
                assert values['scale'] == 1 and values['draft'] is False
            expected_white = {field: defaults[field] for field in ('temperature', 'tint')}
            if case['name'] in white_balance:
                field, value = white_balance[case['name']]
                expected_white[field] = value
            assert all(settings[field] == value for field, value in expected_white.items())
            recipe = controls[case['name']]
            if recipe is None:
                assert settings == defaults
            else:
                assert (settings['exposure'], settings['boost']) == recipe
            assert len(case['buffers']) == 3
            assert {(b['colorSpace'], b['bitsPerComponent']) for b in case['buffers']} == {
                ('extendedLinearSRGB', 32), ('sRGB', 32), ('sRGB', 16)}
            for buffer in case['buffers']:
                bits = buffer['bitsPerComponent']
                row_bytes = int(width - 32) * 4 * bits // 8
                assert (buffer['width'], buffer['height'], buffer['rowBytes']) == (width - 32, 1, row_bytes)
                assert buffer['byteOrder'] == 'little'
                data = base64.b64decode(buffer['rgbaBase64'], validate=True)
                assert len(data) == row_bytes and hashlib.sha256(data).hexdigest() == buffer['sha256']
                samples = [value[0] for value in struct.iter_unpack('<f' if bits == 32 else '<H', data)]
                assert all(math.isfinite(v) for v in samples)
                # The RAW decoder returns an opaque frame in both domains.
                assert all(v == (1 if bits == 32 else 65535) for v in samples[3::4])
                buffer_count += 1
    return buffer_count


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('inputs', type=Path)
    args = parser.parse_args()
    count = validate(json.loads(args.reference.read_text()), args.inputs)
    print(f'Validated six RAW inputs, {count // 3} recipes and {count} diagnostic buffers')
