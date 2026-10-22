#!/usr/bin/env python3
"""Compat SwiftUI API that accepts a call and does nothing (`{ self }`), against upstream's uses of it.

Every use upstream's tree makes of such an overload must be listed, with the reason it's harmless, in
linux/compat-noop-allow.json. A merge that adds a use (or a compat change that turns an implemented overload into a
no-op) fails here instead of silently losing behaviour. A listed use upstream no longer makes fails too, so the list
stays true.

  scripts/check-compat-noops.py          check
  scripts/check-compat-noops.py --list   print every no-op overload and its current upstream uses
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPAT = ROOT / "Sources/Compat/SwiftUI"
UPSTREAM = ROOT / "Compositor"
ALLOW = ROOT / "linux/compat-noop-allow.json"

# A modifier: returns a view (or ForEach). Its body is exactly `{ self }` when it does nothing.
FUNC = re.compile(r"public func (\w+)(?:<[^>]*>)?\((.*?)\)\s*->\s*(some View|ForEach)\s*\{(\s*self\s*\})?", re.S)


def overloads():
    """name -> (no-op first-argument types, implemented first-argument types)."""
    noop, implemented = {}, {}
    for path in sorted(COMPAT.glob("*.swift")):
        text = path.read_text()
        for match in FUNC.finditer(text):
            name, params, body = match.group(1), match.group(2), match.group(4)
            first = params.split(",")[0]
            kind = first.split(":", 1)[1].strip() if ":" in first else ""
            kind = re.sub(r"[?<].*", "", kind).strip()
            (noop if body is not None else implemented).setdefault(name, set()).add(kind)
    return {name: (kinds, implemented.get(name, set())) for name, kinds in noop.items()}


def uses(name, implemented):
    """Upstream lines calling `.name(` whose argument isn't one of the implemented overloads' types."""
    found = []
    for path in sorted(UPSTREAM.rglob("*.swift")):
        for line in path.read_text().splitlines():
            for match in re.finditer(r"\." + name + r"\(\s*([A-Za-z_]*)", line):
                argument = match.group(1)
                if argument and argument in implemented:
                    continue
                found.append(f"{path.relative_to(ROOT)}: {line.strip()}")
    return sorted(set(found))


def main():
    table = overloads()
    current = {name: uses(name, kinds[1] - kinds[0]) for name, kinds in table.items()}
    if "--list" in sys.argv:
        for name, lines in sorted(current.items()):
            print(f"{name}: {len(lines)} use(s)")
            for line in lines:
                print(f"  {line}")
        return 0
    allow = json.loads(ALLOW.read_text())
    problems = []
    for name, lines in sorted(current.items()):
        listed = allow.get(name, {})
        if lines and not listed.get("reason"):
            problems.append(f"{name}: no-op in compat, used upstream, and no reason given in {ALLOW.relative_to(ROOT)}")
        for line in lines:
            if line not in listed.get("uses", []):
                problems.append(f"{name}: unlisted upstream use (does nothing on Linux): {line}")
        for line in listed.get("uses", []):
            if line not in lines:
                problems.append(f"{name}: listed use no longer found (update the list): {line}")
    for name in sorted(set(allow) - set(current)):
        if allow[name].get("uses"):
            problems.append(f"{name}: listed, but compat no longer has a no-op overload of it (drop the entry)")
    if problems:
        print("COMPAT NO-OP AUDIT FAILED")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(f"COMPAT NO-OP AUDIT OK: {len(current)} no-op overloads, "
          f"{sum(map(len, current.values()))} upstream uses, each with a recorded reason")
    return 0


if __name__ == "__main__":
    sys.exit(main())
