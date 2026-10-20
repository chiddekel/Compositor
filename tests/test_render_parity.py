import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('parity', ROOT / 'scripts/compare-render-parity.py')
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)


class RenderParityTests(unittest.TestCase):
    def test_published_ciede2000_pairs(self):
        # Sharma/Wu/Dalal supplementary test data, first three pairs.
        a = np.array([[50, 2.6772, -79.7751], [50, 3.1571, -77.2803], [50, 2.8361, -74.0200]])
        b = np.array([[50, 0, -82.7485]] * 3)
        np.testing.assert_allclose(parity.delta_e(a, b), [2.0425, 2.8615, 3.4412], atol=.0001)

    def test_transparent_hidden_color_is_ignored(self):
        a = np.zeros((16, 16, 4)); b = a.copy(); b[..., :3] = 1
        self.assertEqual(parity.metrics(a, b)['channel_max'], 0)
        self.assertEqual(parity.metrics(a, b)['delta_e_max'], 0)

    def test_alpha_and_visible_color_damage_are_detected(self):
        a = np.ones((16, 16, 4)); b = a.copy(); b[5:10, 5:10, 3] = 0
        self.assertEqual(parity.metrics(a, b)['alpha_max'], 255)
        self.assertLess(parity.metrics(a, b)['ssim'], .99)
        b = a.copy(); b[..., 0] = 0
        self.assertGreater(parity.metrics(a, b)['delta_e_mean'], 3)

    def test_dimensions_must_match(self):
        with self.assertRaises(ValueError):
            parity.metrics(np.zeros((2, 2, 4)), np.zeros((3, 2, 4)))

    def test_absent_reference_never_passes(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            with self.assertRaises(OSError):
                parity.compare(folder / 'mac', folder / 'linux', folder / 'results')

    def test_identical_corrupt_and_missing_evidence(self):
        from PIL import Image
        import hashlib
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            catalog = json.loads((ROOT / 'Tests/RenderParity/cases.json').read_text())
            for platform, name in [('macOS', 'mac'), ('Linux', 'linux')]:
                root = folder / name
                hashes = {}
                for case in catalog:
                    path = root / case['file']; path.parent.mkdir(parents=True, exist_ok=True)
                    Image.new('RGBA', (16, 16), 'white').save(path)
                    hashes[case['file']] = hashlib.sha256(path.read_bytes()).hexdigest()
                    if 'samples' in case:
                        data = root / case['samples']
                        data.write_text(json.dumps({'hdr': False, 'width': 16, 'height': 16, 'samples': [1] * (16 * 16 * 4)}))
                        hashes[case['samples']] = hashlib.sha256(data.read_bytes()).hexdigest()
                manifest = {'schema': 1, 'upstream': 'test', 'corpus_sha256': 'corpus', 'inputs_sha256': 'inputs',
                            'platform': platform, 'environment': {'test': True}, 'cases': catalog, 'images_sha256': hashes}
                (root / 'manifest.json').write_text(json.dumps(manifest))
            self.assertTrue(parity.compare(folder / 'mac', folder / 'linux', folder / 'good'))
            for key, value in [('schema', 0), ('platform', 'macOS'), ('upstream', 'other-upstream'), ('inputs_sha256', 'different')]:
                changed = dict(manifest, **{key: value})
                (folder / 'linux/manifest.json').write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    parity.compare(folder / 'mac', folder / 'linux', folder / f'bad-{key}')
            (folder / 'linux/manifest.json').write_text(json.dumps(manifest))
            damaged = folder / 'linux' / catalog[0]['file']
            Image.new('RGBA', (16, 16), 'black').save(damaged)
            with self.assertRaisesRegex(ValueError, 'checksum'):
                parity.compare(folder / 'mac', folder / 'linux', folder / 'corrupt')
            manifest['images_sha256'][catalog[0]['file']] = hashlib.sha256(damaged.read_bytes()).hexdigest()
            (folder / 'linux/manifest.json').write_text(json.dumps(manifest))
            self.assertFalse(parity.compare(folder / 'mac', folder / 'linux', folder / 'mismatch'))
            damaged.unlink()
            with self.assertRaises(OSError):
                parity.compare(folder / 'mac', folder / 'linux', folder / 'missing')
            manifest['cases'] = catalog[1:]
            (folder / 'linux/manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'cases'):
                parity.compare(folder / 'mac', folder / 'linux', folder / 'incomplete')


if __name__ == '__main__':
    unittest.main()
