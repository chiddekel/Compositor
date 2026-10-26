#!/usr/bin/env python3
"""Capture the unchanged upstream C color-cube kernel on native macOS."""
import argparse
import base64
import ctypes
import functools
import hashlib
import itertools
import json
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
WIDTH, HEIGHT = 96, 72
RECIPES = tuple(itertools.product((2, 3, 17, 33), ("identity", "mixed"), ("opaque", "coverage")))


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def packed(raw):
    return dict(base64=base64.b64encode(raw).decode(), sha256=digest(raw))


@functools.lru_cache(None)
def source(fixture):
    pixels = []
    for y in range(HEIGHT):
        for x in range(WIDTH):
            a = 255 if fixture == "opaque" else (17 * x + 29 * y) % 256
            pixels.extend([(x * 255 // 95) * a // 255, (y * 255 // 71) * a // 255, 100 * a // 255, a])
    return bytes(pixels)


@functools.lru_cache(None)
def cube(dimension, kind):
    state = 0x9e3779b9 ^ dimension
    def random_value():
        nonlocal state
        state ^= (state << 13) & 0xffffffff
        state ^= state >> 17
        state ^= (state << 5) & 0xffffffff
        state &= 0xffffffff
        return state / 0xffffffff
    values = []
    for b, g, r in itertools.product(range(dimension), repeat=3):
        values.extend([r / (dimension - 1), g / (dimension - 1), b / (dimension - 1), 1] if kind == "identity"
                      else [random_value(), random_value(), random_value(), 1])
    return struct.pack("<" + "f" * len(values), *values)


def unpack(item, size):
    raw = base64.b64decode(item["base64"], validate=True)
    assert len(raw) == size and digest(raw) == item["sha256"], "Buffer size or hash"
    return raw


def validate(report):
    assert report["schema"] == 1 and report["platform"] == "Darwin" and report["machine"] == "arm64"
    assert (report["width"], report["height"]) == (WIDTH, HEIGHT)
    assert report["scriptSHA256"] == digest(Path(__file__).read_bytes()), "Script provenance"
    assert report["kernelSHA256"] == digest((ROOT / "Compositor/Rendering/LevelsPixels.c").read_bytes()), "Kernel provenance"
    assert report["headerSHA256"] == digest((ROOT / "Compositor/Rendering/LevelsPixels.h").read_bytes()), "Header provenance"
    assert report["compilerVersion"] and report["os"]
    assert report["compileFlags"] == {"native": ["-O3"], "unfused": ["-O3", "-ffp-contract=off"]}
    assert len(report["cases"]) == len(RECIPES)
    seen, differences = set(), 0
    for case in report["cases"]:
        key = case["dimension"], case["kind"], case["fixture"]
        assert key in RECIPES and key not in seen, "Recipe matrix"
        seen.add(key)
        original = source(key[2])
        assert case["inputSHA256"] == digest(original) and case["cubeSHA256"] == digest(cube(*key[:2])), "Input provenance"
        native = unpack(case["native"], WIDTH * HEIGHT * 4)
        unfused = unpack(case["unfused"], WIDTH * HEIGHT * 4)
        for output in (native, unfused):
            assert output[3::4] == original[3::4], "Alpha preservation"
            assert all(max(output[i:i + 3]) <= output[i + 3] for i in range(0, len(output), 4)), "Associated colors"
        differences += sum(a != b for a, b in zip(native, unfused))
    assert differences == report["nativeUnfusedDifferentComponents"] and differences > 0, "Nonvacuous arithmetic control"
    return dict(cases=len(seen), nativeUnfusedDifferentComponents=differences)


def capture():
    assert platform.system() == "Darwin" and platform.machine() == "arm64", "Native arm64 macOS required"
    compiler = shutil.which("clang")
    assert compiler, "Native compiler required"
    flags = dict(native=["-O3"], unfused=["-O3", "-ffp-contract=off"])
    with tempfile.TemporaryDirectory(prefix="compositor-native-cube-") as tmp:
        libraries = {}
        for name, options in flags.items():
            path = Path(tmp) / (name + ".dylib")
            subprocess.run([compiler, *options, "-dynamiclib", str(ROOT / "Compositor/Rendering/LevelsPixels.c"), "-o", str(path)], check=True)
            library = ctypes.CDLL(str(path))
            function = library.cube_apply
            function.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t, ctypes.POINTER(ctypes.c_float), ctypes.c_int]
            libraries[name] = library
        cases, differences = [], 0
        for dimension, kind, fixture in RECIPES:
            original = source(fixture)
            table = cube(dimension, kind)
            values = (ctypes.c_float * (len(table) // 4)).from_buffer_copy(table)
            row = dict(dimension=dimension, kind=kind, fixture=fixture, inputSHA256=digest(original), cubeSHA256=digest(table))
            outputs = []
            for name, library in libraries.items():
                pixels = (ctypes.c_uint8 * len(original)).from_buffer_copy(original)
                library.cube_apply(pixels, WIDTH * HEIGHT, values, dimension)
                raw = bytes(pixels)
                row[name] = packed(raw)
                outputs.append(raw)
            differences += sum(a != b for a, b in zip(*outputs))
            cases.append(row)
    return dict(schema=1, platform=platform.system(), machine=platform.machine(), os=platform.platform(), width=WIDTH, height=HEIGHT,
                scriptSHA256=digest(Path(__file__).read_bytes()), kernelSHA256=digest((ROOT / "Compositor/Rendering/LevelsPixels.c").read_bytes()),
                headerSHA256=digest((ROOT / "Compositor/Rendering/LevelsPixels.h").read_bytes()), compileFlags=flags,
                compilerVersion=subprocess.check_output([compiler, "--version"], text=True).strip(),
                nativeUnfusedDifferentComponents=differences, cases=cases)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate", type=Path)
    args = parser.parse_args()
    if args.validate:
        print(json.dumps(validate(json.loads(args.validate.read_text())), sort_keys=True))
    else:
        report = capture()
        validate(report)
        print(json.dumps(report, sort_keys=True, indent=2))
