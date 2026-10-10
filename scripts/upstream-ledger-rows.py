#!/usr/bin/env python3
"""Per-commit upstream catch-up ledger rows: one row per non-merge upstream commit in a range.

For each commit the generated columns are its subject and, for every Swift file it touches, how the Linux build
consumes that file (compiled as-is / generated override / hand override / Qt adapter / excluded test / test).
The hand-written columns (Linux artifact, evidence) are kept from the existing ledger table.

  scripts/upstream-ledger-rows.py                 # print the table for ledger_base..ledger_to (linux/upstream-parity.json)
  scripts/upstream-ledger-rows.py --write DOC     # replace the table between the ledger markers in DOC
  scripts/upstream-ledger-rows.py --check DOC     # generated columns in DOC match git; exits 1 on drift

A commit is "code" when it changes at least one Compositor/**/*.swift file outside CompositorTests/. Code commits are
numbered first; docs-only and test-only commits follow with generated n/a evidence.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BEGIN, END = "<!-- ledger-rows:begin -->", "<!-- ledger-rows:end -->"
GENERATORS = {  # overrides written by a generator script (their --check is the gate)
    "Compositor/CompositorApp.swift", "Compositor/Document/EditorSession.swift",
    "Compositor/Document/SmudgeLiquify.swift",
}


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def consumption(path: str, overrides: dict[str, str], exclusions: str) -> str:
    name = Path(path).stem
    if path.startswith("CompositorTests/"):
        return "excluded test" if f"`{name}.swift`" in exclusions else "test"
    if path in GENERATORS:
        return "generated override"
    if path in overrides:
        value = overrides[path]
        if value.startswith("excluded"):
            return "excluded (adapter)"
        return "hand override" if value.startswith("Sources/Overrides/") else "Qt adapter"
    return "compiled as-is"


def rows(base: str, to: str) -> list[dict]:
    parity = json.loads((ROOT / "linux/upstream-parity.json").read_text())
    exclusions = (ROOT / parity["excluded_upstream_tests"]).read_text()
    out = []
    log = git("log", "--reverse", "--no-merges", "--format=%h%x00%s", f"{base}..{to}")
    for line in filter(None, log.splitlines()):
        sha, subject = line.split("\x00", 1)
        files = [f for f in git("show", "--name-only", "--format=", sha).splitlines() if f.endswith(".swift")]
        kinds = [(f, consumption(f, parity["overrides"], exclusions)) for f in files]
        code = any(f.startswith("Compositor/") for f in files)
        out.append({"sha": sha, "subject": subject, "files": kinds, "code": code,
                    "class": "code" if code else ("test-only" if files else "docs")})
    return out


def cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def table(entries: list[dict], kept: dict[str, tuple[str, str]]) -> str:
    code = [e for e in entries if e["code"]]
    rest = [e for e in entries if not e["code"]]
    lines = [f"Code commits: **{len(code)}** of {len(entries)} (rule: changes a `Compositor/**/*.swift` file outside "
             f"`CompositorTests/`). Docs/meta: {sum(e['class'] == 'docs' for e in rest)}; "
             f"test-only: {sum(e['class'] == 'test-only' for e in rest)}.", "",
             "| # | Upstream | Subject | Files (consumption) | Linux artifact | Evidence |",
             "|---|---|---|---|---|---|"]
    for number, e in enumerate(code + rest, 1):
        label = str(number) if e["code"] else "—"
        files = "<br>".join(f"`{Path(f).name}` ({k})" for f, k in e["files"]) or "none"
        default = ("n/a (docs)", "n/a (docs)") if e["class"] == "docs" else \
                  ("n/a (test-only, compiled as-is)", "n/a (test-only)") if e["class"] == "test-only" else ("TODO", "TODO")
        artifact, evidence = kept.get(e["sha"], default)
        lines.append(f"| {label} | `{e['sha']}` | {cell(e['subject'])} | {files} | {artifact} | {evidence} |")
    return "\n".join(lines)


def kept_cells(doc: str) -> dict[str, tuple[str, str]]:
    found = {}
    for m in re.finditer(r"^\| [^|]* \| `([0-9a-f]{7,})` \|.*\| ([^|]*) \| ([^|]*) \|$", doc, re.M):
        found[m.group(1)] = (m.group(2).strip(), m.group(3).strip())
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--write", metavar="DOC")
    group.add_argument("--check", metavar="DOC")
    parser.add_argument("--from", dest="base")
    parser.add_argument("--to")
    args = parser.parse_args()
    parity = json.loads((ROOT / "linux/upstream-parity.json").read_text())
    base = args.base or parity.get("ledger_base")
    to = args.to or parity.get("ledger_to") or parity["upstream_ref"]
    if not base:
        print("no range: set ledger_base in linux/upstream-parity.json or pass --from", file=sys.stderr)
        return 2
    print(f"range {base}..{to}", file=sys.stderr)
    entries = rows(base, to)
    target = args.write or args.check
    doc = (ROOT / target).read_text() if target else ""
    rendered = table(entries, kept_cells(doc))
    if not target:
        print(rendered)
        return 0
    if BEGIN not in doc or END not in doc:
        print(f"{target}: missing {BEGIN} / {END} markers", file=sys.stderr)
        return 1
    head, rest = doc.split(BEGIN, 1)
    current, tail = rest.split(END, 1)
    if args.write:
        (ROOT / target).write_text(f"{head}{BEGIN}\n{rendered}\n{END}{tail}")
        return 0
    if current.strip() != rendered.strip():
        print(f"{target}: ledger rows differ from git ({base}..{to}); rerun with --write", file=sys.stderr)
        return 1
    todo = rendered.count("| TODO |")
    if todo:
        print(f"{target}: {todo} evidence cell(s) still TODO", file=sys.stderr)
        return 1
    print(f"LEDGER OK: {len(entries)} commits, {sum(e['code'] for e in entries)} code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
