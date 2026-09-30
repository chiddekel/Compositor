Compositor 1.4.5-linux-alpha.2 for Linux — signed Flatpak alpha, x86_64.

Tip 1.4.5 catch-up on GNU/Linux with editor interaction fixes:

- Gradient tool shows a live fade on the canvas before Apply.
- Copy Merged / Paste round-trip selection pixels from every visible layer (clipboard path no longer overwritten by a full-canvas dump).
- Smudge and Liquify keep first visible feedback under 150 ms on Full HD with large tips; release after a long stroke no longer hangs for ~1 s.
- Cut / Clear with several layers selected cuts the marquee through every selected pixel layer in one undo (not only the active layer).
- Download page shows Unofficial port branding and keeps Version in sync with each alpha build.
- Flatpak Skia bridge builds against current Ganesh `flushAndSubmit(GrSyncCpu)` API.

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates run without closing documents. Save your work and reopen Compositor after installation.

This is an alpha release of the GNU/Linux port of Compositor.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
