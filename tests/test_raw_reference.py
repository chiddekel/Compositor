#!/usr/bin/env python3
"""Validate RAW capture recipe coverage and reject mislabeled diagnostic buffers."""
import base64
import copy
import hashlib
import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'validate-raw-reference.py'
SPEC = importlib.util.spec_from_file_location('raw_reference', SCRIPT)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


def reference(folder, schema):
    recipes = [('decoder-default', None, None, None, None),
               ('boost-0', 0, 0, None, None), ('boost-0.5', 0, .5, None, None),
               ('boost-1', 0, 1, None, None)]
    for boost in (0, 1):
        for name, exposure in [('minus', -1), ('plus', 1)]:
            recipes.append((f'exposure-{name}-1-boost-{boost}', exposure, boost, None, None))
    if schema == 2:
        for boost in (0, 1):
            recipes.extend([(f'temperature-3000-boost-{boost}', 0, boost, 3000, None),
                            (f'temperature-8000-boost-{boost}', 0, boost, 8000, None),
                            (f'tint-minus-50-boost-{boost}', 0, boost, None, -50),
                            (f'tint-plus-50-boost-{boost}', 0, boost, None, 50)])
    inputs = []
    for name in [f'sensor-{i}.dng' for i in range(5)] + ['precision-ramp.dng']:
        # Only the validator's source binding is exercised; these are not decoded DNGs.
        source = name.encode()
        (folder / name).write_bytes(source)
        width, height = (1024, 128) if name == 'precision-ramp.dng' else (512, 512)
        buffers = []
        for space, bits in [('extendedLinearSRGB', 32), ('sRGB', 32), ('sRGB', 16)]:
            pixel = struct.pack('<4f', .25, .5, .75, 1) if bits == 32 else struct.pack('<4H', 1, 2, 3, 65535)
            data = pixel * (width - 32)
            buffers.append(dict(colorSpace=space, bitsPerComponent=bits, width=width - 32,
                                height=1, rowBytes=len(data), byteOrder='little',
                                rgbaBase64=base64.b64encode(data).decode(), sha256=hashlib.sha256(data).hexdigest()))
        cases = []
        for label, exposure, boost, temperature, tint in recipes:
            defaults = dict(exposure=0, boost=1, temperature=5454, tint=-13, scale=1, draft=False)
            settings = defaults.copy()
            for key, value in [('exposure', exposure), ('boost', boost), ('temperature', temperature), ('tint', tint)]:
                if value is not None:
                    settings[key] = value
            cases.append(dict(name=label, defaults=defaults, settings=settings, extent=[0, 0, width, height],
                              sampleBounds=[16, height // 2, width - 32, 1], buffers=copy.deepcopy(buffers)))
        inputs.append(dict(file=name, sha256=hashlib.sha256(source).hexdigest(), cases=cases))
    return dict(schema=schema, platform='macOS', workingFormat='RGBAh', workingColorSpace='extendedLinearSRGB', inputs=inputs)


class RawReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.data = reference(self.folder, 2)

    def test_original_and_white_balance_schemas(self):
        self.assertEqual(VALIDATOR.validate(reference(self.folder, 1), self.folder), 144)
        self.assertEqual(VALIDATOR.validate(self.data, self.folder), 288)

    def test_rejects_missing_and_duplicate_white_balance_recipes(self):
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate):
                data = copy.deepcopy(self.data)
                cases = data['inputs'][0]['cases']
                if duplicate:
                    cases[-1] = copy.deepcopy(cases[-2])
                else:
                    cases.pop()
                with self.assertRaises(AssertionError):
                    VALIDATOR.validate(data, self.folder)

    def test_rejects_wrong_changed_and_unchanged_controls(self):
        for field, value in [('temperature', 5454), ('tint', 50), ('exposure', 1), ('boost', 1)]:
            with self.subTest(field=field):
                data = copy.deepcopy(self.data)
                case = next(c for c in data['inputs'][0]['cases'] if c['name'] == 'temperature-3000-boost-0')
                case['settings'][field] = value
                with self.assertRaises(AssertionError):
                    VALIDATOR.validate(data, self.folder)

    def test_rejects_stale_input_and_corrupt_buffer_hashes(self):
        for target in ('input', 'buffer'):
            with self.subTest(target=target):
                data = copy.deepcopy(self.data)
                item = data['inputs'][0] if target == 'input' else data['inputs'][0]['cases'][0]['buffers'][0]
                item['sha256'] = '0' * 64
                with self.assertRaises(AssertionError):
                    VALIDATOR.validate(data, self.folder)

    def test_old_schema_cannot_claim_white_balance_controls(self):
        self.data['schema'] = 1
        with self.assertRaises(AssertionError):
            VALIDATOR.validate(self.data, self.folder)


if __name__ == '__main__':
    unittest.main()
