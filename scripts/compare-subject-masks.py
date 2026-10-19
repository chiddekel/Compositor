#!/usr/bin/env python3
"""Scores Linux subject masks against the Mac's (T-18).

  scripts/compare-subject-masks.py <linux-masks> <mac-projects | reference-masks> [--min-iou 0.90]

<linux-masks>: `CompositorHostBootstrap --subject-masks <photos> <linux-masks>` output (`<name>.mask.png`).
<mac-projects>: one `<name>.comp` per photo, saved on the Mac after Layer › Remove Background on that photo alone
(docs/mac-verification-plan.md). The layer's mask, `<layer id>.mask.png` in the package, is the Mac's mask.
Or <reference-masks>: `<name>.mask.png` ground truth (scripts/fetch-segmentation-references.py), for Linux alone.

For each pair: intersection over union of the kept area (gray >= 128), the mean absolute difference (0-255) and the
share of pixels that disagree inside a band around the Mac's edge (where hair and fur go). The run passes when the
median IoU reaches --min-iou and no photo falls below 0.5. Standard library only (PNG decoded here).
"""
import json, pathlib, statistics, struct, sys, zlib


def read_png(path):
    """8-bit gray, gray+alpha, RGB or RGBA, non-interlaced -> (width, height, gray bytes)."""
    data = pathlib.Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    offset, chunks, header = 8, [], None
    while offset < len(data):
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        body = data[offset + 8:offset + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            chunks.append(body)
        offset += 12 + length
    width, height, depth, color, _, _, interlace = header
    channels = {0: 1, 4: 2, 2: 3, 6: 4}.get(color)
    if depth != 8 or channels is None or interlace:
        raise ValueError(f"{path}: unsupported PNG (depth {depth}, color type {color}, interlace {interlace})")
    raw = zlib.decompress(b"".join(chunks))
    stride = width * channels
    rows, previous = [], bytearray(stride)
    for y in range(height):
        kind = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            left = line[x - channels] if x >= channels else 0
            up = previous[x]
            corner = previous[x - channels] if x >= channels else 0
            if kind == 1: line[x] = (line[x] + left) & 255
            elif kind == 2: line[x] = (line[x] + up) & 255
            elif kind == 3: line[x] = (line[x] + (left + up) // 2) & 255
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                line[x] = (line[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
        rows.append(bytes(line))
        previous = line
    if channels <= 2:
        gray = b"".join(row[::channels] for row in rows)
    else:  # a color mask: its luma
        gray = bytes((r * 299 + g * 587 + b * 114) // 1000 for row in rows
                     for r, g, b in zip(row[0::channels], row[1::channels], row[2::channels]))
    return width, height, gray


def mac_mask(package):
    manifest = json.loads((package / "manifest.json").read_text())
    masks = [layer["maskFile"] for layer in manifest.get("layers", []) if layer.get("maskFile")]
    if len(masks) != 1:
        raise ValueError(f"{package.name}: expected one masked layer, found {len(masks)}")
    return read_png(package / masks[0])


def score(linux, mac):
    (w, h, a), (mw, mh, b) = linux, mac
    if (w, h) != (mw, mh):
        raise ValueError(f"sizes differ: Linux {w}x{h}, Mac {mw}x{mh}")
    inter = union = diff = 0
    edge = edge_wrong = 0
    for i in range(w * h):
        ka, kb = a[i] >= 128, b[i] >= 128
        inter += ka and kb
        union += ka or kb
        diff += abs(a[i] - b[i])
        # The Mac's soft edge (neither clearly kept nor clearly hidden) plus its hard transitions.
        if 16 < b[i] < 240 or (i % w and (b[i - 1] >= 128) != kb) or (i >= w and (b[i - w] >= 128) != kb):
            edge += 1
            edge_wrong += ka != kb
    return (inter / union if union else 1.0), diff / (w * h), (edge_wrong / edge if edge else 0.0)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    minimum = float(sys.argv[sys.argv.index("--min-iou") + 1]) if "--min-iou" in sys.argv else 0.90
    if "--min-iou" in sys.argv:
        args.remove(sys.argv[sys.argv.index("--min-iou") + 1])
    if len(args) != 2:
        print(__doc__)
        return 2
    linux_dir, mac_dir = map(pathlib.Path, args)
    results, problems = [], []
    packages = sorted(mac_dir.glob("*.comp"))
    references = [] if packages else sorted(mac_dir.glob("*.mask.png"))
    pairs = [(p.stem, lambda p=p: mac_mask(p)) for p in packages] + [(r.name[:-len(".mask.png")], lambda r=r: read_png(r)) for r in references]
    for name, expected in pairs:
        linux = linux_dir / f"{name}.mask.png"
        try:
            if not linux.exists():
                raise ValueError("no Linux mask (run --subject-masks on the same photos)")
            iou, mad, edge = score(read_png(linux), expected())
            results.append((name, iou, mad, edge))
            print(f"{name:40s} IoU {iou:.3f}  mean diff {mad:5.1f}  edge disagreement {edge:.1%}")
        except Exception as error:  # noqa: BLE001 — report and go on
            problems.append(f"{name}: {error}")
    for problem in problems:
        print(f"ERROR {problem}")
    if not results:
        print("No pairs scored.")
        return 1
    ious = [r[1] for r in results]
    median = statistics.median(ious)
    print(f"\n{len(results)} photos: median IoU {median:.3f}, worst {min(ious):.3f} ({min(results, key=lambda r: r[1])[0]}), "
          f"mean diff {statistics.mean(r[2] for r in results):.1f}, edge disagreement {statistics.mean(r[3] for r in results):.1%}")
    ok = median >= minimum and min(ious) >= 0.5 and not problems
    print("PASS" if ok else f"FAIL (needs median IoU >= {minimum} and every photo >= 0.5)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
