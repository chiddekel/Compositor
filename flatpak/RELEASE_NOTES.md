Compositor 1.5.2-linux-alpha.1 for Linux — signed Flatpak alpha, x86_64.

Catches up with Compositor 1.5, 1.5.1 and 1.5.2:

- **CMYK for print**: View › CMYK › Proof Colors shows the canvas as the chosen profile prints it, and Gamut Warning marks colors ink can't reach; export JPEG, TIFF and PDF in CMYK inks; open CMYK Photoshop files, which remember their profile. Load a print ICC profile (for example ISO Coated v2) under View › CMYK › Profile: Linux has no built-in Generic CMYK profile.
- **16-bit layers on the canvas at 16 bits**, dithered to the screen.
- **Filter › Progressive Blur.**
- **Camera Raw**: reset each section from its header; Shadows adapts to the picture; Camera Raw… on a RAW file imports it and opens the Camera Raw Filter.
- **Keyboard Shortcuts**: clear a shortcut, and keys for CMYK proofing.
- Fixed on Linux: typed Transform values (X, Y, W, H, Scale, angle) now show on the canvas as you type, and dragging a number's label scrubs its value again in every panel.
- Otherwise matches 1.4.10-linux-alpha.3 (16-bit and HDR layers, RAW Lens Correction).

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates install without closing documents; use **Restart Now** or reopen Compositor to run the new build.

This is an alpha release of the GNU/Linux port of Compositor.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
