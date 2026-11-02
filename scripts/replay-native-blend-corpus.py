#!/usr/bin/env python3
"""Replay the direct Core Graphics blend corpus through a byte canvas."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path

from PIL import Image


WIDTH, HEIGHT = 96, 72
UPSTREAM = '2d75d9172835e1dd6111cb2b659958ec33fa5abf'
CORPUS_SHA256 = 'ee5004f45175d4bd63a204405a2064b2a1308bc7c063b5e1613ce52f51260088'
INPUTS_SHA256 = 'fefba214b8b3c35fdb819f573b86bf1b4de3cc32ec60dd7c712c2bc5f8fc5b38'
MODES = (
    'Normal', 'Multiply', 'Screen', 'Overlay', 'Darken', 'Lighten',
    'Color Dodge', 'Color Burn', 'Soft Light', 'Hard Light', 'Difference',
    'Exclusion', 'Hue', 'Saturation', 'Color', 'Luminosity',
)


def corpus_images():
    base, foreground = bytearray(), bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            alpha = 0 if x < 12 or y < 12 or x > 80 or y > 58 else 160
            red, green = x * 255 // (WIDTH - 1), y * 255 // (HEIGHT - 1)
            base.extend((red, green, 100, 255))
            foreground.extend((red * alpha // 255, green * alpha // 255,
                               220 * alpha // 255, alpha))
    return bytes(base), bytes(foreground)


def replay(library_path: Path, reference_dir: Path):
    lib = C.CDLL(str(library_path))
    pixels, size, floating = C.POINTER(C.c_uint8), C.c_size_t, C.c_float
    lib.compositor_canvas_create.argtypes = [pixels, size, size, size]
    lib.compositor_canvas_create.restype = C.c_void_p
    lib.compositor_canvas_draw_image_rect.argtypes = [
        C.c_void_p, pixels, size, size, size,
        floating, floating, floating, floating, floating, C.c_int, C.c_int,
    ]
    lib.compositor_canvas_draw_image_rect.restype = None
    lib.compositor_canvas_destroy.argtypes = [C.c_void_p]
    lib.compositor_canvas_destroy.restype = None

    base, foreground = corpus_images()
    cases = []
    for mode, name in enumerate(MODES):
        for opacity in (100, 50):
            destination = (C.c_uint8 * len(base)).from_buffer_copy(base)
            source = (C.c_uint8 * len(foreground)).from_buffer_copy(foreground)
            canvas = lib.compositor_canvas_create(destination, WIDTH, HEIGHT, WIDTH * 4)
            if not canvas:
                raise RuntimeError('The real byte canvas is unavailable')
            try:
                lib.compositor_canvas_draw_image_rect(
                    canvas, source, WIDTH, HEIGHT, WIDTH * 4,
                    0, 0, WIDTH, HEIGHT, opacity / 100, mode, 1)
            finally:
                lib.compositor_canvas_destroy(canvas)

            reference_path = reference_dir / f'{name}-{opacity}.png'
            reference_png = reference_path.read_bytes()
            with Image.open(reference_path) as image:
                if image.size != (WIDTH, HEIGHT):
                    raise ValueError(f'Unexpected reference dimensions: {reference_path}')
                expected = image.convert('RGBA').tobytes()
            actual = bytes(destination)
            deltas = [abs(left - right) for left, right in zip(actual, expected)]
            cases.append({
                'mode': mode,
                'name': name,
                'opacityPercent': opacity,
                'referencePNG': reference_path.name,
                'referencePNG_SHA256': hashlib.sha256(reference_png).hexdigest(),
                'differentPixels': sum(
                    actual[index:index + 4] != expected[index:index + 4]
                    for index in range(0, len(actual), 4)),
                'differentComponents': sum(delta != 0 for delta in deltas),
                'maxChannel': max(deltas, default=0),
            })
    return {
        'schema': 1,
        'upstream': UPSTREAM,
        'corpusSHA256': CORPUS_SHA256,
        'sourceInputsSHA256': INPUTS_SHA256,
        'candidateSHA256': hashlib.sha256(library_path.read_bytes()).hexdigest(),
        'inputDescription': (
            'RenderParityTests.swift opaque 96x72 gradient base and premultiplied '
            'transparent overlay; direct C canvas draw for Core Graphics modes '
            '0...15 at 100% and 50%.'),
        'cases': cases,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True, help='CompositorSkiaBridge shared library')
    parser.add_argument('--reference-dir', type=Path, required=True,
                        help='Directory containing the 32 independent macOS blend PNGs')
    parser.add_argument('--output', type=Path, required=True, help='Path for the JSON comparison report')
    args = parser.parse_args()
    report = replay(args.library, args.reference_dir)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    exact = sum(case['differentPixels'] == 0 for case in report['cases'])
    print(f"Direct Core Graphics blend corpus: {exact}/{len(report['cases'])} images exact")
    for case in report['cases']:
        if case['differentPixels']:
            print(f"{case['name']} {case['opacityPercent']}%: "
                  f"{case['differentPixels']} pixels, max {case['maxChannel']}/255")


if __name__ == '__main__':
    main()
