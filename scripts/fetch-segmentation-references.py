#!/usr/bin/env python3
"""Reference photos with exact subject masks for the subject-mask check (T-18 on Linux).

  scripts/fetch-segmentation-references.py <out-dir>

linux/segmentation/references.json lists cut-out photographs on Wikimedia Commons (each one's own transparency is the
subject; licenses recorded there). Each is downloaded at 640 px, composited over a background chosen and drawn from
its name (plain, gradient, grain, or a busy multi-scale texture, so the model can't rely on an empty backdrop), and
written as <out-dir>/photos/<name>.png, with its alpha as the reference mask <out-dir>/reference/<name>.mask.png
(white = subject). Nothing downloaded is committed. Then:

  CompositorHostBootstrap --subject-masks <out-dir>/photos <out-dir>/linux
  scripts/compare-subject-masks.py <out-dir>/linux <out-dir>/reference
"""
import hashlib, io, json, math, pathlib, random, re, sys, time, urllib.error, urllib.request

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
AGENT = "CompositorAudit/1.0 (segmentation reference fixtures)"


def download(url):
    for attempt in range(6):
        try:
            time.sleep(1.5)
            return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": AGENT}), timeout=60).read()
        except urllib.error.HTTPError as error:
            if error.code != 429:
                raise
            time.sleep(10 * (attempt + 1))
    raise SystemExit(f"rate limited: {url}")


def background(kind, size, rng):
    w, h = size
    if kind == "plain":
        return Image.new("RGB", size, tuple(rng.randrange(60, 220) for _ in range(3)))
    if kind == "gradient":
        a, b = [tuple(rng.randrange(0, 256) for _ in range(3)) for _ in range(2)]
        image = Image.new("RGB", size)
        image.putdata([tuple(int(a[c] + (b[c] - a[c]) * (x + y) / (w + h)) for c in range(3)) for y in range(h) for x in range(w)])
        return image
    if kind == "grain":
        base = [rng.randrange(80, 200) for _ in range(3)]
        return Image.frombytes("RGB", size, bytes(max(0, min(255, base[i % 3] + rng.randrange(-40, 41))) for i in range(w * h * 3)))
    # busy: colored value noise at several scales, like foliage or a cluttered room
    layers = []
    for cell in (64, 24, 8):
        gw, gh = w // cell + 2, h // cell + 2
        grid = [[[rng.random() for _ in range(3)] for _ in range(gw)] for _ in range(gh)]
        layers.append((cell, grid))
    pixels = bytearray()
    for y in range(h):
        for x in range(w):
            color = [0.0, 0.0, 0.0]
            for weight, (cell, grid) in zip((0.5, 0.3, 0.2), layers):
                gx, gy = x / cell, y / cell
                ix, iy, fx, fy = int(gx), int(gy), gx - int(gx), gy - int(gy)
                for c in range(3):
                    top = grid[iy][ix][c] * (1 - fx) + grid[iy][ix + 1][c] * fx
                    bottom = grid[iy + 1][ix][c] * (1 - fx) + grid[iy + 1][ix + 1][c] * fx
                    color[c] += weight * (top * (1 - fy) + bottom * fy)
            pixels += bytes(int(255 * v) for v in color)
    return Image.frombytes("RGB", size, bytes(pixels))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = pathlib.Path(sys.argv[1])
    (out / "photos").mkdir(parents=True, exist_ok=True)
    (out / "reference").mkdir(parents=True, exist_ok=True)
    listing = json.loads((ROOT / "linux/segmentation/references.json").read_text())
    cache = out / "downloads"
    cache.mkdir(exist_ok=True)
    kinds = ["plain", "gradient", "grain", "busy"]
    for entry in listing["images"]:
        name = re.sub(r"[^A-Za-z0-9]+", "-", entry["title"].removeprefix("File:").rsplit(".", 1)[0]).strip("-")[:60]
        cached = cache / f"{name}.png"
        if not cached.exists():
            cached.write_bytes(download(entry["thumbnail"]))
        cutout = Image.open(io.BytesIO(cached.read_bytes())).convert("RGBA")
        if max(cutout.size) > 640:
            cutout.thumbnail((640, 640))
        # A reference is only as good as its cut-out: a file whose thumbnail lost its transparency (all opaque) or
        # whose alpha is mostly partial (a line drawing, a glow) says nothing about where the subject ends.
        alpha = list(cutout.getchannel("A").getdata())
        opaque = sum(a >= 250 for a in alpha) / len(alpha)
        partial = sum(16 < a < 240 for a in alpha) / max(1, sum(a > 16 for a in alpha))
        if opaque > 0.97 or partial > 0.25:
            print(f"{name}: skipped (opaque {opaque:.0%}, partial alpha {partial:.0%}: not a usable cut-out)")
            continue
        # Room around the subject, as in a photo; the background is fixed by the name.
        seed = int(hashlib.sha256(name.encode()).hexdigest()[:8], 16)
        rng = random.Random(seed)
        margin = int(0.12 * max(cutout.size))
        size = (cutout.width + 2 * margin, cutout.height + 2 * margin)
        canvas = background(kinds[seed % len(kinds)], size, rng).convert("RGBA")
        canvas.alpha_composite(cutout, (margin, margin))
        canvas.convert("RGB").save(out / "photos" / f"{name}.png")
        mask = Image.new("L", size, 0)
        mask.paste(cutout.getchannel("A"), (margin, margin))
        mask.save(out / "reference" / f"{name}.mask.png")
        print(f"{name}: {size[0]}x{size[1]} on {kinds[seed % len(kinds)]} ({entry['license']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
