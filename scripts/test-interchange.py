#!/usr/bin/env python3
"""Exercise the native interchange comparator against a generated fixture."""
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: test-interchange.py HOST_BOOTSTRAP FIXTURE_DIRECTORY")
    binary = str(Path(sys.argv[1]).resolve())
    fixture = Path(sys.argv[2]).resolve()
    original = fixture / "original.comp"
    manifest = json.loads((original / "manifest.json").read_text())
    text_index = next(i for i, layer in enumerate(manifest["layers"]) if "text" in layer)
    image = next(layer["imageFile"] for layer in manifest["layers"] if layer.get("imageFile"))
    mask = next(layer["maskFile"] for layer in manifest["layers"] if layer.get("isGroup") and layer.get("maskFile"))
    passed = 0

    def check(left, right, failure=None, renders=()):
        nonlocal passed
        result = subprocess.run([binary, "--interchange", "verify", str(left), str(right), *map(str, renders)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        if failure is None:
            assert result.returncode == 0, result.stdout
        else:
            assert result.returncode != 0 and failure in result.stdout, result.stdout
        passed += 1

    with tempfile.TemporaryDirectory(prefix="compositor-interchange-tests-") as directory:
        root = Path(directory)

        def copy(name):
            return Path(shutil.copytree(original, root / (name + ".comp")))

        def edit(package, change):
            path = package / "manifest.json"
            data = json.loads(path.read_text())
            change(data)
            path.write_text(json.dumps(data, separators=(",", ":")))

        check(original, fixture / "linux-resaved.comp")
        equivalent = copy("different-encoding")
        edit(equivalent, lambda data: None)
        # Insert an ancillary PNG text chunk: compressed file bytes differ,
        # decoded pixels must still compare equal.
        png = equivalent / "images" / image
        payload = b"tEXtInterchange\0Equivalent pixel data"
        chunk = struct.pack(">I", len(payload) - 4) + payload + struct.pack(">I", zlib.crc32(payload))
        data = png.read_bytes()
        assert data[-8:-4] == b"IEND"
        png.write_bytes(data[:-12] + chunk + data[-12:])
        check(original, equivalent)

        changed = copy("font")
        edit(changed, lambda data: data["layers"][text_index]["text"]["fontRuns"][0].update(fontName="DifferentFont"))
        check(original, changed, "/fontName")
        changed = copy("range")
        edit(changed, lambda data: data["layers"][text_index]["text"]["colorRuns"][0].update(length=1))
        check(original, changed, "/length")
        changed = copy("order")
        edit(changed, lambda data: data["layers"].reverse())
        check(original, changed, "Metadata")
        changed = copy("missing")
        (changed / "images" / image).unlink()
        check(original, changed, "Asset escapes images directory")
        changed = copy("broken")
        (changed / "images" / image).write_bytes(b"not a PNG")
        check(original, changed, "Invalid or oversized image")
        changed = copy("pixels")
        shutil.copyfile(fixture / "linux-reference.png", changed / "images" / image)
        check(original, changed, "Decoded pixels changed")
        changed = copy("mask")
        shutil.copyfile(fixture / "linux-reference.png", changed / "images" / mask)
        check(original, changed, "Decoded pixels changed")
        left, right = copy("unsafe-left"), copy("unsafe-right")
        for package in (left, right):
            edit(package, lambda data: next(layer for layer in data["layers"] if layer.get("imageFile")).update(imageFile="../outside.png"))
        check(left, right, "Unsafe asset filename")
        changed = copy("symlink")
        (changed / "images").rename(changed / "external-images")
        (changed / "images").symlink_to(changed / "external-images", target_is_directory=True)
        check(original, changed, "Images directory must not be a symlink")
        check(original, fixture / "linux-resaved.comp", renders=(fixture / "linux-reference.png", fixture / "linux-reference.png"))
        check(original, fixture / "linux-resaved.comp", "Decoded pixels changed",
              renders=(fixture / "linux-reference.png", original / "images" / image))
    print(f"Interchange comparator: {passed} positive/negative cases passed")


if __name__ == "__main__":
    main()
