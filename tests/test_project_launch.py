#!/usr/bin/env python3
"""APP-12: GIO desktop launch of a saved package starts a visible project window."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    args.evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='compositor-project-launch-') as d:
        root = Path(d)
        env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
                   XDG_CACHE_HOME=str(root / 'cache'), QT_QPA_PLATFORM='offscreen')
        with (args.evidence / 'fixture.log').open('w') as log:
            subprocess.run([str(binary), '--interchange', 'fixture', str(root / 'fixture')], check=True,
                           env=dict(env, XCTestConfigurationFilePath='interchange'), stdout=log, stderr=subprocess.STDOUT, timeout=60)
        project = root / 'fixture/original.comp'
        manifest = json.loads((project / 'manifest.json').read_text())
        state = args.evidence.resolve() / 'launch-state.json'
        screenshot = args.evidence.resolve() / 'launch.png'
        # A new evidence directory prevents old state or screenshots from satisfying this test.
        if state.exists() or screenshot.exists():
            raise ValueError('Launch evidence already exists; select a fresh output directory')
        desktop = root / 'compositor-launch.desktop'
        executable = str(binary).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
        desktop.write_text(f'[Desktop Entry]\nType=Application\nName=Compositor launch acceptance\nExec="{executable}" %F\nTerminal=false\n')
        env.update(COMPOSITOR_GRAB_PATH=str(screenshot), COMPOSITOR_GRAB_STATE_PATH=str(state))
        with (args.evidence / 'launch.log').open('w') as log:
            subprocess.run(['gio', 'launch', str(desktop), str(project)], check=True, env=env, stdout=log,
                           stderr=subprocess.STDOUT, timeout=15)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not (state.exists() and screenshot.exists()):
                time.sleep(.1)
        observed = json.loads(state.read_text())
        assert (observed['width'], observed['height']) == (manifest['width'], manifest['height'])
        assert len(observed['layers']) == len(manifest['layers']) and observed['layers']
        assert not observed.get('error') and not observed['modified']
        assert 'original' in observed['windowTitle'].lower()
        assert screenshot.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        print('APP-12 PASS: real GIO %F launch, closed application, project window, exact size/layers, clean history')


if __name__ == '__main__':
    main()
