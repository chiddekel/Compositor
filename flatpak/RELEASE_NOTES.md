Compositor for Linux — signed Flatpak alpha, x86_64.

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates run without closing documents. Save your work and reopen Compositor after installation.
- Gaussian Blur uses faster finite-kernel convolution for large radii; Motion Blur uses wider vector sampling. Slider drags defer unrelated panel rebuilds.

This is an alpha release. The Linux port is based on Compositor by Wonder Assembly.

App ID: `com.compositor.Client`, branch: `alpha`. Older `com.wonderassembly.Compositor` installations are a separate app; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
