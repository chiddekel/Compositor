import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'desktop/nautilus'))
from compositor_preview import PreviewStore, GioMetadata

spec = importlib.util.spec_from_file_location('integration', ROOT / 'scripts/desktop-integration.py')
integration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integration)


class Metadata:
    def __init__(self):
        self.values = {}
    def get(self, uri):
        return self.values.get(uri, '')
    def set(self, uri, value):
        self.values[uri] = value
    def valid_image(self, data):
        return data.startswith(b'image')
    def cache_image(self, data, path):
        path.write_bytes(data)


class DesktopIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / 'Zażółć # %\nimage.comp'
        (self.package / 'QuickLook').mkdir(parents=True)
        self.image = self.package / 'QuickLook/Preview.png'
        self.image.write_bytes(b'image-one')
        self.metadata = Metadata()
        self.store = PreviewStore(self.root / 'cache', self.metadata)

    def test_update_refresh_and_uninstall_preserve_package(self):
        self.assertTrue(self.store.update(self.package))
        original = self.metadata.get(self.package.as_uri())
        self.assertFalse(self.store.update(self.package))
        self.image.write_bytes(b'image-two')
        self.assertTrue(self.store.update(self.package))
        self.assertNotEqual(original, self.metadata.get(self.package.as_uri()))
        self.assertEqual(self.image.read_bytes(), b'image-two')
        self.assertEqual(self.store.restore(), [])
        self.assertEqual(self.metadata.get(self.package.as_uri()), '')
        self.assertEqual(list(self.package.iterdir()), [self.package / 'QuickLook'])

    def test_custom_icons_before_and_after_install_win(self):
        self.metadata.set(self.package.as_uri(), 'file:///user-chosen.png')
        self.assertFalse(self.store.update(self.package))
        self.metadata.set(self.package.as_uri(), '')
        self.store.update(self.package)
        self.metadata.set(self.package.as_uri(), 'file:///new-custom-icon.png')
        self.store.restore()
        self.assertEqual(self.metadata.get(self.package.as_uri()), 'file:///new-custom-icon.png')

    def test_corrupt_deleted_and_external_previews(self):
        self.store.update(self.package)
        self.image.write_bytes(b'corrupt')
        self.assertTrue(self.store.update(self.package))
        self.assertEqual(self.metadata.get(self.package.as_uri()), '')
        self.image.unlink()
        outside = self.root / 'outside.png'; outside.write_bytes(b'image-secret')
        self.image.symlink_to(outside)
        self.assertFalse(self.store.update(self.package))
        self.assertFalse(self.store.update(self.root))

    def test_installer_backup_idempotency_and_user_changes(self):
        manager = integration.Integration(self.root / 'data', self.root / 'config', self.root / 'cache')
        target = self.root / 'data/existing.desktop'
        target.parent.mkdir(); target.write_bytes(b'original')
        manager.install_file(target, b'integration')
        manager.install_file(target, b'integration')
        self.assertEqual(target.read_bytes(), b'integration')
        manager.uninstall()
        self.assertEqual(target.read_bytes(), b'original')
        manager.install_file(target, b'integration')
        target.write_bytes(b'user-edit')
        with self.assertRaises(ValueError):
            manager.install_file(target, b'new-integration')
        manager.uninstall()
        self.assertEqual(target.read_bytes(), b'user-edit')

    def test_real_decoder_rejects_corrupt_and_preserves_aspect(self):
        from PIL import Image
        from io import BytesIO
        metadata = GioMetadata()
        data = BytesIO(); Image.new('RGB', (1280, 800), 'red').save(data, format='PNG')
        self.assertFalse(metadata.valid_image(b'not an image'))
        self.assertTrue(metadata.valid_image(data.getvalue()))
        target = self.root / 'cached.png'
        metadata.cache_image(data.getvalue(), target)
        with Image.open(target) as image:
            self.assertEqual(image.size, (512, 320))

    def test_uninstall_restores_absent_kde_key_and_preserves_later_choices(self):
        manager = integration.Integration(self.root / 'data', self.root / 'config', self.root / 'cache')
        manager.state['kde_plugins'] = {'previous': None, 'installed': 'acompositorpreview,imagethumbnail,jpegthumbnail'}
        with patch.object(integration.subprocess, 'check_output', return_value='acompositorpreview,imagethumbnail,jpegthumbnail'), \
                patch.object(integration.subprocess, 'run') as run:
            manager.uninstall()
            self.assertEqual(run.call_args.args[0][-1], '--delete')
        manager.state['kde_plugins'] = {'previous': 'directorythumbnail,imagethumbnail', 'installed': 'acompositorpreview,imagethumbnail'}
        with patch.object(integration.subprocess, 'check_output', return_value='acompositorpreview,videothumbnail'), \
                patch.object(integration.subprocess, 'run') as run:
            manager.uninstall()
            self.assertEqual(run.call_args.args[0][-1], 'videothumbnail,directorythumbnail')


if __name__ == '__main__':
    unittest.main()
