Compositor 1.4.5-linux-alpha.4 for Linux — signed Flatpak alpha, x86_64.

Minor updater polish on tip 1.4.5 Linux catch-up:

- After **Check for Updates…** installs a Flatpak update, the dialog offers **Restart Now** next to Close (save prompts still run; the new commit starts after quit).
- Editor behavior otherwise matches 1.4.5-linux-alpha.3.

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates install without closing documents; use **Restart Now** or reopen Compositor to run the new build.

This is an alpha release of the GNU/Linux port of Compositor.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
