#!/usr/bin/env python3
"""Run the shared parity corpus using upstream macOS or the Linux compatibility build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'Tests/RenderParity/RenderParityTests.swift'


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digest(folder):
    entries = [(p.relative_to(folder).as_posix(), digest(p)) for p in sorted(folder.rglob('*')) if p.is_file()]
    if not entries:
        raise ValueError('no fixture inputs')
    return hashlib.sha256(json.dumps(entries).encode()).hexdigest()


def render(args):
    output, inputs = args.output.resolve(), args.inputs.resolve()
    if output.exists():
        raise ValueError('output already exists; use a new directory to avoid stale renders')
    upstream = subprocess.check_output(['git', 'rev-parse', args.upstream + '^{commit}'], cwd=ROOT, text=True).strip()
    original_inputs = tree_digest(inputs)
    env = dict(os.environ, COMPOSITOR_PARITY_OUTPUT=str(output), COMPOSITOR_PARITY_INPUT=str(inputs))
    output.mkdir(parents=True)
    if platform.system() == 'Darwin':
        with tempfile.TemporaryDirectory(prefix='compositor-parity-mac-') as temporary:
            workspace = Path(temporary)
            archive = workspace / 'source.tar'
            with archive.open('wb') as stream:
                subprocess.run(['git', 'archive', upstream], cwd=ROOT, stdout=stream, check=True)
            source = workspace / 'source'
            source.mkdir()
            with tarfile.open(archive) as stream:
                stream.extractall(source, filter='data')
            # File-system synchronized test groups discover this in the disposable copy only.
            shutil.copyfile(CORPUS, source / 'CompositorTests/RenderParityTests.swift')
            fonts = Path.home() / 'Library/Fonts'
            fonts.mkdir(exist_ok=True)
            for font in inputs.glob('Inter-*.ttf'):
                destination = fonts / font.name
                if destination.exists() and destination.read_bytes() != font.read_bytes():
                    raise ValueError(f'conflicting font: {destination}')
                shutil.copyfile(font, destination)
            scheme = source / 'Compositor.xcodeproj/xcshareddata/xcschemes/Compositor.xcscheme'
            tree = ET.parse(scheme)
            action = tree.getroot().find('TestAction')
            action.set('shouldUseLaunchSchemeArgsEnv', 'NO')
            variables = ET.SubElement(action, 'EnvironmentVariables')
            for key in ('COMPOSITOR_PARITY_OUTPUT', 'COMPOSITOR_PARITY_INPUT'):
                ET.SubElement(variables, 'EnvironmentVariable', key=key, value=env[key], isEnabled='YES')
            tree.write(scheme)
            result = workspace / 'RenderParity.xcresult'
            try:
                # Only this disposable oracle app needs direct access to the shared fixture/output directories.
                # The protected production project and its sandbox entitlements remain untouched.
                run('xcodebuild', 'test', '-project', str(source / 'Compositor.xcodeproj'), '-scheme', 'Compositor',
                    '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', str(workspace / 'DerivedData'),
                    '-resultBundlePath', str(result), '-only-testing:CompositorTests/RenderParityTests',
                    'CODE_SIGN_IDENTITY=-', 'ENABLE_APP_SANDBOX=NO', 'CODE_SIGN_ENTITLEMENTS=',
                    'SWIFT_OPTIMIZATION_LEVEL=-O', env=env, cwd=source)
            finally:
                if result.exists():
                    try:
                        summary = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                                  '--path', str(result)], capture_output=True, text=True, check=True)
                        details = json.loads(summary.stdout)
                        diagnostics = {key: details[key] for key in
                                       ('title', 'result', 'totalTestCount', 'passedTests', 'failedTests',
                                        'skippedTests', 'testFailures') if key in details}
                        output.with_name(output.name + '.test-results.json').write_text(
                            json.dumps(diagnostics, indent=2) + '\n')
                        print(json.dumps(diagnostics, indent=2), flush=True)
                    except (OSError, ValueError, subprocess.CalledProcessError) as error:
                        print(f'Could not extract XCTest summary: {error}', flush=True)
    elif platform.system() == 'Linux':
        run('swift', 'test', '-c', 'release', '--scratch-path', str(args.scratch), '--jobs', str(args.jobs),
            '--filter', 'RenderParityTests', env=env, cwd=ROOT)
    else:
        raise ValueError('unsupported rendering platform')
    if tree_digest(inputs) != original_inputs:
        raise ValueError('inputs changed during the run')
    cases = [{'file': p.relative_to(output).as_posix(), 'category': p.parent.name}
             for p in sorted(output.rglob('*.png'))]
    for case in cases:
        sidecar = case['file'][:-4] + '.samples.json'
        if (output / sidecar).exists():
            case['samples'] = sidecar
    catalog = json.loads((ROOT / 'Tests/RenderParity/cases.json').read_text())
    if cases != catalog:
        raise ValueError('rendered cases do not match the complete checked-in corpus')
    manifest = {'schema': 1, 'platform': 'macOS' if platform.system() == 'Darwin' else 'Linux',
                'upstream': upstream, 'corpus_sha256': digest(CORPUS), 'inputs_sha256': original_inputs,
                'environment': {'os': platform.platform(), 'machine': platform.machine(),
                                'backend': os.environ.get('COMPOSITOR_COREIMAGE_BACKEND', 'Apple Core Image'),
                                'toolchain': subprocess.check_output(['xcrun', 'swift', '--version'] if platform.system() == 'Darwin'
                                                                    else ['swift', '--version'], text=True).strip()},
                'cases': cases, 'images_sha256': {name: digest(output / name) for c in cases
                                                for name in ([c['file'], c['samples']] if 'samples' in c else [c['file']])}}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--upstream', default='upstream/main')
    parser.add_argument('--scratch', type=Path, default=ROOT / '.build/evidence/swift-build')
    parser.add_argument('--jobs', type=int, default=4)
    render(parser.parse_args())
