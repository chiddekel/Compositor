# CEO review: upstream-first compatibility

Scope: current upstream `3081719`, Linux HEAD `20128a5` plus current WIP. Mode: SELECTIVE EXPANSION.
User confirmation: “Read Upstream and implement all comp mac layer”, followed by a request for recent tasks and implementation status.
The broader compatibility inventory follows the user's direction; it is not a proposed change to that direction.

## System audit and scope calibration

Recent commits show generated UI adaptations and upstream test unexclusions already delivered. Four protected trees
match upstream, and the current generator/shader/drift/ledger gate passes. Current color/touch work is uncommitted;
the full release baseline is building and has no final result. The task list now distinguishes those states.

No new service or infrastructure is required to close the current failures. The existing codec, AppKit, SwiftUI,
session C ABI and host journey seams are the leverage points. An all-compatibility claim needs an upstream behavior
inventory, rather than only a six-finding closeout. Performance rewrites are justified by an observed behavior or
latency gap, not by the existence of a different backend.

Five small useful improvements are complete task status, per-check guard diagnostics, accurate test consumption
labels, clear refusal results and reproducible native journeys. They are inside the current adapters' blast radius.
Hour 1 establishes source identity and current work; hour 2 maps behavior and runs baseline; hours 3–5 close observed
failures and native paths; hour 6+ reruns integrated acceptance and records external-device/Mac evidence separately.

## Independent voices

Fresh independent agent: six findings. Codex CLI: seven findings, preserved in
[outside review](autoplan-ceo-outside-2026-10-11.md). Both are Codex; no Claude model is available in this host.
Same-model agreement is useful independent context, but is not cross-model confirmation.

| Dimension | Independent agent | Codex CLI | Consensus |
|---|---|---|---|
| Premises valid | Output contract valid; scope too narrow | Same | Agree, scope updated from user instruction |
| Right problem | Observable upstream behavior | Same | Agree |
| Scope calibrated | Audit all declared adaptations | Same | Agree |
| Alternatives explored | Inventory plus incremental fixes missing | Same | Agree, added |
| Product risks covered | Source parity is not runtime parity | Same | Agree |
| Six-month trajectory | Versioned acceptance evidence needed | Same | Agree |

Claude/Codex cross-model consensus: N/A for all six dimensions. Independent findings are retained regardless.

## 1. Architecture

Upstream session/document logic remains authoritative, with Linux-specific transport and rendering adapters.
The new touch filter breaks lifetime ownership: application-owned callback captures a window pointer.
Fix ownership and preserve stable input targets rather than introducing application-wide geometry mutation.

```text
Upstream session/document -> Linux bridge -> Qt host -> input/display
Upstream UI -> compat AppKit/SwiftUI -> NativeLowering -> Qt controls or bitmap views
Image file -> Qt/libheif decode -> profile conversion -> sRGB pixels -> upstream import
Snapshot -> upstream render -> ImageIO compat -> Qt/libheif tagged encode
```

## 2. Error and rescue map

Codec failures currently use C integer results; they must distinguish decode failure from incorrect color conversion.
Gradient completion is different: upstream can return early or consume an error internally, so the bridge must
observe the resulting session state before dispatching dependent edits. Do not add a timeout that leaves late edits live.

| Path | Failure | Rescue / result | User outcome |
|---|---|---|---|
| Decode | Missing/invalid bytes | Existing decode error | Import fails without replacing document |
| Color profile | Unknown/unsupported transfer or invalid conversion | Accurate mapping or explicit supported fallback; never mislabel known curves | Correct pixels or explainable import failure |
| Pending gradient | Project busy, apply error, retained edit | Refuse dependent command, preserve draft and report error | Existing work remains recoverable |
| Touch callback | Window destroyed | Object ownership removes filter | No dangling callback/crash |
| Integrity checks | Multiple stale generators | Collect all failures and nonzero final result | Contributor sees every failing check |

## 3. Security and threat model

Image files remain the untrusted input boundary; this work adds no remote endpoint, credential or authorization surface.
HEIF profile sizes and allocations need bounded handling through existing decoder budgets, and conversion failure must
not manufacture success. Native pointer callback lifetime is a high-impact local crash risk verified from current code.
Use the current platform dependencies; no new image decoder or privileged service is required.

## 4. Data flows and interaction edges

The color path must handle absent profiles, empty/malformed files, gray/RGB profiles, orientation, high-precision
sources and alpha before producing document pixels. Touch-to-mouse restoration must distinguish synthesized events
and must not move controls under the initiating finger. A switch after a pending gradient must either finish the
gradient and dispatch once or refuse the switch; duplicate/no-op success is not a valid alternate path.

```text
File -> decode -> profile transform -> RGBA8 sRGB -> document
 nil/empty: reject      invalid profile: policy/error      alpha: preserve
Touch -> scoped input state -> expanded hit test -> same command
 missing device: retain safe mode     window closed: callback removed
Command -> pending-gradient resolution -> postcondition -> dispatch
 busy/error: refuse before dispatch                       success: exactly once
```

## 5. Code quality

Generated UI files are good reuse examples because source drift is mechanically checked against tip.
The table-driven menu/session state is another useful reference; the host should observe upstream state rather than
create a parallel state machine. Avoid repeating that mistake with globally mutable touch state and stylesheets.
Correct stale comments that still describe pinned 1.3.4 Color Range or outdated test mirrors when generators read tip.

## 6. Tests

Read the new P3 and touch geometry tests and the existing exclusions. The untagged color test uses the tagging encoder,
so it cannot prove its name's behavior. Existing tests must remain unchanged; add independent fixtures and Linux-native
integration coverage. Current full-suite build is a baseline, not a passing result, and the two history skips remain
an explicit prior user policy to assess rather than silently erase.

```text
Profile input: P3 RGB [new fixture]; untagged/gray/HEIF curves/alpha [gaps]
Touch: handle reach [new unit]; native events/lifecycle/multi-window [gaps]
Gradient: normal switch [existing combo suite]; busy/error completion [gaps]
Native combination: actual move and transform drag/release [gap]
Integrity: current normal gate [passed]; multiple failing checks [gap]
```

## 7. Performance

RGB-to-wide conversion creates a second image and HEIF currently adds a copied RGBA image; peak memory must respect
the existing supported document limits. Profile conversion is import-time work, not a per-frame operation, so cache
or GPU infrastructure is unnecessary without measurement. Touch changes must avoid full application stylesheet relayout
on each device transition. The existing CPU/GPU evaluator difference is tracked separately and needs measurements before redesign.

## 8. Observability

Current guard success is actionable for source identity but hides unrelated failures after the first error.
Add named results with one final status; retain full native test logs, suite counts and command/upstream revision.
Command failures need the action and preserved session state in tests so false success can be diagnosed.
No application analytics service is needed; local diagnostics and versioned acceptance evidence serve this desktop tool.

## 9. Rollout and rollback

The user has requested implementation, not publishing. Work remains on the Linux branch and uses existing packaging
and backend selection; no new saved format is planned. Reversible source changes can be reverted independently,
while protected upstream trees and old readable project formats remain intact. Before release, build the actual
bootstrap, run affected suites, full suite and native journeys; a source-only gate is insufficient.

## 10. Long-term trajectory

The task list and behavior inventory reduce repeated confusion after future upstream merges.
Generating adaptations from tip is the desired direction; recording a stub as “compiled” is only a migration step.
Treat necessary platform substitutions by observable behavior and document any unavoidable difference.
Reversibility is high for adapter changes, but wrong imported pixels are durable data damage, so color correctness comes first.

## 11. Design and UX

Mac layout and behavior already provide the design system; no new brand direction or mockup is needed.
Touch support should change reachable hit regions without resizing control geometry during input.
Native bitmap views also need focus, keyboard and accessibility semantics; correct pixels alone are insufficient.
Import, busy, refusal and error states must mirror upstream behavior and preserve recoverable work.

## Failure modes registry

| Failure | Severity | Evidence | Required closure |
|---|---|---|---|
| Wrong colors baked into imported file | P1 | nclx curve simplification; gray bypass | Actual source profile conversion and fixtures |
| Closed window used by input filter | P1 | qApp parent + captured this | Safe ownership and native lifecycle coverage |
| Gradient command success without edit | P1 | busy early return and caught apply error | Session postcondition and error propagation |
| Missing native behavior masked by source pass | P1 | absent combo journey | Native gestures and coverage inventory |
| Misleading completion/evidence | P2 | old TODO and ledger labels | Current task list and accurate evidence references |

## NOT in scope

Unrelated GPU rewrites, new editable document precision, Mac source/test edits, deployment and pushing.
Actual Mac screenshot/round-trip execution and physical input checks require the relevant platform/device;
they remain acceptance evidence gaps, not invented local successes.

## Completion summary

| Item | Result |
|---|---|
| System audit | Four protected trees and local integrity checks pass; release baseline building |
| Premises | User confirmed upstream-first full compatibility; visual geometry follows upstream |
| Existing leverage | Current compat, codec, generated UI, session and native journey seams |
| Alternatives | Inventory plus incremental fixes selected; unrelated rewrite deferred |
| Sections | All eleven evaluated; error/rescue and failure registries recorded |
| Outside voices | Six agent and seven CLI findings; same model, no cross-model confirmation |
| Design scope | Yes: touch and native interaction |
| DX scope | Yes: integrity, evidence, test invocation |
| Unresolved permission | None for implementation within the stated scope |
| Unresolved delivery | Behavior inventory, runtime corrections and final verification |
