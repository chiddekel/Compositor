import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("upstream_content", ROOT / "scripts/check-upstream-content.py")
content = importlib.util.module_from_spec(spec)
spec.loader.exec_module(content)


class UpstreamContentTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="compositor-upstream-content-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q")
        (self.root / "Compositor").mkdir()
        (self.root / "Compositor/App.swift").write_text("original\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Initial")
        self.original = self.git("rev-parse", "HEAD").strip()
        (self.root / "Compositor/New.swift").write_text("upstream addition\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Upstream addition")
        self.reference = self.git("rev-parse", "HEAD").strip()
        # Move only the index to the older tree: leave the synchronized upstream addition untracked.
        self.git("read-tree", self.original)

    def git(self, *args):
        return subprocess.check_output(["git", "-c", "user.name=Parity Test", "-c", "user.email=parity@example.invalid", *args],
                                       cwd=self.root, text=True, stderr=subprocess.PIPE)

    def test_unstaged_upstream_addition_matches(self):
        self.assertEqual(content.differences(self.root, self.reference), [])

    def test_modified_upstream_addition_fails(self):
        (self.root / "Compositor/New.swift").write_text("Linux edit\n")
        self.assertEqual(content.differences(self.root, self.reference), ["Compositor/New.swift"])

    def test_missing_upstream_source_fails(self):
        (self.root / "Compositor/App.swift").unlink()
        self.assertEqual(content.differences(self.root, self.reference), ["Compositor/App.swift"])

    def test_extra_protected_file_fails(self):
        (self.root / "Compositor/Linux.swift").write_text("extra\n")
        self.assertEqual(content.differences(self.root, self.reference), ["Compositor/Linux.swift"])

    def test_symlink_cannot_substitute_for_original(self):
        source = self.root / "Compositor/App.swift"
        (self.root / "copy.swift").write_bytes(source.read_bytes())
        source.unlink()
        source.symlink_to("../copy.swift")
        self.assertEqual(content.differences(self.root, self.reference), ["Compositor/App.swift"])

    def test_executable_mode_change_fails(self):
        (self.root / "Compositor/App.swift").chmod(0o755)
        self.assertEqual(content.differences(self.root, self.reference), ["Compositor/App.swift"])

    def test_protected_directory_symlink_fails(self):
        (self.root / "Compositor").rename(self.root / "copy")
        (self.root / "Compositor").symlink_to("copy", target_is_directory=True)
        self.assertEqual(content.differences(self.root, self.reference), ["Compositor"])


if __name__ == "__main__":
    unittest.main()
