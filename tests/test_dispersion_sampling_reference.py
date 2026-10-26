#!/usr/bin/env python3
import base64
import copy
import hashlib
import importlib.util
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("validator", ROOT / "scripts/validate-dispersion-sampling-reference.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def packed(raw):
    return {"base64": base64.b64encode(raw).decode(), "sha256": hashlib.sha256(raw).hexdigest()}


class NativeDispersionSamplingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shader = (ROOT / "Compositor/Rendering/MetalDispersion.swift").read_text().split('private static let source = """\n', 1)[1].split('\n"""', 1)[0]
        cls.fixture = dict(schema=1, platform="macOS", device="test", os="test", width=96, height=72,
                           parameterStride=72, shaderSHA256=hashlib.sha256(shader.encode()).hexdigest(),
                           scriptSHA256=hashlib.sha256((ROOT / "scripts/capture-dispersion-sampling.swift").read_bytes()).hexdigest(),
                           arithmetic=packed(bytes(96 * 72 * 16)), inputs=[], cases=[])
        import math
        for fixture in ("opaque", "overlay"):
            for storage in MODULE.STORAGES:
                cls.fixture["inputs"].append(dict(fixture=fixture, storage=storage, data=packed(MODULE.source(fixture, storage))))
                for angle in (0, 35):
                    p = bytearray(72)
                    struct.pack_into("<8f3I", p, 0, 48, 36, math.cos(math.radians(angle)), math.sin(math.radians(angle)),
                                     10 if angle == 0 else 35, 0, 1000, 0, 0, 10 if angle == 0 else 32, 1)
                    struct.pack_into("<5f", p, 48, 0, 72, 0, 72, -1)
                    cls.fixture["cases"].append(dict(fixture=fixture, storage=storage, angle=angle,
                        parameters=packed(p), float=packed(bytes(96 * 72 * 16)), byte=packed(bytes(96 * 72 * 4))))

    def test_complete_matrix(self):
        self.assertEqual(MODULE.validate(self.fixture, ROOT)["cases"], 16)

    def test_missing_or_duplicate_case(self):
        for duplicate in (False, True):
            d = copy.deepcopy(self.fixture)
            d["cases"].pop()
            if duplicate:
                d["cases"].append(d["cases"][0])
            with self.assertRaises(AssertionError):
                MODULE.validate(d, ROOT)

    def test_rehashed_wrong_input_and_recipe(self):
        d = copy.deepcopy(self.fixture)
        size = len(base64.b64decode(d["inputs"][0]["data"]["base64"]))
        d["inputs"][0]["data"] = packed(bytes(size))
        with self.assertRaisesRegex(AssertionError, "Source conversion"):
            MODULE.validate(d, ROOT)
        d = copy.deepcopy(self.fixture)
        d["cases"][0]["parameters"] = packed(bytes(72))
        with self.assertRaises(AssertionError):
            MODULE.validate(d, ROOT)

    def test_output_hash_nonfinite_and_provenance(self):
        for mutation in ("hash", "nonfinite", "script"):
            d = copy.deepcopy(self.fixture)
            if mutation == "hash":
                d["cases"][0]["float"]["sha256"] = "0" * 64
            elif mutation == "nonfinite":
                raw = bytearray(96 * 72 * 16)
                struct.pack_into("<f", raw, 0, float("nan"))
                d["cases"][0]["float"] = packed(raw)
            else:
                d["scriptSHA256"] = "0" * 64
            with self.assertRaises(AssertionError):
                MODULE.validate(d, ROOT)


if __name__ == "__main__":
    unittest.main()
