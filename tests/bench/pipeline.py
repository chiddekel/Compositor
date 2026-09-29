"""Reference (Pillow) and Host-backed E2E graphics pipelines."""
from __future__ import annotations

import json
import time
from pathlib import Path

from tests.bench.validate import validate_export


def _load_recipe(fixtures: Path) -> dict:
    return json.loads((fixtures / "recipe.json").read_text())


def _phase(record, name, fn):
    started = time.perf_counter()
    fn()
    record["phases"][name] = {"wall_ms": (time.perf_counter() - started) * 1000}


def _hex_rgba(hex_color: str, alpha=255):
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (alpha,)


def run_reference_pipeline(fixtures: Path, artifacts: Path, *, scene: str = "A",
                           golden_dir: Path | None = None, backend: str = "reference",
                           keep_layers: bool = False) -> dict:
    """Full mixed-ops E2E using Pillow as a deterministic reference compositor.

    Mirrors the phase machine the Host pipeline uses so cold/warm/concurrency/soak
    methodology can run without a display. Host backend swaps the compose/export
    implementation while keeping the same recipe and validation.
    """
    from PIL import Image, ImageDraw, ImageFilter, ImageFont

    recipe = _load_recipe(fixtures)
    width, height = recipe["width"], recipe["height"]
    ppi = recipe["ppi"]
    artifacts.mkdir(parents=True, exist_ok=True)
    record = {
        "backend": backend,
        "scene": scene,
        "level": recipe.get("level"),
        "width": width,
        "height": height,
        "ppi": ppi,
        "phases": {},
        "fixture_sha256": (fixtures / "fixture_sha256").read_text().strip(),
    }
    t0 = time.perf_counter()
    layers = []

    def decode():
        nonlocal layers
        bitmaps = []
        for name in recipe["bitmaps"]:
            bitmaps.append(Image.open(fixtures / "bitmaps" / name).convert("RGBA"))
        layers = bitmaps
        record["bitmap_count"] = len(bitmaps)

    _phase(record, "decode_ms", decode)

    canvas = None

    def compose():
        nonlocal canvas, layers
        canvas = Image.new("RGBA", (width, height), (18, 18, 22, 255))
        # Place bitmaps with transforms, opacity, and pseudo blend modes.
        for i, bmp in enumerate(layers):
            scale = 0.35 + (i % 5) * 0.08
            w = max(8, int(bmp.width * scale))
            h = max(8, int(bmp.height * scale))
            placed = bmp.resize((w, h), Image.Resampling.BILINEAR)
            if i % 4 == 1:
                placed = placed.transpose(Image.Transpose.ROTATE_90)
            if i % 4 == 2:
                placed = placed.transpose(Image.Transpose.ROTATE_180)
            ox = (i * 97 + (ord(scene) * 13)) % max(1, width - w)
            oy = (i * 53 + (ord(scene) * 7)) % max(1, height - h)
            # Multiply-ish darken for variety.
            if i % 3 == 1:
                base = canvas.crop((ox, oy, ox + w, oy + h))
                mixed = Image.blend(base, placed, 0.55)
                canvas.paste(mixed, (ox, oy))
            else:
                canvas.alpha_composite(placed, (ox, oy))

        draw = ImageDraw.Draw(canvas, "RGBA")
        palette = recipe["palette"]
        # Vector shapes + gradients (approximated with filled ellipses/rects).
        for s in range(recipe["shapes"]):
            color = _hex_rgba(palette[s % len(palette)], 160 + (s % 80))
            x0 = (s * 41 + ord(scene) * 3) % width
            y0 = (s * 37) % height
            span = 40 + (s % 90)
            if s % 2 == 0:
                draw.ellipse((x0, y0, x0 + span, y0 + span), fill=color)
            else:
                draw.rectangle((x0, y0, x0 + span, y0 + span // 2), fill=color)

        # Text layers (bundled default font; face name recorded for Host parity).
        try:
            font = ImageFont.load_default()
        except Exception:
            font = None
        for t in range(recipe["texts"]):
            label = f"{scene}-{t}-{recipe['fonts'][t % len(recipe['fonts'])]}"
            color = _hex_rgba(palette[(t + 2) % len(palette)], 230)
            draw.text(((t * 120) % (width - 80), (t * 40) % (height - 40)),
                      label, fill=color, font=font)

        # Mask / clipping approximation: punch a soft hole then restore rim.
        mask = Image.new("L", (width, height), 255)
        mdraw = ImageDraw.Draw(mask)
        mdraw.ellipse((width // 4, height // 4, 3 * width // 4, 3 * height // 4), fill=200)
        faded = canvas.copy()
        faded.putalpha(mask)
        canvas = Image.alpha_composite(Image.new("RGBA", (width, height), (18, 18, 22, 255)), faded)

        # Effects: blur / shadow on a crop region.
        for e in range(min(recipe["effect_layers"], 32)):
            box = (
                (e * 64) % max(1, width - 128),
                (e * 48) % max(1, height - 128),
                (e * 64) % max(1, width - 128) + 128,
                (e * 48) % max(1, height - 128) + 128,
            )
            region = canvas.crop(box).filter(ImageFilter.GaussianBlur(radius=1.5 + (e % 3)))
            canvas.paste(region, box[:2])

        # Duplicates: stamp downscaled copies (object-count pressure).
        thumb = canvas.resize((max(8, width // 16), max(8, height // 16)), Image.Resampling.BILINEAR)
        for d in range(min(recipe["duplicates"], 2000)):
            canvas.alpha_composite(
                thumb,
                ((d * 31) % max(1, width - thumb.width),
                 (d * 17) % max(1, height - thumb.height)),
            )

        if not keep_layers:
            layers = []

    _phase(record, "compose_ms", compose)

    export_path = artifacts / f"scene-{scene}.png"

    def render_export():
        # Embed recipe PPI in PNG metadata when possible.
        canvas.save(export_path, format="PNG", dpi=(ppi, ppi))
        record["export_bytes"] = export_path.stat().st_size
        record["pixels_processed"] = width * height * (
            record.get("bitmap_count", 0) + recipe["shapes"] + recipe["texts"]
        )

    _phase(record, "render_export_ms", render_export)

    def validate():
        golden = None
        if golden_dir is not None:
            golden = golden_dir / f"{recipe.get('level', 'small')}-{scene}.png"
        result = validate_export(
            export_path, width=width, height=height, ppi=ppi,
            golden=golden, backend=backend,
        )
        record["validation"] = result
        if not result.get("ok"):
            raise AssertionError(result.get("error", "validation failed"))

    _phase(record, "validate_ms", validate)

    record["total_ms"] = (time.perf_counter() - t0) * 1000
    record["export_path"] = str(export_path)
    # Soft handle for warm_same_scene re-export without rebuild.
    record["_canvas"] = canvas
    return record


def reexport_reference(record: dict, artifacts: Path, tag: str) -> dict:
    """Warm same-scene: re-encode the already composed canvas."""
    canvas = record.get("_canvas")
    if canvas is None:
        raise RuntimeError("no composed canvas for re-export")
    artifacts.mkdir(parents=True, exist_ok=True)
    path = artifacts / f"reexport-{tag}.png"
    started = time.perf_counter()
    canvas.save(path, format="PNG", dpi=(record["ppi"], record["ppi"]))
    wall = (time.perf_counter() - started) * 1000
    return {
        "total_ms": wall,
        "phases": {"render_export_ms": {"wall_ms": wall}},
        "export_bytes": path.stat().st_size,
        "export_path": str(path),
        "scene": record["scene"],
        "validation": {"ok": True, "reexport": True},
    }


def run_host_pipeline(fixtures: Path, artifacts: Path, *, scene: str = "A",
                      golden_dir: Path | None = None, session=None) -> dict:
    """Host-backed pipeline via observation bridge + session commands.

    Requires COMPOSITOR_BENCH_ALLOW_COMMANDS=1 and a live HostSession.
    """
    from tests.bench.host_session import HostSession

    recipe = _load_recipe(fixtures)
    own = session is None
    session = session or HostSession(artifacts / "host-bridge")
    record = {
        "backend": "host",
        "scene": scene,
        "level": recipe.get("level"),
        "width": recipe["width"],
        "height": recipe["height"],
        "ppi": recipe["ppi"],
        "phases": {},
        "fixture_sha256": (fixtures / "fixture_sha256").read_text().strip(),
    }
    t0 = time.perf_counter()
    try:
        def decode_and_doc():
            session.command({"action": "new", "width": recipe["width"],
                             "height": recipe["height"], "emptyLayer": True})
            # Apply PPI via resizeImage with same pixel size.
            session.command({
                "action": "resizeImage",
                "width": recipe["width"],
                "height": recipe["height"],
                "value": float(recipe["ppi"]),
            })
            paths = [str(fixtures / "bitmaps" / name) for name in recipe["bitmaps"]]
            session.command({"action": "importFiles", "paths": paths})

        _phase(record, "decode_ms", decode_and_doc)

        def compose():
            # Representative Host ops: shapes, gradient, text, effect.
            w, h = recipe["width"], recipe["height"]
            session.command({"action": "shapeBegin", "kind": "ellipse",
                             "x": w * 0.2, "y": h * 0.2})
            session.command({"action": "shapeDrag", "x": w * 0.5, "y": h * 0.5})
            session.command({"action": "shapeFinish"})
            session.command({"action": "gradientBegin", "x": w * 0.5, "y": h * 0.5})
            session.command({"action": "gradientDrag", "x": w * 0.75, "y": h * 0.5})
            session.command({"action": "gradientApply"})
            session.command({"action": "textBegin", "x": 80, "y": 80})
            session.command({"action": "textInsert", "text": f"E2E {scene}"})
            session.command({"action": "textCommit"})
            session.command({"action": "addLayerEffect", "kind": "Drop Shadow"})

        _phase(record, "compose_ms", compose)

        export_path = artifacts / f"host-scene-{scene}.png"

        def render_export():
            # Prefer bridge export (SessionWindow::exportPNG) — no file dialog.
            result = session.request("export", name=export_path.name)
            if not result.get("ok"):
                raise RuntimeError(f"host export failed: {result}")
            record["export_bytes"] = Path(result["path"]).stat().st_size
            record["pixels_processed"] = recipe["width"] * recipe["height"]

        _phase(record, "render_export_ms", render_export)

        def validate():
            golden = None
            if golden_dir is not None:
                golden = golden_dir / f"{recipe.get('level', 'small')}-{scene}-host.png"
            result = validate_export(
                export_path if export_path.exists() else artifacts / export_path.name,
                width=recipe["width"], height=recipe["height"], ppi=recipe["ppi"],
                golden=golden, backend="host",
            )
            record["validation"] = result
            if not result.get("ok"):
                raise AssertionError(result.get("error", "validation failed"))

        _phase(record, "validate_ms", validate)
        record["total_ms"] = (time.perf_counter() - t0) * 1000
        record["export_path"] = str(export_path)
    finally:
        if own:
            session.close()
    return record
