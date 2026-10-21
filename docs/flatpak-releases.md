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
update this installed application. Installation leaves documents open. When the
update is ready, choose **Restart Now** (save prompts still run) or close and
reopen Compositor yourself.

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

## Watching builds

The terminal dashboard shows the `GNU_Linux` and `linux-v*` GitHub Actions runs,
their job steps, elapsed times and failures. It uses Python's standard library
and your existing GitHub CLI login; it does not need additional Python packages.

```sh
gh auth login                       # only if gh is not already authenticated
./scripts/watch-flatpak-build.py
```

Use **j/k** or arrow keys to select a workflow, **PgUp/PgDn** to scroll its steps,
**r** to refresh, **o** to open the selected run on GitHub, and **q** to quit.
The steps automatically follow the current build step or a failure. Scrolling
switches to browsing; press **a** to follow the current step again.
The display resizes with the terminal. `--ascii` and `NO_COLOR=1` support simpler
terminals. The bar counts finished steps; it does not estimate compiler progress.
If your shell exports `NO_COLOR`, use `env -u NO_COLOR ./scripts/watch-flatpak-build.py`
to enable the color palette for this command.

```sh
./scripts/watch-flatpak-build.py --once                    # one text snapshot
./scripts/watch-flatpak-build.py --run RUN_ID              # one workflow
./scripts/watch-flatpak-build.py --run RUN_ID --plain --wait
./scripts/watch-flatpak-build.py -vvv                     # maximum detail
./scripts/watch-flatpak-build.py --once -vvv              # detailed text snapshot
```

Verbosity levels are cumulative: **-v** adds run/job IDs and step durations;
**-vv** adds runner labels, full commit IDs, events and timestamps; **-vvv** adds
request paths, cache hits, request counts and refresh timings. In the TUI, press
**v** to cycle levels or **d** to toggle the request trace. Diagnostics are bounded
and do not print authentication headers, tokens or environment variables.
Live compiler output is not exposed by GitHub's job-log download API until the
job finishes; use **o** to view GitHub's live log in the browser.

`--wait` exits successfully only when that workflow succeeds; failure returns a
nonzero exit status. API failures remain visible and are retried. Noninteractive
terminals automatically use text mode. The dashboard is read-only: it does not
start, cancel, delete, publish or rerun workflows.

## Publishing another alpha

Preview whether committed changes need a release:

```sh
python3 scripts/release-linux.py
```

After committing and reviewing the Linux changes, publish from a clean
`GNU_Linux` checkout:

```sh
python3 scripts/release-linux.py --publish
```

The script refreshes remote tags, detects changed committed files since the
highest reachable Linux version tag, and increments `linux-alpha.N` when needed.
It updates only the Linux release JSON, AppStream entry, and release notes, runs
the descriptor checks, commits those files, creates an annotated tag, and pushes
the branch and tag atomically. An already prepared newer version is preserved.
There is no time interval: a new release is due when the committed tree changes.
Preview uses local tags and excludes uncommitted work. No Mac versions or tests
are changed. Generated notes list commit subjects; edit and commit a prepared
new version first when curated notes are needed.

The tag triggers the existing build, test, signing, and Pages pipeline. Only after
successful deployment does CI publish with GitHub's **Latest** label. GitHub does
not allow Latest on a prerelease, so the published release has `prerelease=false`
while its title, version, and Flatpak channel continue to identify it as alpha.
If a push fails, retain the release commit and local tag and rerun `--publish`;
the script retries that tag without incrementing again. If the tag is already
pushed, inspect or rerun its workflow on GitHub instead. Existing tags are never
moved. Authentication uses the existing `git` credentials and `gh auth login`.

For manual publication:

1. Update `flatpak/release.json`, the newest AppStream release in
   `flatpak/com.compositor.Client.metainfo.xml`, and `flatpak/RELEASE_NOTES.md`.
2. Run `bash scripts/test-flatpak-updates.sh` and
   `python3 tests/test_flatpak_release.py`. The first needs the manifest's SDK and
   a host `dbus-daemon`; it uses a private test bus, not the desktop portal.
3. Commit and push to `GNU_Linux`. Tag that commit `linux-vVERSION`, matching the
   JSON version, and push the tag. Do not move an existing release tag.

`.github/workflows/flatpak-release.yml` builds and signs the full manifest, runs
native tests, installs the signed result and runs the app's session and preferences smoke tests.
Only then does it stage release assets, deploy Pages, and publish the Linux alpha as Latest.
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
