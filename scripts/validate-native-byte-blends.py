#!/usr/bin/env python3
"""Verify native byte blend inputs, coverage and untouched/opaque controls."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent


def inputs(opaque):
    source, backdrop = bytearray(), bytearray()
    for a in range(256):
        for v in range(256):
            da = 255 if opaque else v
            source.extend((32 * a // 255, 43 * a // 255, 220 * a // 255, a))
            backdrop.extend((v * da // 255, (255 - v) * da // 255, 100 * da // 255, da))
    return bytes(source), bytes(backdrop)


def validate(report, folder):
    assert report['schema'] == 1 and report['platform'] == 'macOS'
    assert (report['width'], report['height']) == (256, 256)
    assert report['layout'] == 'RGBA8-premultipliedLast-byteOrder32Big-sRGB'
    assert report['scriptSHA256'] == hashlib.sha256((ROOT / 'scripts/capture-native-byte-blends.swift').read_bytes()).hexdigest()
    expected = {(m, d, o) for m in range(16) for d in (1, 2, 4) for o in (True, False)}
    seen = set()
    for case in report['cases']:
        m, d, o = key = (case['mode'], case['divisor'], case['opaqueBackdrop'])
        assert key in expected and key not in seen, 'Unique complete native case'
        seen.add(key)
        s, b = inputs(o)
        assert case['sourceSHA256'] == hashlib.sha256(s).hexdigest()
        assert case['backdropSHA256'] == hashlib.sha256(b).hexdigest()
        name = f'mode-{m}-divisor-{d}-opaque-{str(o).lower()}.rgba'
        assert case['file'] == name
        raw = (folder / name).read_bytes()
        assert len(raw) == 256 * 256 * 4
        assert case['outputSHA256'] == hashlib.sha256(raw).hexdigest()
        assert raw[:1024] == b[:1024], 'Zero source alpha preserves backdrop and row orientation'
        if o:
            assert raw[3::4] == bytes([255]) * 65536, 'Opaque backdrop retains opaque coverage'
        if m == 0 and d == 1:
            assert raw[-1024:] == s[-1024:], 'Opaque normal source replaces backdrop'
    assert seen == expected
    return {'cases': len(seen), 'pixels': len(seen) * 65536}


if __name__ == '__main__':
    path = Path(sys.argv[1])
    print(json.dumps(validate(json.loads(path.read_text()), path.parent), sort_keys=True))
