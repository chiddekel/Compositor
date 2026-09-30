Compositor 1.4.5-linux-alpha.3 for Linux — signed Flatpak alpha, x86_64.

Maintenance release on tip 1.4.5 Linux catch-up:

- Editor behavior matches 1.4.5-linux-alpha.2 (live gradient preview, Copy Merged/Paste, Smudge/Liquify latency, multi-layer Cut, Unofficial port download page, Skia Ganesh Flatpak build).
- Remove the Linux UI e2e suite and graphics E2E bench from the repository and CI; smoke and unit tests remain.

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates run without closing documents. Save your work and reopen Compositor after installation.

This is an alpha release of the GNU/Linux port of Compositor.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
