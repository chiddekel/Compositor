#!/usr/bin/env python3
"""Create a synthetic RAW ramp with more than eight bits of intensity information."""
import argparse
import importlib.util
from pathlib import Path
import struct

spec = importlib.util.spec_from_file_location('parity_inputs', Path(__file__).with_name('parity-inputs.py'))
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
args = parser.parse_args()
width, height = 1024, 128
# Each RGGB cell records one gray level; there are 512 distinct sensor levels.
row = struct.pack('<' + 'H' * width, *(4096 + x // 2 * 100 for x in range(width)))
args.output.parent.mkdir(parents=True, exist_ok=True)
parity.bayer_dng(args.output, width, height, row * height)
