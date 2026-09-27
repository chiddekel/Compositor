Compositor 1.2.0-linux-alpha.1 for Linux — signed Flatpak alpha, x86_64.

- Ctrl+Z now stops at the newly created canvas instead of removing the document.
- Preserve the initial blank layer, selection, redo behavior, and unsaved document state when undoing all edits.
- Apply the change only through the GNU/Linux compatibility layer. Upstream macOS source and tests remain unchanged.
- Add Linux regression coverage for the canvas undo boundary and save-state handling.

- Install from the [Linux download page](https://chiddekel.github.io/Compositor/) or the attached `.flatpakref` file. The signed alpha repository supplies future updates.
- Use **Compositor → Check for Updates… → Check and Update**, your software center, or `flatpak update com.compositor.Client`.
- Updates run without closing documents. Save your work and reopen Compositor after installation.

This is an alpha release of the GNU/Linux port of Compositor.

Local validation: 507 tests passed in an optimized sequential run with the manifest's KDE 6.11 SDK (114 XCTest and 393 Swift Testing tests). The updater tests reported zero failures, all three release descriptor tests passed, and a clean optimized GNU/Linux build succeeded. Two upstream tests that expect canvas creation to be undoable are skipped on Linux, with the requested behavior covered by Linux regression tests. The upstream-clean guard confirms that protected macOS source and tests are unchanged. The release pipeline additionally checks native tests, the updater, and the signed installed package before publication.

The earlier [desktop UI run](https://github.com/chiddekel/Compositor/actions/runs/36281364021) reports two unresolved assertions when undoing Gaussian Blur and Motion Blur adjustment layers. Those failures have not yet been diagnosed; this alpha is not a claim of full desktop regression coverage.

App ID: `com.compositor.Client`, branch: `alpha`. Older previews using a different application ID are separate installations; save/export projects before moving to this package. Their private app data is not migrated automatically.

The `.flatpak` bundle includes the alpha repository URL and its public signing key. `SHA256SUMS` covers the release downloads.
