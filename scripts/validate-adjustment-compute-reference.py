#!/usr/bin/env python3
"""Validate the complete native Bokeh/two-pass-dispersion capture and provenance."""
import argparse
import base64
import hashlib
import itertools
import json
import math
from pathlib import Path
import struct


def validate(data, source, script, commit):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    def digest(raw):
        return hashlib.sha256(raw).hexdigest()

    def buffer(item, width, height, bits):
        require((item['width'], item['height'], item['bits']) == (width, height, bits), 'Buffer geometry/format')
        raw = base64.b64decode(item['rgbaBase64'], validate=True)
        require(len(raw) == width * height * 4 * bits // 8, 'Buffer length')
        require(digest(raw) == item['sha256'], 'Buffer SHA256')
        if bits == 16:
            require(all(math.isfinite(v[0]) for v in struct.iter_unpack('<e', raw)), 'Nonfinite half output')
        return raw

    require(data['schema'] == 1 and data['platform'] == 'macOS', 'Native platform/schema')
    require(data['upstreamCommit'] == commit, 'Upstream commit')
    require(data['scriptSHA256'] == digest(script.read_bytes()), 'Capture script SHA256')
    require(data['bokehParameterStride'] == 48 and data['dispersionParameterStride'] == 72, 'Parameter ABI')
    for key, name in [('bokeh', 'MetalBokeh'), ('dispersion', 'MetalDispersion')]:
        text = (source / f'Compositor/Rendering/{name}.swift').read_text()
        shader = text.split('private static let source = """\n', 1)[1].split('\n"""', 1)[0]
        require(data['shaderSHA256'][key] == digest(shader.encode()), f'{name} source SHA256')
    fixtures = ['hdr-gradient', 'impulse']
    require(set(data['bokehInputs']) == set(fixtures), 'Bokeh inputs')
    for name in fixtures:
        raw = buffer(data['bokehInputs'][name], 168, 144, 16)
        if name == 'impulse':
            expected_input = bytearray(len(raw))
            struct.pack_into('<4e', expected_input, (71 * 168 + 84) * 8, 1, 1, 1, 1)
            require(raw == expected_input, 'Bokeh impulse coordinates')
        else:
            values = [v[0] for v in struct.iter_unpack('<e', raw)]
            require(min(values) < 0 and max(values) >= 2, 'Extended-color input coverage')
    cases = data['bokehCases']
    expected = set(itertools.product(fixtures, range(4), [2, 7, 20], [0, 1], [False, True]))
    keys = [(c['fixture'], c['shape'], c['radius'], c['ring'], c['tile']) for c in cases]
    require(len(cases) == 96 and len(set(keys)) == 96 and set(keys) == expected, 'Exact Bokeh matrix')
    outputs = {}
    for key, case in zip(keys, cases):
        tile = case['tile']
        require(case['regionOrigin'] == [0, 0] and case['regionSize'] == [96, 72], 'Bokeh global region')
        require(case['inputTop'] == [-36, 108] and case['outputTop'] == ([13, 43] if tile else [0, 72]), 'Bokeh texture origins')
        outputs[key] = buffer(case['output'], 48 if tile else 96, 36 if tile else 72, 16)
        require(any(outputs[key]), 'Empty native Bokeh output')
    for key in expected:
        if not key[-1]:
            continue
        full, tile = outputs[key[:-1] + (False,)], outputs[key]
        cropped = b''.join(full[((29 + row) * 96 + 13) * 8:((29 + row) * 96 + 61) * 8] for row in range(36))
        require(cropped == tile, 'Native Bokeh tile must retain global aperture coordinates')
    buffer(data['dispersionInput'], 61, 61, 8)
    cases = data['dispersionCases']
    require(len(cases) == 4 and {(c['radial'], c['distance']) for c in cases} == set(itertools.product([0, 1], [4, 10])),
            'Exact dispersion matrix')
    for case in cases:
        require((case['blur'], case['reach'], case['spectral'], case['smear']) == (16, 30.5, 8, 8), 'Dispersion settings')
        pad = math.ceil(case['distance'] * (math.sqrt(2) if case['radial'] else 1)) + 2
        require(case['pad'] == pad, 'Dispersion intermediate extent')
        buffer(case['streaks'], 61 + pad * 2, 61 + pad * 2, 16)
        require(any(buffer(case['output'], 61, 61, 8)), 'Empty native dispersion output')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    validate(json.loads(args.capture.read_text()), args.source,
             Path(__file__).with_name('capture-adjustment-compute.swift'), args.commit)
    print('Validated 96 native Bokeh cases, all tiles, and 4 complete two-pass dispersion outputs')


if __name__ == '__main__':
    main()
