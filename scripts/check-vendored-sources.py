#!/usr/bin/env python3
"""Verify the checked-in Linux dependency archives without network access."""
import ast
import hashlib
import json
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    inventory = json.loads((ROOT / "third_party/sources/inventory.json").read_text())
    manifest = (ROOT / "com.compositor.Client.yaml").read_text()
    assert not re.search(r"^\s+url:", manifest, re.MULTILINE), "Manifest still fetches sources"
    manifest_sources = re.findall(
        r"- type: archive\n\s+path: ([^\n]+)\n\s+sha256: ([a-f0-9]{64})", manifest
    )
    expected = {source["path"]: source["sha256"] for source in inventory["sources"]}
    assert dict(manifest_sources) == expected, "Manifest and source inventory disagree"
    assert "git-sync-deps" not in manifest, "Skia still fetches dependencies"
    skia = next(source for source in inventory["sources"] if source["name"] == "skia")
    with tarfile.open(ROOT / skia["path"]) as archive:
        deps_file = next(member for member in archive.getmembers() if member.name.endswith("/DEPS"))
        tree = ast.parse(archive.extractfile(deps_file).read())
        deps = next(
            node.value for node in tree.body if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "deps" for target in node.targets)
        )
        pinned = {
            key.value: value.value for key, value in zip(deps.keys, deps.values)
            if isinstance(key, ast.Constant) and isinstance(value, ast.Constant)
            and isinstance(value.value, str)
        }
        fetch_gn = next(member for member in archive.getmembers() if member.name.endswith("/bin/fetch-gn"))
        gn_script = archive.extractfile(fetch_gn).read().decode()
    total = 0
    for source in inventory["sources"]:
        if source["name"].startswith("skia-"):
            assert pinned[source["dest"]] == source["url"] + "@" + source["revision"], source["name"]
        if source["name"] == "gn":
            assert "rev = '" + source["revision"] + "'" in gn_script, "GN revision differs from Skia"
        path = ROOT / source["path"]
        content = path.read_bytes()
        assert hashlib.sha256(content).hexdigest() == source["sha256"], source["name"]
        assert len(content) < 100 * 1024**2, f"GitHub file limit: {path}"
        with tarfile.open(path) as archive:
            members = {member.name: member for member in archive.getmembers()}
            assert not any(".git" in Path(name).parts for name in members), path
            assert source["licenses"], f"Missing license inventory: {path}"
            assert {copy["member"] for copy in source["license_copies"]} == set(source["licenses"]), path
            for license_path in source["licenses"]:
                assert members[license_path].isfile(), license_path
            for copy in source["license_copies"]:
                original = archive.extractfile(members[copy["member"]]).read()
                assert (ROOT / copy["path"]).read_bytes() == original, copy["path"]
        total += len(content)
        print(f"PASS {source['name']}: checksum and license notices")
    print(f"Verified {len(inventory['sources'])} archives, {total / 1024**2:.1f} MiB; no network used.")


if __name__ == "__main__":
    main()
