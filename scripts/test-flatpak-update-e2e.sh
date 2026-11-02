#!/usr/bin/env bash
# T-17: the in-app updater's real path, end to end, without the GUI. The installed app's commit is published as a
# throwaway branch (`t17`) in a local repository, installed from there, then a newer commit is published. From inside
# that branch's sandbox — where the portal identifies the caller as the app — the same portal calls the app's
# FlatpakUpdateService makes are made: CreateUpdateMonitor, then UpdateAvailable is awaited, then Update, whose Progress
# must reach "done" and leave the newer commit installed. The user's own branch stays current, and the test branch,
# its remote and repository are removed afterwards. Relaunch after the update is the app's own code
# (FlatpakUpdateService::armRelaunch) and is covered by tests/test_flatpak_updates.cpp.
#   scripts/test-flatpak-update-e2e.sh [work-dir]     (needs a desktop session with xdg-desktop-portal and flatpak-portal)
set -euo pipefail
APP=com.compositor.Client
WORK=$(realpath -m "${1:-.build/evidence/t17}")
REPO=$WORK/repo REMOTE=compositor-t17 BRANCH=t17
current=$(flatpak --user info --show-ref "$APP" 2>/dev/null | awk -F/ '{print $4}')
[[ -n $current ]] || { echo "FAIL: $APP is not installed for this user"; exit 1; }
source_commit=$(flatpak --user info --show-commit "$APP//$current")
cleanup() {
    flatpak --user uninstall -y --noninteractive "$APP//$BRANCH" >/dev/null 2>&1 || true
    flatpak --user make-current "$APP" "$current" >/dev/null 2>&1 || true
    flatpak --user remote-delete --force "$REMOTE" >/dev/null 2>&1 || true
    rm -rf "$REPO"
}
trap cleanup EXIT
cleanup
mkdir -p "$WORK"
ostree init --mode=archive-z2 --repo="$REPO" >/dev/null
# The disk this runs on may be nearly full; the throwaway repository holds one commit.
ostree --repo="$REPO" config set core.min-free-space-percent 0
# The installed commit, copied into the test repository under a source ref of its own.
ostree --repo="$REPO" pull-local "$HOME/.local/share/flatpak/repo" "$source_commit" >/dev/null
ostree --repo="$REPO" refs --create=source/$APP "$source_commit"
publish() {  # publish $1 (subject) as the test branch's newest commit
    flatpak build-commit-from --force --src-repo="$REPO" --src-ref="source/$APP" \
        --subject="$1" --timestamp=NOW "$REPO" "app/$APP/x86_64/$BRANCH" >/dev/null
    flatpak build-update-repo "$REPO" >/dev/null
    ostree --repo="$REPO" rev-parse "app/$APP/x86_64/$BRANCH"
}
first=$(publish "T-17 version N")
flatpak --user remote-add --no-gpg-verify "$REMOTE" "$REPO"
flatpak --user install -y --noninteractive "$REMOTE" "$APP//$BRANCH" >/dev/null
flatpak --user make-current "$APP" "$current" >/dev/null
installed=$(flatpak --user info --show-commit "$APP//$BRANCH")
[[ $installed == "$first" ]] || { echo "FAIL: installed $installed, expected $first"; exit 1; }
echo "PASS: version N installed from the local repository ($first)"

# The probe: the app's own FlatpakUpdateService, built against the app's runtime (tests/flatpak_update_probe.cpp).
sdk=$(sed -n "s/^runtime-version: *['\"]\?\([0-9.]*\)['\"]\?.*/\1/p" com.compositor.Client.yaml)
flatpak run --user --command=bash --devel --filesystem="$PWD" --filesystem="$WORK" "org.kde.Sdk//$sdk" -c '
    set -euo pipefail
    moc=$(pkg-config --variable=libexecdir Qt6Core)/moc
    "$moc" host/FlatpakUpdateService.h -o "$1/moc_FlatpakUpdateService.cpp"
    c++ -std=c++17 -fPIC -Ihost -I"$1" $(pkg-config --cflags Qt6Widgets Qt6DBus) tests/flatpak_update_probe.cpp \
        host/FlatpakUpdateService.cpp "$1/moc_FlatpakUpdateService.cpp" $(pkg-config --libs Qt6Widgets Qt6DBus) -o "$1/update-probe"
' probe "$WORK"

second=$(publish "T-17 version N+1")
echo "published version N+1 ($second)"
# Inside the test branch's sandbox, where the portal sees the caller as the installed app: "Check and Update".
if ! flatpak run --user --branch="$BRANCH" --filesystem="$WORK" --command="$WORK/update-probe" "$APP" > "$WORK/probe.log" 2>&1; then
    cat "$WORK/probe.log"; echo "FAIL: the in-app updater did not install the update"; exit 1
fi
grep '^status' "$WORK/probe.log"
installed=$(flatpak --user info --show-commit "$APP//$BRANCH")
[[ $installed == "$second" ]] || { echo "FAIL: after the update $installed is installed, expected $second"; exit 1; }
echo "PASS: the in-app updater (FlatpakUpdateService, Check and Update) installed version N+1 through the portal ($second)"
active=$(readlink "$HOME/.local/share/flatpak/app/$APP/current")
[[ $active == */$current ]] || { echo "FAIL: the current branch became $active"; exit 1; }
echo "PASS: $current is still the current branch (what \`flatpak run $APP\` starts)"
