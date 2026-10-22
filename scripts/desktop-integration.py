#!/usr/bin/env python3
"""Explicit per-user install/status/uninstall of optional Nautilus/Dolphin previews."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'desktop/nautilus'))
from compositor_preview import GioMetadata, PreviewStore


class Integration:
    def __init__(self, data, config, cache):
        self.data, self.config, self.cache = Path(data), Path(config), Path(cache)
        self.directory = self.data / 'compositor-desktop'
        self.record = self.directory / 'installation.json'
        self.state = json.loads(self.record.read_text()) if self.record.exists() else {'files': {}}

    def save(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile('w', dir=self.directory, delete=False) as stream:
            json.dump(self.state, stream, indent=2)
        os.replace(stream.name, self.record)

    def install_file(self, path, content):
        path = Path(path)
        key = str(path)
        old = self.state['files'].get(key)
        previous = path.read_bytes() if path.exists() else None
        if old and previous is not None and hashlib.sha256(previous).hexdigest() != old['installed']:
            raise ValueError(f'File changed since installation; retained: {path}')
        backup = old['backup'] if old else (base64.b64encode(previous).decode() if previous is not None else None)
        path.parent.mkdir(parents=True, exist_ok=True)
        # Persist the original before replacing any existing user configuration.
        self.state['files'][key] = {'backup': backup, 'installed': hashlib.sha256(content).hexdigest()}
        self.save()
        with tempfile.NamedTemporaryFile('wb', dir=path.parent, delete=False) as stream:
            stream.write(content)
        os.replace(stream.name, path)

    def install(self, desktop, plugin=None):
        if desktop in ('gnome', 'both'):
            import gi
            gi.require_version('Nautilus', '4.0')
            if not any(Path(p).exists() for p in ('/usr/lib64/nautilus/extensions-4/libnautilus-python.so',
                       '/usr/lib/x86_64-linux-gnu/nautilus/extensions-4/libnautilus-python.so',
                       '/usr/lib/nautilus/extensions-4/libnautilus-python.so')):
                raise ValueError('Install the Nautilus 4 Python extension loader first (nautilus-python / python3-nautilus)')
        if desktop in ('kde', 'both'):
            if not plugin or not plugin.is_file():
                raise ValueError('Build desktop/kde and supply --kde-plugin /path/to/acompositorpreview.so')
            if not shutil.which('kreadconfig6') or not shutil.which('kwriteconfig6'):
                raise ValueError('Install KDE Frameworks 6 configuration tools first')
            launcher = next((Path(p) for p in ('/usr/share/applications/org.kde.dolphin.desktop',
                                                '/usr/local/share/applications/org.kde.dolphin.desktop') if Path(p).is_file()), None)
            if launcher is None:
                raise ValueError('Dolphin is not installed')
        if desktop in ('gnome', 'both'):
            for name in ('compositor_preview.py', 'compositor_previews.py'):
                self.install_file(self.data / 'nautilus-python/extensions' / name,
                                  (ROOT / 'desktop/nautilus' / name).read_bytes())
            (self.cache / 'compositor-previews/disabled').unlink(missing_ok=True)
        if desktop in ('kde', 'both'):
            plugin_root = self.directory / 'qt6/plugins'
            self.install_file(plugin_root / 'kf6/thumbcreator/acompositorpreview.so', plugin.read_bytes())
            # Target only Dolphin; other Qt apps keep their existing plugin search paths.
            lines, section = [], ''
            for line in launcher.read_text().splitlines():
                if line.startswith('['):
                    section = line
                if section == '[Desktop Entry]' and line.startswith('Exec='):
                    line = f'Exec=env "QT_PLUGIN_PATH={plugin_root}" dolphin %u'
                if section == '[Desktop Entry]' and line.startswith('DBusActivatable='):
                    continue
                lines.append(line)
                if line == '[Desktop Entry]':
                    lines.append('DBusActivatable=false')
            self.install_file(self.data / 'applications/org.kde.dolphin.desktop', ('\n'.join(lines) + '\n').encode())
            args = ['--file', str(self.config / 'dolphinrc'), '--group', 'PreviewSettings', '--key', 'Plugins']
            saved = subprocess.check_output(['kreadconfig6', *args, '--default', '__COMPOSITOR_UNSET__'], text=True).strip()
            current = 'directorythumbnail,imagethumbnail,jpegthumbnail' if saved == '__COMPOSITOR_UNSET__' else saved
            old = self.state.get('kde_plugins')
            if old and current != old['installed']:
                raise ValueError('Dolphin preview settings changed; retained. Uninstall before reinstalling.')
            desired = ','.join(['acompositorpreview'] + [p for p in current.split(',') if p and p not in ('directorythumbnail', 'acompositorpreview')])
            self.state['kde_plugins'] = {'previous': old['previous'] if old else (None if saved == '__COMPOSITOR_UNSET__' else saved), 'installed': desired}
            self.save()
            subprocess.run(['kwriteconfig6', *args, desired], check=True)
        print('Installed. Restart Nautilus/Dolphin to load the provider. Enable previews in the file manager.')

    def uninstall(self):
        (self.cache / 'compositor-previews').mkdir(parents=True, exist_ok=True)
        (self.cache / 'compositor-previews/disabled').touch()
        failures = (PreviewStore(self.cache / 'compositor-previews', GioMetadata()).restore()
                    if (self.cache / 'compositor-previews/ownership.json').exists() else [])
        if failures:
            raise ValueError(f'Could not restore {len(failures)} preview icons; installation retained for retry')
        old = self.state.get('kde_plugins')
        if old:
            args = ['--file', str(self.config / 'dolphinrc'), '--group', 'PreviewSettings', '--key', 'Plugins']
            current = subprocess.check_output(['kreadconfig6', *args], text=True).strip()
            # Preserve later user selections; only remove our creator and reinstate the original folder creator.
            previous = old['previous'] if old['previous'] is not None else 'directorythumbnail,imagethumbnail,jpegthumbnail'
            restored = previous if current == old['installed'] else ','.join(
                [p for p in current.split(',') if p and p != 'acompositorpreview']
                + (['directorythumbnail'] if 'directorythumbnail' in previous.split(',') and 'directorythumbnail' not in current.split(',') else []))
            subprocess.run(['kwriteconfig6', *args, '--delete'] if current == old['installed'] and old['previous'] is None
                           else ['kwriteconfig6', *args, restored], check=True)
            self.state.pop('kde_plugins')
        for name, record in list(self.state['files'].items()):
            path = Path(name)
            if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != record['installed']:
                print(f'Retained user-modified file: {path}')
                continue
            if record['backup'] is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(base64.b64decode(record['backup']))
            self.state['files'].pop(name)
        self.save()
        print('Uninstalled owned integration. Restart Nautilus/Dolphin to unload the provider.')

    def status(self):
        for name, record in self.state['files'].items():
            path = Path(name)
            state = 'installed' if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == record['installed'] else 'missing or modified'
            print(f'{state}: {path}')
        if not self.state['files']:
            print('Optional desktop integration is not installed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'status', 'uninstall'])
    parser.add_argument('--desktop', choices=['gnome', 'kde', 'both'], default='both')
    parser.add_argument('--kde-plugin', type=Path)
    args = parser.parse_args()
    manager = Integration(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'),
                          os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config'),
                          os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache'))
    try:
        if args.action == 'install':
            manager.install(args.desktop, args.kde_plugin)
        else:
            getattr(manager, args.action)()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'Desktop integration: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
