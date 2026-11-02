#!/usr/bin/env python3
"""Reject incomplete or corrupt native blend captures before using them as evidence."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('blend_validator', ROOT / 'scripts/validate-native-byte-blends.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class NativeByteBlendReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='native-blend-validator-')
        cls.folder = Path(cls.temporary.name)
        cls.report = dict(schema=1, platform='macOS', width=256, height=256,
                          layout='RGBA8-premultipliedLast-byteOrder32Big-sRGB',
                          scriptSHA256=hashlib.sha256((ROOT / 'scripts/capture-native-byte-blends.swift').read_bytes()).hexdigest(), cases=[])
        for opaque in (True, False):
            source, backdrop = validator.inputs(opaque)
            for mode in range(16):
                for divisor in (1, 2, 4):
                    raw = backdrop[:-1024] + source[-1024:] if mode == 0 and divisor == 1 else backdrop
                    name = f'mode-{mode}-divisor-{divisor}-opaque-{str(opaque).lower()}.rgba'
                    (cls.folder / name).write_bytes(raw)
                    cls.report['cases'].append(dict(mode=mode, divisor=divisor, opaqueBackdrop=opaque, file=name,
                        sourceSHA256=hashlib.sha256(source).hexdigest(), backdropSHA256=hashlib.sha256(backdrop).hexdigest(),
                        outputSHA256=hashlib.sha256(raw).hexdigest()))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def copy_report(self):
        return json.loads(json.dumps(self.report))

    def test_complete_controls(self):
        self.assertEqual(validator.validate(self.report, self.folder), dict(cases=96, pixels=6291456))

    def test_missing_and_duplicate_cases(self):
        for cases in (self.report['cases'][:-1], self.report['cases'] + self.report['cases'][:1]):
            report = self.copy_report()
            report['cases'] = cases
            with self.assertRaises(AssertionError):
                validator.validate(report, self.folder)

    def test_source_provenance(self):
        report = self.copy_report()
        report['cases'][0]['sourceSHA256'] = '0' * 64
        with self.assertRaises(AssertionError):
            validator.validate(report, self.folder)

    def test_rehashed_wrong_transparent_source_control(self):
        report = self.copy_report()
        case = report['cases'][0]
        path = self.folder / case['file']
        original = path.read_bytes()
        changed = bytes([original[0] ^ 1]) + original[1:]
        try:
            path.write_bytes(changed)
            case['outputSHA256'] = hashlib.sha256(changed).hexdigest()
            with self.assertRaisesRegex(AssertionError, 'Zero source alpha'):
                validator.validate(report, self.folder)
        finally:
            path.write_bytes(original)


if __name__ == '__main__':
    unittest.main()
