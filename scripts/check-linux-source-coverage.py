#!/usr/bin/env python3
"""Account for protected Swift sources using SwiftPM's evaluated target description.

This checks source inclusion, not behavioral parity. Generator and protected-tree checks
remain separate. Run inside the SDK after `swift package describe --type json`.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def tracked_swift(directory: str) -> set[str]:
    output = subprocess.run(["git", "ls-files", "-z", "--", directory], cwd=ROOT,
                            check=True, capture_output=True).stdout
    return {path.decode() for path in output.split(b"\0") if path.endswith(b".swift")}


def audit(description: dict, parity: dict) -> tuple[list[str], dict]:
    errors: list[str] = []
    targets = {target["name"]: target for target in description["targets"]}

    def sources(name: str) -> set[str]:
        target = targets.get(name)
        if target is None:
            errors.append(f"missing evaluated target: {name}")
            return set()
        paths = []
        for source in target["sources"]:
            path = (ROOT / target["path"] / source).resolve()
            if not path.is_file():
                errors.append(f"{name}: missing source: {source}")
            try:
                paths.append(path.relative_to(ROOT).as_posix())
            except ValueError:
                errors.append(f"{name}: source outside repository: {source}")
        for path, count in Counter(paths).items():
            if count > 1:
                errors.append(f"{name}: duplicate resolved source: {path}")
        return set(paths)

    compiled = sources("Compositor")
    originals = tracked_swift("Compositor")
    mapped: dict[str, list[tuple[str, str]]] = {}
    drift = parity["drift"]
    for replacement, spec in drift.items():
        if replacement not in compiled:
            errors.append(f"declared override not compiled: {replacement}")
        mode = spec["mode"]
        if mode not in {"tip", "generated", "pinned", "replaced", "addition"}:
            errors.append(f"unclassified override mode: {replacement}: {mode}")
        if not spec.get("reason"):
            errors.append(f"override has no reason: {replacement}")
        if mode == "addition" and spec["upstream"]:
            errors.append(f"Linux addition has upstream counterparts: {replacement}")
        if mode != "addition" and not spec["upstream"]:
            errors.append(f"override has no upstream counterpart: {replacement}")
        for original in spec["upstream"]:
            if original not in originals:
                errors.append(f"unknown upstream Swift counterpart: {original}")
            if replacement in compiled:
                mapped.setdefault(original, []).append((replacement, mode))
    for path in sorted(compiled):
        if path.startswith("Sources/Overrides/") and path not in drift:
            errors.append(f"compiled override has no declaration: {path}")

    substitutions = parity.get("platform_substitutions", {})
    for original, reason in substitutions.items():
        if original not in originals or not reason:
            errors.append(f"invalid platform substitution: {original}")
    rows = []
    for original in sorted(originals):
        choices = []
        if original in compiled:
            choices.append((original, "unchanged"))
        choices.extend(mapped.get(original, []))
        if original in substitutions:
            choices.append((substitutions[original], "platform"))
        if len(choices) != 1:
            errors.append(f"{original}: expected one implementation, found {len(choices)}")
        else:
            implementation, mode = choices[0]
            rows.append({"upstream": original, "implementation": implementation, "mode": mode})

    tests = tracked_swift("CompositorTests")
    test_sources = sources("CompositorUpstreamTests")
    linux_tests = sources("LinuxOverrideTests")
    mirrors = parity.get("test_mirrors", {})
    for original, mirror in mirrors.items():
        if original not in tests or mirror not in linux_tests:
            errors.append(f"missing declared test mirror: {original}: {mirror}")
    for original in sorted(tests):
        count = int(original in test_sources) + int(original in mirrors and mirrors[original] in linux_tests)
        if count != 1:
            errors.append(f"{original}: expected one test implementation, found {count}")
    report = {"sources": rows, "counts": dict(Counter(row["mode"] for row in rows)),
              "upstream_tests": len(tests), "unchanged_tests": len(tests & test_sources),
              "test_mirrors": mirrors, "errors": errors}
    return errors, report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-description", type=Path, required=True)
    parser.add_argument("--parity-manifest", type=Path, default=ROOT / "linux/upstream-parity.json")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    errors, report = audit(json.loads(args.package_description.read_text()),
                           json.loads(args.parity_manifest.read_text()))
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        print(f"SOURCE COVERAGE FAILED: {len(errors)} findings", file=sys.stderr)
        return 1
    print(f"SOURCE COVERAGE OK: {len(report['sources'])} upstream Swift files {report['counts']}; "
          f"{report['unchanged_tests']} unchanged test files and {len(report['test_mirrors'])} selector mirror")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
