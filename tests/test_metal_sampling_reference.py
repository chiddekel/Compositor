import base64
import copy
import hashlib
import importlib.util
import itertools
import json
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/capture-metal-sampling.swift'
spec = importlib.util.spec_from_file_location('sampling_validator', ROOT / 'scripts/validate-metal-sampling-reference.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def packed(data):
    return {'base64': base64.b64encode(data).decode(), 'sha256': hashlib.sha256(data).hexdigest()}


class MetalSamplingValidationTests(unittest.TestCase):
    def fixture(self, reference):
        fixtures = ['opaque-gradient', 'float-hdr', 'impulse']
        values = [0.25, 0.5, 0.75, 1] * (24 * 16)
        floats = struct.pack('<1536f', *values)
        reference.write_text(json.dumps({'inputs': [
            {'fixture': name, 'workingFormat': 'RGBAf', 'output': {'floatBase64': base64.b64encode(floats).decode()}}
            for name in fixtures]}))
        offsets = [(0, 0), (1 / 256, 1 / 256), (3 / 256, 3 / 256), (24 / 256, 24 / 256),
                   (54 / 256, 54 / 256), (-54 / 256, -54 / 256), (0.409254816, 0),
                   (1.409254816, 0), (0, 1.409254816), (3.29831846, 0),
                   (0.09558051079511642, 0.09558051079511642)]
        offsets = [list(struct.unpack('<2f', struct.pack('<2f', *o))) for o in offsets]
        inputs = []
        for name, storage in itertools.product(fixtures, ['RGBA8', 'RGBAh', 'RGBAf', 'RGBAhGPU']):
            data = bytes([64, 128, 191, 255]) * (24 * 16) if storage == 'RGBA8' else (
                struct.pack('<1536e', *values) if storage.startswith('RGBAh') else floats)
            inputs.append({'fixture': name, 'storage': storage, 'pixels': packed(data)})
        return {'schema': 1, 'platform': 'macOS', 'device': 'Synthetic validator device', 'os': 'Synthetic validator OS',
                'scriptSHA256': hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),
                'sourceReferenceSHA256': hashlib.sha256(reference.read_bytes()).hexdigest(),
                'width': 24, 'height': 16, 'offsets': offsets, 'inputs': inputs,
                'cases': [{'fixture': name, 'storage': storage, 'resultType': result_type, 'clamped': clamp,
                           'operation': operation, 'offset': offset, 'output': packed(floats)}
                          for name, storage, result_type, clamp, operation
                          in itertools.product(fixtures, ['RGBA8', 'RGBAh', 'RGBAf', 'RGBAhGPU'], ['float', 'half'], [False, True], ['sample', 'compact'])
                          for offset in (offsets if operation == 'sample' else offsets[1:5] + [offsets[10]])]}

    def test_complete_matrix(self):
        with tempfile.TemporaryDirectory() as directory:
            reference = Path(directory) / 'source.json'
            validator.validate(self.fixture(reference), reference, SCRIPT)

    def test_missing_duplicate_and_source_hash_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            reference = Path(directory) / 'source.json'
            for change in ['missing', 'duplicate', 'source']:
                with self.subTest(change=change):
                    data = self.fixture(reference)
                    if change == 'missing': data['cases'].pop()
                    elif change == 'duplicate': data['cases'][-1] = copy.deepcopy(data['cases'][0])
                    else: data['sourceReferenceSHA256'] = '0' * 64
                    with self.assertRaises(ValueError): validator.validate(data, reference, SCRIPT)

    def test_rehashed_source_and_point_identity_changes_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            reference = Path(directory) / 'source.json'
            for change in ['source', 'identity']:
                with self.subTest(change=change):
                    data = self.fixture(reference)
                    if change == 'source': data['inputs'][0]['pixels'] = packed(bytes(24 * 16 * 4))
                    else:
                        case = next(c for c in data['cases'] if c['storage'] == 'RGBAf' and c['resultType'] == 'float' and c['offset'] == [0, 0])
                        case['output'] = packed(struct.pack('<1536f', *([0.5] * 1536)))
                    with self.assertRaises(ValueError): validator.validate(data, reference, SCRIPT)


if __name__ == '__main__':
    unittest.main()
