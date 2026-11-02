#!/usr/bin/env python3
"""Compare complete render-parity manifests for exact visible pixels and deep samples."""
import argparse
import hashlib
import json
import math
from pathlib import Path

from PIL import Image, ImageCms


def read_manifest(folder):
    return json.loads((folder / 'manifest.json').read_text())


def validate_manifest(reference, candidate):
    left, right = read_manifest(reference), read_manifest(candidate)
    for key in ('schema', 'upstream', 'corpus_sha256', 'inputs_sha256'):
        if left.get(key) is None or left.get(key) != right.get(key):
            raise ValueError(f'provenance mismatch or missing {key}')
    if left.get('schema') != 1 or left.get('platform') != 'macOS' or right.get('platform') != 'Linux':
        raise ValueError('expected schema 1 macOS references and Linux candidate')
    if not left.get('environment') or not right.get('environment'):
        raise ValueError('missing environment provenance')
    if not left.get('cases') or left['cases'] != right.get('cases'):
        raise ValueError('missing or different cases')
    catalog = json.loads((Path(__file__).resolve().parents[1] / 'Tests/RenderParity/cases.json').read_text())
    if left['cases'] != catalog:
        raise ValueError('cases do not match the checked-in corpus')
    if len({case['file'] for case in left['cases']}) != len(left['cases']):
        raise ValueError('duplicate cases')
    return left, right


def decode_visible_pixels(path):
    with Image.open(path) as source:
        source.load()
        alpha = source.convert('RGBA').getchannel('A').tobytes()
        if source.info.get('icc_profile'):
            import io
            rgb = ImageCms.profileToProfile(
                source.convert('RGB'),
                ImageCms.ImageCmsProfile(io.BytesIO(source.info['icc_profile'])),
                ImageCms.createProfile('sRGB'), outputMode='RGB')
        else:
            rgb = source.convert('RGB')
        return source.size, rgb.tobytes(), alpha


def compare_pixels(reference, candidate):
    size_a, rgb_a, alpha_a = decode_visible_pixels(reference)
    size_b, rgb_b, alpha_b = decode_visible_pixels(candidate)
    if size_a != size_b:
        raise ValueError(f'image dimensions differ: {reference} and {candidate}')
    changed_pixels = changed_channels = 0
    for offset in range(0, len(alpha_a)):
        a, b = alpha_a[offset], alpha_b[offset]
        differences = (
            rgb_a[offset * 3] * a != rgb_b[offset * 3] * b,
            rgb_a[offset * 3 + 1] * a != rgb_b[offset * 3 + 1] * b,
            rgb_a[offset * 3 + 2] * a != rgb_b[offset * 3 + 2] * b,
            a != b,
        )
        changed_channels += sum(differences)
        changed_pixels += any(differences)
    return changed_pixels, changed_channels


def compare_deep_samples(reference, candidate):
    x, y = json.loads(reference.read_text()), json.loads(candidate.read_text())
    if any(x.get(key) != y.get(key) for key in ('hdr', 'width', 'height')):
        raise ValueError(f'deep representation mismatch: {reference} and {candidate}')
    expected = x['width'] * x['height'] * 4
    a, b = x['samples'], y['samples']
    if len(a) != expected or len(b) != expected:
        raise ValueError(f'invalid deep sample count: {reference} and {candidate}')
    if not all(math.isfinite(value) for value in (*a, *b)):
        raise ValueError(f'nonfinite deep samples: {reference} or {candidate}')
    changed = sum(left != right for left, right in zip(a, b))
    maximum = max((abs(left - right) for left, right in zip(a, b)), default=0.0)
    return changed, maximum


def compare(reference, candidate, output):
    left, right = validate_manifest(reference, candidate)
    results = []
    for case in left['cases']:
        name = case['file']
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or not name.endswith('.png'):
            raise ValueError(f'unsafe case path: {name}')
        image_result = {}
        for folder, manifest, label in ((reference, left, 'reference'), (candidate, right, 'candidate')):
            file = folder / name
            expected_hash = manifest.get('images_sha256', {}).get(name)
            if not expected_hash or hashlib.sha256(file.read_bytes()).hexdigest() != expected_hash:
                raise ValueError(f'image checksum mismatch: {file}')
            image_result[label] = file
        different_pixels, different_channels = compare_pixels(
            image_result['reference'], image_result['candidate'])
        result = {
            'file': name,
            'pixels_equal': different_pixels == 0,
            'different_pixels': different_pixels,
            'different_visible_channels': different_channels,
            'deep_samples_equal': None,
            'different_deep_samples': 0,
            'deep_max_difference': None,
        }
        if 'samples' in case:
            sample_path = case['samples']
            for folder, manifest, label in ((reference, left, 'reference'), (candidate, right, 'candidate')):
                file = folder / sample_path
                expected_hash = manifest.get('images_sha256', {}).get(sample_path)
                if not expected_hash or hashlib.sha256(file.read_bytes()).hexdigest() != expected_hash:
                    raise ValueError(f'deep sample checksum mismatch: {file}')
                image_result[label + '_samples'] = file
            changed, maximum = compare_deep_samples(
                image_result['reference_samples'], image_result['candidate_samples'])
            result.update({
                'deep_samples_equal': changed == 0,
                'different_deep_samples': changed,
                'deep_max_difference': maximum,
            })
        results.append(result)

    report = {
        'schema': 1,
        'reference': {key: left[key] for key in ('platform', 'upstream', 'corpus_sha256', 'inputs_sha256', 'environment')},
        'candidate': {key: right[key] for key in ('platform', 'upstream', 'corpus_sha256', 'inputs_sha256', 'environment')},
        'case_count': len(results),
        'exact_image_cases': sum(case['pixels_equal'] for case in results),
        'exact_deep_cases': sum(case['deep_samples_equal'] is True for case in results),
        'exact_passed': all(case['pixels_equal'] and case['deep_samples_equal'] is not False for case in results),
        'pixel_scope': 'Color-managed sRGB premultiplied RGBA8 visible channels; PNG encoding and hidden RGB beneath zero alpha are ignored.',
        'results': results,
    }
    output.mkdir(parents=True, exist_ok=True)
    (output / 'report.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    report = compare(args.reference, args.candidate, args.output)
    print(f"Exact images: {report['exact_image_cases']}/{report['case_count']}; "
          f"exact deep samples: {report['exact_deep_cases']}; "
          f"exact comparison: {'PASS' if report['exact_passed'] else 'FAIL'}")
    for case in report['results']:
        if not case['pixels_equal'] or case['deep_samples_equal'] is False:
            print(f"{case['file']}: {case['different_pixels']} pixels, "
                  f"{case['different_deep_samples']} deep samples, "
                  f"max deep Δ={case['deep_max_difference']}")
    return 0 if report['exact_passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
