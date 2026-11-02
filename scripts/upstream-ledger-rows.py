#!/usr/bin/env python3
"""Per-commit upstream catch-up ledger rows: one row per non-merge upstream commit in a range.

For each commit the generated columns are its subject and, for every Swift file it touches, how the Linux build
consumes that file (compiled as-is / generated override / hand override / Qt adapter / original or mirrored test /
platform-only test). Test and smoke references are checked for existence, not treated as proof of a successful run.
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
def generated_overrides() -> set[str]:
    """Upstream files whose override a generator writes (its --check is the gate): the parity file's drift entries."""
    parity = json.loads((ROOT / "linux/upstream-parity.json").read_text())
    return {up for entry in parity["drift"].values() if entry.get("mode") == "generated" for up in entry["upstream"]}


GENERATORS = generated_overrides()


def excluded_test_files() -> set[str]:
    package = (ROOT / "Package.swift").read_text()
    start = package.index('name: "CompositorUpstreamTests"')
    end = package.index('.testTarget(', start)
    target = package[start:end]
    match = re.search(r'exclude:\s*\[([^]]*)\]', target)
    return set(re.findall(r'"([^"]+)"', match.group(1))) if match else set()


EXCLUDED_TESTS = excluded_test_files()


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def consumption(path: str, overrides: dict[str, str]) -> str:
    name = Path(path).stem
    if not (ROOT / path).exists():
        return "removed upstream"
    if path == "Compositor/Compositor-Bridging-Header.h":
        return "platform-only header (Xcode)"
    if path.startswith("CompositorUITests/"):
        return "platform-only test (macOS)"
    if path.startswith("CompositorTests/"):
        mirror = ROOT / f"Tests/LinuxOverrideTests/{name}.swift"
        generated = mirror.is_file() and mirror.read_text().startswith("// GENERATED")
        if Path(path).name in EXCLUDED_TESTS:
            return "generated test mirror" if generated else "excluded test"
        return "test + generated mirror" if generated else "test"
    if path in GENERATORS:
        return "generated override"
    if path in overrides:
        value = overrides[path]
        if value.startswith("excluded"):
            return "excluded (adapter)"
        return "hand override" if value.startswith("Sources/Overrides/") else "Qt adapter"
    return "compiled as-is"


def rows(base: str, to: str, include_kernels: bool = False) -> list[dict]:
    parity = json.loads((ROOT / "linux/upstream-parity.json").read_text())
    out = []
    log = git("log", "--reverse", "--no-merges", "--format=%h%x00%s", f"{base}..{to}")
    for line in filter(None, log.splitlines()):
        sha, subject = line.split("\x00", 1)
        files = [f for f in git("show", "--name-only", "--format=", sha).splitlines() if f.endswith(".swift") or (include_kernels and f.endswith((".c", ".h")))]
        kinds = [(f, consumption(f, parity["overrides"])) for f in files]
        code = any(f.startswith("Compositor/") for f in files)
        out.append({"sha": sha, "subject": subject, "files": kinds, "code": code,
                    "class": "code" if code else ("test-only" if files else "docs")})
    return out


def cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def evidence_scope(evidence: str) -> str:
    scopes = []
    if "test:" in evidence:
        scopes.append("test reference; run result required")
    if "smoke:" in evidence:
        scopes.append("journey reference; run result required")
    if "screenshot" in evidence:
        scopes.append("screenshot claim; artifact required")
    if "manual" in evidence:
        scopes.append("manual claim; verification required")
    if "compiled as-is" in evidence or "drift check" in evidence or "generator" in evidence:
        scopes.append("source/generation only")
    return "; ".join(scopes) or ("not applicable" if evidence.startswith("n/a") else "unverified")


def evidence_errors(kept: dict[str, tuple[str, str]]) -> list[str]:
    errors = []
    bootstrap = (ROOT / "Sources/CompositorHostBootstrap/hostMain.swift").read_text()
    for sha, (_, evidence) in kept.items():
        for suite, method in re.findall(r'\btest:([A-Za-z_][\w]*)(?:\.([A-Za-z_][\w]*))?', evidence):
            candidates = [p for scope in ("CompositorTests", "Tests") for p in (ROOT / scope).rglob(f"{suite}.swift")]
            sources = [p.read_text() for p in candidates]
            if not any(re.search(rf'\b(?:struct|class)\s+{re.escape(suite)}\b', s) for s in sources):
                errors.append(f"{sha}: missing test suite {suite}")
            elif method and not any(re.search(rf'\bfunc\s+{re.escape(method)}\s*\(', s) for s in sources):
                errors.append(f"{sha}: missing test method {suite}.{method}")
        for flag, anchor in re.findall(r'\bsmoke:(--[\w-]+)(?:#([\w.-]+))?', evidence):
            if f'"{flag}"' not in bootstrap:
                errors.append(f"{sha}: missing smoke option {flag}")
                continue
            if anchor:
                route = re.search(rf'contains\("{re.escape(flag)}"\)\s*\{{\s*let result = (compositor_host_\w+)\(', bootstrap)
                bodies = []
                if route:
                    for source in (ROOT / "host").glob("*.cpp"):
                        text = source.read_text()
                        start = re.search(rf'extern\s+"C"\s+int\s+{re.escape(route.group(1))}\s*\(', text)
                        if start:
                            body = text[start.end():]
                            bodies.append(re.split(r'\nextern\s+"C"', body, maxsplit=1)[0])
                if not any(anchor.lower() in body.lower() for body in bodies):
                    errors.append(f"{sha}: missing smoke anchor {flag}#{anchor}")
    return errors


def table(entries: list[dict], kept: dict[str, tuple[str, str]], include_kernels: bool = False) -> str:
    code = [e for e in entries if e["code"]]
    rest = [e for e in entries if not e["code"]]
    rule = "changes a Compositor Swift/C/header file" if include_kernels else "changes a `Compositor/**/*.swift` file outside `CompositorTests/`"
    lines = [f"Code commits: **{len(code)}** of {len(entries)} (rule: {rule}). Docs/meta: {sum(e['class'] == 'docs' for e in rest)}; "
             f"test-only: {sum(e['class'] == 'test-only' for e in rest)}.", "",
             "| # | Upstream | Subject | Files (consumption) | Evidence scope | Linux artifact | Evidence |",
             "|---|---|---|---|---|---|---|"]
    for number, e in enumerate(code + rest, 1):
        label = str(number) if e["code"] else "—"
        files = "<br>".join(f"`{Path(f).name}` ({k})" for f, k in e["files"]) or "none"
        default = ("n/a (docs)", "n/a (docs)") if e["class"] == "docs" else \
                  ("n/a (test-only; see consumption)", "n/a (test-only)") if e["class"] == "test-only" else ("TODO", "TODO")
        artifact, evidence = kept.get(e["sha"], default)
        if artifact == "n/a (test-only, compiled as-is)":
            artifact = default[0]
        lines.append(f"| {label} | `{e['sha']}` | {cell(e['subject'])} | {files} | {evidence_scope(evidence)} | {artifact} | {evidence} |")
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
    parser.add_argument("--include-kernels", action="store_true", help="Account for C-only kernel commits and headers")
    args = parser.parse_args()
    parity = json.loads((ROOT / "linux/upstream-parity.json").read_text())
    base = args.base or parity.get("ledger_base")
    to = args.to or parity.get("ledger_to") or parity["upstream_ref"]
    if not base:
        print("no range: set ledger_base in linux/upstream-parity.json or pass --from", file=sys.stderr)
        return 2
    print(f"range {base}..{to}", file=sys.stderr)
    entries = rows(base, to, args.include_kernels)
    target = args.write or args.check
    doc = (ROOT / target).read_text() if target else ""
    rendered = table(entries, kept_cells(doc), args.include_kernels)
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
    errors = evidence_errors(kept_cells(rendered))
    if errors:
        print(f"{target}: invalid evidence references:", *errors, sep="\n  ", file=sys.stderr)
        return 1
    print(f"LEDGER OK: {len(entries)} commits, {sum(e['code'] for e in entries)} code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
