Compositor 1.4.5-linux-alpha.9 for Linux — signed Flatpak alpha, x86_64.

Save / Save As reliability on tip 1.4.5 Linux catch-up:

- **Save As** installs `.comp` directory packages reliably (temp staging, rename-or-copy).
- When the system dialog returns an XDG document-portal file path, the project saves automatically under **Documents** with the chosen name (no second dialog).
- Otherwise matches 1.4.5-linux-alpha.8 (Show Controls Free Transform Cancel/Apply).

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates install without closing documents; use **Restart Now** or reopen Compositor to run the new build.

This is an alpha release of the GNU/Linux port of Compositor.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
