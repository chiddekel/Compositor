#!/usr/bin/env python3
"""Compare independently produced Mac/Linux renders; missing evidence is a failure."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageCms
from scipy.ndimage import uniform_filter


def lab(rgb):
    linear = np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055) ** 2.4)
    xyz = linear @ np.array([[.4124564, .3575761, .1804375],
                             [.2126729, .7151522, .0721750],
                             [.0193339, .1191920, .9503041]]).T
    xyz /= [.95047, 1, 1.08883]
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack((116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])), axis=-1)


def delta_e(a, b):
    """CIEDE2000, with unit parametric factors and angles in radians."""
    l1, a1, b1 = np.moveaxis(a, -1, 0)
    l2, a2, b2 = np.moveaxis(b, -1, 0)
    c = (np.hypot(a1, b1) + np.hypot(a2, b2)) / 2
    g = .5 * (1 - np.sqrt(c ** 7 / (c ** 7 + 25 ** 7)))
    ap1, ap2 = (1 + g) * a1, (1 + g) * a2
    c1, c2 = np.hypot(ap1, b1), np.hypot(ap2, b2)
    h1, h2 = np.mod(np.arctan2(b1, ap1), 2 * np.pi), np.mod(np.arctan2(b2, ap2), 2 * np.pi)
    dh = h2 - h1
    dh = np.where(dh > np.pi, dh - 2 * np.pi, np.where(dh < -np.pi, dh + 2 * np.pi, dh))
    dh = np.where(c1 * c2 == 0, 0, dh)
    dl, dc, dh = l2 - l1, c2 - c1, 2 * np.sqrt(c1 * c2) * np.sin(dh / 2)
    lm, cm = (l1 + l2) / 2, (c1 + c2) / 2
    hm = np.where(np.abs(h1 - h2) <= np.pi, (h1 + h2) / 2,
                  np.where(h1 + h2 < 2 * np.pi, (h1 + h2 + 2 * np.pi) / 2, (h1 + h2 - 2 * np.pi) / 2))
    hm = np.where(c1 * c2 == 0, h1 + h2, hm)
    t = 1 - .17 * np.cos(hm - np.pi / 6) + .24 * np.cos(2 * hm) + .32 * np.cos(3 * hm + np.pi / 30) - .20 * np.cos(4 * hm - 63 * np.pi / 180)
    sl = 1 + .015 * (lm - 50) ** 2 / np.sqrt(20 + (lm - 50) ** 2)
    sc, sh = 1 + .045 * cm, 1 + .015 * cm * t
    rt = -2 * np.sqrt(cm ** 7 / (cm ** 7 + 25 ** 7)) * np.sin(np.pi / 3 * np.exp(-((hm * 180 / np.pi - 275) / 25) ** 2))
    return np.sqrt(np.maximum(0, (dl / sl) ** 2 + (dc / sc) ** 2 + (dh / sh) ** 2 + rt * (dc / sc) * (dh / sh)))


def pixels(path):
    with Image.open(path) as image:
        image.load()
        alpha = np.asarray(image.convert('RGBA'), dtype=np.float64)[..., 3:] / 255
        if image.info.get('icc_profile'):
            import io
            image = ImageCms.profileToProfile(image.convert('RGB'),
                        ImageCms.ImageCmsProfile(io.BytesIO(image.info['icc_profile'])),
                        ImageCms.createProfile('sRGB'), outputMode='RGB')
        rgb = np.asarray(image.convert('RGB'), dtype=np.float64) / 255
        return np.concatenate((rgb, alpha), axis=-1)


def metrics(a, b):
    if a.shape != b.shape:
        raise ValueError(f'dimensions differ: {a.shape} vs {b.shape}')
    # Check premultiplied channels and alpha; compare visible color on BOTH black and white.
    pa, pb = a[..., :3] * a[..., 3:], b[..., :3] * b[..., 3:]
    channel = np.abs(np.concatenate((pa - pb, a[..., 3:] - b[..., 3:]), axis=-1))
    differences = [delta_e(lab(pa + matte * (1 - a[..., 3:])), lab(pb + matte * (1 - b[..., 3:]))) for matte in (0, 1)]
    de = np.maximum(*differences)
    mse = float(np.mean(channel ** 2))
    # Local 7x7 SSIM, averaged over premultiplied RGB and alpha.
    aa = np.concatenate((pa, a[..., 3:]), axis=-1)
    bb = np.concatenate((pb, b[..., 3:]), axis=-1)
    ux, uy = uniform_filter(aa, (7, 7, 1)), uniform_filter(bb, (7, 7, 1))
    vx = np.maximum(0, uniform_filter(aa * aa, (7, 7, 1)) - ux * ux)
    vy = np.maximum(0, uniform_filter(bb * bb, (7, 7, 1)) - uy * uy)
    cov = uniform_filter(aa * bb, (7, 7, 1)) - ux * uy
    ssim = ((2 * ux * uy + .01 ** 2) * (2 * cov + .03 ** 2)) / ((ux * ux + uy * uy + .01 ** 2) * (vx + vy + .03 ** 2))
    mask_a, mask_b = a[..., 3] > .1, b[..., 3] > .1
    union = np.count_nonzero(mask_a | mask_b)
    return {'channel_max': float(channel.max() * 255), 'alpha_max': float(np.abs(a[..., 3] - b[..., 3]).max() * 255),
            'delta_e_mean': float(de.mean()), 'delta_e_max': float(de.max()),
            'psnr': 999.0 if mse == 0 else -10 * math.log10(mse), 'ssim': float(ssim.mean()),
            'glyph_iou': float(np.count_nonzero(mask_a & mask_b) / union) if union else 1.0}


POLICIES = {
    'blend': {'channel_max': ('max', 1)},
    'adjustment': {'delta_e_mean': ('max', .5), 'delta_e_max': ('max', 2), 'alpha_max': ('max', 1)},
    'filter': {'delta_e_mean': ('max', 1), 'delta_e_max': ('max', 3), 'ssim': ('min', .99), 'alpha_max': ('max', 1)},
    'effect': {'delta_e_mean': ('max', 1), 'delta_e_max': ('max', 3), 'alpha_max': ('max', 2)},
    'transform': {'psnr': ('min', 45)},
    'text': {'glyph_iou': ('min', .97), 'delta_e_mean': ('max', 1)},
    'shape': {'psnr': ('min', 45), 'alpha_max': ('max', 2)},
    'raw': {'delta_e_mean': ('max', 3)},
    'color': {'delta_e_mean': ('max', 1), 'delta_e_max': ('max', 3), 'alpha_max': ('max', 1)},
    'export': {'channel_max': ('max', 0)},
}


def compare(reference, candidate, output):
    output.mkdir(parents=True, exist_ok=True)
    left = json.loads((reference / 'manifest.json').read_text())
    right = json.loads((candidate / 'manifest.json').read_text())
    if left.get('schema') != 1 or right.get('schema') != 1:
        raise ValueError('unsupported evidence schema')
    for key in ('schema', 'upstream', 'corpus_sha256', 'inputs_sha256'):
        if left.get(key) is None or left.get(key) != right.get(key):
            raise ValueError(f'provenance mismatch or missing {key}')
    if left['platform'] != 'macOS' or right['platform'] != 'Linux':
        raise ValueError('references must be macOS; candidates must be Linux')
    if not left.get('environment') or not right.get('environment'):
        raise ValueError('missing environment provenance')
    if not left.get('cases') or left['cases'] != right.get('cases'):
        raise ValueError('missing or different cases')
    catalog = json.loads((Path(__file__).resolve().parents[1] / 'Tests/RenderParity/cases.json').read_text())
    if left['cases'] != catalog:
        raise ValueError('cases do not match the checked-in corpus')
    if len({case['file'] for case in left['cases']}) != len(left['cases']):
        raise ValueError('duplicate cases')
    if set(POLICIES) - {c['category'] for c in left['cases']}:
        raise ValueError('incomplete category coverage')
    results = []
    for case in left['cases']:
        name = case['file']
        if Path(name).is_absolute() or '..' in Path(name).parts or not name.endswith('.png'):
            raise ValueError(f'unsafe case path: {name}')
        for folder, manifest in ((reference, left), (candidate, right)):
            if hashlib.sha256((folder / name).read_bytes()).hexdigest() != manifest.get('images_sha256', {}).get(name):
                raise ValueError(f'image checksum mismatch: {folder / name}')
        a, b = pixels(reference / name), pixels(candidate / name)
        measured = metrics(a, b)
        checks = POLICIES[case['category']]
        failures = [key for key, (direction, threshold) in checks.items()
                    if (measured[key] > threshold + 1e-8 if direction == 'max' else measured[key] < threshold)]
        if 'samples' in case:
            samples = []
            for folder, manifest in ((reference, left), (candidate, right)):
                path = folder / case['samples']
                if hashlib.sha256(path.read_bytes()).hexdigest() != manifest.get('images_sha256', {}).get(case['samples']):
                    raise ValueError(f'deep sample checksum mismatch: {path}')
                samples.append(json.loads(path.read_text()))
            x, y = samples
            if any(x[k] != y[k] for k in ('hdr', 'width', 'height')):
                raise ValueError('deep representation mismatch')
            aa, bb = np.array(x['samples']), np.array(y['samples'])
            if aa.shape != bb.shape or aa.size != x['width'] * x['height'] * 4 or not np.isfinite(aa).all() or not np.isfinite(bb).all():
                raise ValueError('invalid deep samples')
            measured['deep_max'] = float(np.abs(aa - bb).max())
            tolerance = 4 / 65535 + (np.maximum(np.abs(aa), np.abs(bb)) / 1024 if x['hdr'] else 0)
            if np.any(np.abs(aa - bb) > tolerance):
                failures.append('deep_max')
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        color_delta = np.abs(a[..., :3] * a[..., 3:] - b[..., :3] * b[..., 3:])
        visible_delta = np.maximum(color_delta, np.abs(a[..., 3:] - b[..., 3:]))
        Image.fromarray(np.uint8(np.clip(visible_delta * 255 * 8, 0, 255)), 'RGB').save(target)
        results.append({'file': name, 'metrics': measured, 'failures': failures})
    report = {'passed': all(not r['failures'] for r in results), 'reference': left,
              'candidate': right, 'results': results}
    (output / 'report.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    lines = ['# Render parity', '', f"Result: {'PASS' if report['passed'] else 'FAIL'}", '', '| Case | Result | ΔE mean / max | PSNR |', '|---|---|---|---|']
    for result in results:
        m = result['metrics']
        lines.append(f"| {result['file']} | {', '.join(result['failures']) or 'PASS'} | {m['delta_e_mean']:.3f} / {m['delta_e_max']:.3f} | {m['psnr']:.2f} |")
    (output / 'report.md').write_text('\n'.join(lines) + '\n')
    return report['passed']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        passed = compare(args.reference, args.candidate, args.output)
        print('PARITY PASS' if passed else 'PARITY FAIL: inspect report.json and difference images')
        return 0 if passed else 1
    except (ValueError, KeyError, OSError) as error:
        print(f'PARITY INCOMPLETE: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
