#!/usr/bin/env bash
# Build a signed alpha repository, installable bundle, and static download site.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GNUPGHOME:?Set GNUPGHOME to the directory containing the release signing key}"
tag=${1:?Usage: build-flatpak-release.sh linux-vVERSION}
key=$(cat flatpak/release-key.fingerprint)
[[ "$key" =~ ^[A-F0-9]{40}$ ]] || { echo 'Invalid signing fingerprint' >&2; exit 1; }
gpg --batch --list-secret-keys "$key" >/dev/null
actual=$(gpg --batch --with-colons --show-keys flatpak/release-key.gpg | awk -F: '$1 == "fpr" {print $10; exit}')
[[ "$actual" == "$key" ]] || { echo 'Public key fingerprint mismatch' >&2; exit 1; }
python3 scripts/prepare-flatpak-release.py --output dist/site --tag "$tag"
flatpak-builder --user --install-deps-from=flathub --assumeyes --disable-rofiles-fuse \
  --force-clean --arch=x86_64 --repo=dist/site/repo \
  --gpg-sign="$key" --gpg-homedir="$GNUPGHOME" build-flatpak com.compositor.Client.yaml
flatpak build-update-repo --title='Compositor Alpha' --default-branch=alpha \
  --gpg-sign="$key" --gpg-homedir="$GNUPGHOME" --gpg-import=flatpak/release-key.gpg \
  --generate-static-deltas --prune dist/site/repo
site_url=$(python3 -c 'import json; print(json.load(open("flatpak/release.json"))["site_url"])')
flatpak build-bundle --arch=x86_64 --repo-url="$site_url/repo" \
  --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo --gpg-keys=flatpak/release-key.gpg \
  dist/site/repo dist/com.compositor.Client.flatpak com.compositor.Client alpha
cp dist/site/com.compositor.Client.flatpakref dist/site/compositor.flatpakrepo dist/site/release-key.gpg dist/
(cd dist && sha256sum com.compositor.Client.flatpak com.compositor.Client.flatpakref compositor.flatpakrepo release-key.gpg > SHA256SUMS)
# GitHub Pages has a 1 GiB site limit. Fail before replacing a working repository.
python3 - <<'PY'
from pathlib import Path
root = Path('dist/site')
if any(p.is_symlink() for p in root.rglob('*')):
    raise SystemExit('Pages artifacts must not contain symbolic links')
size = sum(p.stat().st_size for p in root.rglob('*') if p.is_file())
print(f'Published site size: {size / 1024**2:.1f} MiB')
if size >= 950 * 1024**2:
    raise SystemExit('Repository exceeds the Pages size budget; use a dedicated Flatpak repository host')
PY
