#!/usr/bin/env python3
"""Create the signed-repository install descriptors and the GitHub Pages site."""
import argparse
import base64
import html
import json
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def prepare(output: Path, tag: str):
    config = json.loads((ROOT / "flatpak/release.json").read_text())
    version = config["version"]
    if tag != "linux-v" + version:
        raise ValueError("Release tag must match flatpak/release.json: linux-v" + version)
    if not re.fullmatch(r"[0-9A-Za-z.-]+", version) or config["channel"] != "alpha":
        raise ValueError("Invalid alpha release configuration")
    metadata = ET.parse(ROOT / "flatpak/com.compositor.Client.metainfo.xml")
    if metadata.find("releases/release").get("version") != version:
        raise ValueError("AppStream's newest release must match the release version")
    key = (ROOT / "flatpak/release-key.gpg").read_bytes()
    fingerprint = (ROOT / "flatpak/release-key.fingerprint").read_text().strip()
    if not key or not re.fullmatch(r"[A-F0-9]{40}", fingerprint):
        raise ValueError("Missing release signing key or invalid fingerprint")
    encoded = base64.b64encode(key).decode("ascii")
    url = config["site_url"].rstrip("/")
    release_url = f'https://github.com/{config["repository"]}/releases/tag/{tag}'
    bundle_url = f'https://github.com/{config["repository"]}/releases/download/{tag}/com.compositor.Client.flatpak'
    output.mkdir(parents=True, exist_ok=True)
    (output / "com.compositor.Client.flatpakref").write_text(
        f'[Flatpak Ref]\nName={config["app_id"]}\nBranch={config["channel"]}\n'
        f'Title=Compositor for Linux (Alpha)\nUrl={url}/repo\n'
        f'SuggestRemoteName=compositor-alpha\nIsRuntime=false\n'
        f'RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo\nGPGKey={encoded}\n')
    (output / "compositor.flatpakrepo").write_text(
        f'[Flatpak Repo]\nTitle=Compositor Alpha\nUrl={url}/repo\n'
        f'Homepage={url}/\nComment=Compositor Linux alpha releases\n'
        f'Description=Signed Flatpak updates for Compositor\nGPGKey={encoded}\n')
    replacements = {"VERSION": version, "REPOSITORY": config["repository"], "SITE_URL": url,
                    "RELEASE_URL": release_url, "BUNDLE_URL": bundle_url, "FINGERPRINT": fingerprint}
    page = (ROOT / "site/index.html").read_text()
    for name, value in replacements.items():
        page = page.replace("@" + name + "@", html.escape(value, quote=True))
    if re.search(r"@[A-Z_]+@", page):
        raise ValueError("Unresolved website template value")
    (output / "index.html").write_text(page)
    (output / ".nojekyll").touch()
    shutil.copyfile(ROOT / "flatpak/release-key.gpg", output / "release-key.gpg")
    shutil.copyfile(ROOT / "Compositor/Assets.xcassets/AppIcon.appiconset/app-icon-128.png", output / "icon.png")
    (output / "release.json").write_text(json.dumps(dict(config, tag=tag, release_url=release_url), indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    prepare(args.output, args.tag)
