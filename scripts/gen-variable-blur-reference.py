#!/usr/bin/env python3
"""Losslessly package the independently captured native variable-blur controls."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import zlib


GROUPS = [
    ("pyramid", "variableBlurProbes", 168),
    ("request", "variableRequestProbes", 36),
    ("mask-input", "variableMaskInputs", 6),
    ("varying-mask", "variableMaskProbes", 32),
    ("colored-mask", "variableColorMaskProbes", 8),
    ("geometry", "variableGeometryProbes", 8),
]


def package(raw, source_run, source_commit):
    data = json.loads(raw)
    rows = []
    for group, key, count in GROUPS:
        items = data[key]
        if len(items) != count:
            raise ValueError(f"{key}: expected {count} controls, found {len(items)}")
        for case in items:
            row = {k: case[k] for k in ["fixture", "radius", "maskIntensity", "phaseX", "phaseY",
                                        "renderMargin", "maskKind", "geometryKind"] if k in case}
            row["group"] = group
            row.setdefault("fixture", "opaque-gradient")
            row.setdefault("radius", 0)
            row.setdefault("maskIntensity", 1)
            if group == "geometry":
                extent = case["outputExtent"]
                row["extent"] = [extent[k] for k in ["x", "y", "width", "height"]]
            for field, digest, name, size in [("rgbaBase64", "byteSha256", "rgba", 4),
                                              ("floatBase64", "floatSha256", "floats", 16)]:
                buf = base64.b64decode(case["output"][field], validate=True)
                if len(buf) != 96 * 72 * size or hashlib.sha256(buf).hexdigest() != case["output"][digest]:
                    raise ValueError(f"{key}: invalid {name} buffer or SHA256")
                compressor = zlib.compressobj(9, wbits=-15)
                packed = compressor.compress(buf) + compressor.flush()
                if zlib.decompress(packed, wbits=-15) != buf:
                    raise ValueError("DEFLATE round trip failed")
                row[name + "Deflate"] = base64.b64encode(packed).decode()
                row[name + "SHA256"] = case["output"][digest]
            rows.append(row)
    reference = {"schema": 1, "width": 96, "height": 72, "compression": "RFC1951 raw DEFLATE",
                 "sourceRun": source_run, "sourceCommit": source_commit,
                 "sourceSHA256": hashlib.sha256(raw).hexdigest(), "cases": rows}
    return (json.dumps(reference, indent=2) + "\n").encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--source-run", type=int, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] /
                        "Tests/Fixtures/coreimage-variable-blur-reference.json")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = package(args.capture.read_bytes(), args.source_run, args.source_commit)
    if args.check:
        if args.output.read_bytes() != result:
            raise SystemExit("Native variable-blur fixture differs from the capture")
        print("Native variable-blur fixture matches all 258 captured controls")
    else:
        args.output.write_bytes(result)
        print(f"Packaged 258 native controls into {args.output}")


if __name__ == "__main__":
    main()
