import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('parity', ROOT / 'scripts/compare-render-parity.py')
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)


class RenderParityTests(unittest.TestCase):
    def test_backend_paths_use_the_render_working_directory(self):
        spec = importlib.util.spec_from_file_location('render', ROOT / 'scripts/render-parity.py')
        render = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(render)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            library = root / 'native/libBackend.so'
            library.parent.mkdir()
            library.write_bytes(b'backend fixture')
            env = {'COMPOSITOR_SKIA_BRIDGE': 'native/libBackend.so',
                   'COMPOSITOR_IMAGEIO_BACKEND': str(library),
                   'COMPOSITOR_PDF_BACKEND': './native/libBackend.so'}
            with patch.object(render, 'ROOT', root):
                metadata = render.prepare_native_backends(env)
            for variable in env:
                self.assertEqual(env[variable], str(library))
            for key in ['skia_bridge', 'imageio_backend', 'pdf_backend']:
                self.assertEqual(metadata[key + '_sha256'], render.digest(library))
                self.assertEqual(metadata[key + '_path'], str(library))

    def test_loader_soname_does_not_hash_a_same_named_local_file(self):
        spec = importlib.util.spec_from_file_location('render', ROOT / 'scripts/render-parity.py')
        render = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(render)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'libBackend.so').write_bytes(b'not necessarily the loader-selected backend')
            env = {'COMPOSITOR_IMAGEIO_BACKEND': 'libBackend.so'}
            with patch.object(render, 'ROOT', root):
                metadata = render.prepare_native_backends(env)
            self.assertEqual(env['COMPOSITOR_IMAGEIO_BACKEND'], 'libBackend.so')
            self.assertEqual(metadata, {'imageio_backend_configured': 'libBackend.so'})

    def test_dng_strings_crop_and_strip_payload_are_consistent(self):
        spec = importlib.util.spec_from_file_location('parity_inputs', ROOT / 'scripts/parity-inputs.py')
        inputs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(inputs)
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / 'inputs'
            inputs.generate(folder)
            for path in sorted(folder.glob('sensor-*.dng')):
                data = path.read_bytes()
                self.assertEqual(data[:4], b'II*\0')
                offset = struct.unpack_from('<I', data, 4)[0]
                count = struct.unpack_from('<H', data, offset)[0]
                tags = {}
                for index in range(count):
                    tag, kind, size, value = struct.unpack_from('<HHI4s', data, offset + 2 + index * 12)
                    tags[tag] = (kind, size, value)
                for tag in (271, 272, 50708):
                    kind, size, value = tags[tag]
                    self.assertEqual(kind, 2)
                    position = struct.unpack('<I', value)[0]
                    text = data[position:position + size] if size > 4 else value[:size]
                    self.assertTrue(text.endswith(b'\0'), (path.name, tag))
                    self.assertNotIn(b'\0', text[:-1], (path.name, tag))
                width = struct.unpack('<I', tags[256][2])[0]
                height = struct.unpack('<I', tags[257][2])[0]
                crop = struct.unpack_from('<II', data, struct.unpack('<I', tags[50720][2])[0])
                self.assertEqual(crop, (width, height))
                active = struct.unpack_from('<IIII', data, struct.unpack('<I', tags[50829][2])[0])
                self.assertEqual(active, (0, 0, height, width))
                strip = struct.unpack('<I', tags[273][2])[0]
                size = struct.unpack('<I', tags[279][2])[0]
                self.assertEqual(size, width * height * 2)
                self.assertEqual(strip + size, len(data))

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
            self.assertTrue(parity.compare(folder / 'mac', folder / 'linux', folder / 'exact', require_exact=True))
            exact_report = json.loads((folder / 'exact/report.json').read_text())
            self.assertTrue(exact_report['exact_passed'])
            self.assertEqual(exact_report['exact_image_cases'], len(catalog))

            # A one-level color difference can pass perceptual limits but is not pixel equivalence.
            near = folder / 'linux' / catalog[0]['file']
            image = Image.new('RGBA', (16, 16), 'white')
            image.putpixel((5, 5), (254, 255, 255, 255))
            image.save(near)
            previous_hash = manifest['images_sha256'][catalog[0]['file']]
            manifest['images_sha256'][catalog[0]['file']] = hashlib.sha256(near.read_bytes()).hexdigest()
            (folder / 'linux/manifest.json').write_text(json.dumps(manifest))
            self.assertTrue(parity.compare(folder / 'mac', folder / 'linux', folder / 'near'))
            self.assertFalse(parity.compare(folder / 'mac', folder / 'linux', folder / 'near-exact', require_exact=True))
            report = json.loads((folder / 'near-exact/report.json').read_text())
            self.assertEqual(report['exact_image_cases'], len(catalog) - 1)
            self.assertEqual(report['results'][0]['exact']['different_pixels'], 1)
            self.assertIn('exact_pixels', report['results'][0]['failures'])
            Image.new('RGBA', (16, 16), 'white').save(near)
            manifest['images_sha256'][catalog[0]['file']] = previous_hash

            # Deep sample differences must not disappear behind RGBA8 PNG conversion.
            deep = next(case['samples'] for case in catalog if 'samples' in case)
            path = folder / 'linux' / deep
            original = path.read_bytes()
            values = json.loads(original)
            values['samples'][0] -= 1 / 65535
            path.write_text(json.dumps(values))
            manifest['images_sha256'][deep] = hashlib.sha256(path.read_bytes()).hexdigest()
            (folder / 'linux/manifest.json').write_text(json.dumps(manifest))
            self.assertTrue(parity.compare(folder / 'mac', folder / 'linux', folder / 'near-deep'))
            self.assertFalse(parity.compare(folder / 'mac', folder / 'linux', folder / 'exact-deep', require_exact=True))
            report = json.loads((folder / 'exact-deep/report.json').read_text())
            self.assertTrue(any('exact_deep_samples' in row['failures'] for row in report['results']))
            path.write_bytes(original)
            manifest['images_sha256'][deep] = hashlib.sha256(original).hexdigest()
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
