#!/usr/bin/env python3
"""Fault injection against the evaluated package description supplied on the command line."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
DESCRIPTION = json.loads(Path(sys.argv.pop(1)).read_text())
PARITY = json.loads((ROOT / 'linux/upstream-parity.json').read_text())
spec = importlib.util.spec_from_file_location('source_coverage', ROOT / 'scripts/check-linux-source-coverage.py')
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class SourceCoverageTests(unittest.TestCase):
    def setUp(self):
        self.description = copy.deepcopy(DESCRIPTION)
        self.parity = copy.deepcopy(PARITY)

    def target(self, name):
        return next(target for target in self.description['targets'] if target['name'] == name)

    def remove_source(self, target_name, path):
        target = self.target(target_name)
        source = next(source for source in target['sources']
                      if (ROOT / target['path'] / source).resolve() == ROOT / path)
        target['sources'].remove(source)

    def findings(self):
        return coverage.audit(self.description, self.parity)[0]

    def test_actual_package_is_fully_accounted_for(self):
        self.assertEqual(self.findings(), [])

    def test_existing_drift_modes_remain_source_accounted(self):
        # Freshness/allowlist policy belongs to upstream-override-drift.py, not source inclusion.
        for mode in ('tip', 'pinned'):
            with self.subTest(mode=mode):
                self.parity['drift']['Sources/Overrides/NativeLayerList.swift']['mode'] = mode
                self.assertEqual(self.findings(), [])

    def test_missing_unchanged_history_fails(self):
        self.remove_source('Compositor', 'Compositor/Document/DocumentHistory.swift')
        self.assertIn('Compositor/Document/DocumentHistory.swift: expected one implementation, found 0', self.findings())

    def test_missing_generated_layer_table_fails(self):
        self.remove_source('Compositor', 'Sources/Overrides/NativeLayerList.swift')
        self.assertIn('Compositor/UI/NativeLayerList.swift: expected one implementation, found 0', self.findings())

    def test_compiling_original_and_override_together_fails(self):
        target = self.target('Compositor')
        target['sources'].append('../../Compositor/UI/NativeLayerList.swift')
        self.assertIn('Compositor/UI/NativeLayerList.swift: expected one implementation, found 2', self.findings())

    def test_undeclared_compiled_override_fails(self):
        del self.parity['drift']['Sources/Overrides/NativeLayerList.swift']
        self.assertIn('compiled override has no declaration: Sources/Overrides/NativeLayerList.swift', self.findings())

    def test_missing_selector_test_mirror_fails(self):
        self.remove_source('LinuxOverrideTests', 'Tests/LinuxOverrideTests/LayerTests.swift')
        self.assertIn('CompositorTests/LayerTests.swift: expected one test implementation, found 0', self.findings())

    def test_compiling_selector_original_and_mirror_together_fails(self):
        self.target('CompositorUpstreamTests')['sources'].append('LayerTests.swift')
        self.assertIn('CompositorTests/LayerTests.swift: expected one test implementation, found 2', self.findings())

    def test_missing_shortcut_type_mirror_fails(self):
        self.remove_source('LinuxOverrideTests', 'Tests/LinuxOverrideTests/KeyboardShortcutTests.swift')
        self.assertIn('CompositorTests/KeyboardShortcutTests.swift: expected one test implementation, found 0', self.findings())

    def test_compiling_shortcut_original_and_mirror_together_fails(self):
        self.target('CompositorUpstreamTests')['sources'].append('KeyboardShortcutTests.swift')
        self.assertIn('CompositorTests/KeyboardShortcutTests.swift: expected one test implementation, found 2', self.findings())

    def test_claiming_a_compiled_canvas_is_replaced_fails(self):
        self.parity['platform_substitutions']['Compositor/Rendering/EditorCanvas.swift'] = 'Qt replacement'
        self.assertIn('Compositor/Rendering/EditorCanvas.swift: expected one implementation, found 2', self.findings())


if __name__ == '__main__':
    unittest.main()
