#!/usr/bin/env python3
"""Compile with the SDK's glslangValidator; --check detects stale bundled words."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = root / 'backends/brush/shaders/continuous_brush.comp'
header = source.with_name('continuous_brush_spv.h')
with tempfile.TemporaryDirectory() as directory:
    output = Path(directory) / 'shader.h'
    subprocess.run(['glslangValidator', '-V', '--target-env', 'vulkan1.0', '--vn',
                    'compositor_brush_spv', '-o', str(output), str(source)], check=True)
    generated = output.read_text()
    if args.check:
        words = lambda text: re.findall(r'0x[0-9a-fA-F]+', text)
        if words(generated) != words(header.read_text()):
            raise SystemExit('Bundled brush SPIR-V is stale; regenerate inside the SDK.')
    else:
        header.write_text(generated)
