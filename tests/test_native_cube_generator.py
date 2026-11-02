#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("generator", ROOT / "scripts/gen-native-cube-kernel.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeCubeGeneratorTests(unittest.TestCase):
    def test_preserves_other_upstream_functions_and_rejects_drift(self):
        source = (ROOT / "Compositor/Rendering/LevelsPixels.c").read_text()
        generated = MODULE.generate(source)
        prefix = source.split("void cube_apply(")[0]
        self.assertIn(prefix, generated)
        self.assertEqual(generated.count("fmaf("), 7)
        with self.assertRaises(ValueError):
            MODULE.generate(source.replace("y0 + (y1 - y0) * fraction[2]", "another_expression"))


if __name__ == "__main__":
    unittest.main()
