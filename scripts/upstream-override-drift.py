#!/usr/bin/env python3
"""Upstream changes a hand-kept override has not taken.

A hand override (`Sources/Overrides/X.swift` kept in step with tip by hand) silently falls behind when upstream changes
the file it replaces: the protected-tree gate stays clean because the upstream copy is untouched. For each override
listed under "drift" in linux/upstream-parity.json this compares the upstream changes in ledger_base..ledger_to with
the override and reports, per upstream hunk:

  * added code lines the override does not contain (the port was missed), and
  * removed code lines the override still contains (upstream deleted them; the override kept them).

Lines compare after collapsing whitespace. Comments and lines shorter than 12 characters are ignored.

"drift" entries: {"<override path>": {"mode": "tip|generated|pinned|replaced|addition", "upstream": ["Compositor/..."],
                  "allow": [{"line": "<normalized line>", "reason": "...", "commit": "<sha>"}], "reason": "..."}}
  tip       — must follow tip: every finding fails unless allowlisted
  generated — written from tip by a generator script ("generator"), whose --check is the gate; skipped here
  pinned    — deliberately held at an older upstream version (reason required); skipped
  replaced  — a different implementation (AppKit/Metal stand-in); skipped, reason required
  addition  — Linux-only file with no upstream counterpart; reason required

Every Swift file in Sources/Overrides needs an entry, so a new override can't go unwatched.

  scripts/upstream-override-drift.py [--from SHA --to SHA] [--check]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def norm(line: str) -> str:
    return re.sub(r"\s+", " ", line).strip()


def significant(line: str) -> bool:
    return len(line) >= 12 and not line.startswith(("//", "///", "/*", "*"))


def hunks(base: str, to: str, path: str) -> list[tuple[str, list[str], list[str]]]:
    # The net change over the range, not each commit's: intermediate states a later commit replaced don't count.
    out = subprocess.run(["git", "diff", base, to, "--", path], cwd=ROOT, check=True, capture_output=True, text=True).stdout
    result, sha, added, removed = [], f"{base}..{to}", [], []
    for raw in out.splitlines():
        if raw.startswith("@@"):
            if added or removed:
                result.append((sha, added, removed))
            added, removed = [], []
        elif raw.startswith("+") and not raw.startswith("+++"):
            added.append(norm(raw[1:]))
        elif raw.startswith("-") and not raw.startswith("---"):
            removed.append(norm(raw[1:]))
    if added or removed:
        result.append((sha, added, removed))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--from", dest="base")
    parser.add_argument("--to")
    parser.add_argument("--check", action="store_true", help="exit 1 on any non-allowlisted finding")
    args = parser.parse_args()
    parity = json.loads((ROOT / "linux/upstream-parity.json").read_text())
    base = args.base or parity.get("ledger_base")
    to = args.to or parity.get("ledger_to") or parity["upstream_ref"]
    drift = parity.get("drift", {})
    if not base or not drift:
        print("upstream-override-drift: need ledger_base and a \"drift\" map in linux/upstream-parity.json", file=sys.stderr)
        return 2
    print(f"override drift over {base}..{to}", file=sys.stderr)
    failures = 0
    for path in sorted((ROOT / "Sources/Overrides").glob("*.swift")):
        if str(path.relative_to(ROOT)) not in drift:
            print(f"{path.relative_to(ROOT)}: no \"drift\" entry in linux/upstream-parity.json", file=sys.stderr); failures += 1
    for override, spec in sorted(drift.items()):
        mode = spec.get("mode")
        if not (ROOT / override).exists():
            print(f"{override}: listed under \"drift\" but missing", file=sys.stderr); failures += 1
            continue
        if mode == "generated":
            if not spec.get("generator") or not (ROOT / spec["generator"]).exists():
                print(f"{override}: mode generated needs an existing \"generator\"", file=sys.stderr); failures += 1
            continue
        if mode in ("pinned", "replaced", "addition"):
            if not spec.get("reason"):
                print(f"{override}: mode {mode} needs a reason", file=sys.stderr); failures += 1
            continue
        if mode != "tip":
            print(f"{override}: unknown mode {mode!r} (tip|generated|pinned|replaced|addition)", file=sys.stderr); failures += 1
            continue
        body = {norm(l) for l in (ROOT / override).read_text().splitlines()}
        allowed = {norm(a["line"]) for a in spec.get("allow", [])}
        used = set()
        for upstream in spec.get("upstream", []):
            for sha, added, removed in hunks(base, to, upstream):
                still_removed = set(removed) - set(added)
                for line in added:
                    if significant(line) and line not in body:
                        if line in allowed: used.add(line); continue
                        failures += 1
                        print(f"MISSING  {override} ← {upstream}@{sha}: {line}")
                for line in still_removed:
                    if significant(line) and line in body:
                        if line in allowed: used.add(line); continue
                        failures += 1
                        print(f"STALE    {override} ← {upstream}@{sha} removed: {line}")
        for line in sorted(allowed - used):
            print(f"note: {override}: allowlist entry no longer needed: {line}", file=sys.stderr)
    if failures:
        print(f"\n{failures} drift finding(s). Port each into the override, or allowlist it in linux/upstream-parity.json:\n"
              '  "allow": [{"line": "<the line>", "reason": "<why Linux differs>", "commit": "<sha>"}]', file=sys.stderr)
        return 1 if args.check else 0
    print("OVERRIDE DRIFT CLEAN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
