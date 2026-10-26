#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("capture", ROOT / "scripts/capture-native-cube.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeCubeReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = dict(schema=1, platform="Darwin", machine="arm64", os="test", width=96, height=72,
            compilerVersion="test", compileFlags={"native": ["-O3"], "unfused": ["-O3", "-ffp-contract=off"]},
            scriptSHA256=MODULE.digest(Path(MODULE.__file__).read_bytes()),
            kernelSHA256=MODULE.digest((ROOT / "Compositor/Rendering/LevelsPixels.c").read_bytes()),
            headerSHA256=MODULE.digest((ROOT / "Compositor/Rendering/LevelsPixels.h").read_bytes()),
            nativeUnfusedDifferentComponents=1, cases=[])
        for dimension, kind, fixture in MODULE.RECIPES:
            raw = MODULE.source(fixture)
            cls.report["cases"].append(dict(dimension=dimension, kind=kind, fixture=fixture,
                inputSHA256=MODULE.digest(raw), cubeSHA256=MODULE.digest(MODULE.cube(dimension, kind)),
                native=MODULE.packed(raw), unfused=MODULE.packed(raw)))
        changed = bytearray(MODULE.source("opaque"))
        changed[0] = 1
        cls.report["cases"][0]["unfused"] = MODULE.packed(changed)

    def test_complete_matrix(self):
        self.assertEqual(MODULE.validate(self.report)["cases"], 16)

    def test_missing_duplicate_or_corrupt_buffer(self):
        for mutation in ("missing", "duplicate", "hash"):
            d = copy.deepcopy(self.report)
            if mutation == "missing":
                d["cases"].pop()
            elif mutation == "duplicate":
                d["cases"][-1] = d["cases"][0]
            else:
                d["cases"][0]["native"]["sha256"] = "0" * 64
            with self.assertRaises(AssertionError):
                MODULE.validate(d)

    def test_input_and_source_provenance(self):
        for location, key in (("case", "cubeSHA256"), ("case", "inputSHA256"), ("report", "kernelSHA256")):
            d = copy.deepcopy(self.report)
            (d["cases"][0] if location == "case" else d)[key] = "0" * 64
            with self.assertRaises(AssertionError):
                MODULE.validate(d)

    def test_alpha_and_vacuous_control(self):
        d = copy.deepcopy(self.report)
        raw = bytearray(MODULE.source("opaque"))
        raw[3] = 0
        d["cases"][0]["native"] = MODULE.packed(raw)
        with self.assertRaisesRegex(AssertionError, "Alpha preservation"):
            MODULE.validate(d)
        d = copy.deepcopy(self.report)
        d["cases"][0]["unfused"] = d["cases"][0]["native"]
        d["nativeUnfusedDifferentComponents"] = 0
        with self.assertRaisesRegex(AssertionError, "Nonvacuous"):
            MODULE.validate(d)


if __name__ == "__main__":
    unittest.main()
