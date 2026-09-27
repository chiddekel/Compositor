Compositor 1.1.0-linux-alpha.1 for Linux — signed Flatpak alpha, x86_64.

- Fix the diagnosed save/autosave crash when updating recent projects in statically linked Flatpak builds.
- Store preferences in SQLite behind the existing UserDefaults API. Existing settings are imported once; project files keep their current format.
- Retry temporarily blocked preference writes and verify migration, recent-project updates, and persistence in the installed-package smoke test.
- Update Linux application branding and include the license in the Flatpak package.

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates run without closing documents. Save your work and reopen Compositor after installation.

This is an alpha release of the GNU/Linux port of Compositor.

Local validation: 508 tests passed in sequential mode, including five new SQLite tests. The static Swift build passed the preferences and session smoke tests. A file-watcher test failed during parallel execution and passed both separately and in the full sequential run. The release pipeline additionally checks native tests, the updater, and the signed installed package before publication.

The earlier [desktop UI run](https://github.com/chiddekel/Compositor/actions/runs/36281364021) reports two unresolved assertions when undoing Gaussian Blur and Motion Blur adjustment layers. Those failures have not yet been diagnosed; this alpha is not a claim of full desktop regression coverage.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
