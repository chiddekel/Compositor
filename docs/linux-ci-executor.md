# Linux save tests and executor starvation

The full Linux parity job in run `40122628134`, at commit `a822193`, exceeded its
150-minute limit. Native dependency preparation and compilation consumed about 53 minutes;
the parallel Swift run then stopped making progress with many tests unfinished.
The runner reported four CPU cores. Its native Mac reference completed successfully,
but Linux rendering and comparison never ran.

A local CPU-affinity limit alone did not reproduce the stall: Foundation still
reported twelve processors and the suite finished in 153 seconds. A diagnostic-only
CPU-count shim made Foundation report four processors as well as restricting CPU
affinity. Both the full suite and a focused five-suite subset then stalled.

The focused debugger snapshot shows all four cooperative workers waiting inside
`compositorSaveWritePackage` or `compositorSaveExportPreview`. These synchronous C
APIs wait for `ImageExporter` or `ProjectStore` actor operations. Calling them from
`Task.detached` occupies the same limited Swift pool that must run those operations.
The full-suite snapshot shows the same waits alongside the raster-worker barrier
deliberately held by `PendingGradientTests`.

The Qt host calls these APIs from native workers. `ProjectSaveSnapshotTests` now
uses `onNativeWorker`, which suspends its Swift caller and runs the blocking C call
on a dispatch worker. The helper forwards return values and thrown errors through
checked continuations. Production C APIs, upstream sources, save/preview behavior
and existing test assertions are unchanged.

The exact focused reproduction now passes 20 tests in five suites in 1.81 seconds
with the verified four-processor runtime view. It covers snapshot retention after
replacement/close, 16-bit/HDR packages, preview caching, save completion/history,
dependent gradient commands and native control callbacks. A separate probe verifies
that the helper has no current Swift task, is off the main thread, and preserves
return values and errors. The application sampling checks also pass 35 XCTest cases
and 29 Swift tests after rebuilding.

The Linux workflow now runs this parallel subset after the existing contracts,
with a five-minute step limit. The temporary CPU-count shim is not part of the
repository or workflow; the GitHub runner already has four real processors.

Local evidence is under `.build/evidence/`:

- `upstream-format18-parity-linux-terminal.log` and `upstream-format18-linux-ci-unfinished-tests.json`
- `upstream-format18-ci-four-worker-stacks-before.txt` and `upstream-format18-ci-callback-stacks-before.txt`
- `upstream-format18-ci-callback-subset-before.log` and `upstream-format18-ci-callback-subset-after.log`

The full constrained CPU rerun completes in 146.88 seconds: all 187 XCTest cases
finish, and all 1,038 parallel Swift tests terminate. Its 27 recorded issues are
exactly the existing fifteen unavailable-hardware assertions and twelve proposed
golden differences. The save and pending-gradient suites pass. With the physical
AMD Vulkan device exposed, the same four-worker parallel run completes in 91.294
seconds: 187 XCTest cases complete, and the 1,038 Swift tests report only the same
twelve golden differences. All fifteen hardware-availability assertions pass.
The same hardware run also passes all 48 serial Swift tests and nine native
adjustment journeys (`upstream-format18-ci-four-worker-hardware-full-status.json`).

The separate rendering candidate still has twelve unapproved golden differences
and 36 native comparison failures; this test-execution correction does not resolve
those rendering gaps.
