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

These passes do not establish a fix or a root cause. Keep the diagnostic in the
native gate and inspect any recurrence before changing field reconciliation or
the journey's timing. The original CI failure remains unresolved.
