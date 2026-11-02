#!/usr/bin/env python3
"""Audit native precision controls and compare an analytical Gaussian model.

This is a diagnostic, not a renderer acceptance gate: reported model failures
remain failures. Uses the dependencies in scripts/parity-requirements.txt.
"""
import argparse
from pathlib import Path
import base64
import hashlib
import json
import math
import numpy as np
from scipy.ndimage import convolve1d
from scipy.special import erf, erfc


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path, help='Native coreimage-reference.json with 504 precision controls')
    parser.add_argument('--previous', type=Path, required=True, help='Earlier capture whose 358 cases must remain unchanged')
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--source-run', type=int, help='Optional native workflow run ID for provenance')
    return parser.parse_args()


def decode(item):
    raw = base64.b64decode(item['rgbaBase64'], validate=True)
    if hashlib.sha256(raw).hexdigest() != item['sha256']:
        raise ValueError('Native bitmap SHA256 mismatch')
    bits = item['bitsPerComponent']
    if bits not in [8, 32] or (item['width'], item['height']) != (96, 72):
        raise ValueError('Unexpected native bitmap dimensions or component format')
    if item['rowBytes'] != 96 * 4 * bits // 8 or len(raw) != item['rowBytes'] * 72:
        raise ValueError('Unexpected native bitmap row layout')
    dtype = '<f4' if item['bitsPerComponent'] == 32 else 'u1'
    array = np.frombuffer(raw, dtype=dtype).reshape(item['height'], item['width'], 4).astype(np.float32)
    if not np.isfinite(array).all():
        raise ValueError('Nonfinite native bitmap components')
    return array if dtype == '<f4' else array / 255


def model(source, sigma):
    radius = math.ceil(3 * sigma)
    x = np.arange(-radius, radius + 1)
    k = ((erf((x + .5) / (sigma * math.sqrt(2))) - erf((x - .5) / (sigma * math.sqrt(2)))) / 2).astype(np.float32)
    k[0] = k[-1] = erfc((radius - .5) / (sigma * math.sqrt(2))) / 2
    total = np.float32(0)
    for value in k:
        total = np.float32(total + value)
    k /= total
    return convolve1d(convolve1d(source, k, axis=1, mode='constant'), k, axis=0, mode='constant')


def main():
    args = arguments()
    data = json.loads(args.capture.read_text())
    previous = json.loads(args.previous.read_text())
    if data.get('cases') != previous.get('cases') or data.get('inputs') != previous.get('inputs'):
        raise ValueError('Preceding native cases or inputs changed')
    cases = data['workingPrecision']
    keys = {(c['sourceFormat'], c['fixture'], c['alphaLevel'], c['radius'], c['workingFormat']) for c in cases}
    expected = {(source, fixture, level, radius, working)
                for source in ['RGBA8', 'RGBAf']
                for fixture in ['opaque-rectangle', 'step-x', 'step-y', 'impulse']
                for level in [1, .5, .25] for radius in [.5, 1, 2, 5, 10, 17, 35]
                for working in ['default', 'RGBAh', 'RGBAf']}
    if len(cases) != 504 or keys != expected or len(data['cases']) != 358:
        raise ValueError('Missing or duplicate native control recipes')
    groups = {}
    rows = []
    for case in data['workingPrecision']:
        if (case['contextPolicy'] != 'shared-no-cache'
                or case['input']['bitsPerComponent'] != (32 if case['sourceFormat'] == 'RGBAf' else 8)
                or case['output']['float']['bitsPerComponent'] != 32
                or case['output']['byte']['bitsPerComponent'] != 8):
            raise ValueError('Unexpected native context policy or bitmap component format')
        key = (case['sourceFormat'], case['fixture'], case['alphaLevel'], case['radius'])
        values = {'input': decode(case['input']), 'float': decode(case['output']['float']),
                  'byte': decode(case['output']['byte'])}
        groups.setdefault(key, {})[case['workingFormat']] = values
        actual = model(values['input'], case['radius'])
        target = values['float']
        byte_error = abs(np.floor(np.clip(actual, 0, 1) * 255 + .5) - np.rint(values['byte'] * 255))
        float_error = abs(actual - target) * 255
        rows.append({**{k: case[k] for k in ['sourceFormat', 'fixture', 'alphaLevel', 'radius', 'workingFormat']},
                     'float16ExactFraction': float(np.mean(target.astype(np.float16).astype(np.float32) == target)),
                     'modelFloatMaxByteError': float(float_error.max()),
                     'modelAlphaMaxByteError': float(float_error[:, :, 3].max()),
                     'modelByteMaxError': float(byte_error.max()),
                     'modelAlphaByteMaxError': float(byte_error[:, :, 3].max()),
                     'modelAlphaAboveOne': int((byte_error[:, :, 3] > 1).sum())})

    comparisons = []
    for key, group in groups.items():
        default, half, full = [group[name] for name in ['default', 'RGBAh', 'RGBAf']]
        comparisons.append({'sourceFormat': key[0], 'fixture': key[1], 'alphaLevel': key[2], 'radius': key[3],
                            'defaultEqualsHalf': all(np.array_equal(default[kind], half[kind]) for kind in ['float', 'byte']),
                            'halfVsFullMaxByteError': float((abs(half['float'] - full['float']) * 255).max()),
                            'halfVsFullAlphaMaxByteError': float((abs(half['float'][:, :, 3] - full['float'][:, :, 3]) * 255).max())})

    linearity = []
    for key, group in groups.items():
        source_format, fixture, level, radius = key
        if source_format != 'RGBAf' or level == 1:
            continue
        for working, values in group.items():
            opaque = groups[(source_format, fixture, 1, radius)][working]['float']
            error = abs(values['float'] - opaque * level) * 255
            linearity.append({'fixture': fixture, 'alphaLevel': level, 'radius': radius, 'workingFormat': working,
                              'maxByteError': float(error.max()), 'alphaMaxByteError': float(error[:, :, 3].max())})

    phases = []
    reference = next(case for case in data['cases']
                     if case['fixture'] == 'impulse-phase-0' and case['radius'] == 10)
    first = decode(reference['output']['float'])[:, :, 3]
    for case in data['cases']:
        if case['fixture'].startswith('impulse-phase-') and case['radius'] == 10:
            alpha = np.roll(decode(case['output']['float'])[:, :, 3], -case['sourceOffsetX'], axis=1)
            phases.append({'offset': case['sourceOffsetX'], 'mass': float(alpha.sum()),
                           'alignedMaxByteError': float((abs(alpha - first) * 255).max()),
                           'alignedEqualsFirst': bool(np.array_equal(alpha, first))})

    summary = {'sourceRun': args.source_run, 'captureSha256': hashlib.sha256(args.capture.read_bytes()).hexdigest(),
               'captureScriptSha256': data['scriptSha256'], 'oldCasesPreserved': len(data['cases']), 'controls': len(rows),
               'defaultEqualsHalf': sum(row['defaultEqualsHalf'] for row in comparisons),
               'defaultHalfPairs': len(comparisons),
               'formats': {}, 'rows': rows, 'comparisons': comparisons, 'linearity': linearity,
               'nativeImpulsePhases': phases}
    for working in ['default', 'RGBAh', 'RGBAf']:
        selected = [r for r in rows if r['workingFormat'] == working]
        summary['formats'][working] = {
            'modelWithinOne': sum(r['modelByteMaxError'] <= 1 for r in selected),
            'modelAlphaWithinOne': sum(r['modelAlphaByteMaxError'] <= 1 for r in selected),
            'cases': len(selected),
            'float16ExactFractionMean': float(np.mean([r['float16ExactFraction'] for r in selected])),
            'floatAlphaLinearityMaxByteError': max(r['alphaMaxByteError'] for r in linearity if r['workingFormat'] == working)}
    output = args.report
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({k: v for k, v in summary.items()
                      if k not in ['rows', 'comparisons', 'linearity', 'nativeImpulsePhases']}, indent=2))
    print('Opaque sigma10:', [r for r in rows if r['sourceFormat'] == 'RGBA8' and r['fixture'] == 'opaque-rectangle' and r['alphaLevel'] == 1 and r['radius'] == 10])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
