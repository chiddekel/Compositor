"""Deterministic fixture pack generator for the graphics E2E benchmark."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import sys
from pathlib import Path

# Allow `python3 tests/bench/fixtures/generate.py` without installing the package.
_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from tests.bench.levels import DEFAULT_SEED, GENERATOR_VERSION, LEVELS  # noqa: E402


def _rng(seed: int, level: str) -> random.Random:
    material = f"{seed}:{level}:v{GENERATOR_VERSION}".encode()
    digest = hashlib.sha256(material).hexdigest()
    return random.Random(int(digest[:16], 16))


def _write_bitmap(path: Path, side: int, rng: random.Random, index: int) -> None:
    from PIL import Image, ImageDraw

    image = Image.new("RGBA", (side, side), (20 + (index * 17) % 40, 24, 28, 255))
    draw = ImageDraw.Draw(image)
    for _ in range(8):
        x0, y0 = rng.randint(0, side - 1), rng.randint(0, side - 1)
        x1, y1 = rng.randint(0, side - 1), rng.randint(0, side - 1)
        color = (rng.randint(40, 255), rng.randint(40, 255), rng.randint(40, 255), rng.randint(180, 255))
        if index % 3 == 0:
            draw.ellipse((min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)), fill=color)
        elif index % 3 == 1:
            draw.rectangle((min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)), fill=color)
        else:
            draw.polygon([(x0, y0), (x1, y0), ((x0 + x1) // 2, y1)], fill=color)
    # Soft radial falloff for blend/mask stress.
    cx = cy = side / 2
    pixels = image.load()
    for y in range(0, side, 2):
        for x in range(0, side, 2):
            d = math.hypot(x - cx, y - cy) / (side * 0.55)
            if d > 1:
                r, g, b, a = pixels[x, y]
                pixels[x, y] = (r, g, b, max(0, int(a * (2 - d))))
    image.save(path, format="PNG")


def generate(level: str, seed: int, out: Path) -> dict:
    if level not in LEVELS:
        raise SystemExit(f"unknown level {level!r}; choose from {sorted(LEVELS)}")
    spec = dict(LEVELS[level])
    if level == "stress" and os.environ.get("BENCH_STRESS_8K") == "1":
        spec["width"] = spec["width_8k"]
        spec["height"] = spec["height_8k"]

    out.mkdir(parents=True, exist_ok=True)
    bitmaps_dir = out / "bitmaps"
    bitmaps_dir.mkdir(exist_ok=True)
    rng = _rng(seed, level)

    bitmap_paths = []
    for i in range(spec["bitmaps"]):
        path = bitmaps_dir / f"bmp_{i:03d}.png"
        _write_bitmap(path, spec["bitmap_side"], rng, i)
        bitmap_paths.append(path.name)

    recipe = {
        "generator_version": GENERATOR_VERSION,
        "seed": seed,
        "level": level,
        "width": spec["width"],
        "height": spec["height"],
        "ppi": spec["ppi"],
        "bitmaps": bitmap_paths,
        "shapes": spec["shapes"],
        "texts": spec["texts"],
        "effect_layers": spec["effect_layers"],
        "duplicates": spec["duplicates"],
        "scenes": list(spec["scenes"]),
        "warm_iters": spec["warm_iters"],
        "warmup_pipelines": spec["warmup_pipelines"],
        "palette": [
            "#2563eb", "#e11d48", "#f59e0b", "#10b981", "#8b5cf6",
            "#06b6d4", "#f97316", "#84cc16",
        ],
        "blend_modes": ["Normal", "Multiply", "Screen", "Overlay"],
        "fonts": ["DejaVu Sans", "DejaVu Serif", "DejaVu Sans Mono"],
    }
    (out / "recipe.json").write_text(json.dumps(recipe, indent=2) + "\n")

    # Content hash over recipe + every bitmap byte.
    h = hashlib.sha256()
    h.update(json.dumps(recipe, sort_keys=True).encode())
    for name in bitmap_paths:
        h.update((bitmaps_dir / name).read_bytes())
    digest = h.hexdigest()
    (out / "fixture_sha256").write_text(digest + "\n")
    meta = {"fixture_sha256": digest, "level": level, "seed": seed,
            "generator_version": GENERATOR_VERSION, "path": str(out)}
    (out / "manifest.json").write_text(json.dumps(meta, indent=2) + "\n")
    return meta


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--level", required=True, choices=sorted(LEVELS))
    parser.add_argument("--out", type=Path,
                        default=None,
                        help="Output directory (default: tests/bench/fixtures/generated/<level>)")
    args = parser.parse_args(argv)
    out = args.out or (Path(__file__).resolve().parent / "generated" / args.level)
    meta = generate(args.level, args.seed, out)
    print(json.dumps(meta, indent=2))


if __name__ == "__main__":
    main()
