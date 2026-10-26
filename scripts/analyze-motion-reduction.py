#!/usr/bin/env python3
"""Identify a diagnostic motion-reduction model from native scanline captures.

Four radius-four impulse phases fit a fixed symmetric reduction kernel. Other
phases, step/stripe inputs and a two-stage radius-16.25 graph validate it without
refitting. This is a reconstruction diagnostic, not production renderer code or
an acceptance gate for angular motion. Requires NumPy (parity-requirements.txt).
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import numpy as np

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture', type=Path)
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
capture = args.capture
data = json.loads(capture.read_text())
assert (data['schema'], data['sourceWidth'], data['sourceHeight'], data['scanlineY']) == (1, 512, 8, 3)
width = data['sourceWidth']

def decode(item):
    raw = base64.b64decode(item['floatBase64'], validate=True)
    assert hashlib.sha256(raw).hexdigest() == item['floatSha256']
    values = np.frombuffer(raw, dtype='<f4').reshape(-1, 4)
    assert values.shape == (width, 4) and np.isfinite(values).all()
    return values[:, 0].astype(np.float64)

inputs = {(s['fixture'], s['phase']): decode(s['output']) for s in data['inputs']}
targets = {(s['fixture'], s['phase']): decode(s['output']) for s in data['cases']
           if s['filter'] == 'CIMotionBlur' and s['radius'] == 4}
expected_keys = {(fixture, phase) for fixture in ['impulse', 'step', 'stripes'] for phase in range(16)}
assert len(data['inputs']) == 48 and set(inputs) == set(targets) == expected_keys

def bspline_weights(x):
    return np.array([(1-x)**3/6, (3*x**3-6*x*x+4)/6,
                     (-3*x**3+3*x*x+3*x+1)/6, x**3/6])

def basis(source, offsets, quantized):
    q = (np.arange(width) + .5)/4 - .5
    lo = np.floor(q).astype(int)
    weights = bspline_weights(q-lo)
    # The usual two-linear-fetch cubic B-spline reconstruction. Texture
    # fractions, rather than the polynomial's input, may be hardware-quantized.
    indices, contributions = [], []
    for pair, shift in [(0, -1), (2, 1)]:
        group = weights[pair]+weights[pair+1]
        at = lo+shift+weights[pair+1]/group
        index = np.floor(at).astype(int)
        fraction = at-index
        if quantized:
            fraction = np.floor(fraction*256+.5)/256
        indices.extend([index, index+1])
        contributions.extend([group*(1-fraction), group*fraction])
    columns = []
    for first, second in offsets:
        column = np.zeros(width)
        for index, weight in zip(indices, contributions):
            for tap in [first, second]:
                column += weight*source[np.clip(index*4+tap, 0, width-1)]
        columns.append(column)
    return np.array(columns).T

rows = []
for reach in [6, 8, 10, 12, 14, 16]:
    # A factor-four output pixel center maps to source index 4*j+1.5.
    # Pair symmetric integer taps around that half-pixel center.
    offsets = [(t, 3-t) for t in range(2-reach, 2)]
    for quantized in [False, True]:
        train = [('impulse', p) for p in range(4)]
        matrix = np.concatenate([basis(inputs[key], offsets, quantized) for key in train])
        target = np.concatenate([targets[key] for key in train])
        taps, _, rank, singular = np.linalg.lstsq(matrix, target, rcond=None)
        errors = []
        for key in targets:
            actual = basis(inputs[key], offsets, quantized)@taps
            delta = np.abs(actual-targets[key])*255
            errors.append({'fixture':key[0], 'phase':key[1],
                           'usedForFitting':key in train,
                           'maxFloatByteError':float(np.max(delta)),
                           'worstX':int(np.argmax(delta)),
                           'interiorFloatByteError':float(np.max(delta[48:-48]))})
        rows.append({'reach':reach, 'quantizedTextureFractions':quantized,
                     'rank':int(rank), 'unknowns':len(taps),
                     'tapPairs':[[a,b,float(v)] for (a,b),v in zip(offsets,taps)],
                     'sum':float(2*sum(taps)), 'minimumTap':float(min(taps)),
                     'worstFloatByteError':max(e['maxFloatByteError'] for e in errors),
                     'errors':errors})
report = {'scope':'Diagnostic factor-four reduction model trained only on four impulse phases; no production changes',
          'captureSHA256':hashlib.sha256(capture.read_bytes()).hexdigest(), 'models':rows}
output = args.report
for row in rows:
    print(row['reach'], row['quantizedTextureFractions'], row['rank'], row['sum'],
          row['minimumTap'], row['worstFloatByteError'])

# Independent composition check: radius 16.25 uses two native factor-four
# reductions, whereas the fitted radius-four graph uses just one. No pixels
# from this larger-radius recipe participate in fitting the fixed reduction.
model = next(r for r in rows if r['reach'] == 10 and r['quantizedTextureFractions'])
taps = np.array([v for a,b,v in model['tapPairs']]*2)
tap_offsets = np.array([a for a,b,v in model['tapPairs']]+[b for a,b,v in model['tapPairs']])
taps /= np.sum(taps)

def composed(source, levels, half):
    def reduced(indices, level):
        if level == 0:
            return source[np.clip(indices, 0, width-1)]
        distinct, inverse = np.unique(indices, return_inverse=True)
        previous = distinct[:, None]*4+tap_offsets[None, :]
        values = np.sum(reduced(previous, level-1)*taps[None, :], axis=1)
        if half:
            values = values.astype(np.float16).astype(np.float64)
        return values[inverse].reshape(indices.shape)
    scale = 4**levels
    q = (np.arange(width)+.5)/scale-.5
    lo = np.floor(q).astype(int)
    weights = bspline_weights(q-lo)
    result = np.zeros(width)
    for pair, shift in [(0, -1), (2, 1)]:
        group = weights[pair]+weights[pair+1]
        at = lo+shift+weights[pair+1]/group
        index = np.floor(at).astype(int)
        fraction = np.floor((at-index)*256+.5)/256
        result += group*((1-fraction)*reduced(index, levels)+fraction*reduced(index+1, levels))
    return result

composition = []
for radius, levels in [(4,1), (16.25,2)]:
    samples = [s for s in data['cases'] if s['filter']=='CIMotionBlur' and s['radius']==radius]
    assert len(samples) == 48 and {(s['fixture'], s['phase']) for s in samples} == expected_keys
    for half in [False, True]:
        checks = []
        for sample in samples:
            key = (sample['fixture'], sample['phase'])
            expected = decode(sample['output'])
            actual = composed(inputs[key], levels, half)
            delta = np.abs(actual-expected)*255
            byte_data = base64.b64decode(sample['output']['rgbaBase64'], validate=True)
            assert len(byte_data) == width*4
            assert hashlib.sha256(byte_data).hexdigest() == sample['output']['byteSha256']
            native_bytes = np.frombuffer(byte_data,dtype='u1').reshape(-1,4)[:,0]
            quantized = np.clip(np.floor(actual*255+.5),0,255)
            checks.append({'fixture':key[0],'phase':key[1],
                           'floatMaxByteError':float(np.max(delta)),
                           'interiorFloatMaxByteError':float(np.max(delta[48:-48])),
                           'byteMaxError':int(np.max(np.abs(quantized-native_bytes)))})
        entry = {'radius':radius,'levels':levels,'halfIntermediates':half,'cases':checks,
                 'withinOneByte':sum(c['byteMaxError']<=1 for c in checks)}
        composition.append(entry)
        print('COMPOSED',radius,half,entry['withinOneByte'],'/',len(checks),
              'float',max(c['floatMaxByteError'] for c in checks))
report['independentComposition'] = composition
output.write_text(json.dumps(report, indent=2)+'\n')
