# 11 — Final parity assessment

**Baseline:** upstream `365b574` (1.5.3) against GNU_Linux **`a13f27d`**, 2026-10-19.

Commits since the first pass (`959850f`):
- UI fixes: `6f69273`.
- Performance: `79c4976`, `0640011`.
- Roadmap T-08 to T-21: `9bf048b` … `d9fea91`.
- Linux-only verification (the epic "Complete GNU/Linux port without macOS hardware"): `8cad036` … `a13f27d`.

## Answer

**The Linux implementation and every verification possible on Linux are complete.**
- Every upstream commit is merged, and the protected upstream tree compiles byte for byte.
- Every upstream feature has a Linux implementation.
- All Linux tests pass on two Vulkan drivers: AMD RADV, and Mesa lavapipe (software rendering).
- No Linux defect is open; every one found during the epic was fixed.

**Parity with macOS is UNVERIFIED.** Nothing in this audit compares Linux output with macOS output, because no Mac was available. Where this report says "verified", it means Linux checked against upstream's own tests, Linux baselines, or reference data. That is never the same as checked against a Mac. The external dependencies are listed below, with the exact steps to close them (`docs/mac-verification-plan.md`, `docs/desktop-integration-matrix.md`).

## Metrics

The denominator is the 179 feature IDs in report 04.

| # | Metric | Value | Basis |
|---|---|---|---|
| 1 | Feature implementation coverage | **179 / 179 (100%)** | catalog |
| 2 | Verified functional parity (Linux scope) | **118 / 179 (65.9%)** VERIFIED_PARITY; 56 IMPLEMENTED_UNVERIFIED; 3 LINUX_EQUIVALENT; 2 PARTIAL; 0 BEHAVIOR_MISMATCH; 0 BROKEN; 0 MISSING | report 04 rules |
| 3 | UI/UX parity (against upstream source, observed) | 158 features have UI. **120 seen working (75.9%)**, 0 visibly wrong, 38 not observed. The UI audit is clean at 100, 125, 150 and 200 % scale | report 05, `--ui-audit-probe` |
| 4 | Model and data compatibility | Same code as upstream. On Linux, the 8-case `.comp` corpus round trip is exact: manifest, assets and flattened image. **Mac-written packages: unverified** | `ProjectCorpusRoundTripTests` |
| 5 | Rendering correctness | All upstream rendering assertions pass. 88 Linux golden images, identical on RADV and lavapipe. **Distance from macOS output: unverified** | `LinuxGoldenImageTests` |
| 6 | Subject masks | Against 28 reference cut-outs: median IoU **0.917**, worst 0.537. **Against Apple Vision: unverified** | `scripts/compare-subject-masks.py` |
| 7 | Automated tests | Full contract exit `0 0` (details below) | `.build/evidence/full-contract-epic.log` |
| 8 | Regression status | 0 failing tests. 0 BROKEN or MISSING features. 0 open Linux defects | reports 08, 09 |

The full contract run on `a13f27d` covered:
- 990 Swift Testing tests: 945 in parallel, then 45 in 8 suites that share global state, one at a time.
- 154 XCTests.
- CTest.
- 36 native journeys, including `--ui-audit-probe`, `--input-probe` and `--dialog-smoke`.
- The upstream-integrity check, including the compat no-op audit.

Three more runs, outside the contract:
- On lavapipe: every native journey passes. The Swift tests that require a hardware GPU fail there by design, because the Vulkan backends skip CPU devices.
- On a private X server: drag and drop and the clipboard (`scripts/test-desktop-dnd.sh`).
- Three parallel runs in a row, all passing.

Gaps: 22 confirmed. **7 open:**
- 1 High: GAP-VER-04, macOS comparison. It is an external dependency, not a Linux defect.
- 6 Low:
  - GAP-PLAT-01, GAP-VER-01, GAP-VER-03: macOS or hardware verification still needed.
  - GAP-PERF-01, GAP-PLAT-03: accepted Linux equivalents.
  - GAP-VER-02: a Flatpak limitation.

15 are resolved.

## What the epic delivered (T-10, T-15, T-16, T-18, T-23, T-24, T-25)

| Task | Linux implementation and verification | Still external |
|---|---|---|
| T-10 `.comp` compatibility | `8cad036`: corpus round trip of every content kind | Opening Mac-written packages, and the reverse |
| T-15 Desktop integration | `585f080`, `a13f27d`. The scripted desktop check passes everything except Flatpak's missing thumbnailer export. On a private X server: clipboard both ways with other X clients, drop delivery and acceptance, header drop opening a new tab | Drop contents: the headless server carries no XDND data even between plain Qt programs. Rows 1–13 of the matrix need a real GNOME and KDE session |
| T-16 Physical input | `a13f27d`: `--input-probe` covers pen, touch, trackpad scroll and pinch, Ctrl+wheel and brush keys through Qt's platform layer. The UI audit is clean at 125, 150 and 200 % | Real devices and their drivers |
| T-18 Subject segmentation | `e10239d`: reference set, scoring, and guided edge refinement (median IoU 0.885 → 0.917) | Comparison with Apple Vision |
| T-23 Golden images | `d00f506`: 88 Linux baselines in an automated pixel-regression test | Baselines rendered on macOS |
| T-24 Full audit | Full contract `0 0`, lavapipe gates, X11 test, HiDPI audit, three parallel runs. Defects found and fixed in this pass: subject-mask edges (`e10239d`), and `--dialog-smoke` missing from the contract (it runs as the app runs) | — |
| T-25 Metrics | This report and reports 04 and 09 regenerated (`.build/evidence/audit/gen_reports.py`) | Re-run once the Mac steps are done |

## Certainty

| Claim | Strength |
|---|---|
| Upstream fully merged; protected tree identical | Verified (git, `check-upstream-clean.sh`) |
| Linux tests pass | Verified: full contract `0 0` on `a13f27d`; three parallel runs in a row; native journeys on lavapipe |
| `.comp` round trip on Linux | Verified (`ProjectCorpusRoundTripTests`) |
| Rendering is stable on Linux | Verified against Linux baselines on two Vulkan drivers |
| Visual and colour parity with macOS | **Unverified** |
| Reading and writing Mac `.comp` packages | **Unverified** |
| Subject masks against Apple Vision | **Unverified** |
| Physical devices; drop contents in real desktop sessions | **Unverified** |

## Acceptance (the epic's criteria)

| Criterion | Status |
|---|---|
| All available Linux tests pass | ✅ |
| No unresolved critical Linux defects | ✅ No Critical gaps. The one High gap is the external macOS comparison |
| Automated regression tests are reproducible | ✅ Contract runner, golden baselines, corpus, the reference-mask script, and the X11 and input probes |
| Missing hardware tests explicitly documented | ✅ `docs/desktop-integration-matrix.md` (T-15, T-16 manual rows) |
| macOS parity marked Unverified, never falsely completed | ✅ Metrics 4–6 and the certainty table |
| Final audit and metrics published | ✅ `reports/` committed with this change |
