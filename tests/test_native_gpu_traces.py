import base64
import copy
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/capture-coreimage-unsharp.swift'
spec = importlib.util.spec_from_file_location('trace_validator', ROOT / 'scripts/validate-native-gpu-traces.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def fixture(directory):
    report = {'schema': 1, 'platform': 'macOS', 'device': 'Synthetic validator device', 'os': 'Synthetic validator OS',
              'scriptSHA256': hashlib.sha256(SCRIPT.read_bytes()).hexdigest(), 'supported': True,
              'status': 'captured', 'traces': []}
    reference = {'cases': []}
    output = {}
    for name, data in [('float', struct.pack('<1536f', *([0.5] * 1536))), ('rgba', bytes([128] * 1536))]:
        output[name + 'Base64'] = base64.b64encode(data).decode()
        output[name + 'SHA256'] = hashlib.sha256(data).hexdigest()
    for name, source, format_, radius, clamp in [('compact-half-hdr', 'float-hdr', 'RGBAh', 0.3, True),
                                               ('blur2-float', 'opaque-gradient', 'RGBAf', 2, False),
                                               ('blur5-half', 'opaque-gradient', 'RGBAh', 5, False)]:
        path = directory / (name + '.gputrace') / 'synthetic.bin'
        path.parent.mkdir(parents=True, exist_ok=True)
        data = b'Synthetic validator trace member'
        path.write_bytes(data)
        metadata = {'fixture': source, 'workingFormat': format_, 'radius': radius,
                    'clamped': clamp, 'output': copy.deepcopy(output)}
        report['traces'].append(dict(metadata, name=name, files=[{'path': str(path.relative_to(directory)),
            'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}]))
        reference['cases'].append(dict(copy.deepcopy(metadata), filter='CIGaussianBlur'))
    return report, reference


class NativeGPUTraceValidationTests(unittest.TestCase):
    def test_complete_inventory_and_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report, reference = fixture(root)
            self.assertTrue(validator.validate(report, reference, root, SCRIPT))

    def test_unsupported_is_distinct_from_captured(self):
        report = {'schema': 1, 'platform': 'macOS', 'device': 'Synthetic device', 'os': 'Synthetic OS',
                  'scriptSHA256': hashlib.sha256(SCRIPT.read_bytes()).hexdigest(), 'supported': False,
                  'status': 'unsupported', 'reason': 'Synthetic unsupported device', 'traces': []}
        self.assertFalse(validator.validate(report, {}, Path('/tmp/unused-native-trace'), SCRIPT))
        report['status'] = 'captured'
        with self.assertRaises(ValueError): validator.validate(report, {}, Path('/tmp/unused-native-trace'), SCRIPT)

    def test_missing_tampered_rehashed_pixels_and_extra_files_are_rejected(self):
        for change in ['missing', 'tampered', 'pixels', 'extra']:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                report, reference = fixture(root)
                item = report['traces'][0]['files'][0]
                if change == 'missing': (root / item['path']).unlink()
                elif change == 'tampered': (root / item['path']).write_bytes(b'Changed')
                elif change == 'pixels':
                    data = struct.pack('<1536f', *([0.75] * 1536))
                    report['traces'][0]['output'].update(floatBase64=base64.b64encode(data).decode(),
                                                        floatSHA256=hashlib.sha256(data).hexdigest())
                else: (root / 'extra.bin').write_bytes(b'Unlisted')
                with self.assertRaises(ValueError): validator.validate(report, reference, root, SCRIPT)

    def test_post_exit_inventory_binds_late_members_and_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report, reference = fixture(root)
            report['inventoryStage'] = 'before-process-exit'
            late = root / 'compact-half-hdr.gputrace' / 'late-surface.bin'
            late.write_bytes(b'Synthetic late serialization')
            with self.assertRaises(ValueError): validator.validate(report, reference, root, SCRIPT)
            receipt = validator._finalizer.finalize(report, root)
            self.assertTrue(validator.validate(report, reference, root, SCRIPT, receipt))
            for change in ['binding', 'missing', 'tampered']:
                with self.subTest(change=change):
                    changed = copy.deepcopy(receipt)
                    if change == 'binding': changed['reportSHA256'] = '0' * 64
                    elif change == 'missing': changed['files'] = [i for i in changed['files'] if i['path'] != str(late.relative_to(root))]
                    else: late.write_bytes(b'Changed late serialization')
                    with self.assertRaises(ValueError): validator.validate(report, reference, root, SCRIPT, changed)


if __name__ == '__main__':
    unittest.main()
