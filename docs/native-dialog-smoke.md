# Native dialog smoke test

The Linux contract runner exercises the native Qt dialog journey with
`CompositorHostBootstrap --dialog-smoke`. It checks resize and resolution changes,
filter preview/cancel/commit, adjustment panels, the command palette, autosave,
save/reopen and tool transitions.

Inside the runner's configured SDK environment, the default scratch-path command is:

```bash
QT_QPA_PLATFORM=offscreen .build/release/CompositorHostBootstrap --dialog-smoke
```

When the runner uses a different Swift scratch path, use that scratch directory's
release executable. The regular `scripts/linux-contract-tests.sh` invocation
includes this journey automatically.

The dialog helper observes presentation with a timer and a scoped Qt event loop.
It returns after the dialog closes, including interactions scheduled by the test
body. A ten-second deadline reports the action name and unwinds modal `exec()`
waits. `QPointer` tracks a dialog that may be destroyed on close.

The regression fixture pumps events inside an action before queuing its dialog.
The old helper waited inside that callback, preventing the action from reaching
the presentation request. It failed with `dialog missing`, as reported by Linux
CI [run 40178982588](https://github.com/chiddekel/Compositor/actions/runs/40178982588).
The fixture also delays its interaction and requires that
interaction to finish before the helper returns. The fixed helper passes this
fixture and the complete native dialog journey.
