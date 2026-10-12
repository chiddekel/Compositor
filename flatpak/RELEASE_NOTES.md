Compositor 1.4.10-linux-alpha.3 for Linux — signed Flatpak alpha, x86_64.

Catches up with Compositor's 16-bit and HDR work (after 1.4.10):

- **16-bit layers**: 16-bit PNG and TIFF images keep their precision through Levels, Hue/Saturation, filters, Smudge, Liquify, Blur, transforms, merging, saving and 16-bit PNG export; convert any layer between 8 and 16 bits; 16-bit gradients and fills.
- **HDR layers**: import OpenEXR and Radiance HDR keeping light brighter than white; adjustment layers bring highlights back into view; export as EXR.
- Paste an image on the New canvas screen to make the canvas; drop files anywhere on the tab bar to open them in a new project.
- Export As lists JPEG and PNG first, with PDF and EXR under More.
- Otherwise matches 1.4.10-linux-alpha.2 (RAW Lens Correction, camera HEIF).

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates install without closing documents; use **Restart Now** or reopen Compositor to run the new build.

This is an alpha release of the GNU/Linux port of Compositor.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
