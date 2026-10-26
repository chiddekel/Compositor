import base64
import copy
import hashlib
import importlib.util
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/capture-coreimage-unsharp.swift'
spec = importlib.util.spec_from_file_location('validator', ROOT / 'scripts/validate-coreimage-unsharp-reference.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def packed(key, data):
    return {key + 'Base64': base64.b64encode(data).decode(), key + 'SHA256': hashlib.sha256(data).hexdigest()}


def fixture():
    def f32(value):
        return struct.unpack('<f', struct.pack('<f', value))[0]

    output = dict(packed('float', struct.pack('<4f', 0.25, 0.5, 0.75, 1) * (24 * 16)),
                  **packed('rgba', bytes([64, 128, 191, 255]) * (24 * 16)), description='Synthetic validator control')
    result = {'schema': 1, 'platform': 'macOS', 'device': 'Synthetic test device', 'os': 'Synthetic test OS',
              'scriptSHA256': hashlib.sha256(SCRIPT.read_bytes()).hexdigest(), 'width': 24, 'height': 16,
              'radii': [1, 2, 5], 'intensities': [0, 0.5, 1, 2], 'inputs': [], 'cases': []}
    for name in ['opaque-gradient', 'overlay-gradient', 'float-hdr', 'impulse']:
        source = bytearray()
        for y in range(16):
            for x in range(24):
                if name == 'impulse':
                    source.extend([255 if x == 12 and y == 8 else 0] * 4)
                elif name == 'float-hdr':
                    alpha = [0, 0.25, 0.5, 1][(x // 6 + y // 4) % 4]
                    source.extend(struct.pack('<4f', f32(f32(f32(x / 23) * 3) - 0.5) * alpha,
                                              f32(y / 15) * alpha, 1.25 * alpha, alpha))
                else:
                    alpha = (0 if x < 3 or y < 3 or x > 20 or y > 12 else 160) if name == 'overlay-gradient' else 255
                    source.extend([(x * 255 // 23) * alpha // 255, (y * 255 // 15) * alpha // 255,
                                   (220 if name == 'overlay-gradient' else 100) * alpha // 255, alpha])
        for format_ in ['RGBAh', 'RGBAf']:
            result['inputs'].append(dict(fixture=name, workingFormat=format_, output=copy.deepcopy(output),
                                         sourceFormat='RGBAf' if name == 'float-hdr' else 'RGBA8', **packed('source', source)))
            for clamped in [False, True]:
                for radius in [1, 2, 5]:
                    for intensity in [None, 0, 0.5, 1, 2]:
                        case = dict(fixture=name, workingFormat=format_, clamped=clamped, radius=radius,
                                    filter='CIGaussianBlur' if intensity is None else 'CIUnsharpMask',
                                    output=copy.deepcopy(output))
                        if intensity is not None:
                            case['intensity'] = intensity
                        result['cases'].append(case)
    return result


class UnsharpCaptureValidationTests(unittest.TestCase):
    def test_complete_matrix(self):
        validator.validate(fixture(), SCRIPT)

    def test_missing_duplicate_and_changed_provenance_are_rejected(self):
        for change in ['missing', 'duplicate', 'script']:
            with self.subTest(change=change):
                data = fixture()
                if change == 'missing':
                    data['cases'].pop()
                elif change == 'duplicate':
                    data['cases'][-1] = copy.deepcopy(data['cases'][0])
                else:
                    data['scriptSHA256'] = '0' * 64
                with self.assertRaises(ValueError):
                    validator.validate(data, SCRIPT)

    def test_rehashed_wrong_source_is_rejected(self):
        data = fixture()
        data['inputs'][0].update(packed('source', bytes(24 * 16 * 4)))
        with self.assertRaisesRegex(ValueError, 'Procedural source'):
            validator.validate(data, SCRIPT)

    def test_nonfinite_empty_and_nonidentity_outputs_are_rejected(self):
        for change in ['nonfinite', 'empty', 'identity']:
            with self.subTest(change=change):
                data = fixture()
                case = next(c for c in data['cases'] if c.get('intensity') == 0)
                value = float('nan') if change == 'nonfinite' else 0 if change == 'empty' else 0.75
                case['output'].update(packed('float', struct.pack('<f', value) * (24 * 16 * 4)))
                with self.assertRaises(ValueError):
                    validator.validate(data, SCRIPT)


if __name__ == '__main__':
    unittest.main()
