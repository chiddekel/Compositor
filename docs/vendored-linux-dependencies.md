# Vendored Linux dependency sources

The Linux Flatpak manifest uses source archives committed in `third_party/sources`.
Building these dependencies does not require GitHub, Googlesource, or a live Skia
`git-sync-deps` invocation. Flatpak itself still needs its declared SDK, runtime and
Swift extension installed. A fresh checkout must contain the committed archives;
Git LFS and Git submodules are not used.

## Inventory and integrity

`third_party/sources/inventory.json` records each original URL, SHA-256 checksum,
and, for Git snapshots, the exact commit and destination within Skia. Release
archives retain the checksums previously pinned by the manifest. Skia snapshots
use the revisions from the pinned Skia release's `DEPS` file. Only dependencies
required by this Linux build are included; Android, browser, developer-test and
other unused Skia dependencies are not downloaded.

OpenCV still builds only `core`, `imgproc` and `dnn`; its unused G-API/ADE
download probe is explicitly disabled with `WITH_ADE=OFF`.

GN is included as source at the revision pinned by Skia's `bin/fetch-gn`. The
manifest builds GN locally with the SDK's compiler, Python and Ninja. It does not
download a GN executable during the build.

`linux/gn-last-commit-position.h` supplies the matching version metadata
(`2175 (b2afae122eeb)`) that GN otherwise derives from Git history.

Verify the checkout before building:

```sh
python3 scripts/check-vendored-sources.py
```

The check reads every archive, verifies its checksum and GitHub file-size limit,
and compares the readable license copies with the originals in the archives.
It does not access the network.

Once the manifest's Flatpak SDK dependencies are installed, test dependency
builds with downloads disabled:

```sh
flatpak-builder --user --disable-download --disable-rofiles-fuse \
  --jobs=6 --stop-at=compositor build-vendored com.compositor.Client.yaml
```

`--stop-at=compositor` builds the dependency modules before the application.
Use a new build directory, or follow flatpak-builder's instructions for an
existing build directory. The release workflow uses the same manifest.

## Licenses and notices

Every source archive retains its upstream license and notice files. Readable
copies are in `third_party/licenses/vendored/<dependency>/`; their original paths
and the complete discovered license-file list are recorded in the inventory.
These copies supplement the original files in the archives. They do not replace
or change the upstream terms, and do not change Compositor's own MIT license.

Skia and its dependencies have separate notices. Preserve those notices when
updating or redistributing their sources. The existing Flatpak dependency
license installation remains in place, including Poppler, Poppler-data and
Lensfun notices. The Flatpak also installs the readable vendored notices and
inventory under `/app/share/licenses/com.compositor.Client/`. Source availability
alone does not describe all obligations for a particular binary distribution;
consult the included upstream terms.

## Updating a dependency

1. Choose an explicit upstream release or Git commit. Save the original URL and
   revision in the inventory; never use a moving branch.
2. For a release archive, retain its original bytes and verify its upstream
   checksum. For a Git snapshot, export the pinned commit with `git archive
   --format=tar --prefix=source/` and gzip with no filename or timestamp metadata.
   Do not include a working directory, `.git`, credentials or build output.
3. Record the archive's SHA-256, retain the original license files, refresh the
   readable copies and update the manifest's local path and checksum together.
4. When updating Skia, review its `DEPS`, GN revision and Linux build arguments.
   Include all newly required transitive sources before removing network access.
5. Run the integrity check and an offline dependency build, then the Linux
   contract tests. Review the archive sizes and commit the sources, notices,
   inventory and manifest together.

Large archives are stored once and shared between modules. Keep every committed
file below GitHub's 100 MiB limit. Do not replace the source archives with locally
compiled libraries: those depend on the compiler, SDK and build configuration.
