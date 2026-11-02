#!/usr/bin/env python3
"""Native Bokeh pixels, immutable ownership, device lifetime and transfer accounting."""
import base64
import ctypes as C
import gzip
import json
import os
from pathlib import Path
import struct
import sys


def main(path):
    lib = C.CDLL(path)
    pointer, uint, floats = C.c_void_p, C.c_uint32, C.POINTER(C.c_float)
    lib.compositor_vulkan_raster_create.argtypes = [C.c_int]
    lib.compositor_vulkan_raster_create.restype = pointer
    lib.compositor_vulkan_raster_destroy.argtypes = [pointer]
    lib.compositor_vulkan_raster_device.argtypes = [pointer]
    lib.compositor_vulkan_raster_device.restype = C.c_char_p
    lib.compositor_vulkan_image_upload.argtypes = [pointer, uint, uint, floats]
    lib.compositor_vulkan_image_upload.restype = pointer
    lib.compositor_vulkan_image_upload_rgba8.argtypes = [pointer, uint, uint, C.POINTER(C.c_uint8)]
    lib.compositor_vulkan_image_upload_rgba8.restype = pointer
    lib.compositor_vulkan_image_apply.argtypes = [pointer, uint, uint, uint, uint, pointer, pointer, pointer, floats]
    lib.compositor_vulkan_image_apply.restype = pointer
    lib.compositor_vulkan_image_read.argtypes = [pointer, floats]
    lib.compositor_vulkan_image_destroy.argtypes = [pointer]
    for name in ['resident_bytes', 'upload_bytes', 'readback_bytes', 'submissions']:
        function = getattr(lib, 'compositor_vulkan_raster_' + name)
        function.argtypes = [pointer]
        function.restype = C.c_uint64
    required = os.environ.get('REQUIRE_COREIMAGE_VULKAN') == '1'
    context = lib.compositor_vulkan_raster_create(0 if required else 1)
    if not context:
        assert not required, 'A hardware Vulkan device is required'
        print('SKIP: resident Vulkan (no supported Vulkan device, including software)')
        return
    device = lib.compositor_vulkan_raster_device(context).decode()
    handles = []

    def upload(width, height, data):
        image = lib.compositor_vulkan_image_upload(context, width, height, (C.c_float * len(data))(*data))
        assert image
        handles.append(image)
        return image

    def upload_rgba8(width, height, data):
        image = lib.compositor_vulkan_image_upload_rgba8(context, width, height, (C.c_uint8 * len(data))(*data))
        assert image
        handles.append(image)
        return image

    def apply(width, height, operation, source, values=None, background=None, mask=None, channel=0):
        values = (values or []) + [0] * (20 - len(values or []))
        result = lib.compositor_vulkan_image_apply(context, width, height, operation, channel, source, background, mask,
                                                  (C.c_float * 20)(*values))
        assert result, (operation, width, height)
        handles.append(result)
        return result

    def read(image, count):
        result = (C.c_float * count)()
        assert lib.compositor_vulkan_image_read(image, result) == 0
        return list(result)

    def release():
        for image in reversed(handles):
            lib.compositor_vulkan_image_destroy(image)
        handles.clear()
        assert lib.compositor_vulkan_raster_resident_bytes(context) == 0

    def flip(values, width, height):
        return [v for y in reversed(range(height)) for v in values[y * width * 4:(y + 1) * width * 4]]

    root = Path(__file__).resolve().parents[1]
    reference = json.loads(gzip.decompress((root / 'Tests/Fixtures/metal/adjustment-compute-reference.json.gz').read_bytes()))
    worst = 0
    try:
        # Every byte value must decode bit-for-bit identically on the CPU and GPU.
        raw = list(range(256))
        byte_image = upload_rgba8(64, 1, raw)
        assert lib.compositor_vulkan_raster_resident_bytes(context) == 256
        expected_bytes = [C.c_float(v / 255).value for v in raw]
        assert read(byte_image, 256) == expected_bytes
        decoded = apply(64, 1, 13, byte_image, [1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0])
        assert read(decoded, 256) == expected_bytes
        background = upload_rgba8(64, 1, list(reversed(raw)))
        expected_background = list(reversed(expected_bytes))
        clear_mask = upload_rgba8(64, 1, [0] * 256)
        result = apply(64, 1, 2, byte_image, background=background, mask=clear_mask, channel=3)
        assert read(result, 256) == expected_background
        mask = upload_rgba8(64, 1, [64, 128, 192, 128] * 64)
        for channel, weight in [(0, 0.5), (3, C.c_float(128 / 255).value), (4, 0.9298)]:
            mixed = apply(64, 1, 2, byte_image, background=background, mask=mask, channel=channel)
            blended = [s * weight + b * (1 - weight) for s, b in zip(expected_bytes, expected_background)]
            assert max(abs(a - b) for a, b in zip(read(mixed, 256), blended)) < 2e-7
        release()
        # Half storage must reduce the allocation and physical readback, not only round float32 values.
        source = upload(2, 1, [-0.0, 2, -0.25, 1, 0.1, 0.2, 0.3, 0.5])
        allocated = lib.compositor_vulkan_raster_resident_bytes(context)
        half = apply(2, 1, 14, source)
        assert lib.compositor_vulkan_raster_resident_bytes(context) - allocated == 2 * 8, 'RGBAh must use 8 bytes per pixel'
        reads = lib.compositor_vulkan_raster_readback_bytes(context)
        values = read(half, 8)
        expected = list(struct.unpack('<8e', struct.pack('<8e', -0.0, 2, -0.25, 1, 0.1, 0.2, 0.3, 0.5)))
        assert values == expected, ('Packed half values', values, expected)
        assert struct.pack('<f', values[0]) == struct.pack('<f', -0.0), ('Packed negative zero', values[0])
        assert lib.compositor_vulkan_raster_readback_bytes(context) - reads == 2 * 8
        boundary = [0.0, -0.0, 2**-25, -(2**-25), 2**-24, -(2**-24), 2**-14,
                    1 + 2**-11, 1 + 3 * 2**-11, 65504, 65519, -65519]
        encoded = apply(3, 1, 14, upload(3, 1, boundary))
        rounded = list(struct.unpack('<12e', struct.pack('<12e', *boundary)))
        assert struct.pack('<12f', *read(encoded, 12)) == struct.pack('<12f', *rounded), 'Half storage must round ties to even and preserve subnormals'
        decoded = apply(3, 1, 13, encoded, [1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0])
        assert struct.pack('<12f', *read(decoded, 12)) == struct.pack('<12f', *rounded), 'GPU half reads must preserve signed zero and subnormals'
        mask = apply(2, 1, 14, upload(2, 1, [0.125, 0.25, 0.375, 0.5] * 2))
        background = apply(2, 1, 14, upload(2, 1, [0.25, 0.5, 1, 1] * 2))
        for channel in [0, 3, 4]:
            weight = 0.25 if channel == 0 else 0.5 if channel == 3 else (0.2126 * 0.125 + 0.7152 * 0.25 + 0.0722 * 0.375) / 0.5
            mixed = apply(2, 1, 2, half, background=background, mask=mask, channel=channel)
            blended = [s * weight + b * (1 - weight) for s, b in zip(expected, [0.25, 0.5, 1, 1] * 2)]
            assert max(abs(a - b) for a, b in zip(read(mixed, 8), blended)) < 1e-6, 'Packed source, background and mask must load independently'
        allocated = lib.compositor_vulkan_raster_resident_bytes(context)
        placed = apply(4, 1, 13, half, [1, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0])
        assert lib.compositor_vulkan_raster_resident_bytes(context) - allocated == 4 * 8, 'Padding a half image must retain half storage'
        assert read(placed, 16) == [0] * 4 + expected + [0] * 4
        release()
        # Exhaustive representable values and every finite adjacent-value midpoint,
        # checked against Python's independent IEEE binary16 conversion.
        words = [*range(0x7C01), *range(0x8000, 0xFC01)]
        representable = [struct.unpack('<e', struct.pack('<H', word))[0] for word in words]
        positive = representable[:0x7C00]
        midpoints = [(a + b) / 2 for a, b in zip(positive, positive[1:])]
        for group in [representable, midpoints + [-v for v in midpoints]]:
            group += [0.0] * (-len(group) % 4)
            count = len(group)
            encoded = apply(count // 4, 1, 14, upload(count // 4, 1, group))
            expected = struct.unpack('<' + 'e' * count, struct.pack('<' + 'e' * count, *group))
            assert struct.pack('<' + 'f' * count, *read(encoded, count)) == struct.pack('<' + 'f' * count, *expected)
            decoded = apply(count // 4, 1, 13, encoded, [1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0])
            assert struct.pack('<' + 'f' * count, *read(decoded, count)) == struct.pack('<' + 'f' * count, *expected)
        release()
        # Real allocation pressure: 128 MiB float input plus five 64 MiB half results
        # fit the 512 MiB budget. A sixth result is refused, without poisoning the device.
        width, height = 4096, 2048
        large_pixels = (C.c_float * (width * height * 4))()
        large = lib.compositor_vulkan_image_upload(context, width, height, large_pixels)
        assert large
        handles.append(large)
        for _ in range(5):
            apply(width, height, 14, large)
        assert lib.compositor_vulkan_raster_resident_bytes(context) == 448 * 1024 * 1024
        assert not lib.compositor_vulkan_image_apply(context, width, height, 14, 0, large, None, None, (C.c_float * 20)())
        assert read(upload(1, 1, [0.25, 0.5, 1, 1]), 4) == [0.25, 0.5, 1, 1]
        release()
        del large_pixels
        for sample in reference['bokehCases']:
            buffer = reference['bokehInputs'][sample['fixture']]
            raw = base64.b64decode(buffer['rgbaBase64'])
            pixels = list(struct.unpack('<' + 'e' * (len(raw) // 2), raw))
            result = sample['output']
            expected_raw = base64.b64decode(result['rgbaBase64'])
            expected = struct.unpack('<' + 'e' * (len(expected_raw) // 2), expected_raw)
            for bottom_up in [False, True]:
                source = upload(buffer['width'], buffer['height'], flip(pixels, buffer['width'], buffer['height']) if bottom_up else pixels)
                uploads = lib.compositor_vulkan_raster_upload_bytes(context)
                reads = lib.compositor_vulkan_raster_readback_bytes(context)
                p = [sample['radius'], sample['shape'], sample['ring'], *sample['regionOrigin'],
                     *sample['regionSize'], *sample['outputTop'], *sample['inputTop']] + [0] * 7 + [int(bottom_up), 0]
                image = apply(result['width'], result['height'], 11, source, p)
                assert lib.compositor_vulkan_raster_resident_bytes(context) == buffer['width'] * buffer['height'] * 16 + result['width'] * result['height'] * 8
                assert lib.compositor_vulkan_raster_readback_bytes(context) == reads
                assert lib.compositor_vulkan_raster_upload_bytes(context) == uploads
                actual = read(image, len(expected))
                if bottom_up:
                    actual = flip(actual, result['width'], result['height'])
                error = max(abs(a - b) for a, b in zip(actual, expected))
                worst = max(worst, error)
                assert error <= 0.002, (sample['fixture'], sample['shape'], sample['radius'], sample['ring'], sample['tile'], bottom_up, error)
                release()
        assert len(reference['bokehCases']) == 96
        image = [v / 255 for v in base64.b64decode(reference['dispersionInput']['rgbaBase64'])]
        for case in reference['dispersionCases']:
            source = upload(61, 61, flip(image, 61, 61))
            reads = lib.compositor_vulkan_raster_readback_bytes(context)
            uploads = lib.compositor_vulkan_raster_upload_bytes(context)
            sw, sh, pad = case['streaks']['width'], case['streaks']['height'], case['pad']
            p = [30.5, 30.5, 1, 0, case['distance'], case['blur'], case['reach'], case['radial'],
                 0, case['spectral'], case['smear'], -pad, -pad, 0, 0, 1, 0, 0, 1, 1]
            streaks = apply(sw, sh, 10, source, p)
            p[8], p[11:16], p[18] = 15, [0, 0, -pad, -pad, 1], 2
            result = apply(61, 61, 10, streaks, p)
            assert lib.compositor_vulkan_raster_readback_bytes(context) == reads
            assert lib.compositor_vulkan_raster_upload_bytes(context) == uploads
            expected = base64.b64decode(case['streaks']['rgbaBase64'])
            expected = struct.unpack('<' + 'e' * (len(expected) // 2), expected)
            assert max(abs(a - b) for a, b in zip(flip(read(streaks, sw * sh * 4), sw, sh), expected)) <= 0.002
            expected = base64.b64decode(case['output']['rgbaBase64'])
            actual = flip(read(result, 61 * 61 * 4), 61, 61)
            error = max(abs(round(max(0, min(1, a)) * 255) - b) for a, b in zip(actual, expected))
            assert error <= 2, ('resident spectrum', case['radial'], case['distance'], error)
            release()
        assert len(reference['dispersionCases']) == 4
        # Matrix bias and immutable branching must survive later submissions/scratch reuse.
        source = upload(2, 1, [2, -0.25, 0.5, 1, 0.1, 0.2, 0.3, 0.5])
        matrix = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0.125, 0, 0, 0]
        changed = apply(2, 1, 3, source, matrix)
        half = apply(2, 1, 14, changed)
        uploads = lib.compositor_vulkan_raster_upload_bytes(context)
        reads = lib.compositor_vulkan_raster_readback_bytes(context)
        composite = apply(2, 1, 1, half, background=source)
        assert lib.compositor_vulkan_raster_upload_bytes(context) == uploads
        assert lib.compositor_vulkan_raster_readback_bytes(context) == reads
        assert abs(read(changed, 8)[0] - 2.125) < 1e-6
        assert read(source, 8) == [2, -0.25, 0.5, 1, *list((C.c_float * 4)(0.1, 0.2, 0.3, 0.5))]
        linear = apply(2, 1, 15, source, [1])
        encoded = apply(2, 1, 15, linear, [0])
        assert max(abs(a - b) for a, b in zip(read(encoded, 8), read(source, 8))) < 1e-5
        zero = apply(1, 1, 15, upload(1, 1, [-0.0, 0, 0, 1]), [1])
        assert struct.pack('<f', read(zero, 4)[0]) == struct.pack('<f', -0.0)
        table = upload(2, 1, [0, 0, 0, 1, 1, 1, 1, 1])
        curved = apply(2, 1, 16, source, background=table)
        assert max(abs(a - b) for a, b in zip(read(curved, 8), [1, 0, 0.5, 1, 0.1, 0.2, 0.3, 0.5])) < 1e-5
        opaque = apply(2, 1, 17, source)
        assert read(opaque, 8)[3::4] == [1, 1]
        black = upload(2, 1, [0, 0, 0, 1] * 2)
        dodge = apply(2, 1, 18, source, background=black)
        assert max(abs(a - b) for a, b in zip(read(dodge, 8), [1, -0.25, 0.5, 1, 0.1, 0.2, 0.3, 1])) < 1e-5
        placed = apply(4, 1, 13, source, [1, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0])
        assert read(placed, 16) == [0] * 4 + read(source, 8) + [0] * 4
        # Rejected dimensions, cross-device resources and over-budget requests keep the device alive.
        other = lib.compositor_vulkan_raster_create(1)
        assert other
        assert not lib.compositor_vulkan_image_apply(other, 2, 1, 1, 0, source, source, None, None)
        lib.compositor_vulkan_raster_destroy(other)
        assert not lib.compositor_vulkan_image_upload(context, 65536, 65536, (C.c_float * 4)(1, 1, 1, 1))
        assert read(source, 8)[0] == 2
        # The image owns its device even when the context owner goes away first.
        lib.compositor_vulkan_raster_destroy(context)
        context = None
        assert read(composite, 8)[0] == 2.125
        print(f'Resident Vulkan ({device}): 96 native Bokeh cases in both row orders, 4 native two-pass RGB cases; max Bokeh error {worst}; no intermediate pixel transfers; ownership/lifetime pass')
    finally:
        for image in reversed(handles):
            lib.compositor_vulkan_image_destroy(image)
        if context:
            lib.compositor_vulkan_raster_destroy(context)


if __name__ == '__main__':
    main(sys.argv[1])
