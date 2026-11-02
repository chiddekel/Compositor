#!/usr/bin/env python3
"""Exercise the provider in a real, isolated Nautilus process (requires Xvfb and D-Bus)."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(predicate, process):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if predicate():
            return
        if process.poll() is not None:
            raise RuntimeError(f'Nautilus exited with {process.returncode}')
        time.sleep(.2)
    raise RuntimeError('Nautilus did not produce the expected preview within 30 seconds')


def session(root):
    from PIL import Image
    root = Path(root)
    folder = root / 'projects'
    package = folder / 'Zażółć # % sample.comp'
    preview = package / 'QuickLook/Preview.png'
    preview.parent.mkdir(parents=True)
    Image.new('RGB', (320, 200), 'red').save(preview)
    extensions = root / 'data/nautilus-python/extensions'
    extensions.mkdir(parents=True)
    for name in ('compositor_preview.py', 'compositor_previews.py'):
        shutil.copyfile(ROOT / 'desktop/nautilus' / name, extensions / name)
    state = root / 'cache/compositor-previews/ownership.json'
    def owned():
        try:
            return json.loads(state.read_text()).get(package.as_uri(), {}).get('owned')
        except (OSError, ValueError):
            return None
    with (root / 'nautilus.log').open('w') as log:
        app = subprocess.Popen(['nautilus', '--new-window', str(folder)], stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_for(owned, app)
            first = owned()
            Image.new('RGB', (320, 200), 'blue').save(preview)
            wait_for(lambda: owned() and owned() != first, app)
            subprocess.run(['gio', 'info', '-a', 'metadata::custom-icon', str(package)], check=True)
            if shutil.which('xdotool'):
                window = subprocess.check_output(['xdotool', 'search', '--onlyvisible', '--class', 'org.gnome.Nautilus'], text=True).splitlines()[0]
                subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
                subprocess.run(['xdotool', 'key', 'ctrl+r'], check=True)
            if shutil.which('import'):
                def painted():
                    target = root / 'nautilus-preview.png'
                    subprocess.run(['import', '-window', 'root', str(target)], check=True, timeout=10)
                    with Image.open(target) as picture:
                        return sum(r < 30 and g < 70 and b > 180 for r,g,b in picture.convert('RGB').getdata()) > 1000
                wait_for(painted, app)
            preview.write_bytes(b'corrupt')
            wait_for(lambda: not owned(), app)
            assert not (package / '.directory').exists()
            print('Real Nautilus: initial preview, saved-preview refresh, corrupt-preview removal, package preservation PASS')
        finally:
            if shutil.which('import'):
                subprocess.run(['import', '-window', 'root', str(root / 'nautilus.png')], timeout=10)
            app.terminate()
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill(); app.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', type=Path)
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    if args.session:
        session(args.session)
        return
    for command in ('nautilus', 'dbus-run-session', 'xvfb-run', 'xdotool', 'import'):
        if not shutil.which(command):
            raise RuntimeError(f'Required real-desktop test dependency missing: {command}')
    with tempfile.TemporaryDirectory(prefix='compositor-nautilus-') as d:
        root = Path(d)
        (root / 'runtime').mkdir(mode=0o700)
        env = dict(os.environ, XDG_DATA_HOME=str(root / 'data'), XDG_CONFIG_HOME=str(root / 'config'),
                   XDG_CACHE_HOME=str(root / 'cache'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                   GDK_BACKEND='x11', GTK_A11Y='none', NAUTILUS_PYTHON_DEBUG='misc',
                   COMPOSITOR_PREVIEW_DEBUG='1', PATH='/usr/bin:' + os.environ['PATH'])
        for name in ('PYTHONPATH', 'PYTHONHOME', 'VIRTUAL_ENV'):
            env.pop(name, None)
        try:
            subprocess.run(['dbus-run-session', 'xvfb-run', '-a', '/usr/bin/python3', str(Path(__file__).resolve()),
                            '--session', d], check=True, env=env, timeout=100)
        finally:
            if args.evidence:
                args.evidence.mkdir(parents=True, exist_ok=True)
                for name in ('nautilus.log', 'nautilus.png', 'nautilus-preview.png'):
                    if (root / name).exists():
                        shutil.copyfile(root / name, args.evidence / name)


if __name__ == '__main__':
    main()
