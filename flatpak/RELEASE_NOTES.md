Compositor 1.5.4-linux-alpha.3 for Linux — signed Flatpak alpha, x86_64.

- Stores 29 pinned dependency source archives in the repository, including Skia's required dependencies and GN. Flatpak builds use local sources rather than live Git downloads.
- Adds 109 unchanged upstream license and notice files, a source inventory, offline integrity checks in CI, and dependency update documentation. Notices and provenance are installed with the Flatpak.
- Disables OpenCV's unused ADE download probe while retaining core, imgproc and dnn.
- Retains the upstream 1.5.4 integration: pen pressure, searchable fonts, PDF import, line styles and project format 15.

Verification:

- All dependency modules built locally with Flatpak downloads disabled. OpenCV's final configuration also passed with the unused ADE probe disabled and no download attempts.
- Archive checksums, pinned Skia/GN revisions, all readable notice copies, 17 release tests and protected upstream source checks pass.
- The signed distributable and installation checks run in the release workflow before publication. Physical tablet/Wayland input and macOS comparisons remain unverified locally.

Previous release notes:

Compositor 1.5.4-linux-alpha.2 for Linux — signed Flatpak alpha, x86_64.

- Fixes the Flatpak build by installing the three license files present in the pinned Poppler-data archive.
- Integrates upstream 1.5.4: pen pressure, searchable fonts, PDF import, new line styles and project format 15.
- Adds Linux compatibility for tablet pressure, the font search panel and Poppler PDF rendering while preserving upstream Mac sources.
- Verified 1,019 Swift tests, 154 XCTest checks and all 37 native journeys across the complete run and targeted reruns. See docs/upstream-1.5.4-integration.md for evidence and qualifications.

Verification limits:

- Physical tablet/Wayland input and macOS comparisons were not tested locally. Variable pressure uses the CPU fallback.
- A complete Flatpak image was not built locally; the release workflow builds, tests and signs it before publication.

Previous release notes:

Compositor 1.5.3-linux-alpha.5 for Linux — signed Flatpak alpha, x86_64.

- Optional Nautilus and Dolphin providers display saved project previews. Installation is user-scoped and documented in docs/render-parity-and-desktop-previews.md; host integration is not installed automatically by the Flatpak.
- Added an independent 151-case render corpus covering blend modes, adjustments, filters, effects, transforms, text, shapes, color imports and synthetic RAW fixtures. Linux CPU/Vulkan outputs pass the comparison thresholds, including deep color samples.
- Verified project launch through a GIO desktop entry, real Nautilus preview display/refresh, and KDE KIO worker dispatch.
- Upstream app source, tests and Xcode project remain unchanged.

Verification limits:

- Independent macOS comparisons and real Dolphin GUI acceptance are pending their new GitHub Actions workflows; this release does not claim completed macOS visual/color parity.
- All 994 Swift tests passed locally. The full native batch passed 34 of 36 journeys: Canvas Size failed focus validation and Image Size stalled during parallel execution. Both passed in isolated reruns; the parallel failure remains unresolved.
- RAW fixtures are synthetic and do not establish every camera's rendering. Physical desktop input, broader Flatpak desktop delivery and cross-platform project round trips retain their separate acceptance checks.

Previous release notes:

Compositor 1.5.3-linux-alpha.4 for Linux — signed Flatpak alpha, x86_64.

- Linux: Smudge keeps up with a fast drag and releases faster
- Linux: About shows 1.5.3 (49); the upstream gate fails when AppVersion.h is stale

Previous release notes:

Compositor 1.5.3-linux-alpha.3 for Linux — signed Flatpak alpha, x86_64.

- RAW Develop and Add Noise/Grain now use upstream's own code unchanged
- Live Add Noise and Grain run on the GPU (Vulkan); Gaussian noise matches the exported file exactly
- Projects tab bar: a dragged tab stays above its neighbours
- UI checks now cover the Export As sheet and the command palette

Previous release notes:

Compositor 1.5.3-linux-alpha.2 for Linux — signed Flatpak alpha, x86_64.

- RAW Lens Correction for files without their own profile, from the lensfun lens database
- A default CMYK profile (SWOP TR005 Coated), so View › CMYK and CMYK export work without loading one
- Select Subject and Remove Background follow the photo's edges more closely
- Faster brushes and drags on large documents; no stall on a stroke's first frame
- Command palette as on the Mac: its placeholder, No commands match, shortcuts in their own column
- Window menu: Bring All to Front and the window entry
- Export As preview: dragging the zoomed image pans it, and zooming keeps its middle
- View › Clear Guides works
- UI fixes: New Canvas preset menu, CMYK proof and gamut pills, unclipped slider titles, missing icons, Camera Raw scope layout

Previous release notes:

Compositor 1.5.3-linux-alpha.1 for Linux — signed Flatpak alpha, x86_64.

- Linux: adaptations and parity fixes for upstream 1.5.3
- Merge upstream 1.5.3 into GNU_Linux
- Publish update feed for Compositor 1.5.3
- Version 1.5.3
- Accelerate large Camera Raw previews with verified Metal lookup
- Reduce Camera Raw scope sampling and benchmark preview latency
- Keep Camera Raw previews at native resolution during adjustments
- Update zoom cursors immediately when drag direction changes
- Add middle-mouse dragging to scroll the layer list
- Disable smooth corners when rectangle radius is zero
- Add smooth rectangle corners and simplify shape controls
- Remove temporary proof benchmark test committed by mistake

Previous release notes:

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
