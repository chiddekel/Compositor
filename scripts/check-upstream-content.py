#!/usr/bin/env python3
"""Compare protected working-tree content with upstream, independently of staging state."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROTECTED = ("Compositor", "CompositorTests", "CompositorUITests", "Compositor.xcodeproj")


def differences(root: Path, reference: str) -> list[str]:
    def git(*args: str) -> bytes:
        return subprocess.check_output(["git", *args], cwd=root)

    expected = {}
    for record in git("ls-tree", "-rz", reference, "--", *PROTECTED).split(b"\0"):
        if record:
            metadata, path = record.split(b"\t", 1)
            mode, kind, object_id = metadata.split()
            expected[path.decode()] = (mode, kind, object_id.decode())
    actual = set()
    for directory in PROTECTED:
        path = root / directory
        if path.is_symlink():
            actual.add(directory)
        if path.is_dir():
            actual.update(file.relative_to(root).as_posix() for file in path.rglob("*") if file.is_file() or file.is_symlink())
    changed = actual.symmetric_difference(expected)
    for path in actual & expected.keys():
        mode, kind, object_id = expected[path]
        file = root / path
        if kind != b"blob" or file.is_symlink() != (mode == b"120000"):
            changed.add(path)
            continue
        if not file.is_symlink() and bool(file.stat().st_mode & 0o111) != (mode == b"100755"):
            changed.add(path)
        content = str(file.readlink()).encode() if file.is_symlink() else file.read_bytes()
        if content != git("cat-file", "blob", object_id):
            changed.add(path)
    return sorted(changed)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="upstream/main")
    args = parser.parse_args()
    changed = differences(ROOT, args.ref)
    if changed:
        print(f"UPSTREAM DRIFT: protected trees differ from {args.ref}", file=sys.stderr)
        print(*changed, sep="\n", file=sys.stderr)
        print("Move Linux-only changes behind compatibility code or host adapters.", file=sys.stderr)
        return 1
    print(f"UPSTREAM CONTENT CLEAN: protected files match {args.ref}, including unstaged upstream additions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
