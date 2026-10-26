#!/usr/bin/env python3
"""Validate independent native RGB Split inputs, recipes and complete readbacks."""
import base64
import hashlib
import itertools
import json
import math
from pathlib import Path
import struct
import sys


STORAGES = ("RGBA8", "RGBAh-RNE", "RGBAh-RTZ", "RGBAf")


def unpack(item, size):
    raw = base64.b64decode(item["base64"], validate=True)
    assert len(raw) == size, "Buffer size"
    assert hashlib.sha256(raw).hexdigest() == item["sha256"], "Buffer hash"
    return raw


def source(fixture, storage):
    pixels = []
    for y in range(72):
        for x in range(96):
            a = 255 if fixture == "opaque" else (0 if x < 12 or y < 12 or x > 80 or y > 58 else 160)
            pixels.extend([(x * 255 // 95) * a // 255, (y * 255 // 71) * a // 255,
                           (100 if fixture == "opaque" else 220) * a // 255, a])
    if storage == "RGBA8":
        return bytes(pixels)
    floats = [struct.unpack("<f", struct.pack("<f", v / 255))[0] for v in pixels]
    if storage == "RGBAf":
        return struct.pack("<" + "f" * len(floats), *floats)
    bits = []
    for v in floats:
        half = struct.pack("<e", v)
        bit, = struct.unpack("<H", half)
        if storage == "RGBAh-RTZ" and struct.unpack("<e", half)[0] > v:
            bit -= 1
        bits.append(bit)
    return struct.pack("<" + "H" * len(bits), *bits)


def validate(data, root):
    assert data["schema"] == 1 and data["platform"] == "macOS"
    assert data["device"] and data["os"]
    assert (data["width"], data["height"], data["parameterStride"]) == (96, 72, 72)
    shader = (root / "Compositor/Rendering/MetalDispersion.swift").read_text()
    shader = shader.split('private static let source = """\n', 1)[1].split('\n"""', 1)[0]
    assert data["shaderSHA256"] == hashlib.sha256(shader.encode()).hexdigest(), "Shader provenance"
    script = root / "scripts/capture-dispersion-sampling.swift"
    assert data["scriptSHA256"] == hashlib.sha256(script.read_bytes()).hexdigest(), "Script provenance"
    expected_inputs = set(itertools.product(("opaque", "overlay"), STORAGES))
    assert len(data["inputs"]) == len(expected_inputs)
    seen = set()
    for item in data["inputs"]:
        key = item["fixture"], item["storage"]
        assert key in expected_inputs and key not in seen, "Input matrix"
        seen.add(key)
        expected = source(*key)
        assert unpack(item["data"], len(expected)) == expected, "Source conversion"
    arithmetic = unpack(data["arithmetic"], 96 * 72 * 16)
    for phase, sine, noise, jitter in struct.iter_unpack("<4f", arithmetic):
        assert all(math.isfinite(v) for v in (phase, sine, noise, jitter))
        assert abs(sine) <= 1 and 0 <= jitter < 1
        assert noise - math.floor(noise) == jitter, "Hash arithmetic"
    expected_cases = set(itertools.product(("opaque", "overlay"), STORAGES, (0, 35)))
    assert len(data["cases"]) == len(expected_cases)
    seen = set()
    for item in data["cases"]:
        key = item["fixture"], item["storage"], item["angle"]
        assert key in expected_cases and key not in seen, "Case matrix"
        seen.add(key)
        p = unpack(item["parameters"], 72)
        angle = key[2]
        head = struct.unpack_from("<8f3I", p)
        assert head[:2] == (48, 36) and head[4:] == (10 if angle == 0 else 35, 0, 1000, 0, 0, 10 if angle == 0 else 32, 1)
        assert abs(head[2] - math.cos(math.radians(angle))) < 1e-7
        assert abs(head[3] - math.sin(math.radians(angle))) < 1e-7
        assert struct.unpack_from("<5f", p, 48) == (0, 72, 0, 72, -1)
        floats = unpack(item["float"], 96 * 72 * 16)
        byte = unpack(item["byte"], 96 * 72 * 4)
        for i, (r, g, b, a) in enumerate(struct.iter_unpack("<4f", floats)):
            assert all(math.isfinite(v) for v in (r, g, b, a))
            assert 0 <= a <= 1.000001 and min(r, g, b) >= 0 and max(r, g, b) <= a + 1e-6
            for c, value in enumerate((r, g, b, a)):
                assert abs(byte[i * 4 + c] - min(255, max(0, math.floor(value * 255 + .5)))) <= 1, "Output conversion"
    return {"inputs": len(expected_inputs), "cases": len(expected_cases), "nativeFloatComponents": 16 * 96 * 72 * 4}


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    print(json.dumps(validate(json.loads(Path(sys.argv[1]).read_text()), root), sort_keys=True))
