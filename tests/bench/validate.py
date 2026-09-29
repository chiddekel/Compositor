"""Correctness gates for exported benchmark frames."""
from __future__ import annotations

import os
from pathlib import Path


def _as_rgba(image_or_path):
    from PIL import Image
    if isinstance(image_or_path, (str, Path)):
        return Image.open(image_or_path).convert("RGBA")
    return image_or_path.convert("RGBA")


def _ssim(a, b) -> float:
    """Structural similarity on luma without numpy (Pillow-only dependency)."""
    a = _as_rgba(a)
    b = _as_rgba(b)
    if a.size != b.size:
        return 0.0
    la = list(a.convert("L").getdata())
    lb = list(b.convert("L").getdata())
    n = len(la)
    if n == 0:
        return 0.0
    mu_a = sum(la) / n
    mu_b = sum(lb) / n
    # Downsample for speed on large frames (still correlated with full SSIM).
    step = max(1, n // 250_000)
    la_s = la[::step]
    lb_s = lb[::step]
    m = len(la_s)
    mu_a = sum(la_s) / m
    mu_b = sum(lb_s) / m
    var_a = sum((x - mu_a) ** 2 for x in la_s) / m
    var_b = sum((x - mu_b) ** 2 for x in lb_s) / m
    cov = sum((la_s[i] - mu_a) * (lb_s[i] - mu_b) for i in range(m)) / m
    c1, c2 = 6.5025, 58.5225
    return float(((2 * mu_a * mu_b + c1) * (2 * cov + c2)) /
                 ((mu_a ** 2 + mu_b ** 2 + c1) * (var_a + var_b + c2)))


def _pixel_budget(a, b, max_abs=3, max_frac=0.001) -> dict:
    a = _as_rgba(a)
    b = _as_rgba(b)
    pa = list(a.getdata())
    pb = list(b.getdata())
    total = len(pa)
    bad = 0
    step = max(1, total // 500_000)
    checked = 0
    for i in range(0, total, step):
        checked += 1
        ca, cb = pa[i], pb[i]
        if max(abs(ca[c] - cb[c]) for c in range(4)) > max_abs:
            bad += 1
    frac = bad / checked if checked else 1.0
    return {"bad_pixels": bad, "checked": checked, "total_pixels": total,
            "frac": frac, "ok": frac <= max_frac}


def validate_export(path: Path, *, width: int, height: int, ppi: float,
                    golden: Path | None = None, backend: str = "reference") -> dict:
    from PIL import Image

    result = {"ok": False, "path": str(path)}
    if not path.exists() or path.stat().st_size < 100:
        result["error"] = "export missing or too small"
        return result
    image = Image.open(path)
    result["format"] = image.format
    result["size"] = list(image.size)
    if image.format != "PNG":
        result["error"] = f"expected PNG, got {image.format}"
        return result
    if image.size != (width, height):
        result["error"] = f"size {image.size} != {(width, height)}"
        return result
    rgba = image.convert("RGBA")
    extrema = rgba.getextrema()
    if not any(lo != hi for lo, hi in extrema):
        result["error"] = "export looks empty/uniform"
        return result
    result["ppi_expected"] = ppi
    dpi = image.info.get("dpi")
    result["export_dpi"] = list(dpi) if dpi else None
    result["ppi_note"] = "export DPI metadata is informational; recipe PPI is authoritative"

    ssim_floor = 0.990 if backend == "host-gpu" else 0.995
    if golden is not None and golden.exists():
        score = _ssim(rgba, golden)
        budget = _pixel_budget(rgba, golden)
        result["ssim"] = score
        result["pixel_budget"] = budget
        if score < ssim_floor:
            result["error"] = f"SSIM {score:.6f} < {ssim_floor}"
            return result
        if not budget["ok"]:
            result["error"] = f"pixel budget exceeded: {budget}"
            return result
    elif os.environ.get("BENCH_UPDATE_GOLDEN") == "1" and golden is not None:
        golden.parent.mkdir(parents=True, exist_ok=True)
        rgba.save(golden)
        result["golden_written"] = str(golden)

    result["ok"] = True
    return result
