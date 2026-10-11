Compositor 1.4.10-linux-alpha.1 for Linux — signed Flatpak alpha, x86_64.

Catches up with Compositor 1.4.10:

- HEIF photos from Canon, Sony and Fuji cameras (`.hif`, `.heif`) import like HEIC, from the Open panel, drag and drop or a folder.
- New app icon: a page of color peeling back to transparency.
- Otherwise matches 1.4.5-linux-alpha.10 plus the upstream 1.4.6–1.4.10 features ported since.

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates install without closing documents; use **Restart Now** or reopen Compositor to run the new build.

This is an alpha release of the GNU/Linux port of Compositor.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
