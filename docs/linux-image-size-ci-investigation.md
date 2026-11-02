# Image Size CI typing investigation

CI run `40135765490` completed the native journey matrix with one failed gate:
`--combo-smoke --image-size-controls-probe`. The failure occurred while typing
the Centimeters height print dimension (`0.60960000`), after all three Inches
edits and the Centimeters width edit passed. The existing assertion combines
field lifetime, text, focus and cursor position, so that log does not identify
which invariant failed. This was a completed test failure, not the earlier
save-callback timeout.

`canvassizejourney::type`, also used by the Image Size journey, now logs the
field title, expected and actual text, focus state and cursor position before
that assertion fails. It retains the original keyboard events, event pumping
and assertions. No timeout, scheduling mode or acceptance condition changes.
The logging reports synthetic journey input only.

Local verification uses the rebuilt release `CompositorHostBootstrap`, Qt's
offscreen platform, the real Qt/Skia/PDF backends, the CPU image renderer and
`XCTestConfigurationFilePath=linux-contract-tests`:

- The complete image-size journey passes once with the ordinary local CPU count.
- Four more complete journeys pass in two rounds of two concurrent processes.
  Both processes share four CPUs, report four CPUs to the Swift runtime through
  the existing diagnostic shim, and use separate XDG configuration/data folders.
- Every run retains the six print edits, resampling and DPI controls, validation,
  Undo/Redo, deep SDR/HDR cases and multiple-window ownership assertions.
- The rebuilt native text backend smoke journey also passes.

Evidence is under `.build/evidence/`: `image-size-diagnostic-build.log`,
`image-size-diagnostic-probe.log`, `image-size-parallel-{0,1}-{0,1}.log`,
`image-size-parallel-results.json` and `text-final-native-smoke-probe.log`.
The original failed workflow output is in
`upstream-format18-callback-ci-failure.log`.

## Selection lost during model refresh

Diagnostic run `40143833991` reproduced the failure at the same Centimeters
height edit. It expected `0.60960000` but recorded `1.2190.60960000`, with focus
retained and the cursor at position 15. The old dimension remained in front of
the replacement input. The final diagnostic alone does not reveal the preceding
focus and refresh event sequence.

The native Qt `TextFieldState` regression reproduces that exact concatenation
deterministically: select the old print dimension with Ctrl+A, resolve a queued
model update to `1.219`, then type `0.60960000`. The previous refresh called
`QLineEdit::setText`, which cleared the selection and moved the caret to the end.

`SwiftUITextFieldState.h` now owns model-to-field updates. Focused, untyped fields
still accept new model values, while retaining a full or partial selection and
its direction. A full selection follows the new value's length; interior carets
are clamped and end carets follow the new end. Focused fields with typed input
retain their existing protection, and signal blocking prevents updates from
dispatching back into the Swift model.

The test fails with the original update behavior and passes with the fix. It
also checks shorter and empty values, reversed selections, caret positions,
typed input, unfocused fields and unchanged values. It runs through CTest and the
Linux contract script. Evidence is in `text-field-selection-{before,after}-fix.log`
and `text-field-state-ctest.log` under `.build/evidence/`.

The native typing helper additionally retains a bounded trace of text,
selection, focus and input-method events, printed on failure or when
`COMPOSITOR_TRACE_SIZE_FIELDS` is enabled. Keyboard events, event pumping and
acceptance conditions remain unchanged. The queued-update mechanism is proven
locally; its precise event ordering in the original CI run was not captured.

The isolated fixed host passes the complete Image Size, Canvas Size, transform
field and scrub journeys, plus 1,092 Swift tests and all 93 tested golden images
without baseline changes. Two more complete Image Size runs pass together on
four shared CPUs with the existing four-core runtime shim.

Further contention runs uncovered a separate wait in both the original and fixed
adapters. After the deep-layer DPI interaction, `DeepSizeJourney.h:59` waits for
the operation to finish while the Image Size dialog remains in its event loop,
reached through `SessionWindow::handleShellRequests`. The typing trace has already
recorded the inspector's DPI edit. These stacks do not establish why the dialog
failed to close or that any request was replayed. Four owned diagnostic processes were
stopped after saving their stacks; those runs are incomplete, not passes.
See `image-size-selection-{original,fixed}-main-stack.log` and
`size-selection-stress-process-cleanup.json`. The action diagnostics below
subsequently identified the missing handler behind a reproduced modal wait.

## Resize action missing after a conditional layout change

Conditional action diagnostics at `601a8b7` reproduced the modal wait in two of
four workers sharing four CPUs. Qt emitted the enabled Resize button's click
with node ID `0.11.2`, but `compositor_session_dispatch_swiftui_action` returned
`-1`: the latest Swift registry no longer had that visible control's handler.
The other two workers completed. The diagnostic watchdog stopped the two waits;
it did not count them as passes. See `modal-action-rejection-before-fix.json`.

The Resample conditional has different numbers of layout children in its two
branches. IDs assigned from flattened child offsets moved the following footer
when the branch changed. The host can retain the existing widgets while a field
is being edited, while resolving a fresh tree and replacing the action registry.
That combination retired the still-visible Resize button's action.

The compatibility resolver now retains declaration slots as view lists flatten.
IDs use those slots for a primitive's declared children, and separate true/false
branch identities. Fixed wrapper children, such as a background and its base,
retain positional identity independently of whether the wrapper's content is
visible. Pass-through modifiers and type erasure retain the child's declaration
identity. Rendered child order and layout remain unchanged. Declaration metadata
stays inside `RenderNode`, except for a reserved passive-text refresh slot in the
existing string parameters. The builder also retains a leading optional
tuple as a declaration slot instead of dynamically unwrapping and flattening it,
so following controls and their state paths do not move when it appears.

The regression dispatches the old visible footer ID against the newly resolved
handler registry. It fails with the original resolver. Further controls cover
optional and collection changes, conditional branches, modified groups, type
erasure, backgrounds, sheets and manually constructed node trees.

Distinct branch IDs also require refreshing passive conditional labels while an
edited field retains its widget tree. The Qt adapter can match a label by its
declaration slot when exactly one old and one new label occupy that slot. Both
must have no action handlers; interactive controls retain their branch identity.
This preserves the Canvas Size validation warning during numeric editing.

The isolated final candidate passes all 15 identity regressions, 195 XCTest
dispatches and 1,092 Swift Testing tests. All 93 generated golden images are
byte-identical to their committed baselines. Native Image Size, Canvas Size,
transform-field, scrub, input and layer-search journeys pass. Evidence is in
`swiftui-identity-passive-labels-verified.log`, `identity-reviewed-full-suite.log`
and `identity-reviewed-native-*.log` under `.build/evidence/`. Four additional
Image Size workers sharing four CPUs all complete, with no rejected sheet
actions or watchdog stops (`modal-identity-reviewed-results.json`). Source
coverage and its 11 regression tests pass. These local results do not establish
the outcome of a subsequent CI run.
