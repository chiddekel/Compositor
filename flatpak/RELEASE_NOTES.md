Compositor for Linux — signed Flatpak alpha, x86_64.

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates run without closing documents. Save your work and reopen Compositor after installation.
- Gaussian Blur uses faster finite-kernel convolution for large radii; Motion Blur uses wider vector sampling. Slider drags defer unrelated panel rebuilds.

This is an alpha release of the GNU/Linux port of Compositor.

Validation: the release build, six native tests, updater tests, and signed-install session smoke test passed. The broader [desktop UI run](https://github.com/chiddekel/Compositor/actions/runs/36281364021) reports two unresolved assertions when undoing Gaussian Blur and Motion Blur adjustment layers. Those failures have not yet been diagnosed; this alpha is not a claim of full desktop regression coverage.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
