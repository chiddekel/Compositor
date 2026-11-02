"""Package preview ownership, shared by the Nautilus provider and integration installer."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile


class PreviewStore:
    def __init__(self, root, metadata):
        self.root = Path(root)
        self.metadata = metadata

    def _locked(self):
        self.root.mkdir(parents=True, exist_ok=True)
        lock = (self.root / 'lock').open('a')
        fcntl.flock(lock, fcntl.LOCK_EX)
        return lock

    def _read(self):
        path = self.root / 'ownership.json'
        return json.loads(path.read_text()) if path.exists() else {}

    def _save(self, state):
        with tempfile.NamedTemporaryFile(mode='w', dir=self.root, delete=False) as stream:
            json.dump(state, stream)
            temporary = stream.name
        os.replace(temporary, self.root / 'ownership.json')

    def update(self, package):
        package = Path(package).absolute()
        if package.suffix.lower() != '.comp' or package.is_symlink() or not package.is_dir():
            return False
        uri = package.as_uri()
        with self._locked():
            state = self._read()
            old = state.get(uri)
            current = self.metadata.get(uri)
            # A custom icon chosen by the user always wins, including changes made after installation.
            if current and (not old or current != old['owned']):
                return False
            data = None
            for name in ('Preview.jpg', 'Preview.png'):
                preview = package / 'QuickLook' / name
                if (not (package / 'QuickLook').is_symlink() and preview.is_file()
                        and not preview.is_symlink() and preview.stat().st_size <= 16 * 1024 * 1024):
                    try:
                        data = preview.read_bytes()
                        if not self.metadata.valid_image(data):
                            data = None
                            continue
                        break
                    except OSError:
                        continue
            if data is None:
                if old and current == old['owned']:
                    self.metadata.set(uri, old['previous'])
                    state.pop(uri)
                    self._save(state)
                    return True
                return False
            key = hashlib.sha256(uri.encode() + data).hexdigest()
            cached = self.root / (key + '.png')
            owned = cached.as_uri()
            if old and old['owned'] == owned and current == owned and cached.exists():
                return False
            self.metadata.cache_image(data, cached)
            self.metadata.set(uri, owned)
            state[uri] = {'owned': owned, 'previous': old['previous'] if old else current}
            self._save(state)
            return True

    def restore(self):
        with self._locked():
            state = self._read()
            failures = []
            for uri, record in list(state.items()):
                try:
                    if self.metadata.get(uri) == record['owned']:
                        self.metadata.set(uri, record['previous'])
                    state.pop(uri)
                except Exception:
                    failures.append(uri)
            self._save(state)
            return failures


class GioMetadata:
    def __init__(self):
        import gi
        gi.require_version('GdkPixbuf', '2.0')
        from gi.repository import Gio, GdkPixbuf
        self.Gio, self.Pixbuf = Gio, GdkPixbuf

    def get(self, uri):
        info = self.Gio.File.new_for_uri(uri).query_info('metadata::custom-icon', self.Gio.FileQueryInfoFlags.NONE, None)
        return info.get_attribute_string('metadata::custom-icon') or ''

    def set(self, uri, value):
        info = self.Gio.FileInfo()
        if value:
            info.set_attribute_string('metadata::custom-icon', value)
        else:
            # PyGObject disallows None here; INVALID ignores the value pointer (zero).
            info.set_attribute('metadata::custom-icon', self.Gio.FileAttributeType.INVALID, 0)
        self.Gio.File.new_for_uri(uri).set_attributes_from_info(info, self.Gio.FileQueryInfoFlags.NONE, None)

    def _image(self, data):
        loader = self.Pixbuf.PixbufLoader.new()
        # Bound decoded dimensions before allocation, including hostile image headers.
        def sized(loader, width, height):
            factor = min(1, 512 / max(width, height))
            loader.set_size(max(1, round(width * factor)), max(1, round(height * factor)))
        loader.connect('size-prepared', sized)
        loader.write(data)
        loader.close()
        return loader.get_pixbuf()

    def valid_image(self, data):
        try:
            return self._image(data) is not None
        except Exception:
            return False

    def cache_image(self, data, path):
        image = self._image(data)
        temporary = str(path) + '.tmp'
        image.savev(temporary, 'png', [], [])
        os.replace(temporary, path)
