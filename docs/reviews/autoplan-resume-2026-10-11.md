<!-- /autoplan restore point: /tmp/compositor-autoplan-restore-20261011.md -->
# Resume Claude Code: Linux compatibility closeout

Status: IMPLEMENTATION REQUESTED. User confirmed upstream-first compatibility scope on 2026-10-11; review phases continue sequentially.
Branch: GNU_Linux. HEAD: 20128a5. Base: origin/main (git-native default branch).
Upstream: upstream/main at 3081719, fetched 2026-10-11. Already merged as 4cfc244.

## Recovered direction

Claude's most recent session was implementing the remaining TODOS, after the user requested
full compatibility completion and authorized merging upstream. It stopped during integrity-gate
changes. The September port plan and October test-unexclusion plans are historical inputs;
the current task is to finish and verify the current working tree and unresolved closeout findings.

Prior settled requirements: Mac Swift is the source of truth; Qt mirrors the session. Protected
Mac application, tests, UI tests, and Xcode project remain upstream-identical. Existing tests are
immutable; new Linux-owned tests can cover new behavior. Do not push. Generated overrides are
changed through their generator or patch. Completion claims require behavioral evidence.

## Current working tree read

| Work | Files | Current evidence / remaining concern |
|---|---|---|
| Profile conversion and export tags | host/QtImageIO.cpp; Tests/CompatTests/ColourManagementTests.swift | Upstream importer renders RGBA8 sRGB; exporter renders 8-bit sRGB. New P3 fixture test exists, not run in this review. HEIF nclx maps all non-linear transfer curves to sRGB, including curves that are not sRGB. Gray profile conversion is bypassed. The untagged test uses the newly tagging encoder. |
| Touch targets | host/SessionWindow.cpp/.h; Sources/LinuxBridge/TouchTargets.swift; transform patch/generator/generated override; Tests/LinuxOverrideTests/TouchTargetsTests.swift | Geometry test covers finger/mouse reach. Application-owned filter captures window pointer and can survive its destruction. Global stylesheet changes control geometry; compatibility with the parity rule needs an explicit premise. Real touch routing, synthesized mouse events, multiple windows, and window destruction lack proof. |
| Integrity gate | .github/workflows/ci-guard.yml; scripts/check-upstream-clean.sh; linux/upstream-parity.json | Four protected trees match upstream; generator, shader, drift, and ledger checks pass locally. CI now requires glslangValidator. Guard still exits at first failure. |
| Outside review | docs/reviews/codex-outside-review-2026-10-11.md | Six findings exist; TODOS still says the review is blocked on quota. Review has run; findings have not all been resolved. |
| Scratch status | done.txt | Historical note, contradicts later fixes. Preserve pending reconciliation; do not use as current proof. |

`git diff --check` passed. `bash scripts/check-upstream-clean.sh` passed, including shader checks.
No build, native journey, or full Swift test run has been performed in this resumed review.
Graph discovery was used first; its coverage reports changed metadata for several affected files,
so current diffs and direct source are authoritative for the working tree.

## Phase 1 step 0A: premises

P1. Audit and implement all upstream-used Mac compatibility behavior on Linux at upstream 3081719. The current WIP and six findings are the first implementation slice, not the coverage boundary. Confirmed by the latest user direction.

P2. Match the current upstream 8-bit sRGB document contract. Supported by ImageImporter.decode
and ImageExporter.render. Wide-gamut or 16-bit editable documents would introduce a separate
format/product change and are not a prerequisite for upstream parity.

P3. Touch support is an input adaptation. The current code also grows visible Qt controls.
That choice needs confirmation because the parity policy prohibits Linux visual redesigns.
Recommendation: enlarge hit areas while preserving upstream visual geometry where possible;
surface any unavoidable visible deviation explicitly.

P4. Mark TODOs complete only after relevant behavior runs successfully. A clean source/drift
gate cannot establish working gestures, focus, error recovery, image conversion, or accessibility.

## Phase 1 step 0B: existing code leverage

| Subproblem | Reuse |
|---|---|
| Color contract | Compositor/IO/ImageImporter.swift, ImageExporter.swift; host/QtImageIO.cpp codec seam |
| Touch handle detection | TransformOverlayGeometry.hit; generated transform-overlay patch |
| Tool switching and gradient completion | UpstreamEditor bridge; EditorSession.commitGradient; existing tool-combination suites |
| Native interaction verification | host/DialogJourney.cpp and existing host smoke entry points |
| Integrity | Existing protected-tree, generator, shader, override-drift and ledger checks |
| Evidence bookkeeping | Existing ledgers and TODOS.md, corrected rather than replaced |

## Phase 1 step 0C: dream state

```text
CURRENT                         THIS PLAN                        12-MONTH IDEAL
Merged upstream + WIP     ->     Verified remaining TODOs    ->    Upstream updates regenerate
Partial behavioral proof        Native combinations proved       and validate Linux behavior
Stale completion records        Honest acceptance evidence       without repeated regressions
```

The delta is trustworthy closeout evidence. The long-term ideal still requires maintainable
runtime and screenshot coverage across native controls and platform adapters.

## Phase 1 step 0C-bis: alternatives

| Approach | Coverage | Effort (human / agent) | Risk | Pros | Cons |
|---|---|---|---|---|---|
| A. Verify only existing WIP | 6/10 | 1 day / hours | Medium | Smallest change; preserves work | Leaves review findings and stale evidence unresolved |
| B. Complete WIP and closeout findings | 10/10 for recovered scope | Several days / multiple hours | Medium | Uses existing seams; covers actual acceptance gaps | Requires native journeys and full runtime checks |
| C. Resume broader GPU architecture work now | Separate scope | Weeks / days | High | Advances performance roadmap | Does not directly resolve current WIP correctness and evidence gaps |

Updated recommendation after the latest user direction: inventory upstream behavior and complete gaps incrementally through existing compatibility seams. WIP plus six findings is the first slice. Do not infer unrelated document-format or GPU architecture changes.

## Proposed execution after premise confirmation

1. Finish CEO review with independent voices; then Design, Engineering, and DX in that order.
2. Review color conversion, error paths, bit-depth reduction, HEIF transfer handling, alpha,
   untagged fixtures, and export tagging against upstream behavior.
3. Review touch-filter ownership, window lifecycle, input routing, parity, and state access.
4. Resolve gradient false-success and define busy/refusal behavior from upstream; add actual
   native combination evidence without weakening or editing existing tests.
5. Complete integrity diagnostics and truthful ledger classification/evidence.
6. Reconcile TODOs and record builds, affected tests, native journeys, and full-suite results.

## NOT in scope

Mac source changes; edits or exclusions to existing tests; new document precision/profile
features; pushing or deploying; deleting scratch work; unrelated GPU rewrites. Prior authorized
Linux work remains available, but changes to its direction require explicit justification.

## Decision Audit Trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|---|---|---|---|---|---|
| 1 | Intake | Use current WIP and last session as resumed input | Mechanical | Reuse | Historical plans contain tasks that have already shipped | Restarting old port plan |
| 2 | Intake | Use current upstream sRGB/RGBA8 contract for color review | Mechanical | Explicit | Direct upstream source specifies the storage/rendering contract | Inventing a new file-format requirement |
| 3 | Intake | Preserve all current changes while reviewing | Mechanical | Pragmatic | Work is uncommitted and verification is incomplete | Discarding or stashing WIP |
| 4 | CEO | Recommend complete WIP plus six findings | Taste, pending gate | Completeness | Existing TODO completion alone would leave known acceptance failures | WIP-only closeout |

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|---|---|---|---|---|---|
| CEO | /autoplan | Resumed scope and premises | 0 complete | Pending premise gate | Intake and alternatives recorded |
| Design | /autoplan | Touch adaptation and native interaction | 0 | Pending | UI scope: yes |
| Engineering | /autoplan | Runtime correctness and verification | 0 | Pending | Current integrity gate passes; runtime unverified |
| DX | /autoplan | Guard, ledgers, test invocation | 0 | Pending | DX scope: yes |

**VERDICT:** Intake complete; full review and implementation approval pending.

**UNRESOLVED DECISIONS:**
- Runtime gaps remain to implement and verify; no new scope permission is required for upstream-first compatibility work.
