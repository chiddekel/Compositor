#!/usr/bin/env python3
"""Create small, deterministic, redistributable color and Bayer RAW fixtures."""
from pathlib import Path
import argparse
import shutil
import struct

import numpy as np
from PIL import Image, ImageCms

ROOT = Path(__file__).resolve().parents[1]


def tiff(path, width, height, data, extra, bits=16, samples=1, photometric=32803):
    # Classic little-endian TIFF, one uncompressed strip. All offsets are absolute.
    fields = {256: (4, 1, struct.pack('<I', width)), 257: (4, 1, struct.pack('<I', height)),
              258: (3, samples, struct.pack('<' + 'H' * samples, *([bits] * samples))),
              259: (3, 1, struct.pack('<H', 1)), 262: (3, 1, struct.pack('<H', photometric)),
              273: (4, 1, b'\0' * 4), 277: (3, 1, struct.pack('<H', samples)),
              278: (4, 1, struct.pack('<I', height)), 279: (4, 1, struct.pack('<I', len(data))),
              284: (3, 1, struct.pack('<H', 1))}
    fields.update(extra)
    offset = 8 + 2 + 12 * len(fields) + 4
    payload = bytearray()
    entries = []
    for tag, (kind, count, value) in sorted(fields.items()):
        if len(value) > 4:
            if len(payload) % 2:
                payload += b'\0'
            encoded = struct.pack('<I', offset + len(payload))
            payload += value
        else:
            encoded = value.ljust(4, b'\0')
        entries.append((tag, kind, count, encoded))
    strip = offset + len(payload)
    entries = [(t, k, c, struct.pack('<I', strip) if t == 273 else v) for t, k, c, v in entries]
    path.write_bytes(b'II*\0' + struct.pack('<I', 8) + struct.pack('<H', len(fields))
                     + b''.join(struct.pack('<HHI', t, k, c) + v for t, k, c, v in entries)
                     + b'\0' * 4 + payload + data)


def generate(folder):
    folder.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(ROOT / 'third_party/color/SWOP_TR005_coated_5.icc', folder / 'proof.icc')
    for face in ('Regular', 'Bold', 'Light'):
        shutil.copyfile(ROOT / f'third_party/fonts/inter/Inter-{face}.ttf', folder / f'Inter-{face}.ttf')
    profile = bytearray(ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes())
    # Display-P3 primaries adapted to the ICC D50 white point, with the sRGB transfer curve.
    primaries = {b'rXYZ': (.515102, .241182, -.001049), b'gXYZ': (.291965, .692236, .041882),
                 b'bXYZ': (.157153, .066582, .784378)}
    for index in range(struct.unpack_from('>I', profile, 128)[0]):
        tag, offset, size = struct.unpack_from('>4sII', profile, 132 + 12 * index)
        if tag in primaries:
            struct.pack_into('>iii', profile, offset + 8, *(round(v * 65536) for v in primaries[tag]))
    y, x = np.mgrid[:72, :96]
    rgb = np.stack((x * 255 // 95, y * 255 // 71, (x + y) * 255 // 166), axis=-1).astype('uint8')
    Image.fromarray(rgb).save(folder / 'p3.png', icc_profile=bytes(profile))
    Image.fromarray(np.stack((x * 255 // 95, y * 255 // 71), axis=-1).astype('uint8'), 'LA').save(folder / 'gray-alpha.png')
    ramp = np.stack((x / 95, y / 71, (x + y) / 166), axis=-1)
    tiff(folder / 'ramp16.tiff', 96, 72, (ramp * 65535).astype('<u2').tobytes(), {}, samples=3, photometric=2)
    tiff(folder / 'highlights.tiff', 96, 72, (ramp * 3).astype('<f4').tobytes(),
         {339: (3, 3, struct.pack('<HHH', 3, 3, 3))}, bits=32, samples=3, photometric=2)
    for index in range(5):
        width = height = 512
        yy, xx = np.mgrid[:height, :width]
        samples = (4000 + ((xx * (index + 1) + yy * 2) % 128) * 320).astype('<u2')
        make, model = b'Compositor\0', b'Parity sensor\0'
        fields = {254: (4, 1, struct.pack('<I', 0)),
                  271: (2, len(make), make), 272: (2, len(model), model),
                  33421: (3, 2, struct.pack('<HH', 2, 2)), 33422: (1, 4, bytes([0, 1, 1, 2])),
                  50706: (1, 4, bytes([1, 4, 0, 0])), 50707: (1, 4, bytes([1, 3, 0, 0])),
                  50708: (2, len(model), model), 50710: (1, 3, bytes([0, 1, 2])),
                  50711: (3, 1, struct.pack('<H', 1)), 50714: (5, 1, struct.pack('<II', 0, 1)),
                  50717: (4, 1, struct.pack('<I', 65535)),
                  50718: (5, 2, struct.pack('<IIII', 1, 1, 1, 1)),
                  50719: (4, 2, struct.pack('<II', 0, 0)),
                  50720: (4, 2, struct.pack('<II', width, height)),
                  50721: (10, 9, b''.join(struct.pack('<ii', int(i % 4 == 0), 1) for i in range(9))),
                  50728: (5, 3, struct.pack('<IIIIII', 1, 1, 1, 1, 1, 1)),
                  50778: (3, 1, struct.pack('<H', 21)),
                  50829: (4, 4, struct.pack('<IIII', 0, 0, height, width))}
        tiff(folder / f'sensor-{index}.dng', width, height, samples.tobytes(), fields)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    generate(parser.parse_args().output)
