#!/usr/bin/env python3
"""Verify the optional installer and real Dolphin preview display in an isolated session."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def session(root, plugin):
    from PIL import Image
    root = Path(root)
    folder = root / 'projects'
    package = folder / 'Zażółć # % sample.comp'
    preview = package / 'QuickLook/Preview.png'
    preview.parent.mkdir(parents=True)
    Image.new('RGB', (320, 200), 'red').save(preview)
    (folder / '.directory').write_text('[Dolphin]\nPreviewsShown=true\nViewMode=1\n')
    subprocess.run(['/usr/bin/python3', str(ROOT / 'scripts/desktop-integration.py'), 'install',
                    '--desktop', 'kde', '--kde-plugin', str(plugin)], check=True)
    env = dict(os.environ, QT_PLUGIN_PATH=str(root / 'data/compositor-desktop/qt6/plugins'), QT_QPA_PLATFORM='xcb')
    with (root / 'dolphin.log').open('w') as log:
        app = subprocess.Popen(['dolphin', '--new-window', str(folder)], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            def painted(color):
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    if app.poll() is not None:
                        raise RuntimeError(f'Dolphin exited with {app.returncode}')
                    target = root / 'dolphin-preview.png'
                    subprocess.run(['import', '-window', 'root', str(target)], check=True, timeout=10)
                    with Image.open(target) as picture:
                        pixels = picture.convert('RGB').getdata()
                        count = sum((r > 180 and g < 50 and b < 50) if color == 'red' else
                                    (r < 30 and g < 70 and b > 180) for r, g, b in pixels)
                    if count > 1000:
                        return True
                    time.sleep(.3)
                return False
            if not painted('red'):
                windows = subprocess.check_output(['xdotool', 'search', '--onlyvisible', '--class', 'dolphin'], text=True).splitlines()
                subprocess.run(['xdotool', 'windowfocus', '--sync', windows[0]], check=True)
                subprocess.run(['xdotool', 'key', 'F12'], check=True)
                assert painted('red'), 'Dolphin did not paint the project preview'
            Image.new('RGB', (320, 200), 'blue').save(preview)
            windows = subprocess.check_output(['xdotool', 'search', '--onlyvisible', '--class', 'dolphin'], text=True).splitlines()
            subprocess.run(['xdotool', 'windowfocus', '--sync', windows[0]], check=True)
            subprocess.run(['xdotool', 'key', 'ctrl+r'], check=True)
            assert painted('blue'), 'Dolphin did not refresh the saved preview'
            assert not (package / '.directory').exists()
            print('Real Dolphin: optional installation, painted preview, saved-preview refresh, package preservation PASS')
        finally:
            app.terminate()
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill(); app.wait()
            subprocess.run(['/usr/bin/python3', str(ROOT / 'scripts/desktop-integration.py'), 'uninstall'], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plugin', type=Path, required=True)
    parser.add_argument('--session', type=Path)
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    if args.session:
        return session(args.session, args.plugin.resolve())
    for command in ('dolphin', 'dbus-run-session', 'xvfb-run', 'xdotool', 'import'):
        if not shutil.which(command):
            raise RuntimeError(f'Required real-desktop test dependency missing: {command}')
    with tempfile.TemporaryDirectory(prefix='compositor-dolphin-') as d:
        root = Path(d)
        (root / 'runtime').mkdir(mode=0o700)
        env = dict(os.environ, XDG_DATA_HOME=str(root / 'data'), XDG_CONFIG_HOME=str(root / 'config'),
                   XDG_CACHE_HOME=str(root / 'cache'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                   QT_QPA_PLATFORM='xcb', PATH='/usr/bin:' + os.environ['PATH'])
        try:
            subprocess.run(['dbus-run-session', 'xvfb-run', '-a', '/usr/bin/python3', str(Path(__file__).resolve()),
                            '--session', d, '--plugin', str(args.plugin.resolve())], check=True, env=env, timeout=120)
        finally:
            if args.evidence:
                args.evidence.mkdir(parents=True, exist_ok=True)
                for name in ('dolphin.log', 'dolphin-preview.png'):
                    if (root / name).exists():
                        shutil.copyfile(root / name, args.evidence / name)


if __name__ == '__main__':
    main()
