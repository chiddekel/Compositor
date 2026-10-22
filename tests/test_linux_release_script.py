#!/usr/bin/env python3
"""Exercise release planning and pushes using disposable local Git repositories."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("linux_release", ROOT / "scripts/release-linux.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "work"
        self.root.mkdir()
        self.remote = Path(self.temp.name) / "remote.git"
        subprocess.run(["git", "init", "--bare", "--quiet", str(self.remote)], check=True)
        self.call("init", "--quiet", "-b", "GNU_Linux")
        self.call("config", "user.name", "Release test")
        self.call("config", "user.email", "release@example.invalid")
        self.call("config", "commit.gpgsign", "false")
        self.call("config", "tag.gpgsign", "false")
        self.call("remote", "add", "origin", str(self.remote))
        (self.root / "flatpak").mkdir()
        config = dict(version="1.4.10-linux-alpha.9", channel="alpha", repository="example/Compositor")
        (self.root / release.FILES[0]).write_text(json.dumps(config) + "\n")
        (self.root / release.FILES[1]).write_text(
            '<component><releases>\n    <release version="1.4.10-linux-alpha.9" '
            'date="2026-10-01" type="development"><description><p>Old</p></description>'
            '</release>\n</releases></component>\n')
        (self.root / release.FILES[2]).write_text("Compositor 1.4.10-linux-alpha.9\n")
        # Fixture checks validate the same metadata boundary without a signing key.
        (self.root / "scripts").mkdir()
        (self.root / "tests").mkdir()
        checker = (
            "import json, pathlib, xml.etree.ElementTree as ET\n"
            "p = pathlib.Path('.')\n"
            "v = json.loads((p/'flatpak/release.json').read_text())['version']\n"
            "assert ET.parse(p/'flatpak/com.compositor.Client.metainfo.xml').find('releases/release').get('version') == v\n"
            "assert v in (p/'flatpak/RELEASE_NOTES.md').read_text()\n")
        (self.root / "scripts/prepare-flatpak-release.py").write_text(checker)
        (self.root / "tests/test_flatpak_release.py").write_text(checker)
        self.commit("Initial release")
        self.old_tag = "linux-v1.4.10-linux-alpha.9"
        self.call("tag", self.old_tag)
        self.call("push", "--quiet", "origin", "GNU_Linux", self.old_tag)
        self.addCleanup(patch.stopall)
        patch.object(release, "ROOT", self.root).start()

    def call(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True,
                                       stderr=subprocess.PIPE).strip()

    def commit(self, subject):
        self.call("add", ".")
        self.call("commit", "--quiet", "-m", subject)

    def change(self):
        (self.root / "linux.txt").write_text("Linux change\n")
        self.commit("Fix Linux <canvas> & mask")

    def publishing_mocks(self):
        original_git, original_run = release.git, release.run

        def git(*args):
            if args[:2] == ("remote", "get-url"):
                return "https://github.com/example/Compositor.git"
            return original_git(*args)

        def run(*args, **kwargs):
            if args[0] == "gh":
                self.assertEqual(args, ("gh", "auth", "status", "--hostname", "github.com"))
                return ""
            return original_run(*args, **kwargs)

        patch.object(release, "git", side_effect=git).start()
        patch.object(release, "run", side_effect=run).start()

    def test_unchanged_tag_is_reused(self):
        config, previous, version, changes = release.plan()
        self.assertEqual(previous, self.old_tag)
        self.assertEqual(version, config["version"])
        self.assertEqual(changes, [])

    def test_bump_numeric_alpha_and_preserve_appstream_history(self):
        self.change()
        config, previous, version, changes = release.plan()
        self.assertEqual(version, "1.4.10-linux-alpha.10")
        self.assertEqual(changes, ["linux.txt"])
        release.prepare(config, previous, version)
        releases = ET.parse(self.root / release.FILES[1]).find("releases")
        self.assertEqual(len(releases), 2)
        self.assertEqual(releases[0].get("version"), version)
        self.assertIn("<canvas> & mask", releases[0].find("description/p").text)
        self.assertEqual(releases[1].get("version"), config["version"])
        self.assertEqual(set(self.call("diff", "--name-only").splitlines()), set(release.FILES))

    def test_prepared_version_is_not_incremented_again(self):
        self.change()
        config, previous, version, _ = release.plan()
        release.prepare(config, previous, version)
        self.commit("Prepare curated release")
        self.assertEqual(release.plan()[2], version)

    def test_empty_commit_does_not_need_bump(self):
        self.call("commit", "--quiet", "--allow-empty", "-m", "No tree change")
        self.assertIsNone(release.plan()[2])

    def test_dirty_publish_refused_before_network(self):
        (self.root / "untracked.txt").write_text("work")
        with patch.object(release, "run", wraps=release.run) as runner:
            with self.assertRaisesRegex(ValueError, "Commit or stash"):
                release.publish("origin")
            self.assertFalse(any(call.args[0] == "gh" for call in runner.call_args_list))

    def test_wrong_branch_refused(self):
        self.call("switch", "--quiet", "-c", "main")
        with self.assertRaisesRegex(ValueError, "GNU_Linux"):
            release.plan()

    def test_wrong_remote_refused(self):
        with self.assertRaisesRegex(ValueError, "Remote URLs"):
            release.publish("origin")

    def test_invalid_metadata_does_not_write_other_files(self):
        self.change()
        config, previous, version, _ = release.plan()
        path = self.root / release.FILES[1]
        path.write_text(path.read_text().replace(config["version"], "wrong"))
        before = [(self.root / filename).read_bytes() for filename in release.FILES]
        with self.assertRaisesRegex(ValueError, "AppStream"):
            release.prepare(config, previous, version)
        self.assertEqual(before, [(self.root / filename).read_bytes() for filename in release.FILES])

    def test_foreign_tag_is_not_moved(self):
        self.change()
        next_tag = "linux-v1.4.10-linux-alpha.10"
        self.call("tag", next_tag, self.old_tag)
        with self.assertRaisesRegex(ValueError, "older"):
            release.plan()
        self.assertEqual(self.call("rev-parse", next_tag), self.call("rev-parse", self.old_tag))

    def test_publish_and_second_run_are_idempotent(self):
        self.change()
        self.publishing_mocks()
        release.publish("origin")
        tag = "linux-v1.4.10-linux-alpha.10"
        head = self.call("rev-parse", "HEAD")
        self.assertEqual(self.call("rev-parse", tag + "^{commit}"), head)
        self.assertEqual(self.call("cat-file", "-t", tag), "tag")
        self.assertEqual(self.call("status", "--porcelain"), "")
        self.assertIn(head, self.call("ls-remote", "origin", "refs/heads/GNU_Linux"))
        self.assertIn(head, self.call("ls-remote", "origin", "refs/tags/" + tag + "^{}"))
        release.publish("origin")
        self.assertEqual(self.call("rev-parse", "HEAD"), head)

    def test_failed_atomic_push_can_retry_existing_local_tag(self):
        self.change()
        self.publishing_mocks()
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            release.publish("origin")
        tag = "linux-v1.4.10-linux-alpha.10"
        head = self.call("rev-parse", "HEAD")
        self.assertEqual(self.call("rev-parse", tag + "^{commit}"), head)
        self.assertNotIn(head, self.call("ls-remote", "origin", "refs/heads/GNU_Linux"))
        hook.write_text("#!/bin/sh\nexit 0\n")
        release.publish("origin")
        self.assertEqual(self.call("rev-parse", "HEAD"), head)
        self.assertIn(head, self.call("ls-remote", "origin", "refs/tags/" + tag + "^{}"))

    def test_remote_tag_on_other_commit_is_refused(self):
        self.change()
        self.call("tag", "linux-v1.4.10-linux-alpha.10", self.old_tag)
        self.call("push", "--quiet", "origin", "linux-v1.4.10-linux-alpha.10")
        self.call("tag", "-d", "linux-v1.4.10-linux-alpha.10")
        self.publishing_mocks()
        head = self.call("rev-parse", "HEAD")
        with self.assertRaisesRegex(ValueError, "older"):
            release.publish("origin")
        self.assertEqual(self.call("rev-parse", "HEAD"), head)
        self.assertEqual(self.call("status", "--porcelain"), "")

    def test_remote_branch_ahead_is_refused_before_preparing(self):
        self.change()
        self.call("push", "--quiet", "origin", "GNU_Linux")
        # Construct a behind checkout without resetting or discarding files.
        self.call("switch", "--quiet", "--detach", self.old_tag)
        self.call("branch", "-m", "GNU_Linux", "saved-work")
        self.call("switch", "--quiet", "-c", "GNU_Linux")
        self.publishing_mocks()
        head = self.call("rev-parse", "HEAD")
        with self.assertRaises(subprocess.CalledProcessError):
            release.publish("origin")
        self.assertEqual(self.call("rev-parse", "HEAD"), head)
        self.assertEqual(self.call("status", "--porcelain"), "")

    def test_ci_marks_latest_only_after_pages_deployment(self):
        workflow = (ROOT / ".github/workflows/flatpak-release.yml").read_text()
        self.assertLess(workflow.index("actions/deploy-pages@"), workflow.index("--latest"))
        self.assertIn("--draft=false --prerelease=false --latest", workflow)
        self.assertIn("releases/latest", workflow)


if __name__ == "__main__":
    unittest.main()
