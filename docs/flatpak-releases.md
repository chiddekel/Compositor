# Linux Flatpak alpha releases

The [Linux download page](https://chiddekel.github.io/Compositor/) provides an
install reference for `com.compositor.Client`, branch `alpha`, on x86_64:

```sh
flatpak install --user https://chiddekel.github.io/Compositor/com.compositor.Client.flatpakref
flatpak run com.compositor.Client
```

The reference adds the signed `compositor-alpha` repository hosted alongside the
page. GitHub Releases also provides a `.flatpak` bundle containing the repository
URL and public key. The KDE runtime comes from Flathub. Alpha builds may have bugs;
keep backups of important projects. Older previews using a different application
ID are separate installations; their private settings are not automatically migrated.

## Updating

Choose **Check for Updates…** in Compositor's menu, then **Check and Update** (or
**Install Update** when an update is known). The Flatpak portal asks the host to
update this installed application. Installation leaves documents open. Save your
work, close Compositor, and reopen it after installation completes.

Development launches inside the SDK do not enable the updater. The app checks its
Flatpak identity, installed commit, and executable path. It never runs host shell
commands or requires network access inside the application sandbox. If the portal
is unavailable, or an update changes sandbox permissions, use your software center
or `flatpak update com.compositor.Client`.

The updater follows the host's installed origin. It cannot update an old standalone
bundle that has no configured remote. The update monitor's absence of notifications
does not mean the app is up to date; only a completed check reports that result.

## Preferences on Linux

The Linux compatibility layer keeps the existing `UserDefaults.standard` and
`@AppStorage` calls, with SQLite storing the values in
`$XDG_CONFIG_HOME/Compositor/preferences.sqlite3` (or
`~/.config/Compositor/preferences.sqlite3` when XDG_CONFIG_HOME is unset).
Flatpak supplies its private configuration directory under
`~/.var/app/com.compositor.Client/config`.

The first successful database initialization imports the current executable's
Foundation preferences once, without changing the old plist. Later launches use
SQLite, so deleted settings are not reimported. Project files are unaffected.
Each setting change is committed in a transaction; a temporarily failed write
stays in memory and is retried by the shell's regular preference flush. Persistent
storage errors are logged to stderr, and unsaved changes cannot survive process exit.

This avoids the static Swift Foundation property-list writer crash encountered
when save/autosave updates the recent-project array. To exercise migration and
that exact application entry point with temporary, isolated settings, run:

```sh
flatpak run com.compositor.Client --preferences-smoke
```

## Publishing another alpha

1. Update `flatpak/release.json`, the newest AppStream release in
   `flatpak/com.compositor.Client.metainfo.xml`, and `flatpak/RELEASE_NOTES.md`.
2. Run `bash scripts/test-flatpak-updates.sh` and
   `python3 tests/test_flatpak_release.py`. The first needs the manifest's SDK and
   a host `dbus-daemon`; it uses a private test bus, not the desktop portal.
3. Commit and push to `GNU_Linux`. Tag that commit `linux-vVERSION`, matching the
   JSON version, and push the tag. Do not move an existing release tag.

`.github/workflows/flatpak-release.yml` builds and signs the full manifest, runs
native tests, installs the signed result and runs the app's session and preferences smoke tests.
Only then does it stage release assets, deploy Pages, and publish the prerelease.
A failed deployment leaves the new release as a draft. A manual workflow rerun
must use `GNU_Linux` with its matching release tag already present.

Pages must use **GitHub Actions** as its build source. The repository secret
`FLATPAK_SIGNING_KEY` holds an armored secret signing key; its public counterpart
and fingerprint are committed under `flatpak/`. Keep the same key for subsequent
releases so existing installations trust updates. Never commit the private key or
print it in build logs. Restore the secret from the release administrator's secure
backup if needed. Key rotation requires a migration plan for existing remotes;
merely replacing the key in the website does not update their trust.

For a local release build, import the signing key into a private GnuPG directory:

```sh
export GNUPGHOME=/path/to/private/release-keyring
bash scripts/build-flatpak-release.sh linux-vVERSION
```

Artifacts appear in `dist/`; the complete Pages artifact is `dist/site/`.
The build checks a 950 MiB size budget to stay within the
[GitHub Pages site limit](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits).
For larger repositories or substantial download traffic, move the signed repository
to a dedicated static host and plan remote URL migration.

The implementation uses the
[Flatpak update portal](https://github.com/flatpak/flatpak/blob/main/data/org.freedesktop.portal.Flatpak.xml)
and [Flatpak's signed repository format](https://docs.flatpak.org/en/latest/hosting-a-repository.html).
