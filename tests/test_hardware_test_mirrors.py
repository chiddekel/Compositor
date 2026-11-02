#!/usr/bin/env python3
"""Availability adaptations must preserve every upstream assertion and fail closed on drift."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('test_mirrors_generator', ROOT / 'scripts/gen-linux-test-mirrors.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class HardwareMirrorTests(unittest.TestCase):
    def test_roundtrip_recovers_the_complete_original_files(self):
        for name, (path, before, after) in generator.HARDWARE_MIRRORS.items():
            with self.subTest(name=name):
                original = (ROOT / path).read_text()
                mirrored = generator.hardware_mirror(name).split('\n', 2)[2]
                self.assertEqual(mirrored.replace(after, before, 1), original)
                self.assertEqual(mirrored.count('#expect'), original.count('#expect'))
                self.assertEqual(mirrored.count('#require'), original.count('#require'))

    def test_changed_upstream_declaration_requires_review(self):
        for path, before, after in generator.HARDWARE_MIRRORS.values():
            with self.subTest(path=path), self.assertRaises(ValueError):
                generator.adapt_hardware_test((ROOT / path).read_text().replace(before, 'changed declaration', 1), before, after)

    def test_duplicate_upstream_declaration_requires_review(self):
        for path, before, after in generator.HARDWARE_MIRRORS.values():
            with self.subTest(path=path), self.assertRaises(ValueError):
                generator.adapt_hardware_test((ROOT / path).read_text() + '\n' + before, before, after)

    def test_check_rejects_a_removed_assertion_or_weakened_trait(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            (temporary / 'CompositorTests').mkdir()
            (temporary / 'Tests/LinuxOverrideTests').mkdir(parents=True)
            for path, _, _ in generator.HARDWARE_MIRRORS.values():
                (temporary / path).write_text((ROOT / path).read_text())
            with patch.object(generator, 'root', temporary), patch.object(generator, 'MIRRORS', {}), \
                    patch.object(generator, 'DEFAULTS_MIRRORS', {}), patch.object(sys, 'argv', ['generate']):
                self.assertEqual(generator.main(), 0)
                for name in generator.HARDWARE_MIRRORS:
                    path = temporary / 'Tests/LinuxOverrideTests' / f'{name}.swift'
                    expected = path.read_text()
                    for mutation in [expected.replace('#expect', 'removed_expect', 1),
                                     expected.replace('REQUIRE_COREIMAGE_VULKAN', 'IGNORED_GPU_REQUIREMENT', 1)]:
                        with self.subTest(name=name), patch.object(sys, 'argv', ['generate', '--check']), \
                                contextlib.redirect_stdout(io.StringIO()):
                            path.write_text(mutation)
                            self.assertEqual(generator.main(), 1)
                        path.write_text(expected)


if __name__ == '__main__':
    unittest.main()
