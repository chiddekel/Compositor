# 01 — Repository history and synchronization

Read-only audit, 2026-10-18. Every value below was produced by `.build/evidence/audit/gen_history.py` from the local clone after `git ls-remote` confirmed the remote heads. Commit categories are keyword heuristics for navigation only; feature status is decided in reports 02–04 from source and runtime evidence, never from commit messages.

## Baseline

| Item | Value |
|---|---|
| Upstream | `robbietilton/Compositor` `main` = `365b5745eda537f984f3d5bed1e53c361dbc9c91` (1.5.3, 2026-10-14 18:43:32 -0700) |
| GNU/Linux port | `chiddekel/Compositor` `GNU_Linux` = `6f69273d7f6f23f3fb1d9812b085eae0b55010f6` (2026-10-18 21:27:08 +0200) |
| Reference branch | `chiddekel/Compositor` `main` = `c9f8fad82b39e11d5a69df2c288a12defe057ba2` (2026-09-22 Merge remote-tracking branch 'upstream/main'); a stale fork of upstream from 2026-09-22, merge base with upstream `609dbea`. Not a parity baseline. |
| Upstream root commit | `2dae6a2a560580ee785f82564678f8a70a571736` (2026-09-16 Initial commit) |
| Merge base upstream ↔ GNU_Linux | `365b5745eda537f984f3d5bed1e53c361dbc9c91` = upstream head (GNU_Linux contains all of upstream) |
| Upstream commits missing from GNU_Linux | 0 |
| First Linux-specific commit | `fd4feef` 2026-09-19 — chore: add gstack skill routing rules to CLAUDE.md |
| Commit counts | upstream 431 non-merge (+49 merges); GNU_Linux-only 299 non-merge + 28 merges |
| Protected-tree diff (`Compositor/`, `CompositorTests/`, `CompositorUITests/`, Xcode project) GNU_Linux vs upstream | (none) |

Consequence: GNU_Linux is upstream plus a Linux layer (`Sources/`, `host/`, `backends/`, `linux/`, `scripts/`, `Tests/`, Flatpak). Upstream Swift is compiled from the identical tree; parity questions are therefore about the Linux layer that hosts, draws and backs that code, not about missing merges.

## Upstream releases

| Tag | Commit | Date |
|---|---|---|
| v1.0 | `5165e1b` | 2026-09-16 |
| v1.0.1 | `77a3018` | 2026-09-16 |
| v1.0.2 | `2ef78cf` | 2026-09-16 |
| v1.0.3 | `89dfb56` | 2026-09-17 |
| v1.0.4 | `8fed2e7` | 2026-09-18 |
| v1.1 | `cdd8eb6` | 2026-09-20 |
| v1.1.1 | `2e8ebd7` | 2026-09-20 |
| v1.1.2 | `e521ca0` | 2026-09-20 |
| v1.1.3 | `827847c` | 2026-09-20 |
| v1.1.4 | `f8e54b3` | 2026-09-20 |
| v1.1.5 | `9f49d67` | 2026-09-20 |
| v1.1.6 | `391042d` | 2026-09-20 |
| v1.1.7 | `3e4fd6a` | 2026-09-20 |
| v1.1.8 | `886d178` | 2026-09-20 |
| v1.2.0 | `28855e6` | 2026-09-21 |
| v1.2.1 | `12bb77c` | 2026-09-21 |
| v1.2.2 | `e3fbdd1` | 2026-09-21 |
| v1.2.3 | `db25522` | 2026-09-22 |
| v1.2.4 | `e08dd8c` | 2026-09-22 |
| v1.2.5 | `bff6b8f` | 2026-09-22 |
| v1.2.6 | `cceab20` | 2026-09-22 |
| v1.2.7 | `d302214` | 2026-09-23 |
| v1.2.8 | `092146a` | 2026-09-23 |
| v1.2.9 | `292cb6b` | 2026-09-23 |
| v1.2.10 | `17d2454` | 2026-09-23 |
| v1.2.11 | `0ecbacf` | 2026-09-24 |
| v1.3 | `a299f4c` | 2026-09-25 |
| v1.3.1 | `6131001` | 2026-09-25 |
| v1.3.2 | `ff7e039` | 2026-09-25 |
| v1.3.3 | `5888be2` | 2026-09-25 |
| v1.3.4 | `ab99b60` | 2026-09-26 |
| v1.3.5 | `4f11bb5` | 2026-09-27 |
| v1.3.6 | `5809fe9` | 2026-09-27 |
| v1.3.7 | `9e2894e` | 2026-09-27 |
| v1.4 | `d04f159` | 2026-09-28 |
| v1.4.1 | `0d9986f` | 2026-09-28 |
| v1.4.2 | `ed9c280` | 2026-09-29 |
| v1.4.3 | `557d2f0` | 2026-09-29 |
| v1.4.4 | `ec02559` | 2026-09-29 |
| v1.4.5 | `086f163` | 2026-09-29 |
| v1.4.6 | `6e6ca38` | 2026-10-07 |
| v1.4.7 | `675d8a4` | 2026-10-08 |
| v1.4.8 | `24ef288` | 2026-10-08 |
| v1.4.9 | `0ab3ff5` | 2026-10-09 |
| v1.4.10 | `eb1fda7` | 2026-10-11 |
| v1.5 | `1071f4f` | 2026-10-12 |
| v1.5.1 | `539a78d` | 2026-10-12 |
| v1.5.2 | `f2d5754` | 2026-10-13 |
| v1.5.3 | `554104c` | 2026-10-14 |

Linux release tags: alpha-linux, linux-v1.0.5-linux-alpha.1, linux-v1.1.0-linux-alpha.1, linux-v1.2.0-linux-alpha.1, linux-v1.4.10-linux-alpha.1, linux-v1.4.10-linux-alpha.2, linux-v1.4.10-linux-alpha.3, linux-v1.4.5-linux-alpha.1, linux-v1.4.5-linux-alpha.10, linux-v1.4.5-linux-alpha.2, linux-v1.4.5-linux-alpha.3, linux-v1.4.5-linux-alpha.4, linux-v1.4.5-linux-alpha.5, linux-v1.4.5-linux-alpha.6, linux-v1.4.5-linux-alpha.7, linux-v1.4.5-linux-alpha.8, linux-v1.4.5-linux-alpha.9, linux-v1.5.2-linux-alpha.1, linux-v1.5.3-linux-alpha.1.

## Upstream merges into GNU_Linux (synchronization points)

| # | Commit | Date | Category | Subject |
|---:|---|---|---|---|
| 1 | `d287f5d` | 2026-09-20 | other | Merge remote-tracking branch 'upstream/main' |
| 2 | `85b55ad` | 2026-09-20 | other | Merge branch 'linux-port-plan' |
| 3 | `06b200b` | 2026-09-20 | test | Merge eng-1-c-abi-seam: complete Linux port with Qt6, Skia, Vulkan, 414 tests |
| 4 | `65b78ef` | 2026-09-21 | other | Merge upstream/main into main |
| 5 | `63b0bb1` | 2026-09-21 | other | Merge main into GNU_Linux |
| 6 | `c9f8fad` | 2026-09-22 | other | Merge remote-tracking branch 'upstream/main' |
| 7 | `520538d` | 2026-09-22 | other | Merge branch 'main' into GNU_Linux |
| 8 | `5d9cf26` | 2026-09-22 | other | Merge remote-tracking branch 'upstream/main' into GNU_Linux |
| 9 | `0a1eba8` | 2026-09-23 | other | Merge remote-tracking branch 'upstream/main' into GNU_Linux |
| 10 | `da1b004` | 2026-09-23 | other | Merge remote-tracking branch 'upstream/main' into GNU_Linux |
| 11 | `a9b6112` | 2026-09-23 | other | Merge upstream 1.2.8 (092d030) into GNU_Linux; port its changes to the Linux side |
| 12 | `edcc39e` | 2026-09-23 | other | Merge remote-tracking branch 'upstream/main' into GNU_Linux |
| 13 | `ce8cba6` | 2026-09-25 | fix | Merge upstream 1.3.1 (44 commits) — Linux keeps up through the compat layer |
| 14 | `290bf5e` | 2026-09-26 | other | Merge upstream 1.3.3 (26 commits) — every new feature recreated on Linux through the compat layer |
| 15 | `d779d5a` | 2026-09-29 | other | Merge upstream/main (Compositor 1.4) into GNU_Linux |
| 16 | `02b9b7c` | 2026-09-29 | other | Merge upstream/main (Compositor 1.4.1) into GNU_Linux |
| 17 | `4bf14fa` | 2026-09-29 | other | Merge upstream/main (Compositor 1.4.2–1.4.4) |
| 18 | `4b5fb23` | 2026-09-30 | other | Merge upstream/main (Compositor 1.4.5) |
| 19 | `f85b407` | 2026-10-04 | other | Merge branch 'icons' into GNU_Linux. |
| 20 | `c80117a` | 2026-10-09 | other | Merge upstream/main (Compositor 1.4.8) |
| 21 | `cf12a32` | 2026-10-10 | other | Merge upstream/main (Compositor 1.4.9) |
| 22 | `4cfc244` | 2026-10-11 | other | Merge remote-tracking branch 'upstream/main' into GNU_Linux |
| 23 | `83a8cd5` | 2026-10-11 | other | Merge remote-tracking branch 'upstream/main' into GNU_Linux |
| 24 | `74dbacf` | 2026-10-11 | other | Merge commit '39d1257' into GNU_Linux |
| 25 | `2b737cb` | 2026-10-11 | other | Merge remote-tracking branch 'upstream/main' into GNU_Linux |
| 26 | `2464706` | 2026-10-12 | other | Merge remote-tracking branch 'upstream/main' into GNU_Linux |
| 27 | `aca44c2` | 2026-10-14 | other | Merge remote-tracking branch 'upstream/main' into GNU_Linux |
| 28 | `94cf71e` | 2026-10-15 | other | Merge upstream 1.5.3 into GNU_Linux |

## Category counts (heuristic)

| Category | Upstream | GNU_Linux-only |
|---|---:|---:|
| ci/build | 11 | 32 |
| docs | 19 | 24 |
| feature | 59 | 60 |
| fix | 35 | 30 |
| format/IO | 35 | 9 |
| other | 88 | 35 |
| perf | 6 | 16 |
| release | 86 | 14 |
| rendering | 33 | 20 |
| revert | 2 | 0 |
| test | 16 | 22 |
| ui/ux | 41 | 37 |

## Upstream development, root to head (every non-merge commit)

| # | Commit | Date | Category | Subject |
|---:|---|---|---|---|
| 1 | `2dae6a2` | 2026-09-16 | other | Initial commit |
| 2 | `7619255` | 2026-09-16 | docs | Add README with features, and MIT license |
| 3 | `b36b305` | 2026-09-16 | feature | Add Sparkle updates and release publishing script |
| 4 | `1c0d5b2` | 2026-09-16 | release | Publish update feed for Compositor 1.0 |
| 5 | `f24657e` | 2026-09-16 | fix | Stop tracking BUILD_PLAN.md |
| 6 | `5165e1b` | 2026-09-16 | other | Start updater after launch; fit zoom controls beside tabs |
| 7 | `4015b75` | 2026-09-16 | release | Publish update feed for Compositor 1.0 |
| 8 | `77a3018` | 2026-09-16 | other | Clip from row bottom, Option-drag to copy masks, row edge lines; version 1.0.1 |
| 9 | `375e6a4` | 2026-09-16 | release | Publish update feed for Compositor 1.0.1 |
| 10 | `c1176a2` | 2026-09-16 | other | Move to robbietilton GitHub account; version 1.0.2 |
| 11 | `b8ddfd1` | 2026-09-16 | release | Publish update feed for Compositor 1.0.2 |
| 12 | `8863eda` | 2026-09-16 | other | Shift-constrain and edge autoscroll for selection moves and marquees |
| 13 | `1dcfe85` | 2026-09-16 | release | Publish update feed for Compositor 1.0.2 |
| 14 | `028f4ff` | 2026-09-16 | docs | Update README about section |
| 15 | `1c26aff` | 2026-09-16 | other | Live shape layers, no window fade on file open; version 1.0.3 |
| 16 | `9b1efbf` | 2026-09-16 | release | Publish update feed for Compositor 1.0.3 |
| 17 | `89dfb56` | 2026-09-17 | feature | Smear tool (Liquify, Blur, Smudge), right-drag brush size and hardness, sticky selection modes |
| 18 | `91e1534` | 2026-09-17 | release | Publish update feed for Compositor 1.0.3 |
| 19 | `958bb01` | 2026-09-17 | rendering | Smear tool, eraser mode, blend modes, burn/dodge and cursor fixes; version 1.0.4 |
| 20 | `5f5eb61` | 2026-09-17 | release | Publish update feed for Compositor 1.0.4 |
| 21 | `5ca5f03` | 2026-09-17 | other | Finer Liquify spacing; Shift locks brush strokes from where it is pressed |
| 22 | `1db2c2e` | 2026-09-17 | release | Publish update feed for Compositor 1.0.4 |
| 23 | `cc5aac4` | 2026-09-17 | fix | Fix dark soft edges in Hue/Saturation and Levels |
| 24 | `0f47044` | 2026-09-17 | release | Publish update feed for Compositor 1.0.4 |
| 25 | `8fed2e7` | 2026-09-18 | other | Eye swipe for visibility, dimmer hidden rows, zoom tool cursors and drag-to-zoom |
| 26 | `a19db90` | 2026-09-18 | release | Publish update feed for Compositor 1.0.4 |
| 27 | `e3a474a` | 2026-09-19 | feature | Add Photoshop-style rulers, guides, grid, and snap. |
| 28 | `8ccfcf0` | 2026-09-19 | feature | Add object selection tool |
| 29 | `3c322c7` | 2026-09-19 | other | Refine object selection edges |
| 30 | `cdd8eb6` | 2026-09-20 | rendering | Type tool refinements, line shape, layer effects with GPU rendering; version 1.1 |
| 31 | `7451cef` | 2026-09-20 | release | Publish update feed for Compositor 1.1 |
| 32 | `2e8ebd7` | 2026-09-20 | feature | Add feathered selection modifiers; version 1.1.1 |
| 33 | `6d22f5c` | 2026-09-20 | release | Publish update feed for Compositor 1.1.1 |
| 34 | `e521ca0` | 2026-09-20 | rendering | Add Soft Light blend mode; version 1.1.2 |
| 35 | `01affeb` | 2026-09-20 | release | Publish update feed for Compositor 1.1.2 |
| 36 | `827847c` | 2026-09-20 | other | Improve text tool responsiveness; version 1.1.3 |
| 37 | `37dbe59` | 2026-09-20 | release | Publish update feed for Compositor 1.1.3 |
| 38 | `f8e54b3` | 2026-09-20 | fix | Keep the font menu a fixed width; version 1.1.4 |
| 39 | `611894a` | 2026-09-20 | release | Publish update feed for Compositor 1.1.4 |
| 40 | `9f49d67` | 2026-09-20 | feature | Add folder duplication and refine layer controls; version 1.1.5 |
| 41 | `6f32adf` | 2026-09-20 | release | Publish update feed for Compositor 1.1.5 |
| 42 | `391042d` | 2026-09-20 | feature | Add folder opacity and a keyboard shortcuts window; version 1.1.6 |
| 43 | `9d5582d` | 2026-09-20 | release | Publish update feed for Compositor 1.1.6 |
| 44 | `3e4fd6a` | 2026-09-20 | other | Rulers, guides, grid and snap; version 1.1.7 |
| 45 | `08af9b0` | 2026-09-20 | release | Publish update feed for Compositor 1.1.7 |
| 46 | `8c5fade` | 2026-09-20 | other | Run Object mode before the colour wand on a canvas click |
| 47 | `886d178` | 2026-09-20 | other | Object selection in the Magic tool; version 1.1.8 |
| 48 | `c39da13` | 2026-09-20 | release | Publish update feed for Compositor 1.1.8 |
| 49 | `ac5aa88` | 2026-09-21 | format/IO | Add Photoshop PSD import as an interchange format |
| 50 | `9075348` | 2026-09-21 | docs | Cite Adobe’s 2019 Photoshop File Formats Specification in the PSD importer |
| 51 | `f833288` | 2026-09-21 | other | Skip unused Photoshop channel IDs before RLE or raw decode |
| 52 | `feedc26` | 2026-09-21 | other | Reject oversized Photoshop shape descriptors before converting them to Int |
| 53 | `8b6b484` | 2026-09-21 | other | Move Photoshop PackBits encoding out of the app target |
| 54 | `fe90f1f` | 2026-09-21 | ci/build | Split the Gradient Map lookup table so Xcode can type-check it |
| 55 | `f22847d` | 2026-09-21 | revert | Revert the Gradient Map lookup-table split |
| 56 | `a642165` | 2026-09-21 | ci/build | Make the test suite compile again |
| 57 | `121a15f` | 2026-09-21 | rendering | Blend Color Dodge and Color Burn in sRGB, not in a linear space |
| 58 | `f6a74c9` | 2026-09-21 | fix | Stop Levels converting semi-transparent pixels twice |
| 59 | `7c4512a` | 2026-09-21 | test | Update the tests that outlived the rules they assert |
| 60 | `362dde5` | 2026-09-21 | other | Split three expressions that exceed the type checker's limit |
| 61 | `6230e41` | 2026-09-21 | fix | fix: persist layer effects through project snapshots |
| 62 | `f11017a` | 2026-09-21 | rendering | Add native Outer Glow layer effect with Metal and CPU rendering |
| 63 | `5a34538` | 2026-09-21 | test | Update two tests to the rules 1.1.5 and 1.1.6 shipped |
| 64 | `16a0707` | 2026-09-21 | format/IO | Import Photoshop group opacity onto the folder |
| 65 | `f137814` | 2026-09-21 | format/IO | Offer Photoshop files in Import Images |
| 66 | `54dc7ba` | 2026-09-21 | fix | Keep a dropped file's own name |
| 67 | `cf1ae1d` | 2026-09-21 | format/IO | Show the Photoshop import sheet while the file is still being read |
| 68 | `2bb20ea` | 2026-09-21 | docs | Describe every layer effect in the format notes, and drop the added changelog |
| 69 | `7c9f821` | 2026-09-21 | docs | Note outer glow in the format documentation |
| 70 | `1a96d48` | 2026-09-21 | other | Default Outer Glow to white |
| 71 | `dbe82b0` | 2026-09-21 | fix | Keep the effects that stay visible on screen while one is hidden |
| 72 | `d9b3f9e` | 2026-09-21 | other | Let a project save with a dimmed folder |
| 73 | `90ee29f` | 2026-09-21 | other | Let text fields keep Select All |
| 74 | `8b0215e` | 2026-09-21 | feature | Add Smoothing to the brush |
| 75 | `1daf133` | 2026-09-21 | docs | List the features added since launch in the README |
| 76 | `3384e52` | 2026-09-21 | other | Use American spelling for color throughout |
| 77 | `28855e6` | 2026-09-21 | format/IO | PSD import, Outer Glow, rulers and guides; version 1.2.0 |
| 78 | `0a73424` | 2026-09-21 | release | Publish update feed for Compositor 1.2.0 |
| 79 | `691bfd4` | 2026-09-21 | other | Select the foreground layer when Auto Select clicks a stack |
| 80 | `26acd89` | 2026-09-21 | other | Select the layer under the pointer by default |
| 81 | `7111885` | 2026-09-21 | test | Update the distort tests to the folding they assert against |
| 82 | `30a8694` | 2026-09-21 | ui/ux | Pan with the middle button |
| 83 | `45ab8fd` | 2026-09-21 | ui/ux | Reshape the app icon onto Apple's grid |
| 84 | `0555d62` | 2026-09-21 | format/IO | Open camera RAW files, with a develop step |
| 85 | `12bb77c` | 2026-09-21 | format/IO | RAW import, middle-click pan, persistent tool settings; version 1.2.1 |
| 86 | `b7f3b7f` | 2026-09-21 | release | Publish update feed for Compositor 1.2.1 |
| 87 | `0d31ccb` | 2026-09-21 | feature | Add Invert, Black & White and Color Balance adjustments |
| 88 | `09a65db` | 2026-09-21 | rendering | Add Photoshop's remaining blend modes, grouped as it groups them |
| 89 | `e3fbdd1` | 2026-09-21 | rendering | Blend modes, Black & White, Color Balance and Invert; version 1.2.2 |
| 90 | `1e6cdbc` | 2026-09-21 | release | Publish update feed for Compositor 1.2.2 |
| 91 | `609dbea` | 2026-09-21 | other | Say 'or later' on the macOS requirement |
| 92 | `682e342` | 2026-09-22 | ci/build | Run the test suite on every push so a broken build shows up before review. |
| 93 | `9982fad` | 2026-09-22 | feature | Add a Camera Raw Filter workspace beside the canvas. |
| 94 | `aa4088b` | 2026-09-22 | other | Leave the Camera Raw design notes out of the change. |
| 95 | `f24dd37` | 2026-09-22 | fix | Keep a docked filter panel from moving the other filters. |
| 96 | `5ddb41e` | 2026-09-22 | fix | Keep a docked filter panel on the document window when that window moves. |
| 97 | `8837709` | 2026-09-22 | other | Remove Camera Raw upright modes that ignore the picture. |
| 98 | `a74e7f5` | 2026-09-22 | other | Remember the Camera Raw grade that OK actually applied. |
| 99 | `7cadabf` | 2026-09-22 | other | Find Camera Raw auto white balance off the main thread. |
| 100 | `f1895c7` | 2026-09-22 | docs | Describe every Camera Raw group in the panel comment. |
| 101 | `98ad817` | 2026-09-22 | feature | Add Gaussian and motion blur adjustment layers |
| 102 | `24052b5` | 2026-09-22 | feature | Add noise adjustment layers |
| 103 | `59b5040` | 2026-09-22 | other | Improve grain size behavior |
| 104 | `feb39f3` | 2026-09-22 | feature | Add Image Trim command |
| 105 | `cd0ca3c` | 2026-09-22 | feature | Add native Inner Glow layer effect |
| 106 | `95c1ddc` | 2026-09-22 | ui/ux | Match Camera Raw slider click animation |
| 107 | `d076c28` | 2026-09-22 | test | Revert "Merge pull request #67 from Cengokill/feature/verify-tests-on-push" |
| 108 | `a361901` | 2026-09-22 | other | Let the loader open the projects the app now writes |
| 109 | `8d9d692` | 2026-09-22 | fix | Correct the Camera Raw Balance slider, and the fixtures that hid it |
| 110 | `3e97eb3` | 2026-09-22 | feature | Open Camera Raw beside the window instead of docking to it |
| 111 | `6fa115e` | 2026-09-23 | ui/ux | Move layer context menu handling to table-level routing |
| 112 | `2f1e796` | 2026-09-23 | ui/ux | Add native layer actions to context menu |
| 113 | `5c5f05b` | 2026-09-23 | ui/ux | Add context-sensitive menu validation |
| 114 | `1366f68` | 2026-09-23 | test | Add layer context menu regression tests |
| 115 | `a5cd7a6` | 2026-09-22 | test | Dock Camera Raw again, now that its tests hold still |
| 116 | `dc26b6d` | 2026-09-22 | ui/ux | Fit Camera Raw's colour grading inside its panel |
| 117 | `0ecddf6` | 2026-09-22 | other | Check for updates automatically without asking first |
| 118 | `db25522` | 2026-09-22 | feature | Camera Raw, Inner Glow, Image Trim and blur and noise adjustment layers; version 1.2.3 |
| 119 | `c802b19` | 2026-09-22 | release | Publish update feed for Compositor 1.2.3 |
| 120 | `383548c` | 2026-09-22 | feature | Add stepped keyboard zoom from PR #79 |
| 121 | `8053fb6` | 2026-09-22 | ui/ux | Adjust zoom toolbar button spacing |
| 122 | `75c4219` | 2026-09-22 | fix | Keep tool rail and project tabs stable while scrolling |
| 123 | `4cc9951` | 2026-09-22 | fix | Keep the project format version in one place |
| 124 | `e08dd8c` | 2026-09-22 | feature | Add finishing filters and bump version to 1.2.4 |
| 125 | `679e66f` | 2026-09-22 | release | Publish update feed for Compositor 1.2.4 |
| 126 | `c4244c4` | 2026-09-23 | fix | Fix text tool undo and redo |
| 127 | `67301d2` | 2026-09-22 | revert | Revert "Merge pull request #93 from kaivyy/fix/text-box-undo" |
| 128 | `5ece82b` | 2026-09-22 | other | Start the crop box at the selection |
| 129 | `5d7adba` | 2026-09-22 | ui/ux | Leave Layer Effects out of the layer context menu |
| 130 | `8b5a6af` | 2026-09-22 | feature | Add 3:4 and 9:16 crop ratios (#92) |
| 131 | `5ef5b0a` | 2026-09-22 | feature | Copy and paste whole layers, within a project and between projects (#86) |
| 132 | `c873453` | 2026-09-22 | feature | Copy and paste every selected layer, not just the active one |
| 133 | `245db93` | 2026-09-22 | feature | Duplicate every selected layer with Cmd-J and Duplicate Layer |
| 134 | `2f1537f` | 2026-09-22 | other | Stack duplicates of several layers above the topmost one; Cmd-J duplicates folders |
| 135 | `bff6b8f` | 2026-09-22 | release | Compositor 1.2.5 |
| 136 | `3133e91` | 2026-09-22 | release | Publish update feed for Compositor 1.2.5 |
| 137 | `0488cab` | 2026-09-22 | other | Vignette: round by default, and paint an empty layer across the canvas |
| 138 | `cceab20` | 2026-09-22 | release | Compositor 1.2.6 |
| 139 | `5d6be39` | 2026-09-22 | release | Publish update feed for Compositor 1.2.6 |
| 140 | `f0ccb6e` | 2026-09-23 | test | Run the unit tests on every push |
| 141 | `3317d02` | 2026-09-23 | other | Preview text color changes while the color picker is open |
| 142 | `156c38c` | 2026-09-23 | docs | Document project format versions 7–9 and the additive layer fields |
| 143 | `e8ed83b` | 2026-09-23 | ui/ux | Let the title bar's free space drag the window again |
| 144 | `1fb6a3f` | 2026-09-23 | fix | Keep the tab strip's edge fade steady when a new tab opens |
| 145 | `4455a72` | 2026-09-23 | docs | Use American spelling in the project format doc |
| 146 | `4e5f4ec` | 2026-09-23 | other | Preview text color from the foreground color picker too |
| 147 | `d302214` | 2026-09-23 | release | Compositor 1.2.7 |
| 148 | `44a1c76` | 2026-09-23 | release | Publish update feed for Compositor 1.2.7 |
| 149 | `7dadc88` | 2026-09-23 | other | Give a document's total raster its own budget, separate from one surface |
| 150 | `bc865fb` | 2026-09-23 | other | Scale the document pixel budget to the Mac's memory; cap one surface at 200 MP |
| 151 | `092146a` | 2026-09-23 | release | Compositor 1.2.8 |
| 152 | `092d030` | 2026-09-23 | release | Publish update feed for Compositor 1.2.8 |
| 153 | `b8e3cd1` | 2026-09-23 | format/IO | Read Photoshop Large Document (.psb) files through the PSD importer |
| 154 | `b8cce6e` | 2026-09-23 | format/IO | Import simple Photoshop text as editable text. |
| 155 | `fa2b342` | 2026-09-23 | fix | Fix PSD text import scale and conversion edge cases |
| 156 | `a5721b2` | 2026-09-23 | feature | Open editable text on double-click |
| 157 | `96edd5f` | 2026-09-23 | other | Draw Camera Raw's grading wheels in the direction their hue runs |
| 158 | `e6bcfa1` | 2026-09-23 | format/IO | Import a background-only PSD or PSB from its merged image |
| 159 | `a2160fa` | 2026-09-23 | release | Compositor 1.2.9 |
| 160 | `292cb6b` | 2026-09-23 | other | Start clicked text on its first baseline at the pointer; keep the pointer visible while typing |
| 161 | `a0eb31c` | 2026-09-23 | release | Publish update feed for Compositor 1.2.9 |
| 162 | `01e8e52` | 2026-09-23 | docs | List the features added since launch in the README |
| 163 | `1fcf854` | 2026-09-23 | other | Crop oversized layers to the canvas when a Photoshop file would not fit |
| 164 | `072fa08` | 2026-09-23 | test | Update the text tests for text that starts on its first baseline at the click |
| 165 | `8eba077` | 2026-09-23 | other | Draw marching ants from a screen-resolution outline when zoomed out (#112) |
| 166 | `0534e00` | 2026-09-23 | format/IO | Import SVG files as image layers (#102) |
| 167 | `17d2454` | 2026-09-23 | release | Compositor 1.2.10 |
| 168 | `4306206` | 2026-09-23 | release | Publish update feed for Compositor 1.2.10 |
| 169 | `ed5ddea` | 2026-09-24 | other | Reload the open document when its package changes on disk |
| 170 | `075a71b` | 2026-09-24 | fix | Fix the app target's compiler warnings (#118) |
| 171 | `725b934` | 2026-09-24 | ci/build | Declare the PSB type in the right list and clear the remaining build warnings (#120) |
| 172 | `fe6cb2b` | 2026-09-24 | other | Show text being typed as the pixels it will be committed as (#121) |
| 173 | `b683acb` | 2026-09-24 | fix | Keep layer effects on screen while editing text, painting masks and undoing |
| 174 | `a247676` | 2026-09-24 | other | Show a mask thumbnail's background white or black, as the canvas treats it |
| 175 | `2d36d6e` | 2026-09-24 | feature | Add numeric label scrubbing and interaction coverage |
| 176 | `e753f26` | 2026-09-24 | other | Paint a layer mask anywhere on the canvas |
| 177 | `8d2eade` | 2026-09-24 | fix | Keep a moved, unlinked mask in place under layer effects |
| 178 | `2ffb092` | 2026-09-24 | other | Restore painting a layer mask anywhere on the canvas |
| 179 | `680a522` | 2026-09-24 | test | Scrub whole numbers where they belong; keep UI tests and New Canvas as they were |
| 180 | `0ecbacf` | 2026-09-24 | release | Compositor 1.2.11 |
| 181 | `c64183f` | 2026-09-24 | release | Publish update feed for Compositor 1.2.11 |
| 182 | `77cbcde` | 2026-09-25 | docs | docs: new installation method from homebrew |
| 183 | `0af5730` | 2026-09-24 | docs | Spell GitHub with a capital H in the README |
| 184 | `07cfdc6` | 2026-09-24 | docs | Drop the Homebrew upgrade command from the README: the app updates itself |
| 185 | `cdf45a5` | 2026-09-24 | docs | Keep the README's Homebrew section to the install command |
| 186 | `1e77953` | 2026-09-24 | docs | Point the README's download option at the website first |
| 187 | `cd4061a` | 2026-09-24 | ci/build | Fingerprint a project from its manifest and image sizes, not every image's bytes |
| 188 | `940e188` | 2026-09-24 | fix | Keep editing while a project saves |
| 189 | `cba6efc` | 2026-09-24 | other | Decode opened project images from memory, not from their files |
| 190 | `c317306` | 2026-09-25 | feature | Add a guide for AI agents writing Compositor projects |
| 191 | `a299f4c` | 2026-09-25 | release | Compositor 1.3 |
| 192 | `ddce078` | 2026-09-25 | release | Publish update feed for Compositor 1.3 |
| 193 | `4a4cf85` | 2026-09-25 | fix | fix(type): changed I-beam back to pointer cursor when leaving the text editing view. |
| 194 | `a18d86c` | 2026-09-25 | fix | fix(TypeTool): close the app while TypeTool editing is active |
| 195 | `221d6cc` | 2026-09-25 | fix | Keep the Type tool's I-beam over the canvas while editing text |
| 196 | `6131001` | 2026-09-25 | release | Compositor 1.3.1 |
| 197 | `c6329dc` | 2026-09-25 | release | Publish update feed for Compositor 1.3.1 |
| 198 | `73dc0f4` | 2026-09-25 | other | File > Open Recent |
| 199 | `7e9afbe` | 2026-09-25 | feature | Camera Raw: Color Grading under Color, open by default |
| 200 | `555417e` | 2026-09-25 | other | Image Size: keep print sizes through an invalid resolution |
| 201 | `6b709b4` | 2026-09-25 | ui/ux | Black & White and Color Balance: colored slider tracks with double-click reset |
| 202 | `d62a132` | 2026-09-25 | other | Always dark, including alerts and open/save panels |
| 203 | `2bfc4ea` | 2026-09-25 | feature | Type: color only the selected letters of the text being edited |
| 204 | `c8ed9ba` | 2026-09-25 | ui/ux | Hue/Saturation: colored slider tracks with double-click reset |
| 205 | `0c969af` | 2026-09-25 | other | Filters: line up sliders to the widest title |
| 206 | `4503998` | 2026-09-25 | feature | Type: keep a text selection when the color swatch is clicked |
| 207 | `b5fe653` | 2026-09-25 | feature | Type colors: swatch follows the caret, selection stays see-through under the picker |
| 208 | `810c88a` | 2026-09-25 | fix | Sampling for a panel keeps its focus, and text editing gets the keys back |
| 209 | `d448625` | 2026-09-25 | other | Filters, adjustments and Invert wait for text editing to finish |
| 210 | `ff7e039` | 2026-09-25 | release | Compositor 1.3.2 |
| 211 | `0eaeb98` | 2026-09-25 | feature | Type: apply a font change to the selected letters |
| 212 | `6db1b20` | 2026-09-25 | release | Publish update feed for Compositor 1.3.2 |
| 213 | `1ffc8f4` | 2026-09-25 | ui/ux | Type: let a mixed selection take the face the menu already shows |
| 214 | `9593bf5` | 2026-09-25 | feature | Add the review of the per-letter font change |
| 215 | `f3cd4e9` | 2026-09-25 | rendering | Filter › Dither |
| 216 | `71635e2` | 2026-09-25 | rendering | Filter menu: Dither under Bloom / Glow |
| 217 | `29f0bea` | 2026-09-25 | ci/build | Guide: an unchanged manifest doesn't trigger a reload |
| 218 | `d0aae29` | 2026-09-25 | rendering | Dither: fewer styles |
| 219 | `09ab78a` | 2026-09-25 | rendering | Dither: Pixel Shape, and chunky pixels by default |
| 220 | `e70da06` | 2026-09-25 | feature | Opening a project while Compositor is quit shows its window |
| 221 | `5888be2` | 2026-09-25 | release | Compositor 1.3.3 |
| 222 | `aba3077` | 2026-09-25 | release | Publish update feed for Compositor 1.3.3 |
| 223 | `2309a85` | 2026-09-25 | rendering | Dither: ASCII as readable text |
| 224 | `bc29006` | 2026-09-26 | feature | Drop the review note and the font-width assertion |
| 225 | `916d1ab` | 2026-09-26 | ui/ux | Type: the font menu says (Multiple) for a selection in several faces |
| 226 | `c3e360a` | 2026-09-26 | feature | Select › Color Range |
| 227 | `ab99b60` | 2026-09-26 | release | Compositor 1.3.4 |
| 228 | `c28f827` | 2026-09-26 | release | Publish update feed for Compositor 1.3.4 |
| 229 | `908bed9` | 2026-09-27 | other | Hop to the main actor instead of asserting it on activation |
| 230 | `158cd53` | 2026-09-27 | fix | Fix the compiler warnings in the external-changes watcher |
| 231 | `c580a38` | 2026-09-27 | format/IO | Export JPEG and Canvas Size use the app's color picker |
| 232 | `d6e3e93` | 2026-09-27 | other | Marquee and shapes snap to View › Snap To |
| 233 | `ac6f309` | 2026-09-27 | format/IO | Export JPEG: zoomable preview and a tidier layout |
| 234 | `1c819d0` | 2026-09-27 | feature | View › Grid Settings… |
| 235 | `250578e` | 2026-09-27 | ci/build | Xcode 27's recommended project settings |
| 236 | `8b1369a` | 2026-09-27 | other | Moving a selection snaps to View › Snap To |
| 237 | `db5eafa` | 2026-09-27 | other | Grid Settings: Restore Defaults, as Keyboard Shortcuts calls it |
| 238 | `ee68ba9` | 2026-09-27 | other | ⌘Z while typing takes back what was typed |
| 239 | `38ec6f7` | 2026-09-27 | other | Runs on macOS 26.0 and later, Apple silicon only |
| 240 | `1bd1df4` | 2026-09-27 | other | Font previews in the Type bar |
| 241 | `4f11bb5` | 2026-09-27 | release | Compositor 1.3.5 |
| 242 | `0c56c86` | 2026-09-27 | release | Publish update feed for Compositor 1.3.5 |
| 243 | `14aad18` | 2026-09-27 | other | Finder thumbnails and Quick Look previews for projects |
| 244 | `aaf3dc0` | 2026-09-27 | ui/ux | New Canvas: preset sizes in a More menu |
| 245 | `5809fe9` | 2026-09-27 | release | Compositor 1.3.6 |
| 246 | `8294fc4` | 2026-09-27 | release | Publish update feed for Compositor 1.3.6 |
| 247 | `4868465` | 2026-09-27 | ci/build | Save only the Quick Look preview, and a warning-free release build |
| 248 | `9e2894e` | 2026-09-27 | release | Compositor 1.3.7 |
| 249 | `e2440b4` | 2026-09-27 | release | Publish update feed for Compositor 1.3.7 |
| 250 | `8c0417b` | 2026-09-28 | format/IO | Sharper canvas with adjustment layers, and PSD adjustment and mask fixes |
| 251 | `fe7a83d` | 2026-09-28 | other | Match Photoshop's positive Saturation in Hue/Saturation |
| 252 | `af3b568` | 2026-09-28 | perf | Run Levels and Hue/Saturation across all cores |
| 253 | `cdf8674` | 2026-09-28 | rendering | Draw the canvas on the GPU |
| 254 | `4b04323` | 2026-09-28 | rendering | Move selected pixels on the GPU |
| 255 | `5708ed3` | 2026-09-28 | rendering | Paint, drag gradients and smudge on the GPU canvas |
| 256 | `dcf1c66` | 2026-09-28 | other | Work out visible layers once per canvas check |
| 257 | `d0135c8` | 2026-09-28 | fix | Keep the layer hierarchy until what shapes it changes |
| 258 | `93de9e7` | 2026-09-28 | rendering | Show a new mask's layer whole on the GPU canvas |
| 259 | `54dd707` | 2026-09-28 | rendering | Run every adjustment on the GPU canvas |
| 260 | `3ccc125` | 2026-09-28 | fix | Keep a blur's preview up while it grows the layer |
| 261 | `91cb0b1` | 2026-09-28 | rendering | Run Smudge and Liquify on the GPU |
| 262 | `6dc2219` | 2026-09-28 | rendering | Sharpen clipping stacks and blend every mode for adjustments |
| 263 | `f773f7b` | 2026-09-28 | rendering | Draw every canvas frame on the GPU |
| 264 | `8ab32c9` | 2026-09-28 | rendering | Blend clipping stacks in every mode off the GPU canvas |
| 265 | `5a8f6ce` | 2026-09-28 | rendering | Compute Soft Light through Core Image everywhere |
| 266 | `e6c964b` | 2026-09-28 | test | Test soft-edged layers in blend modes on both canvases |
| 267 | `4c5e1a6` | 2026-09-28 | rendering | Hold less on the GPU when zoomed out or idle |
| 268 | `b1b7490` | 2026-09-28 | test | Report where an edge-painting test's mask stroke parts from the layer |
| 269 | `3b3f6ca` | 2026-09-28 | docs | README: Photoshop is what I used before Compositor |
| 270 | `60bde4f` | 2026-09-28 | fix | Shift keeps moved pixels on a straight line |
| 271 | `451281e` | 2026-09-28 | ui/ux | Cmd-A selects the canvas from the Layers panel too |
| 272 | `2fbf14f` | 2026-09-28 | release | Compositor 1.4 |
| 273 | `d04f159` | 2026-09-28 | rendering | Copy tiles into GPU-drawn textures on the GPU |
| 274 | `de442f2` | 2026-09-28 | release | Publish update feed for Compositor 1.4 |
| 275 | `133c34a` | 2026-09-28 | other | Say why a brush can't paint, and let Select All then Inverse deselect |
| 276 | `d3170ab` | 2026-09-28 | other | Clone Stamp and Blur paint at the layer's own resolution |
| 277 | `67cc31e` | 2026-09-28 | other | Show Cancel and Apply only when an edit waits for them; give scaled layers their scale |
| 278 | `b3419ab` | 2026-09-28 | ui/ux | Masks follow Photoshop: the button reveals the selection, and Option-click shows a mask alone |
| 279 | `bca8f13` | 2026-09-28 | ui/ux | Command flips Auto Select both ways, and Shift the aspect lock, live in the options bar |
| 280 | `1faf7a0` | 2026-09-28 | fix | Tabs: drag to reorder them, and gather the ones that don't fit into a menu |
| 281 | `1318f1e` | 2026-09-28 | feature | Ungroup Layers (⇧⌘G) |
| 282 | `03d692c` | 2026-09-28 | test | Drop the held-Command checkbox test |
| 283 | `6c3b9a5` | 2026-09-28 | ui/ux | Ungroup Layers in a folder's right-click menu |
| 284 | `6955a6f` | 2026-09-28 | other | Option over a mask thumbnail: the duplicate pointer with a small eye |
| 285 | `686d8c7` | 2026-09-28 | other | Move bar values apply without Apply, as one undo step |
| 286 | `c459f88` | 2026-09-28 | other | Resize handles snap, as moving does |
| 287 | `0d9986f` | 2026-09-28 | release | Compositor 1.4.1 |
| 288 | `3b50e5d` | 2026-09-28 | release | Publish update feed for Compositor 1.4.1 |
| 289 | `7164dd4` | 2026-09-29 | fix | Liquify keeps pixels sharp, as Photoshop's does |
| 290 | `ad9ad7c` | 2026-09-29 | other | Smudge without ghost copies, as Photoshop's does |
| 291 | `504129d` | 2026-09-29 | other | Blur brush has its own Radius, apart from Strength |
| 292 | `ed9c280` | 2026-09-29 | release | Compositor 1.4.2 |
| 293 | `0787b60` | 2026-09-29 | release | Publish update feed for Compositor 1.4.2 |
| 294 | `095da2f` | 2026-09-29 | perf | Blur, Smudge and Liquify keep up on big canvases |
| 295 | `557d2f0` | 2026-09-29 | release | Compositor 1.4.3 |
| 296 | `3a2798b` | 2026-09-29 | release | Publish update feed for Compositor 1.4.3 |
| 297 | `1aad384` | 2026-09-29 | ui/ux | Quit works mid-gradient or with a dialog open |
| 298 | `9c99853` | 2026-09-29 | rendering | Dither › Scanlines (CRT), with glow, dots and wobble |
| 299 | `cd2f998` | 2026-09-29 | perf | Scanlines renders across all cores, with a quicker glow |
| 300 | `ec02559` | 2026-09-29 | release | Compositor 1.4.4 |
| 301 | `2187cbf` | 2026-09-29 | release | Publish update feed for Compositor 1.4.4 |
| 302 | `60d9117` | 2026-09-29 | feature | Camera Raw curves behave as Photoshop's |
| 303 | `086f163` | 2026-09-29 | release | Compositor 1.4.5 |
| 304 | `11d8d7a` | 2026-09-29 | release | Publish update feed for Compositor 1.4.5 |
| 305 | `94e90bd` | 2026-09-29 | fix | Keep layer effects and live text through size changes and adjustments |
| 306 | `cb139a1` | 2026-09-29 | ui/ux | Command palette (⌥⌘P): search every menu command and tool |
| 307 | `6490bb3` | 2026-09-29 | ui/ux | Navigator above the Layers panel |
| 308 | `f745d65` | 2026-09-29 | feature | Camera Raw: reset each section from its header |
| 309 | `a2718d9` | 2026-09-29 | feature | Camera Raw color noise reduction: clear pixels count as unsaturated |
| 310 | `0415aa4` | 2026-09-30 | feature | Filter › Last Filter (⌘F): the last filter again, with the same settings |
| 311 | `9287cf1` | 2026-10-01 | format/IO | File > Export PDF |
| 312 | `07eee7e` | 2026-10-04 | test | Slider snap test draws its slider before pressing it |
| 313 | `b0b4f01` | 2026-10-07 | feature | New Canvas in inches, cm or mm, at 72 or 300 DPI |
| 314 | `ab9779a` | 2026-10-07 | feature | New Canvas: transparent, white or black, with every setting a pill |
| 315 | `a00d8b6` | 2026-10-07 | feature | New Canvas always starts transparent, in pixels, at 72 DPI |
| 316 | `e7e295e` | 2026-10-08 | other | Color Overlay recolors translucent pixels fully, as in Photoshop |
| 317 | `f25effa` | 2026-10-07 | ui/ux | Layer effects button: "Add layer effect" |
| 318 | `9cb57db` | 2026-10-07 | other | Inner Glow and Inner Shadow recolor translucent pixels fully, as in Photoshop |
| 319 | `710dd66` | 2026-10-07 | ui/ux | Edit menu without macOS's text extras |
| 320 | `6345432` | 2026-10-07 | fix | RAW imports round to 8 bits with fine noise, so gradients don't band |
| 321 | `0907f51` | 2026-10-07 | format/IO | RAW develop sheet shows Importing… until the layer is in |
| 322 | `196342c` | 2026-10-07 | format/IO | RAW import rounds in C: 0.6 s instead of 15 s in debug builds |
| 323 | `754f188` | 2026-10-07 | feature | Image › Rotate Canvas 90° Clockwise and Counterclockwise |
| 324 | `384632d` | 2026-10-07 | ui/ux | Command palette on F, centered on the window |
| 325 | `231b7d3` | 2026-10-07 | test | Command palette: keep the three tests that matter |
| 326 | `07b8b1e` | 2026-10-07 | ui/ux | Command palette: tools and their modes by name, whole words first, Return runs the chosen row, list runs to the bottom edge |
| 327 | `94b57f7` | 2026-10-07 | ui/ux | Command palette: F anywhere in the editor, layer masks, typed words ranked, shorter panel |
| 328 | `bba92dc` | 2026-10-07 | ui/ux | One View › Snap for all snapping; palette shows which toggles are on |
| 329 | `42a559b` | 2026-10-07 | feature | Camera Raw Color noise reduction smooths color, keeping brightness |
| 330 | `ad4bddf` | 2026-10-07 | ui/ux | Canvas Only (F): the canvas alone on black over the whole screen; palette on ⌘F |
| 331 | `75f3556` | 2026-10-07 | docs | README: command palette on ⌘F, Canvas Only on F |
| 332 | `088a5c1` | 2026-10-07 | ui/ux | Canvas Only covers the window's rim and corners in black; narrower palette |
| 333 | `e64f749` | 2026-10-07 | release | Compositor 1.4.6 |
| 334 | `6e6ca38` | 2026-10-07 | ci/build | RawDitherTests: split an expression CI's compiler couldn't type-check in time |
| 335 | `fa41b9b` | 2026-10-07 | release | Publish update feed for Compositor 1.4.6 |
| 336 | `6b81d4a` | 2026-10-08 | ui/ux | Last Filter on ⌃⌘F, as in Photoshop: ⌘F is the command palette |
| 337 | `720c121` | 2026-10-08 | ui/ux | Toggle Fullscreen on F (shown in the menu) and Esc; Search Commands on ⌘F |
| 338 | `c0a1cd0` | 2026-10-08 | other | The hand stays closed for a whole Space or Hand tool pan |
| 339 | `7fb40a9` | 2026-10-07 | feature | Layers footer buttons use the primary color, for readability |
| 340 | `283d360` | 2026-10-07 | ui/ux | `Don't Save` button in the unsaved-changes dialog is marked as destructive |
| 341 | `8f7d344` | 2026-10-08 | other | `LayerCell`'s name field stays the same size while renaming, marking the editing state with a layer background instead of a bezel |
| 342 | `68396ff` | 2026-10-08 | other | Tool headers scroll when the window is too narrow, instead of squeezing |
| 343 | `790195f` | 2026-10-08 | other | Disabled Layers footer buttons dim as far as its menus do |
| 344 | `675d8a4` | 2026-10-08 | release | Compositor 1.4.7 |
| 345 | `af30c45` | 2026-10-08 | release | Publish update feed for Compositor 1.4.7 |
| 346 | `d2b8aaf` | 2026-10-09 | ui/ux | Reveal selected layers in the Layers panel |
| 347 | `0b4c56c` | 2026-10-08 | feature | Camera Raw Shadows and Highlights keep tones in order |
| 348 | `4e035bf` | 2026-10-08 | ui/ux | Don't Save matches Cancel, leaving Save the one colored button |
| 349 | `cea9083` | 2026-10-08 | docs | README: translations are on hold |
| 350 | `b4e147b` | 2026-10-08 | test | Layers panel reveal: no separate test file |
| 351 | `06313a9` | 2026-10-08 | fix | Layers panel doesn't flash gray for a click, a stroke or a moment's work |
| 352 | `450af5f` | 2026-10-08 | format/IO | File › Export As…: PNG, JPEG or PDF, sized and previewed |
| 353 | `b1db93d` | 2026-10-08 | format/IO | Export As previews transparency on the canvas's checkerboard |
| 354 | `06c3a22` | 2026-10-08 | feature | Filter › Scanlines: its own filter, with Displace, Threshold, Thickness and Color Split |
| 355 | `1187736` | 2026-10-08 | other | Scanlines: smoothed displacement with lines hiding those behind, ±100 px, and Dots by tone |
| 356 | `cdde327` | 2026-10-08 | other | Scanlines show on solid colors: Black Level, glow that eases off near white, no glow by default |
| 357 | `e1a5210` | 2026-10-08 | docs | README lists Dither and Scanlines among the filters |
| 358 | `3e09948` | 2026-10-08 | feature | Navigator as a minimap in the canvas's corner from 300% zoom |
| 359 | `24ef288` | 2026-10-08 | release | Version 1.4.8 |
| 360 | `22c7b8d` | 2026-10-08 | release | Publish update feed for Compositor 1.4.8 |
| 361 | `5724099` | 2026-10-09 | format/IO | Add WebP image import support |
| 362 | `e03923f` | 2026-10-09 | other | Command or Control with a middle drag zooms, as in Blender |
| 363 | `57ab3bb` | 2026-10-09 | feature | Camera Raw's Light and Color sliders match Photoshop's Camera Raw Filter |
| 364 | `75147a2` | 2026-10-09 | feature | Camera Raw: adaptive Contrast, Highlights and Shadows; Dehaze, Texture, Clarity and Sharpening nearer Photoshop |
| 365 | `bdfb9c2` | 2026-10-09 | feature | Camera Raw: Color Mixer, Calibration, curve, vignettes and Color Grading match Photoshop |
| 366 | `9dac4f1` | 2026-10-09 | feature | Camera Raw: Color Grading measured at Photoshop's real Blending, all four wheels |
| 367 | `7b5a592` | 2026-10-09 | feature | Camera Raw tables: 3.2 MB to 1.25 MB |
| 368 | `a8630e4` | 2026-10-09 | perf | Camera Raw preview 5 to 20 times faster |
| 369 | `d0ec2f3` | 2026-10-09 | ui/ux | Tabs: the blank start tab stays put, and Untitled numbers stay low |
| 370 | `759bcbe` | 2026-10-09 | ui/ux | Update alert lists what's new, in the same compact dialog |
| 371 | `0ab3ff5` | 2026-10-09 | release | Version 1.4.9 |
| 372 | `b4bfdea` | 2026-10-09 | release | Publish update feed for Compositor 1.4.9 |
| 373 | `518d0bf` | 2026-10-10 | ci/build | CI in about 4 minutes: tests side by side, optimized builds, filter suites when touched |
| 374 | `7311d69` | 2026-10-10 | fix | Tool options bars never show a scroll bar |
| 375 | `3081719` | 2026-10-10 | ci/build | CI: screenshots of the main screens |
| 376 | `0a5c8d9` | 2026-10-11 | fix | Layers panel at its narrowest keeps everything inside it |
| 377 | `b2a0c45` | 2026-10-11 | format/IO | Import a folder of images as layers |
| 378 | `9a0ad3e` | 2026-10-11 | other | Gaussian Blur: Preserve Transparency, solid edges at the canvas, 5 px to start |
| 379 | `248d4d4` | 2026-10-11 | format/IO | RAW develop: Noise Reduction, Lens Correction and Highlight Recovery |
| 380 | `23913d3` | 2026-10-11 | other | Spot Healing and Content-Aware Fill rebuild with multi-scale PatchMatch |
| 381 | `39d1257` | 2026-10-11 | other | Content-Aware Fill carries busy texture to the edge of what it fills |
| 382 | `70b3e14` | 2026-10-11 | format/IO | Import HEIF files from cameras (.hif, .heif) |
| 383 | `ce5ea67` | 2026-10-11 | ui/ux | New app icon: a page of color peeling back to transparency |
| 384 | `eb1fda7` | 2026-10-11 | release | Version 1.4.10 |
| 385 | `a1bd74c` | 2026-10-11 | release | Publish update feed for Compositor 1.4.10 |
| 386 | `bdcedf2` | 2026-10-11 | format/IO | 16-bit images are dithered to 8 bits on import, not rounded |
| 387 | `216be97` | 2026-10-11 | format/IO | Ignore the local HDR plans (HDR_*.md) |
| 388 | `d9cdb81` | 2026-10-11 | rendering | 16-bit layers: imported 16-bit images keep their precision |
| 389 | `6aea90a` | 2026-10-11 | rendering | 16-bit layers: adjustments, Liquify, Smudge and Blur keep 16 bits |
| 390 | `2b9603f` | 2026-10-11 | rendering | 16-bit layers: Hue/Saturation and color adjustments without banding |
| 391 | `f01e298` | 2026-10-11 | rendering | Blur tool on a 16-bit layer: no banding while painting |
| 392 | `93f8e8d` | 2026-10-11 | rendering | 16-bit blurs run once in Core Image; keep pixel buffers alive in C calls |
| 393 | `3d2ada4` | 2026-10-11 | rendering | 16-bit layers: Camera Raw and other 8-bit tools without banding |
| 394 | `2fe3524` | 2026-10-11 | rendering | Convert layers between 8 and 16 bits; 16-bit gradients and fills |
| 395 | `a65313a` | 2026-10-11 | test | Give each test process its own pasteboard |
| 396 | `2522e3b` | 2026-10-11 | feature | Paste an image on the New canvas screen to make the canvas |
| 397 | `067fca4` | 2026-10-11 | ui/ux | Layers panel: adjustment layer button before layer effects |
| 398 | `d3d0ce7` | 2026-10-11 | ui/ux | Drop anywhere on the tab bar to open in a new project |
| 399 | `e580107` | 2026-10-11 | other | A layer dragged into a new project sizes the canvas to it |
| 400 | `7f239dc` | 2026-10-11 | format/IO | HDR layers: import EXR and Radiance HDR, keeping light brighter than white |
| 401 | `a10fcb7` | 2026-10-11 | format/IO | HDR layers keep their highlights through edits |
| 402 | `b9186f7` | 2026-10-11 | format/IO | HDR: EXR export, and adjustment layers that reveal highlights live |
| 403 | `5a2e57f` | 2026-10-11 | format/IO | HDR layers convert to 16-bit; depth tag reads "16-Bit" and refreshes |
| 404 | `f5ae5ba` | 2026-10-11 | format/IO | Export As: JPEG and PNG first, PDF and EXR under More |
| 405 | `59025aa` | 2026-10-12 | format/IO | CMYK for print: proof on the canvas and CMYK export |
| 406 | `896d5c8` | 2026-10-12 | format/IO | Open CMYK Photoshop files, and remember a CMYK file's profile |
| 407 | `dac3bc6` | 2026-10-12 | format/IO | Export As: a quieter Color choice, always starting on RGB |
| 408 | `1071f4f` | 2026-10-12 | release | Version 1.5 |
| 409 | `3beab33` | 2026-10-12 | release | Publish update feed for Compositor 1.5 |
| 410 | `905efc5` | 2026-10-12 | rendering | 16-bit layers on the canvas at 16 bits, dithered to the screen |
| 411 | `3ae11cd` | 2026-10-12 | feature | Filter › Progressive Blur |
| 412 | `539a78d` | 2026-10-12 | release | Version 1.5.1 |
| 413 | `5a18e8b` | 2026-10-12 | release | Publish update feed for Compositor 1.5.1 |
| 414 | `5e9033f` | 2026-10-12 | other | Update alert in the wide layout every time |
| 415 | `f2747c4` | 2026-10-12 | release | Update feed: list 1.5's highlights with 1.5.1's changes |
| 416 | `87e2283` | 2026-10-12 | format/IO | Keyboard Shortcuts: clear a shortcut, keys for CMYK proofing, two fixes |
| 417 | `b8ff682` | 2026-10-12 | ui/ux | Show Camera Raw section reset only alongside its eye icon |
| 418 | `e8c9e29` | 2026-10-12 | other | Move Camera Raw scrollbar clear of the controls |
| 419 | `735c2cc` | 2026-10-13 | feature | Camera Raw Shadows adapts to the picture as Photoshop's does |
| 420 | `a3a0e29` | 2026-10-13 | format/IO | RAW import: Camera Raw… imports, then opens the Camera Raw Filter |
| 421 | `f2d5754` | 2026-10-13 | release | Version 1.5.2 |
| 422 | `43d691b` | 2026-10-13 | release | Publish update feed for Compositor 1.5.2 |
| 423 | `9f1d158` | 2026-10-14 | feature | Add smooth rectangle corners and simplify shape controls |
| 424 | `9b3f48e` | 2026-10-14 | other | Disable smooth corners when rectangle radius is zero |
| 425 | `92eba05` | 2026-10-14 | feature | Add middle-mouse dragging to scroll the layer list |
| 426 | `fc4c273` | 2026-10-14 | other | Update zoom cursors immediately when drag direction changes |
| 427 | `f4b7009` | 2026-10-14 | fix | Keep Camera Raw previews at native resolution during adjustments |
| 428 | `cf0ffa1` | 2026-10-14 | perf | Reduce Camera Raw scope sampling and benchmark preview latency |
| 429 | `9329ab8` | 2026-10-14 | perf | Accelerate large Camera Raw previews with verified Metal lookup |
| 430 | `554104c` | 2026-10-14 | release | Version 1.5.3 |
| 431 | `365b574` | 2026-10-14 | release | Publish update feed for Compositor 1.5.3 |

## GNU_Linux-specific development (every non-merge commit not in upstream)

| # | Commit | Date | Category | Subject |
|---:|---|---|---|---|
| 1 | `fd4feef` | 2026-09-19 | other | chore: add gstack skill routing rules to CLAUDE.md |
| 2 | `bbb2b7a` | 2026-09-19 | docs | docs: add Linux port plan and file-by-file disposition |
| 3 | `5a99292` | 2026-09-19 | feature | feat(abi): add C ABI seam for the Linux port (ENG-1) |
| 4 | `3c07533` | 2026-09-19 | ci/build | feat(kernels): bring portable C pixel kernels under the build (ENG-17) |
| 5 | `25e8c66` | 2026-09-19 | feature | feat(host): Qt6 composition root and open/filter/save shell (ENG-2) |
| 6 | `f7193c4` | 2026-09-19 | ci/build | feat(build): Flatpak manifest + vendored Skia/OpenCV, block host-system Qt |
| 7 | `62daf4c` | 2026-09-19 | ci/build | feat(build): proven Flatpak build spine — Swift compiles in-sandbox, runtime-only launch |
| 8 | `a940815` | 2026-09-19 | feature | feat(core): portable CGAffineTransform + CG geometry glue (ENG-1 core tier) |
| 9 | `d51b03a` | 2026-09-19 | fix | feat(core): port CanvasSize + CanvasViewport (Keep-logic tier, geometry-only) |
| 10 | `f51cede` | 2026-09-19 | feature | feat(core): portable canonical raster buffers + PortableImage (raster substrate) |
| 11 | `1875f35` | 2026-09-19 | feature | feat(core): portable transform math + BrushRaster pure math (transform tier) |
| 12 | `4dda4c3` | 2026-09-19 | feature | feat(core): portable settings-data layer (levels/curves/exposure/gradient/grain/hue-sat/filters) |
| 13 | `3916c4f` | 2026-09-19 | feature | feat(core): portable LayerAdjustment + AdjustmentKind data layer |
| 14 | `2db0c30` | 2026-09-19 | feature | feat(core): portable document-model core (layers, mask, selection, shape, transform edit) |
| 15 | `300730e` | 2026-09-19 | fix | feat(core): portable history + layer/gradient/clone ops (Keep-logic tier) |
| 16 | `9ed5759` | 2026-09-19 | feature | feat(core): portable color-picker math + brush modes + levels auto/sample |
| 17 | `97192e1` | 2026-09-19 | feature | feat(core): portable crop/wand/distort/guided-matte geometry + brush settings |
| 18 | `f323b6d` | 2026-09-19 | feature | feat(core): portable project-record + layer hierarchy + live-mask graph + selection geometry |
| 19 | `dd0cc0c` | 2026-09-19 | feature | feat(core): portable MaskTracing marching-squares outline algorithm |
| 20 | `59d79bb` | 2026-09-19 | ci/build | feat(core): portable project manifest + validation + shape outline path |
| 21 | `0989464` | 2026-09-19 | feature | feat(core): portable LayerMerge merge-plan logic |
| 22 | `2b3f02f` | 2026-09-19 | ci/build | fix(build): link Swift static runtime set for CMake-linked host binary |
| 23 | `162200c` | 2026-09-19 | ci/build | feat(core): portable BrushStroke CPU engine + kernels in SwiftPM |
| 24 | `fa4a56b` | 2026-09-19 | feature | feat(core): portable RasterSnapshot — sparse tiles, lazy materialization |
| 25 | `efd8c93` | 2026-09-19 | feature | feat(core): portable raster core — LayerRenderer, GaussianBlur, WarpStroke, PixelAdjust |
| 26 | `67119e9` | 2026-09-19 | feature | feat(core): portable editor session, filter/resize execution, C ABI bridge |
| 27 | `7bb727d` | 2026-09-19 | feature | feat(core): portable PixelMove + Clone Stamp geometry, path transforms |
| 28 | `915e5a5` | 2026-09-19 | ci/build | chore: ignore CMake build-cmake directory |
| 29 | `38f06d3` | 2026-09-19 | feature | feat(core): verify session journey via Swift XCTest; document composition-root constraint |
| 30 | `ef9a4e0` | 2026-09-19 | feature | feat(core): Swift @main composition-root bootstrap (unblocks host journey) |
| 31 | `b600d46` | 2026-09-19 | feature | feat(host): compositor_host_run C entry + CompositorHostRun static lib |
| 32 | `e425881` | 2026-09-19 | ci/build | feat(host): wire Swift @main -> Qt composition root; fix Flatpak manifest |
| 33 | `e1fab86` | 2026-09-19 | docs | docs(port): add ImageIO→Qt codec mapping; record verified composition root |
| 34 | `0b54eb6` | 2026-09-19 | test | test(port): verify save/reopen render→import_rgba round-trip |
| 35 | `b81b916` | 2026-09-19 | test | test(port): port macOS viewport-geometry assertions to Linux suite |
| 36 | `1a76f36` | 2026-09-19 | feature | feat(port): port grouping/selection logic; align createDocument with macOS |
| 37 | `8cc8b1d` | 2026-09-19 | feature | feat(host): moc'd Q_OBJECT Qt window drives Swift core via C ABI |
| 38 | `b0766e5` | 2026-09-19 | docs | docs(port): record moc'd Qt SessionWindow milestone in file map |
| 39 | `d948714` | 2026-09-19 | test | test(io): verify PNG RGBA8888 codec round-trip (ImageIO→Qt mapping) |
| 40 | `44bd76f` | 2026-09-19 | docs | docs(port): record PNG RGBA8888 codec round-trip verification |
| 41 | `4e4e5aa` | 2026-09-19 | rendering | feat(port): portable operations batch + Vulkan brush backend |
| 42 | `51ba560` | 2026-09-19 | feature | feat(port): distort raster warp + commit as one undo step |
| 43 | `0384f8e` | 2026-09-19 | feature | feat(port): floating selection transform + duplicate as one undo step |
| 44 | `088e045` | 2026-09-19 | docs | docs(port): align adjustment/filter/color rows with implemented, tested state |
| 45 | `6833b69` | 2026-09-19 | docs | docs(port): align mask/selection/magic-wand rows with implemented, tested state |
| 46 | `820c6dc` | 2026-09-19 | feature | feat(port): magic wand flood selection |
| 47 | `d5d42b4` | 2026-09-19 | feature | feat(port): guided matte refinement |
| 48 | `936b051` | 2026-09-19 | test | test(core): renderer folder and live-mask integration |
| 49 | `a81e2c8` | 2026-09-20 | feature | feat(port): Qt adjustment sheets for all six adjustment kinds |
| 50 | `c40d43e` | 2026-09-20 | test | test(port): Qt layers dock round-trip smoke |
| 51 | `e725efe` | 2026-09-20 | rendering | feat(port): Qt brush palette and blend-mode dock |
| 52 | `95021ee` | 2026-09-20 | ui/ux | feat(port): layer visibility/mask toggles and selection-fill menu |
| 53 | `155edd5` | 2026-09-20 | docs | docs(plan): finalize multi-phase convergence plan and review for Linux port |
| 54 | `2f49459` | 2026-09-20 | ci/build | build(deps): update Skia and OpenCV pins and CMake build integration |
| 55 | `8ad6b79` | 2026-09-20 | feature | feat(graphics): implement CoreGraphicsCompat shim, SkiaBridge, and Qt host hooks |
| 56 | `58bdc12` | 2026-09-20 | ci/build | fix(packaging): align Flatpak manifests with Freedesktop Swift 6 extension |
| 57 | `c53e66c` | 2026-09-20 | rendering | feat(graphics): implement SkiaBridge Vulkan query, safe pointer handling, and ctest integration |
| 58 | `310ac7f` | 2026-09-20 | ui/ux | feat(ui): refactor Qt layers dock to hierarchical QTreeView with folder and mask support |
| 59 | `671890f` | 2026-09-20 | rendering | feat(graphics): implement Stage 8 Vulkan backend with device-lost fallback |
| 60 | `ba7d660` | 2026-09-20 | ui/ux | feat(ui,core): implement Stage 9 complete editing tools parity |
| 61 | `3fb4455` | 2026-09-20 | feature | feat(graphics): implement Stage 10 OpenCV inpainting and guided filter bridge |
| 62 | `3ab3dc3` | 2026-09-20 | feature | feat(desktop): implement Stage 11 XDG desktop portals, clipboard, and drag-and-drop integration |
| 63 | `65ec61a` | 2026-09-20 | feature | feat(stage-12): achieve 100% parity across stages 8-12 with SOLID interfaces |
| 64 | `e3f2097` | 2026-09-20 | fix | fix(ui): introduce central canvas widget and professional desktop layout |
| 65 | `b233f28` | 2026-09-20 | fix | fix(host): defer refreshLayers via QueuedConnection to prevent use-after-free in itemChanged |
| 66 | `ff47e01` | 2026-09-20 | other | WIP. |
| 67 | `9476817` | 2026-09-21 | feature | feat(linux): converge rendering through CoreGraphicsCompat, tighten sandbox, enforce canonical tile contract |
| 68 | `b8f40f0` | 2026-09-21 | fix | fix(qa): ISSUE-001 — Adjust dialogs failed first preview (missing curves in payload) |
| 69 | `d25723f` | 2026-09-21 | test | test(qa): regression test for ISSUE-001 — Adjust dialog first preview |
| 70 | `a09e87a` | 2026-09-21 | test | WIP test(skia): add partial-alpha source-over test that fails on the memcpy bridge stub |
| 71 | `bf40010` | 2026-09-21 | ci/build | feat(skia): composite through real Skia raster backend and wire cache paths in CMake |
| 72 | `3d617c7` | 2026-09-21 | test | feat(graphics): implement Stage 4/5 Canvas C ABI and integration test |
| 73 | `39f1d88` | 2026-09-21 | feature | feat(graphics): implement Stage 4/5 Step 5 CoreGraphicsCompat shims |
| 74 | `02a8178` | 2026-09-21 | test | feat(graphics): implement Stage 4/5 Step 7 CoreGraphics parity test suite with dynamic Skia bridge |
| 75 | `835a7f0` | 2026-09-21 | feature | feat(graphics): implement Stage 4/5 Step 8 COMPOSITOR_RENDERER env switch and document parity verification |
| 76 | `f5e436a` | 2026-09-21 | ci/build | docs: align Flatpak SDK runtime and Swift extension versions with manifest |
| 77 | `dbcd872` | 2026-09-21 | test | test(io): add persistence hardening tests for EditorSession.importManifest |
| 78 | `e4ed66d` | 2026-09-21 | feature | feat(host): implement Command Palette, Adjustment Discard, Multi-Selection, and Autosave |
| 79 | `717aa35` | 2026-09-21 | ui/ux | feat(ui): implement macOS dark theme, document tab header, and dynamic options bar |
| 80 | `d6690ce` | 2026-09-21 | ui/ux | feat(ui): redesign layers panel with eye toggle, thumbnails, size subtitles and icon action bar |
| 81 | `99c84e4` | 2026-09-21 | ui/ux | feat(ui): bind Move/Transform bar to layer geometry, add on-canvas handles, fix layer order and zoom readout |
| 82 | `e0862cb` | 2026-09-21 | ui/ux | feat(ui): Levels histogram, Hue/Saturation range bars, slider+field rows and foreground colour picker dialog |
| 83 | `c2b3bb9` | 2026-09-21 | docs | docs: record UI/UX parity progress |
| 84 | `69a3c85` | 2026-09-21 | ui/ux | feat(selection): combine modes, expand/contract, multi-contour paths, shape-aware fill/clear, polygonal lasso, Curves graph, Adjustments panel |
| 85 | `fefe025` | 2026-09-21 | other | refactor(host): inject platform services behind narrow interfaces (SOLID) |
| 86 | `e6b7b80` | 2026-09-21 | ui/ux | feat(ui): Levels Auto buttons and canvas eyedroppers via injected AdjustServices |
| 87 | `d5a25dd` | 2026-09-21 | docs | docs: upstream parity audit (symbol coverage + verified feature matrix) |
| 88 | `772b085` | 2026-09-21 | docs | docs: Phase 0 spike — upstream compiles against Apple-API compat with ~82 missing symbols (probe script + work list) |
| 89 | `fdbad56` | 2026-09-21 | other | refactor(compat): extract CoreGraphics into a standalone module below the domain |
| 90 | `a5e4a5a` | 2026-09-21 | rendering | feat(compat): Apple-shaped CGPath/CGMutablePath, CGGradient, path fill/stroke, booleans via Skia PathOps |
| 91 | `a6fa8a1` | 2026-09-21 | feature | feat(compat): Apple colour API shapes (CGColorSpace names, failable CGColor init, srgbRed), CoreGraphics re-exports Foundation |
| 92 | `a0b8ad4` | 2026-09-21 | feature | feat(compat): AppKit, FoundationCompat and UniformTypeIdentifiers shims; probe down to 53 missing symbols |
| 93 | `88aa469` | 2026-09-21 | perf | feat(compat): Accelerate (vImage subset) and ImageIO (CGImageSource/Destination, portable PNG, Qt plugin backend) |
| 94 | `ba1f928` | 2026-09-21 | feature | feat(compat): CoreImage (CIImage graph + filters), CoreVideo, Vision (instance masks with pluggable segmenter), SwiftUI shims; probe down to 11 error lines |
| 95 | `7b4241c` | 2026-09-21 | ci/build | feat(compat): Metal overrides, sheet stand-ins and shim fidelity fixes; upstream Document/IO/Rendering build clean unmodified |
| 96 | `09d79d1` | 2026-09-21 | test | feat(compat): checkpoint baseline with pristine upstream, brush masked opacity fix and test harness |
| 97 | `7c3dfce` | 2026-09-21 | test | feat(compat): optimize vImage and CIRaster performance for large invert, document upstream test exclusions |
| 98 | `142b0e1` | 2026-09-21 | feature | feat(compat): exclude TiledLayerTests with documentation and update baseline to 100% green |
| 99 | `d558076` | 2026-09-21 | test | fix(compat): rotated hard clips, upright bitmap contexts, safer library loading; re-include Filter/LayerAppearance/Distort/Tiled tests |
| 100 | `e80d11b` | 2026-09-21 | rendering | refactor(compat): CGContext draws through a CanvasBackend protocol (Skia is one implementation) |
| 101 | `db9977b` | 2026-09-21 | other | refactor(compat): ServiceSlot for every replaceable seam; CompCanvasBridge is internal |
| 102 | `7e58644` | 2026-09-21 | rendering | feat(effects): layer-effects backend chain behind MetalLayerEffects (Vulkan compute -> portable C++ tier) |
| 103 | `6877b66` | 2026-09-21 | rendering | feat(effects): Skia image-filter tier for layer effects (opt-in COMPOSITOR_EFFECTS=skia) |
| 104 | `9f14967` | 2026-09-21 | rendering | feat(effects): OpenCV tier for layer effects on the pinned OpenCV 4.14.0; in the auto chain after Vulkan |
| 105 | `9b80a22` | 2026-09-21 | feature | feat(bridge): UpstreamEditor, the command adapter over upstream's unmodified EditorSession (first slice) |
| 106 | `87965fc` | 2026-09-21 | test | feat(bridge): masks, move, selection, fills, invert, clipboard commands on upstream's session (async entry + parity tests) |
| 107 | `4123476` | 2026-09-21 | docs | feat(bridge): brush, wand and filter commands; upstream-only tests for divergences; retirement plan doc |
| 108 | `0ace6bc` | 2026-09-21 | feature | feat: retire the forked CompositorCore; the Qt shell runs on upstream's unmodified EditorSession |
| 109 | `ead17dc` | 2026-09-22 | format/IO | feat(compat): catch up shims to upstream 1.2.0-1.2.2 (PSD/RAW import, middle-click pan, Outer Glow effect) |
| 110 | `fd75edf` | 2026-09-22 | feature | feat(bridge): map healing and clone-stamp brush commands; wire the Qt host to the new clone protocol |
| 111 | `6bbde5e` | 2026-09-22 | docs | docs: correct a stale test skip in the baseline (translucentStrokesDrawLikeOneImage/maskStrokesDrawLikeOneMask already fixed) |
| 112 | `12b7eb4` | 2026-09-22 | ci/build | fix(flatpak): grant the skia module build-time network access (git-sync-deps needs it) |
| 113 | `0826388` | 2026-09-22 | fix | fix(compat): drop always-failing NSItemProvider(item:) casts |
| 114 | `b1884f5` | 2026-09-22 | fix | fix(ui): match adjust-dialog layout to the macOS reference (right-hand OK/Cancel rail) |
| 115 | `57b90eb` | 2026-09-22 | ci/build | feat(ci,bridge): add upstream-sync CI gate; live in-progress brush-stroke preview |
| 116 | `73ae685` | 2026-09-22 | docs | docs: deep macOS-to-Linux architecture analysis (Polish, evidence-sourced) |
| 117 | `4a4f616` | 2026-09-22 | test | test(bridge): cover the live in-progress brush-stroke preview |
| 118 | `5d19881` | 2026-09-22 | ui/ux | feat(ui): add Hue/Saturation quick-pick range swatches (macOS parity) |
| 119 | `a27cfd0` | 2026-09-22 | perf | feat(linux): optimize Accelerate/CoreImage parallel loops, add run-compositor.sh launcher, and wire CLI file loading |
| 120 | `088a0d5` | 2026-09-22 | ui/ux | feat(ui): complete 100% UI/UX parity with macOS Compositor |
| 121 | `d54172b` | 2026-09-22 | docs | docs: add source-derived macOS UI parity rules |
| 122 | `6ec79f6` | 2026-09-22 | docs | docs: add macOS vs GNU/Linux dependency maps |
| 123 | `5545ed0` | 2026-09-22 | ui/ux | feat(ui): achieve full macOS parity with generic SwiftUI compat runtime and vector tool rail |
| 124 | `72653e4` | 2026-09-22 | ci/build | feat(ui): wire remaining Compositor/UI panels, fix real SwiftUI-compat and build bugs |
| 125 | `8ac58a7` | 2026-09-23 | ui/ux | feat(ui): integrate upstream v1.2.3 UI components, Camera Raw, and compat types |
| 126 | `9738767` | 2026-09-23 | test | feat(ui): extend Qt renderer for Camera Raw/toolbar widgets, exclude ObjC-blocked test |
| 127 | `7a787f4` | 2026-09-23 | other | chore: remove dead old-approach Compositor executable and duplicate linux/ tree |
| 128 | `399d74d` | 2026-09-23 | ui/ux | feat(ui): hide native system title bar, drag window via custom header |
| 129 | `43d3598` | 2026-09-23 | ci/build | fix(ci): read KDE SDK version from the manifest instead of hardcoding it |
| 130 | `2a0ccbb` | 2026-09-23 | docs | docs: document the real Linux dev loop, fix stale/misleading references |
| 131 | `f967a9f` | 2026-09-23 | docs | docs(readme): make README the primary Linux-port developer entry point |
| 132 | `476f8e7` | 2026-09-23 | docs | docs(readme): condense Linux Port section |
| 133 | `449c0c9` | 2026-09-23 | feature | feat(compat): add CIBloom and NSPasteboard.setString for upstream v1.2.4-1.2.6 |
| 134 | `fcc99ac` | 2026-09-23 | fix | fix(compat): fix real CIBloom bugs; correct the blank-render/heap-corruption misdiagnosis |
| 135 | `ff152ef` | 2026-09-23 | other | WIP. |
| 136 | `bebb180` | 2026-09-23 | fix | fix(host): window dragging, brush redraw coalescing, unsaved-changes prompt |
| 137 | `ae15ee7` | 2026-09-23 | perf | perf(host): render only the stroke's dirty region; frame pacing; --release |
| 138 | `4aa7c30` | 2026-09-23 | test | feat(compat): catch up upstream f67b46b; inner glow on all effects tiers; full test suite green |
| 139 | `c1c3ad8` | 2026-09-23 | test | fix(bridge): tests stay as written — make "new" satisfy them instead |
| 140 | `3c5cbd1` | 2026-09-23 | ci/build | feat(compat): compile upstream ProjectTabs.swift unmodified; TitleBarDragTests runs and passes |
| 141 | `81fb981` | 2026-09-23 | ci/build | chore: remove the minimal Flatpak manifest |
| 142 | `b34681b` | 2026-09-23 | fix | fix(host): colour palette follows the session; swatches, swap/reset and picker work; rail fits |
| 143 | `0081409` | 2026-09-23 | fix | fix(host): no stale or freed SwiftUI panels; clean Layers dock; drop invalid QSS |
| 144 | `197aac6` | 2026-09-23 | perf | perf(host): rebuild SwiftUI panels only when their tree changes; profiler; fewer redundant refreshes |
| 145 | `9e04ffa` | 2026-09-23 | perf | perf(host): sliders drag without interruption and keep up; render only when pixels change |
| 146 | `754f194` | 2026-09-23 | format/IO | Merge upstream 1.2.9 (a2160fa); PSD/PSB import on Linux; real installed-font lookup |
| 147 | `7c0fb07` | 2026-09-23 | rendering | feat(host): Gradient and Shape tools on the Qt canvas; fix Skia gradients in translated contexts |
| 148 | `f7b62e9` | 2026-09-23 | feature | feat(host): Type tool on the Qt canvas; double-click live text to edit (upstream 1.2.9) |
| 149 | `9264039` | 2026-09-23 | feature | feat(compat): real fonts for text — Qt text engine behind compat's text layout and drawing |
| 150 | `573b98a` | 2026-09-24 | ui/ux | feat(ui): real layer and mask thumbnails in the Layers panel |
| 151 | `a2fca95` | 2026-09-24 | ui/ux | feat(compat): .onChange/.task(id:) fire as in SwiftUI; Swift main queue pumped under Qt; sheet presenter |
| 152 | `78bf3b9` | 2026-09-24 | format/IO | feat(raw): camera RAW import on Linux via LibRaw, built for very large files |
| 153 | `e2180d7` | 2026-09-24 | perf | perf(canvas): huge documents render at display resolution; parallel SIMD Lanczos resampling |
| 154 | `b2997ec` | 2026-09-24 | perf | perf(raw): preview from the sensor data, leaner full develop, responsive window during long imports |
| 155 | `6cee379` | 2026-09-24 | perf | feat(raw): RawSpeed-v3 behind LibRaw for faster unpacking (on by default, COMPOSITOR_RAWSPEED=0 to disable) |
| 156 | `0f91f19` | 2026-09-24 | ci/build | fix(flatpak): the full Flatpak builds, passes CTest and draws again |
| 157 | `8487226` | 2026-09-24 | fix | fix(brush): hardness, opacity and smoothing from the options bar apply to strokes |
| 158 | `29d8cf5` | 2026-09-25 | ui/ux | feat(ui): macOS parity pass — documentless welcome, upstream viewport, fonts, renderer fidelity |
| 159 | `b79ee5c` | 2026-09-25 | ui/ux | feat(ui): the menu bar is upstream's own — CompositorApp's .commands, resolved on Linux |
| 160 | `451a340` | 2026-09-25 | ui/ux | feat(ui): rulers, layout grid, guides and snap lines as upstream draws them; guide drags from rulers and the Move tool |
| 161 | `68b3f6b` | 2026-09-25 | ui/ux | feat(ui): SF Symbol names draw as Lucide icons (ISC), close to SF's weight |
| 162 | `d297014` | 2026-09-25 | ui/ux | feat(ui): Canvas Size and Image Size are upstream's sheets and resizers; default buttons in accent; more symbols |
| 163 | `1899c84` | 2026-09-25 | ui/ux | feat(ui): Levels, Hue/Saturation, Curves, filters and selection Expand/Contract/Feather float as upstream's panels |
| 164 | `9091a93` | 2026-09-25 | ui/ux | feat(ui): eye swipe in the Layers list — press an eye, drag over others, one undo step (EyeSwipeButton) |
| 165 | `8aa1b72` | 2026-09-25 | rendering | feat(ui): blend modes preview on the canvas as the menu highlights them (BlendModePicker's menu delegate) |
| 166 | `56efc27` | 2026-09-25 | format/IO | feat(ui): Export PNG / JPEG through upstream's exporter and Export JPEG sheet; the shell only picks the file |
| 167 | `e6060e8` | 2026-09-25 | ui/ux | feat(ui): the color picker is upstream's floating ColorPickerSheet; the canvas samples into it |
| 168 | `3dbc573` | 2026-09-25 | fix | fix(ui): shortcut labels name Linux keys (Ctrl/Alt/Shift), matching the menus (§12.2) |
| 169 | `e1e02d6` | 2026-09-25 | ci/build | feat(compat): renderer fidelity work found in the tree (backgrounds, masks, sheets, list mask drops, number formats, timers), made to build; hosted CanvasView bridge |
| 170 | `720d8f2` | 2026-09-25 | feature | feat(canvas): Move, Marquee, Lasso, Magic and Crop run on upstream's own CanvasView; its TransformOverlay draws the canvas chrome |
| 171 | `fc86603` | 2026-09-25 | ui/ux | feat(canvas): upstream's cursors on the canvas — cursor rects on hover, what CanvasView sets while dragging |
| 172 | `dd40969` | 2026-09-25 | ui/ux | feat(canvas): upstream's own cursor pictures — selection modes, eyedropper, zoom, rotate |
| 173 | `743166b` | 2026-09-25 | feature | feat(canvas): brushes, Gradient, Eyedropper, Zoom and Hand also run on upstream's CanvasView |
| 174 | `2a68319` | 2026-09-25 | ui/ux | feat(ui): menus go to the desktop's global menu where there is one (as on the Mac); in the window otherwise |
| 175 | `2219136` | 2026-09-25 | feature | feat(layers): effect rows, thumbnail and mask-link clicks, double-click to rename / edit, as NativeLayerList |
| 176 | `636b34f` | 2026-09-25 | ui/ux | feat(ui): About Compositor is the Mac's standard panel — icon, name, Version 1.2.9 (24) |
| 177 | `acf1796` | 2026-09-25 | feature | feat(canvas): Shape runs on upstream's CanvasView; the draft previews filled, above the active layer, as on the Mac |
| 178 | `59f982a` | 2026-09-25 | fix | fix(ui): symbol .rotationEffect and a single ↔ for arrow.left.and.right (the palette's swap button) |
| 179 | `caff3b3` | 2026-09-25 | ui/ux | feat(ui): the window's first launch fills the screen, later launches reopen where it was left (CompositorApp's placement) |
| 180 | `008ed12` | 2026-09-25 | rendering | refactor(ui): tool headers, tool rail and status bar render ContentView's own views, not copies |
| 181 | `b5c6d0f` | 2026-09-25 | ui/ux | feat(ui): zoom in/out share one toolbar capsule, and Fit / 100% / zoom are disabled without a document (ContentView's toolbar) |
| 182 | `b53cec1` | 2026-09-25 | ui/ux | feat(ui): the New canvas toolbar button is a 28-pt capsule with the plus symbol, like the other toolbar controls |
| 183 | `99d6875` | 2026-09-25 | feature | feat(canvas): Type runs on upstream's CanvasView too — every tool now uses EditorCanvas's own mouse code |
| 184 | `a9b5b04` | 2026-09-25 | feature | feat(canvas): the canvas's plain keys are upstream's (EditorCanvas.keyDown) |
| 185 | `2fc1c40` | 2026-09-25 | other | refactor(canvas): drop the shell's own tool code; pens act as mice; default/cancel buttons as SwiftUI's |
| 186 | `6dbb3c7` | 2026-09-25 | fix | fix(ui): zoom percent follows the user's locale like SwiftUI; smoke drags use the app's viewport mapping |
| 187 | `fd72e0b` | 2026-09-25 | perf | perf(ui): snappy canvas — no 60 Hz idle refresh, cached overlay with dirty rects, panels throttled mid-drag |
| 188 | `db9c524` | 2026-09-25 | ui/ux | feat(ui): SwiftUI Grid with real columns, radio-group pickers, visible dividers, capsule sheet buttons |
| 189 | `7db9457` | 2026-09-25 | fix | fix(ui): Label buttons are bordered push buttons with their symbol (Levels' Sample); tree dumps survive the size-query cache |
| 190 | `87c94cf` | 2026-09-25 | fix | fix(ui): grid columns keep their cells' width; maxWidth-infinity labels widen their button; large control size (color picker's OK/Cancel) |
| 191 | `c6324cf` | 2026-09-25 | rendering | feat(ui): panels invalidate as SwiftUI's do — observation-tracked resolves, only changed panels re-render; viewport changes reach status bar and rulers |
| 192 | `6f32ebf` | 2026-09-25 | other | chore(host): drop the leftover debug filter that printed every Close/Quit event |
| 193 | `c9a45a7` | 2026-09-25 | feature | feat(linux): NSPasteboard.general is the desktop clipboard — copy/paste with other apps, New Canvas takes the clipboard's size |
| 194 | `aaa9e81` | 2026-09-25 | feature | feat(linux): trackpad pinch zooms the canvas through upstream's magnify(with:) |
| 195 | `7dc603b` | 2026-09-25 | fix | fix(ui): the shortcut recorder takes Esc as a key, as upstream's does; inventory updated |
| 196 | `2ab52fc` | 2026-09-26 | fix | fix(canvas): brush strokes show while painting, not only on release |
| 197 | `5a7876b` | 2026-09-26 | perf | perf(brush): painting ~8x faster per frame — coalesced drags, region-only live stroke, no mid-stroke panel rebuilds |
| 198 | `a7a90da` | 2026-09-26 | feature | feat(vision): U²-Net-small subject segmentation behind the Vision compat (groundwork; model + OpenCV dnn to add) |
| 199 | `0a95226` | 2026-09-26 | feature | feat(vision): Select Subject / Remove Background run U²-Net-small — model bundled, OpenCV dnn built |
| 200 | `268a165` | 2026-09-26 | fix | fix(ui): hovering a scrubbable label no longer hangs the app |
| 201 | `676f97e` | 2026-09-26 | perf | perf(canvas): zoom never waits on a whole-document composite; upstream's draw(_:) available as a parity reference |
| 202 | `8e55e0c` | 2026-09-26 | feature | feat(canvas): pixel grid at 800% and above, as EditorCanvas.drawPixelGrid draws it |
| 203 | `2476e9c` | 2026-09-26 | ui/ux | feat(layers): close the Layers panel's remaining gaps with the Mac's list |
| 204 | `1c980c6` | 2026-09-26 | other | WIP. |
| 205 | `434ea49` | 2026-09-26 | other | WIP: fix Linux color picker, layer renaming, and brush input |
| 206 | `64b6943` | 2026-09-26 | perf | Optimize Linux brush rendering for lower latency and CPU use |
| 207 | `e4dba5a` | 2026-09-26 | format/IO | Add Linux desktop E2E coverage, performance metrics, and PSD fixtures |
| 208 | `c39c26f` | 2026-09-27 | ci/build | Fix Linux tool responsiveness and rename Flatpak application |
| 209 | `051c7e7` | 2026-09-27 | perf | Optimize Linux Gaussian and Motion Blur rendering |
| 210 | `27d14b5` | 2026-09-27 | ci/build | Add signed Flatpak alpha releases and in-app updates |
| 211 | `34b7a9a` | 2026-09-27 | docs | Document alpha release validation limits [skip ci] |
| 212 | `2351e3e` | 2026-09-27 | ci/build | Remove upstream company branding from Linux Flatpak presentation |
| 213 | `dc628e2` | 2026-09-27 | ci/build | Back Linux UserDefaults with SQLite to fix Flatpak preference crashes |
| 214 | `2b97eea` | 2026-09-27 | ci/build | Bump Linux Flatpak minor release to 1.1.0 alpha |
| 215 | `f3649f6` | 2026-09-27 | other | Release Linux 1.2.0 alpha with canvas undo boundary |
| 216 | `6e40891` | 2026-09-28 | other | Land Linux 1.3.4 catch-up through the compat layer |
| 217 | `2b8a1bc` | 2026-09-29 | other | Make Linux tool switches follow upstream selectTool |
| 218 | `7ee8b51` | 2026-09-29 | other | Catch up Compositor 1.4 on Linux. |
| 219 | `72b5d11` | 2026-09-29 | perf | Harden Color Range sampling and cut smear first-dab latency on Linux. |
| 220 | `f351d78` | 2026-09-29 | other | Catch up Compositor 1.4.1 on Linux. |
| 221 | `7dd280e` | 2026-09-29 | perf | Add a 150 ms first-feedback latency budget for every tool. |
| 222 | `bccd9b4` | 2026-09-29 | ci/build | Add CI-grade E2E graphics package benchmark with SMALL/MEDIUM/STRESS harness. |
| 223 | `14972d6` | 2026-09-29 | ui/ux | Harden visible UI e2e graphics satellite under nested Xephyr. |
| 224 | `6600a22` | 2026-09-29 | rendering | Route colour blends and GPU canvas tools through Vulkan when available. |
| 225 | `df73bc5` | 2026-09-29 | other | Coalesce Qt refreshes during color picker drags so the shell stays responsive. |
| 226 | `fc35710` | 2026-09-29 | feature | Add opt-in visible E2E demo for layers, color picks, and ring smudge. |
| 227 | `20d10ea` | 2026-09-29 | fix | Run warp strokes on CPU in the Linux override to avoid Smudge SIGSEGV. |
| 228 | `3b84fd5` | 2026-09-29 | fix | Fix Smudge crash on mouse-up after long circular strokes. |
| 229 | `6c42836` | 2026-09-29 | other | Commit long Liquify/Smudge strokes with a single cropped layer replace. |
| 230 | `e8dc46b` | 2026-09-30 | other | Port tip 1.4.2–1.4.4 quit settle, blur radius, and sharp liquify on Linux. |
| 231 | `abf6041` | 2026-09-30 | ci/build | Fix Scanlines glow on Linux: safe BrushRaster.copy and CI bloom transform. |
| 232 | `b77dc1a` | 2026-09-30 | other | Port Compositor 1.4.5 Camera Raw curves on Linux. |
| 233 | `ab2e6bb` | 2026-09-30 | other | Treat tip releases as the Linux catch-up prompt: keep BrushStroke upstream-clean. |
| 234 | `2ccb9b1` | 2026-09-30 | other | Fill Linux platform gaps for tip 1.4.5 editor-done parity. |
| 235 | `ed7db69` | 2026-09-30 | fix | Fix Linux gradient live preview and Copy Merged clipboard paste. |
| 236 | `e39eb90` | 2026-09-30 | fix | Fix Linux smudge/liquify live feedback under 150 ms and multi-layer Cut. |
| 237 | `59326a7` | 2026-09-30 | fix | Fix multi-layer Cut through the stack and liquify release hang. |
| 238 | `7479664` | 2026-09-30 | release | Prepare Linux Flatpak alpha 1.4.5-linux-alpha.1. |
| 239 | `1b1ed78` | 2026-09-30 | fix | Keep the Linux download page version in sync with each alpha release. |
| 240 | `d1e446f` | 2026-09-30 | other | Label the Linux download page as an unofficial port. |
| 241 | `357d26e` | 2026-09-30 | ci/build | Fix Skia Ganesh Flatpak build and ship Linux alpha 1.4.5-linux-alpha.2. |
| 242 | `fa78d0c` | 2026-09-30 | ui/ux | Remove Linux UI e2e suite and graphics E2E bench. |
| 243 | `02359c2` | 2026-09-30 | release | Prepare Linux Flatpak alpha 1.4.5-linux-alpha.3. |
| 244 | `27e500f` | 2026-10-01 | release | Prepare Linux Flatpak alpha 1.4.5-linux-alpha.4. |
| 245 | `4aca891` | 2026-10-03 | feature | Add image to linux-port-file-map.md |
| 246 | `8f15e7e` | 2026-10-04 | ci/build | Fix About panel app icon loading on Linux Flatpak. |
| 247 | `54c6c45` | 2026-10-04 | release | Prepare Linux Flatpak alpha 1.4.5-linux-alpha.5. |
| 248 | `e7a89cc` | 2026-10-05 | other | Map SwiftUI Color views so Curves graph drag works on Linux. |
| 249 | `d658e52` | 2026-10-05 | release | Prepare Linux Flatpak alpha 1.4.5-linux-alpha.6. |
| 250 | `f77f070` | 2026-10-05 | other | Wire Free Transform on Linux: Ctrl+T, handle hit alignment, and hover cursors. |
| 251 | `7f5983c` | 2026-10-05 | release | Prepare Linux Flatpak alpha 1.4.5-linux-alpha.7. |
| 252 | `1d78c91` | 2026-10-05 | other | Free Transform: Enter/Esc apply/reset; Show Controls arms Cancel/Apply. |
| 253 | `5f0f3bd` | 2026-10-05 | release | Prepare Linux Flatpak alpha 1.4.5-linux-alpha.8. |
| 254 | `6d1885a` | 2026-10-05 | fix | Fix Linux Save / Save As for .comp directory packages. |
| 255 | `08fbf2e` | 2026-10-05 | release | Prepare Linux Flatpak alpha 1.4.5-linux-alpha.9. |
| 256 | `4d4126b` | 2026-10-05 | ci/build | Fix Flatpak Save As for .comp directory packages. |
| 257 | `857f158` | 2026-10-05 | release | Prepare Linux Flatpak alpha 1.4.5-linux-alpha.10. |
| 258 | `badd7d4` | 2026-10-07 | docs | Tighten catch-up doc wording around textDraft authority. |
| 259 | `c8320d7` | 2026-10-09 | fix | Keep GNU_Linux building against upstream 1.4.8 tip trees. |
| 260 | `da59c93` | 2026-10-09 | other | Port upstream 1.4.6–1.4.8 ledger features to the Linux host and compat layer. |
| 261 | `7ee6e5e` | 2026-10-10 | feature | Layer effects recolor the source and keep its alpha (upstream 1.4.8) |
| 262 | `7890c79` | 2026-10-10 | docs | Upstream ledgers for 1.4.6-1.4.9 and an override drift check |
| 263 | `ace1b90` | 2026-10-10 | other | Port upstream 1.4.9 and make tool combinations behave as on the Mac |
| 264 | `88724f4` | 2026-10-10 | fix | Options bar fills the window; Inverse of everything keeps the selection on Linux |
| 265 | `867206f` | 2026-10-10 | format/IO | Every Linux override is drift-watched; retire the pre-1.4.8 JPEG export sheet |
| 266 | `c19f319` | 2026-10-10 | other | Compat SwiftUI hosting: intrinsic sizes, .fixedSize() and GeometryReader sizes |
| 267 | `2d9e3ec` | 2026-10-10 | rendering | Compat Core Image: source-over, every blend mode, tiles, gradients, curves |
| 268 | `5502505` | 2026-10-10 | rendering | Compat Core Graphics shadows and strokes; Core Image nearest sampling |
| 269 | `97d657e` | 2026-10-10 | rendering | Linux GPU noise and grain sample the frame where the Metal kernels do |
| 270 | `a32b974` | 2026-10-10 | rendering | GPU canvas: radial gradient radius and mask tiles upright |
| 271 | `9ee1edc` | 2026-10-10 | rendering | GPU canvas tiles replace pixels; mask blends cover input and background |
| 272 | `42af6ed` | 2026-10-10 | perf | GPU canvas renderer wherever Vulkan is; the app keeps the fast canvas |
| 273 | `82b1459` | 2026-10-10 | other | Smudge runs through MetalWarp as on the Mac; exclusion list current |
| 274 | `35b286f` | 2026-10-10 | test | Thirteen upstream test files run again on Linux |
| 275 | `a2873ec` | 2026-10-10 | docs | Ledger: un-excluded upstream tests now count as run |
| 276 | `a7b91d0` | 2026-10-10 | rendering | GPUCanvasLinuxTests follows Vulkan availability like tip's Metal device check |
| 277 | `8f2edb7` | 2026-10-10 | other | Live Smudge and Liquify dabs time-slice so the shell can paint between them |
| 278 | `3d961dd` | 2026-10-10 | test | FloatingPanelTests runs: lazy test-host window, weak window delegates |
| 279 | `62c0a4c` | 2026-10-10 | docs | Ledger row 38: NavigatorTests now runs, fix stale manual evidence |
| 280 | `8af1f52` | 2026-10-10 | test | SliderSnap, CameraRawSlider and CommandPalette tests run on Linux |
| 281 | `18369f4` | 2026-10-10 | feature | LayerTests and CursorTests run on Linux against tip's own layer table |
| 282 | `57952fd` | 2026-10-11 | fix | InlineTextEditor, LayerMaskMenu and ProjectWindowBridge generated from tip; .scrollIndicators(.never) |
| 283 | `6ae0455` | 2026-10-11 | ui/ux | Every Compositor/UI file is tip-generated; the Qt shell draws AppKit views inside SwiftUI |
| 284 | `20128a5` | 2026-10-11 | other | After the upstream merge: ledger, regenerated TypeControls; TODOs done |
| 285 | `3733c33` | 2026-10-11 | other | Complete Linux compatibility catch-up and regression coverage |
| 286 | `cb2b32d` | 2026-10-11 | format/IO | Linux: camera HEIF import and 1.4.10 version for upstream 1.4.10 |
| 287 | `40ca4af` | 2026-10-11 | release | Prepare Linux Flatpak alpha 1.4.10-linux-alpha.1. |
| 288 | `3645b8b` | 2026-10-12 | format/IO | Linux: RAW Lens Correction from the file's own lens profile |
| 289 | `3c79668` | 2026-10-12 | release | Prepare Linux Flatpak alpha 1.4.10-linux-alpha.2. |
| 290 | `72761ad` | 2026-10-12 | format/IO | Linux: 16-bit and HDR layers for upstream after 1.4.10 |
| 291 | `8185eee` | 2026-10-12 | release | Prepare Linux Flatpak alpha 1.4.10-linux-alpha.3. |
| 292 | `72b83ad` | 2026-10-14 | other | Linux: adaptations for upstream 1.5.2 |
| 293 | `16ba06d` | 2026-10-14 | docs | Linux: README feature audit fixes for upstream 1.5.2 |
| 294 | `b94c7a7` | 2026-10-14 | release | Prepare Linux Flatpak alpha 1.5.2-linux-alpha.1. |
| 295 | `11d0564` | 2026-10-14 | test | Remove temporary proof benchmark test committed by mistake |
| 296 | `630172a` | 2026-10-18 | other | Linux: adaptations and parity fixes for upstream 1.5.3 |
| 297 | `98dbefc` | 2026-10-18 | release | Prepare Linux Flatpak alpha 1.5.3-linux-alpha.1. |
| 298 | `959850f` | 2026-10-18 | ci/build | CI: fetch upstream/main for the Linux contract's source-coverage audit |
| 299 | `6f69273` | 2026-10-18 | ui/ux | Linux: UI audit gate and fixes for the upstream panels it found broken |

## Removed or reverted upstream functionality

| Commit | Subject |
|---|---|
| `f22847d` | Revert the Gradient Map lookup-table split |
| `aa4088b` | Leave the Camera Raw design notes out of the change. |
| `8837709` | Remove Camera Raw upright modes that ignore the picture. |
| `d076c28` | Revert "Merge pull request #67 from Cengokill/feature/verify-tests-on-push" |
| `67301d2` | Revert "Merge pull request #93 from kaivyy/fix/text-box-undo" |
| `5d7adba` | Leave Layer Effects out of the layer context menu |
| `07cfdc6` | Drop the Homebrew upgrade command from the README: the app updates itself |
| `bc29006` | Drop the review note and the font-width assertion |
| `03d692c` | Drop the held-Command checkbox test |
| `d3d0ce7` | Drop anywhere on the tab bar to open in a new project |

These are tracked separately from active requirements in report 02 (§ Removed/deprecated).

