#!/usr/bin/env python3
"""Check that installers, the website, and signing identity agree."""
import base64
import configparser
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/prepare-flatpak-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)
        self.config = json.loads((ROOT / "flatpak/release.json").read_text())
        self.tag = "linux-v" + self.config["version"]

    def test_signed_installers_and_page(self):
        release.prepare(self.output, self.tag)
        key = (ROOT / "flatpak/release-key.gpg").read_bytes()
        for filename, section in [("com.compositor.Client.flatpakref", "Flatpak Ref"),
                                  ("compositor.flatpakrepo", "Flatpak Repo")]:
            config = configparser.ConfigParser(interpolation=None)
            config.read(self.output / filename)
            self.assertEqual(base64.b64decode(config[section]["GPGKey"]), key)
            self.assertEqual(config[section]["Url"], self.config["site_url"] + "/repo")
        config.read(self.output / "com.compositor.Client.flatpakref")
        self.assertEqual(config["Flatpak Ref"]["Name"], "com.compositor.Client")
        self.assertEqual(config["Flatpak Ref"]["Branch"], "alpha")
        self.assertEqual(config["Flatpak Ref"]["IsRuntime"], "false")
        page = (self.output / "index.html").read_text()
        self.assertNotRegex(page, r"@[A-Z_]+@")
        self.assertIn("/releases/download/" + self.tag + "/com.compositor.Client.flatpak", page)
        self.assertIn((ROOT / "flatpak/release-key.fingerprint").read_text().strip(), page)
        self.assertTrue((self.output / "icon.png").is_file())
        self.assertTrue((self.output / ".nojekyll").exists())

    def test_wrong_tag_rejected_before_writing(self):
        with self.assertRaisesRegex(ValueError, "tag must match"):
            release.prepare(self.output, "linux-v0.0.0")
        self.assertEqual(list(self.output.iterdir()), [])

    def test_only_public_key_and_matching_fingerprint(self):
        listing = subprocess.check_output([
            "gpg", "--homedir", str(self.output), "--batch", "--with-colons", "--show-keys",
            str(ROOT / "flatpak/release-key.gpg")], text=True)
        records = [line.split(":") for line in listing.splitlines()]
        self.assertFalse(any(record[0] in ("sec", "ssb") for record in records))
        fingerprint = next(record[9] for record in records if record[0] == "fpr")
        self.assertEqual(fingerprint, (ROOT / "flatpak/release-key.fingerprint").read_text().strip())


if __name__ == "__main__":
    unittest.main()
