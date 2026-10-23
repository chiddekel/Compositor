#!/usr/bin/env python3
"""Detect, prepare, and push Linux alpha releases; preview unless --publish is used."""
import argparse
from datetime import date
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
FILES = ("flatpak/release.json", "flatpak/com.compositor.Client.metainfo.xml",
         "flatpak/RELEASE_NOTES.md")
VERSION = re.compile(r"(\d+\.\d+\.\d+)-linux-alpha\.(\d+)")


def run(*args, capture=True):
    return subprocess.run(args, cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def git(*args):
    return run("git", *args).strip()


def ref_commit(ref):
    result = subprocess.run(["git", "rev-parse", "--verify", ref + "^{commit}"],
                            cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    return result.stdout.strip() if result.returncode == 0 else None


def version_parts(version):
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError("Expected version MAJOR.MINOR.PATCH-linux-alpha.N")
    return tuple(map(int, match[1].split("."))), int(match[2])


def plan():
    config = json.loads((ROOT / FILES[0]).read_text())
    current = config["version"]
    current_parts = version_parts(current)
    if config["channel"] != "alpha":
        raise ValueError("Only the Linux alpha channel is supported")
    if git("branch", "--show-current") != "GNU_Linux":
        raise ValueError("Run from the GNU_Linux branch")
    tags = git("tag", "--merged", "HEAD", "--list", "linux-v*").splitlines()
    # Compare numeric versions, not lexicographic alpha.9 / alpha.10 ordering.
    tagged = [(version_parts(tag[7:]), tag) for tag in tags]
    previous = max(tagged)[1] if tagged else None
    previous_parts = version_parts(previous[7:]) if previous else None
    if previous_parts and current_parts < previous_parts:
        raise ValueError("Configured version is older than the latest reachable Linux tag")
    configured_tag = "linux-v" + current
    at_head = ref_commit(configured_tag) == git("rev-parse", "HEAD")
    if at_head:
        return config, previous, current, []
    changes = git("diff", "--name-only", previous, "HEAD").splitlines() if previous else ["initial release"]
    if previous_parts == current_parts and changes:
        base, number = VERSION.fullmatch(current).groups()
        current = f"{base}-linux-alpha.{int(number) + 1}"
    if not changes and previous_parts == current_parts:
        return config, previous, None, []
    if ref_commit("linux-v" + current):
        raise ValueError("Proposed release tag already exists on another commit; never move it")
    return config, previous, current, changes


def prepare(config, previous, version):
    old_version = config["version"]
    xml_path = ROOT / FILES[1]
    xml_text = xml_path.read_text()
    releases = ET.fromstring(xml_text).find("releases")
    if releases is None or not len(releases) or releases[0].get("version") != old_version:
        raise ValueError("Newest AppStream release must match flatpak/release.json")
    notes_path = ROOT / FILES[2]
    notes = notes_path.read_text()
    if version == old_version:
        if version not in notes:
            raise ValueError("Release notes must mention the configured version")
        return
    subjects = git("log", "--format=%s", f"{previous}..HEAD" if previous else "HEAD").splitlines()
    # Escape commit text for XML; do not rewrite historical AppStream entries.
    description = ET.Element("p")
    description.text = "; ".join(subjects)
    entry = (f'    <release version="{version}" date="{date.today().isoformat()}" type="development">\n'
             f'      <description>{ET.tostring(description, encoding="unicode")}</description>\n'
             '    </release>')
    if xml_text.count("<releases>") != 1:
        raise ValueError("Expected one AppStream releases section")
    updated_xml = xml_text.replace("<releases>", "<releases>\n" + entry, 1)
    updated_notes = (f"Compositor {version} for Linux — signed Flatpak alpha, x86_64.\n\n"
                     + "\n".join("- " + subject for subject in subjects)
                     + "\n\nPrevious release notes:\n\n" + notes)
    config = dict(config, version=version)
    # Validate all content before changing the three Linux-only release files.
    ET.fromstring(updated_xml)
    (ROOT / FILES[0]).write_text(json.dumps(config, indent=2) + "\n")
    xml_path.write_text(updated_xml)
    notes_path.write_text(updated_notes)


def publish(remote):
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("Commit or stash existing work before --publish; no files are auto-staged")
    config = json.loads((ROOT / FILES[0]).read_text())
    repository = config["repository"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository in release.json")
    allowed = (f"https://github.com/{repository}", f"git@github.com:{repository}",
               f"ssh://git@github.com/{repository}")
    for options in (("--all",), ("--push", "--all")):
        urls = git("remote", "get-url", *options, remote).splitlines()
        if len(urls) != 1 or urls[0].removesuffix(".git") not in allowed:
            raise ValueError("Remote URLs must match release.json's GitHub repository")
    run("gh", "auth", "status", "--hostname", "github.com", capture=False)
    # Refresh the remote branch and tags before deciding whether a bump is due.
    git("fetch", "--tags", remote,
        f"refs/heads/GNU_Linux:refs/remotes/{remote}/GNU_Linux")
    subprocess.run(["git", "merge-base", "--is-ancestor",
                    f"refs/remotes/{remote}/GNU_Linux", "HEAD"], cwd=ROOT, check=True)
    config, previous, version, changes = plan()
    if version is None:
        print("No committed changes to release.")
        return
    tag = "linux-v" + version
    # A previous failed push may have left a valid local tag. Retry without a bump.
    remote_tags = git("ls-remote", "--tags", remote, "refs/tags/" + tag, "refs/tags/" + tag + "^{}")
    if remote_tags:
        lines = [line.split() for line in remote_tags.splitlines()]
        commit = next((sha for sha, ref in lines if ref.endswith("^{}")), lines[0][0])
        if commit != git("rev-parse", "HEAD"):
            raise ValueError("Remote release tag already exists on another commit")
        print(f"{tag} is already pushed. Check its Flatpak release workflow on GitHub.")
        return
    prepare(config, previous, version)
    with tempfile.TemporaryDirectory(prefix="compositor-release-") as directory:
        run("python3", "scripts/prepare-flatpak-release.py", "--output", directory,
            "--tag", tag, capture=False)
    run("python3", "tests/test_flatpak_release.py", capture=False)
    if git("diff", "--name-only", "--", *FILES):
        git("add", "--", *FILES)
        git("commit", "-m", f"Prepare Linux Flatpak alpha {version}.")
    if ref_commit(tag) is None:
        git("tag", "-a", tag, "-m", f"Compositor {version} (Linux alpha)")
    # Branch and tag become visible together; never force an existing ref.
    run("git", "push", "--atomic", remote, "HEAD:refs/heads/GNU_Linux",
        f"refs/tags/{tag}:refs/tags/{tag}", capture=False)
    print(f"Pushed {tag}. Flatpak CI builds/tests/signs, deploys Pages, then marks the release Latest.")
    print(f"https://github.com/{repository}/actions/workflows/flatpak-release.yml")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true",
                        help="require clean tree, refresh tags, bump, validate, commit, tag and push")
    parser.add_argument("--remote", default="origin", help="GitHub push remote (default: origin)")
    args = parser.parse_args()
    try:
        if args.publish:
            publish(args.remote)
        else:
            config, previous, version, changes = plan()
            print(f"Previous tag: {previous or '(none)'}")
            print(f"Configured version: {config['version']}")
            print(f"Version bump due: {'yes' if version and version != config['version'] else 'no'}")
            print(f"Proposed tag: {'linux-v' + version if version else '(no bump due)'}")
            print(f"Changed committed files: {len(changes)}")
            if git("status", "--porcelain", "--untracked-files=normal"):
                print("Uncommitted work is excluded; --publish requires a clean tree.")
            print("Preview only, using local tags. --publish refreshes remote tags before deciding.")
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        print("Existing files, commits, and tags are retained. Fix the error before retrying.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
