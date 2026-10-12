Compositor 1.4.10-linux-alpha.2 for Linux — signed Flatpak alpha, x86_64.

RAW Lens Correction now works on Linux:

- The Develop sheet's **Lens Correction** removes distortion and vignetting using the profile stored in the file: DNG (OpcodeList3), Sony ARW, Fujifilm RAF, OM System / Olympus ORF and Panasonic RW2.
- It is on by default where the file has a profile and disabled where it has none, as on the Mac. The draft preview and the import show the same correction.
- Otherwise matches 1.4.10-linux-alpha.1 (camera HEIF import, new app icon).

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates install without closing documents; use **Restart Now** or reopen Compositor to run the new build.

This is an alpha release of the GNU/Linux port of Compositor.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
