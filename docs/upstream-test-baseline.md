# Upstream test baseline (unmodified `CompositorTests` on Linux)

## Current-tree contract, resampling and Hide Others, 2026-10-16

Evidence for this section lives under `.build/evidence/` in the checkout. At about 09:35 an external cleanup
removed nearly every `/tmp/compositor-*` log and build cache that earlier sections cite, and emptied
`build-flatpak/`; those paths no longer exist. The SDK dependency modules were rebuilt from the manifest
(`.build/evidence/rebuild-sdk.{log,exit}`, exit 0). The earlier ECI CMYK fixture had no other copy, so CMYK
runs use Ghostscript's `default_cmyk.icc` installed as `Generic CMYK Profile.icc` (a fixture, not Apple's profile).

- **Clean complete run (run 6), after the code-level audit fixes:** exit 0 with integrity exit 0 in 18 minutes
  (`.build/evidence/full-contract-run6-clean.log`, `-integrity.log`): 1,122 framework tests (148 XCTest, 974
  Swift Testing including `RepresentableDismantleTests`) and all 33 native journeys including the newly gated
  `--package-smoke`.
- **Clean complete run (run 5) of the installed runner:** exit 0 with integrity exit 0 in 17 minutes
  (`.build/evidence/full-contract-run5-clean.log`, `.build/evidence/full-contract-run5-integrity.log`): 1,120
  framework tests (148 XCTest including `FileSystemObjectSourceTests`, 972 Swift Testing), all 32 native journeys
  (`--wand-repeat` 834 s, formerly 2,429 s), RAW lens, text backend, six group rotations, Grid settings, thumbnailer,
  source coverage and the Skia bridge. Earlier runs on the way: run 3 failed only `--transform-smoke` (inotify
  exhaustion, fixed by sharing one instance); run 4 deadlocked with parallel Swift Testing and was reverted.
- **Framework:** all 1,119 tests pass (147 XCTest, 972 Swift Testing) on the current tree, including the
  high-quality minification change (`.build/evidence/full-contract.log`).
- **Skia bridge:** `test_skia_bridge` adds direct, scaled, rotated and half-alpha 10x reductions of period-5
  stripes, which must equal their 102 area mean. The previous bridge fails all four (128, 128, 0 and 64 against
  51); the current bridge passes ("SkiaBridge smoke OK").
- **Hide Others / Show All:** under Xvfb with mutter as the X11 window manager, `--app-visibility-probe
  --hide-others-probe` hides a separate client's shown window, leaves its user-minimized window and both project
  windows/documents unchanged, and Show All restores exactly the hidden one
  (`.build/evidence/hide-others-x11-pass.log`, exit 0). The first attempt failed because mutter reports ICCCM
  WM_STATE Iconic for windows it shows; hidden state now follows EWMH `_NET_WM_STATE_HIDDEN`.
- **Native journeys:** 31 of 32 pass with three running at a time; `--tab-smoke` failed under that load
  ("multiple native rows did not reach the destination": its drag is released by a 20 ms timer and checked at
  once) and passes alone with the same build (`.build/evidence/tab-rerun.{log,exit}`, exit 0). The runner now
  runs `--tab-smoke` and `--preview-smoke` alone after the parallel batch. Because the run stopped at that gate,
  the trailing RAW lens, text backend, six group-rotation and Grid settings controls/restart checks ran
  separately against the same build and pass (`.build/evidence/contract-tail.{log,exit}`, exit 0).
- **Integrity:** required-shader protected-tree and ledger checks pass, before and after installing the new
  runner (`.build/evidence/full-contract-integrity.log`, `.build/evidence/integrity-new-runner.{log,exit}`).
- **Runner:** job counts follow cores, available memory and cgroup limits (build `min(cores, MiB/1536)`, native
  journeys `min(cores/2, MiB/2048)`); a 4-core, 16 GiB GitHub runner builds with 4 jobs and runs two journeys at
  a time. Each journey gets its own XDG copy and prints its whole log on completion; failures add `::error`
  annotations on Actions. The parallel/solo/annotation logic passes a stub harness inside the SDK.
- **Hide under X11:** the unchanged offscreen Hide checks fail under mutter ("project windows did not restore
  after Hide") because they assert one event pass after `showNormal()`, while a window manager restores
  asynchronously; an external poller shows Hide itself iconifies both windows
  (`.build/evidence/hide-x11-existing{,-states}.log`). `--hide-others-probe` hides through the visible menu from
  each window, waits for the manager's restore and passes with exact document isolation
  (`.build/evidence/hide-others-x11-pass.log`).

## Home-key viewport synchronization, 2026-10-16

The file-panel follow-up's preview failure now has an isolated boundary diagnosis.
A private renderer logs both states immediately after delivering Home: Qt's
visible scrollbar is still **863**, while the freshly resolved AppKit model
reports **scrollY 0**. The subsequent window-coordinate layer clicks miss the
viewport. This reproduces the original failure without attributing it to pending
AppKit reveals: the model has already moved correctly. Session 16899 exits 1;
see `/tmp/compositor-home-scroll-diagnostic-native.log`, lines 77–78, and
`/tmp/compositor-home-scroll-diagnostic-linked.exit`. The initial private link
attempt omitted SwiftPM's renamed main-symbol alias and failed to link; its
separate build log and exit remain preserved.

The Qt AppKit widget already synchronizes its enclosing scroll area after mouse
tracking. Keyboard dispatch now uses that same synchronization before returning,
so a following pointer event sees the viewport the model just selected. The
existing native preview adds a Home assertion before `processEvents`; periodic
panel refresh cannot hide the mismatch. The unchanged-renderer regression build
fails exactly at that assertion (`/tmp/compositor-home-scroll-before-native.log`,
line 77; `.exit` = 1). The fixed renderer passes the native preview journey on
offscreen Qt, including the previously failing Home, Command-click disjoint
selection and multi-row drag sequence (`/tmp/compositor-home-scroll-fixed-native.log`,
39 OK lines), plus the tab, dialog, image-clipboard and protected-upstream
integrity runs (`/tmp/compositor-home-scroll-fixed-{tabs,dialog,clipboard,integrity}.log`;
`/tmp/compositor-home-scroll-fixed.exit` = 0). The same preview journey also
passes on a private Weston/Xvfb Wayland session with the app in the Flatpak SDK
(`/tmp/compositor-home-scroll-wayland-input-native.log`, 39 OK lines;
`/tmp/compositor-home-scroll-wayland-{host,input}.exit` = 0). Both private
executables link immutable framework objects. Full file-panel session 83638
predates this fix and was interrupted; the current-tree full contract is
`/tmp/compositor-home-scroll-full-contract.log`.

## Owned Open/Save panels and project-package selection, 2026-10-16

The next native audit reproduces two missing behaviors with private temporary
projects. NSOpenPanel's explicit first-window sheet appears on the second active
window. NSSavePanel and the actual ProjectController Save As flow show no chooser
and return Cancel. Session 81798 exits 1; all three cases are recorded in
`/tmp/compositor-file-panel-before-native.log` (modes 0, 1 and 2).

NSSavePanel now retains its requested presentation window weakly during the
callback, including inherited NSOpenPanel presentations. The session-aware
file-panel callback shares live-owner resolution with alerts, retains legacy
Open registration, and implements both Open and Save. JSON transports panel
options and returned paths without splitting Unicode/newline filenames.
Negative response sizes retry a cached native selection instead of reopening
the chooser. Closed owners and invalid replies cancel. The Qt adapter preserves
file types, title/message, suggested name, creation permission, selection mode,
project-package folder opening and confirmed replacement of an existing package.

The initial focused build (52965) compiles in 555.90 seconds but exits 1 with two
assertion issues: this app's exported project type has no filename-extension
tags. The fix registers `.comp` once when the desktop panel adapter is installed,
matching Config/Info.plist, rather than weakening the package assertions.
Session 54985 then passes 12 XCTest + 23 Swift Testing cases in seven suites
(35 focused checks; 375.96-second rebuild) and integrity. The subsequent Save-label
widget rebuild also passes those 35 checks and integrity in session 71401
(40.00-second build, exit 0). Logs use
`/tmp/compositor-file-panel-{fixed,types-fixed,widget-fixed}-{tests,integrity}.log`.
The original failing `.exit` remains 1; the latter two are 0.

The permanent Qt-only `CompositorCore.NativeFilePanels` CTest drives actual
filename inputs and dialog buttons: Open/Save/Cancel, Unicode, short-buffer
single presentation, package-folder opening, replacement confirmation, the
Save label for a package and automatic `.comp` suffix. CTest and direct execution
pass in session 91094 (exit 0), logs:
`/tmp/compositor-file-panel-ctest-final-{native,direct,build,configure}.log`.
Early private-driver attempts are retained; they clicked a disabled Open button,
left a stale preset filename or blocked their own timer inside the nested
replacement question. The corrected driver waits for enabled acceptance,
commits the visible filename and queues its click outside that inspector slot.
A label assertion additionally catches Qt's directory Open label; a package-only
widget hook keeps the action Save. The failed configuration without the SDK
compiler PATH and failed label-check wrappers remain separate evidence.

Full regression session 12628 exits 0: all 147 XCTest + 972 Swift Testing cases
pass (1,119 total; 162 suites, 109.224 seconds), followed by native preview,
tabs, normal-startup dialogs, image clipboard/replacement and required integrity.
Logs: `/tmp/compositor-file-panel-regression-{framework,preview,tabs,dialog,clipboard,integrity}.log`.

The actual producer fixture passes 14 native cases in session 88294 (exit 0):
both window directions for Open/Save/Save As Cancel, exact Cancel isolation,
accepted single/multiple Unicode files and directory paths, ProjectController
Save As and replacement, package reopen with exact rendered pixels/layer records,
and reuse after the newer window closes. Log:
`/tmp/compositor-file-panel-native-reopen-verified-native.log`.
Earlier fixture failures remain: its windows initially aliased one tab and its
manual controller call omitted the real public tab-selection boundary; the
corrected fixture uses distinct projects and that boundary. Its first reopen
oracle retained the old file URL while changing canvas size, so upstream
correctly selected that already-open edited project. Clearing that binding
before reopening exercises actual loading into a new workspace tab. The tests
retain exact pixel/record comparisons rather than accepting the wrong 16×16 tab.

Upstream's workspace Open also selects multiple `.comp` packages. A local Qt
probe confirms real multiple directory-row selection (session 33437, exit 0),
and the adapter now enables it for package/folder multiselection. Focused rebuilds
89390 and 53037 pass all 35 checks and integrity; expanded CTest sessions 1552 and
61200 pass seven visible chooser scenarios, including actual selection of two
package directory rows. Their logs use `/tmp/compositor-file-panel-{multi,final}-fixed-*`
and `/tmp/compositor-file-panel-ctest-{multi,complete}-*`; all corresponding `.exit`
files are 0. Empty captions receive normal Open/Save defaults.

The final producer fixture passes 16 cases in session 10817 (exit 0), including
Save As in both windows and opening two distinct saved projects, one with black
pixels and one white. Both loaded workspace tabs retain their own exact pixels
and layer records. Native Wayland repeats all 16 cases in session 1793 (exit 0)
and checks each chooser's native transient parent. Logs:
`/tmp/compositor-file-panel-native-complete-native.log` and
`/tmp/compositor-file-panel-wayland-native.log`. The Wayland wrapper's `.exit` is 0;
both owned Weston/Xvfb servers exit 0 afterward and the socket lock is absent.
This verifies Qt-hosted native Wayland dialogs, not a physical desktop portal.

A later native-only regression wrapper, session 94792, exits 1 in preview's
Command-click disjoint-selection check. Its trace shows Home key 115 delivered
to the current session-9 table, but the Qt viewport still has offset 863; intended
rows 2/8 map to window Y -474/-150, outside the visible viewport, with no hit
widget. This is retained in
`/tmp/compositor-file-panel-native-regression-preview.log`; it is not relabeled
passing or attributed to file-panel changes. The Home/queued-scroll interaction
needs an isolated reproduction. Remaining tabs/dialog/clipboard/integrity phases
pass separately in session 59759 (exit 0), prefix
`/tmp/compositor-file-panel-native-regression-resume-*`. This includes native
multi-window tabs, normal-startup save/reopen dialogs, clipboard replacement and
protected-upstream integrity. The preview failure remains open; the earlier
complete regression 12628 remains a recorded pass within its build scope.

The canonical runner now includes the permanent chooser test: **37 gates**, 34
host commands plus three standalone gates. It was replaced atomically so the
three already-running 36-gate scripts retain their original contents and scope
(45852 alert, 61973 teardown/clipboard, 25384 entry/popup). They predate this
file-panel work. The fresh current 37-gate run is session 83638, scratch
`/tmp/compositor-file-panel-build`, module cache `/tmp/compositor-file-panel-module-cache`.
Logs: `/tmp/compositor-file-panel-full-contract.{log,exit}` and companion integrity
log (pending). Its framework phase has passed all 147 XCTest + 972 Swift
Testing cases (1,119 total; 162 suites, 109.106 seconds); the chooser component
also passes in this run. Native gates are still running, so the complete contract
is not yet a pass.

Two older runs have now terminated. Alert-build session 45852 completes all 36
gates and protected-upstream integrity (exit 0), including 147 XCTest + 966 Swift
Testing cases (1,113 total; 161 suites, 117.308 seconds). Its logs are
`/tmp/compositor-alert-owner-full-contract{,-integrity}.log` and `.exit`.
Entry/popup session 25384 exits 139 in `--transform-smoke` after its external
package-corruption recovery marker. The Swift runtime could not suspend threads
or produce a usable backtrace; preserve
`/tmp/compositor-entry-owner-full-contract.log` and `.exit`. That binary predates
clipboard, teardown, alert and file-panel fixes; this crash is not attributed to
any one of them or claimed resolved. Teardown session 61973 remains pending.
Earlier sections' running-state statements describe their recorded checkpoints;
these terminal results supersede those states.

Physical desktop portals, broader chooser/window combinations,
the observed Home/scroll issue and Mac acceptance remain open.

## Native alert window ownership, 2026-10-16

The application-callback audit finds that HeldModifiers refreshes modifier state
on activation/menu-end and RecentProjects refreshes its URL list on activation;
these traced observers do not dispatch project shell requests. A separate alert
boundary loses an explicit project window. Upstream's ProjectController and
external-change prompt use `NSAlert.beginSheetModal(for:)`, but the compatibility
handler discards that window and Qt always parents its message box to the active
window.

The native two-window reproduction fails in session 10802 (exit 1): a real
`beginSheetModal(for:)` requested for handle 1 while handle 2 is active creates a
visible QMessageBox parented to the second window. Cancel returns the correct
button response. `/tmp/compositor-alert-owner-before-native.log` records
`actual parent is first false actual parent is second true`. The private fixture
links immutable existing application objects and does not rebuild either active
contract executable. It tests the actual NSAlert/Qt path with an upstream-style
explicit sheet window, not an invocation of ProjectController's private method.

`NSAlert` now exposes its temporary weak presentation window to native handlers
and restores it afterward. A new session-aware alert presenter maps that window
to its live session; synchronous modal alerts use their explicit request owner,
and unowned application alerts use handle 0. Closed or unresolvable explicit
owners cancel instead of falling back to the active window. Qt parents project
alerts to the corresponding live SessionWindow. The legacy presenter remains
available with unchanged response encoding. Four new bridge tests cover both
window directions, modal/application alerts, closed owners and legacy clearing.

The real unsaved ProjectController close path also displays its alert on the
wrong window, then exposes a second failure: refreshLayers sets checkboxes while
`m_syncingLayers` is true, but the visibility/mask callbacks dispatch commands
without checking that flag. GDB traces the nested command waits from
QCheckBox::toggled through setLayerFlag/sendCommand/awaitOnMain, below
QDialog::exec and ProjectController.confirmReplacement. Diagnostic logs are
`/tmp/compositor-alert-controller-before-{native,gdb-main,gdb-full}.log`.
The fixture remains live until explicitly terminated after stack capture
(session 85744, exit 143); that is not a completed passing or normal assertion
result. The two checkbox callbacks now honor the existing synchronization flag,
so displaying model values does not feed commands back into a modal operation.

The first isolated build (54292) exits 1 because copied Clang PCMs embed the old
module-cache path; `/tmp/compositor-alert-owner-fixed-tests.log` retains that
build-environment failure. A fresh module cache at
`/tmp/compositor-alert-owner-module-cache` and separate scratch directory
`/tmp/compositor-alert-owner-build` resolve it. Session 7169 exits 0 after a
566.03-second build, with 12 XCTest + 17 Swift Testing tests passing (29 focused
checks, six Swift Testing suites) and integrity. After that build is terminal,
the checkbox-guard rebuild and the same 29 checks plus integrity pass in session
31538 (40.41-second build, exit 0). Logs:
`/tmp/compositor-alert-owner-{cache,guard}-fixed-{tests,integrity}.log` and `.exit`.

The extended native ProjectController close fixture uses the guarded build for
both background-window directions and older-window reuse after newer close,
checking Cancel and document/history isolation. Session 91888,
`/tmp/compositor-alert-owner-native-fixed-{native,build}.log` and `.exit` (0).
All three cases pass: both background-window directions and the original window
after the second closes, with actual unsaved ProjectController close prompts,
correct Qt parents, Cancel and exact checked document/history fields. The
fixture now exercises the real producer, extending the initial direct NSAlert
reproduction. Native Wayland repeats all three real close-prompt cases and also
requires the message box's QWindow transientParent to be the expected native
window. Session 83228 exits 0, with three correct-parent records and its final
acceptance marker in `/tmp/compositor-alert-owner-wayland-native.log`;
`/tmp/compositor-alert-owner-wayland.exit` is 0. The private input-capable
Weston/Xvfb servers are stopped afterward; their sessions exit 0 and the socket
lock is absent. This verifies native Wayland parenting, not physical input.

Full framework/preview/tabs/dialog/clipboard regression completes in session
51706 with exit 0: 147 XCTest + 966 Swift Testing cases pass (1,113 total;
161 suites, 116.623 seconds), all four native journeys pass and required
integrity passes. Logs:
`/tmp/compositor-alert-owner-regression-{framework,preview,tabs,dialog,clipboard,integrity}.log`
and `.exit` (0).

A fresh complete 36-gate contract starts only after those build/fixture/regression
sessions are terminal: session 45852, scratch `/tmp/compositor-alert-owner-build`,
module-cache arguments pointing at `/tmp/compositor-alert-owner-module-cache`.
Logs: `/tmp/compositor-alert-owner-full-contract.{log,exit}` and companion
integrity log (pending). The older full contracts remain running (61973,
teardown/clipboard build; 25384, entry/popup build) and predate the alert fixes.
Broader background-operation/dialog combinations and physical/Mac acceptance
remain open.

## Close-time lifecycle request ownership, 2026-10-16

The teardown audit confirms a failure beyond popup cancellation. A registered
`ChangeTracker` disappearance callback belongs to closing handle 1, but the
C-ABI close invoked under caller 2 runs it as handle 2. Both its immediate Save
and deferred Export request then target the surviving handle. The isolated
fixture uses the real lifecycle registry, panel scope, C ABI and queue, linked
to immutable existing objects without rebuilding either active contract binary.
The noncrashing reproduction exits 1 in session 59312:
`/tmp/compositor-close-owner-before-safe-native.log` records
`closing=1 survivor=2 observed=Optional(2) restored=Optional(2)` and the two
incorrectly attributed queued requests. The initial trapping fixture (session
51390, exit 132) is retained separately and is not a passing test.

`releaseSessionHandle` now binds the closing handle while its complete owned
teardown runs: popup completion, queue removal, controller/project/tab cleanup,
panel disappearance/state disposal and canvas close. A disappearance callback
runs after entry removal; its immediate and inherited deferred requests retain
the closed owner and are rejected instead of falling back to another window.
The caller's task-local context is restored afterward. The regression in
`ShellRequestOwnershipTests.swift` checks that behavior and survivor retention.
This exercises a supported lifecycle callback boundary; it does not claim an
existing upstream disappearance callback currently invokes Save/Export.

The fresh clipboard contract (session 84680) stops with exit 1 because its test
source was edited while Swift compiled it, before execution of the new test.
`/tmp/compositor-wayland-clipboard-full-contract.log` explicitly reports
`ShellRequestOwnershipTests.swift` modified during build. That wrapper/result is
retained; it is not a product regression or a completed contract. Source files
are held unchanged during the replacement focused build, session 47641.
It exits 0 after a 331.39-second release rebuild: all four native lifetime XCTest
cases and 13 Swift Testing cases in five suites pass, including the new lifecycle
regression (17 focused tests total). Required integrity also passes. Logs:
`/tmp/compositor-close-owner-fixed-{tests,integrity}.log` and
`/tmp/compositor-close-owner-fixed.exit` (0).

Full framework and native regression completes in session 54499 with exit 0,
using the resulting executable without rebuilding it. All 147 XCTest + 962
Swift Testing tests pass (1,109 total; 160 suites, 121.218 seconds). Native
preview, tabs, normal-startup dialogs and image clipboard/replacement journeys
also pass, including exact records/pixels and Undo/Redo; required integrity
passes. Its `-framework.log`, `-preview.log`, `-tabs.log`, `-dialog.log`,
`-clipboard.log` and `-integrity.log` share the
`/tmp/compositor-close-owner-regression` prefix; its `.exit` is 0.

After that wrapper is terminal, a fresh complete 36-gate canonical run starts
as session 61973 in `/tmp/compositor-crash-recovery-build`. Source files remain
unchanged during its build. Logs are
`/tmp/compositor-close-owner-full-contract.{log,exit}` and its companion
integrity log. No final result is available.
The older entry/popup contract remains session 25384; the last complete contract
is session 87491 (36 gates / 1,103 tests), which predates entry/popup, clipboard
and this teardown fix. Broader direct app-level producers, reentrant lifecycle
combinations, physical desktop delivery and Mac comparison remain open.

## Native Wayland seat and clipboard ownership, 2026-10-16

The unchanged entry/popup executable passes the full native Wayland preview and
normal-startup dialog journey when Weston uses its X11 input backend over a
private Xvfb display. Rename-editor Copy/Paste, layer focus/accessibility,
keyboard/tool input, mask/pixel/text edits and Undo/Redo pass. Both
`/tmp/compositor-wayland-input-{preview,dialog}.exit` are 0. Logs use the same
prefix. This resolves the earlier seatless compositor's preview limitation;
it does not certify physical input or desktop interapplication delivery.

A separate normal-system-pasteboard image journey exposes a real Wayland
ownership defect: selected PNG pixels match, but Paste centers the 20×20 image
at [22,22] instead of retaining [12,12]. The diagnostic records a synchronous
own-write notification with external count 1, followed by an asynchronous
notification while Qt still owns the clipboard, increasing the count to 2.
Upstream therefore rejects its retained pixel clipboard and treats the same
image as external. Both the original run and diagnostic exit 1:
`/tmp/compositor-wayland-input-image-clipboard.log` and
`/tmp/compositor-wayland-clipboard-diagnostic-native.log`.

`host/SystemClipboard.h` tracks the written MIME object with `QPointer` so a
later notification for that same object keeps the original change count.
Replacement data, including writes from Qt editors, still invalidates the
cached selection. The native image journey adds a replacement-image oracle:
centered 6×8 green pixels, exact source records, and Undo/Redo. A private
executable rebuilds both host translation units without relinking either live
full-contract executable. The real Wayland image journey now passes Copy, Copy
Merged and Cut, retained crop origin/dimensions, every pixel and Undo/Redo, plus
the replacement-image oracle. `/tmp/compositor-wayland-clipboard-input.exit`
is 0; its `-native.log` contains all four acceptance markers.

Intermediate fixed builds expose a separate test-input limitation: Paste is
enabled, but the compositor dismisses a popup opened without a fresh real input
serial. A diagnostic records enabled=true/visible=false. Native popup sync alone
does not solve it, and that experimental driver change is removed. The final
private Wayland driver requests a real Shift press/release from a host-side
`xdotool` worker targeting only the owned Xvfb window before each menu. Seven
input requests complete and the worker exits 0. This hook remains under `/tmp`;
the repository driver retains actual menu visibility/enabled assertions and
adds failure diagnostics. No application input or clipboard assertion is
bypassed. The unmodified repository driver also passes independently offscreen, including
all three image choices and replacement-image invalidation. The same fixed
executable passes the full Wayland preview and normal-startup dialog journey.
`/tmp/compositor-wayland-clipboard-final.exit` is 0; companion logs are
`-native.log`, `-preview.log` and `-dialog.log`. Required protected-source,
generator, shader and ledger integrity passes in
`/tmp/compositor-wayland-clipboard-integrity.log`. The input worker and both
owned servers are stopped after testing; the Wayland socket lock is absent.

The older 36-gate contract finishes in session 87491 with exit 0: all 147 XCTest +
956 Swift Testing tests (1,103 total; 159 suites, 105.804 seconds), all 34
host-native commands, both standalone gates and required integrity. Logs:
`/tmp/compositor-deep-size-full-contract.{log,exit}` and its `-integrity.log`.
This is the latest complete canonical checkpoint, covering the menu/deep-sizing
build. It predates common-entry/popup and clipboard corrections. Session 25384
still runs the entry/popup build and also predates this clipboard fix.

After confirming session 87491 is terminal, the fresh complete current-source
contract starts as session 84680 in its released `/tmp/compositor-crash-recovery-build`.
Logs: `/tmp/compositor-wayland-clipboard-full-contract.{log,exit}` and companion
integrity log. It is pending. The existing canonical image gate exercises the
extended probe after this fresh build. Physical input, external applications and Mac
comparison remain separate open acceptance scopes.

## SwiftUI/AppKit entry ownership and popup lifetime, 2026-10-16

The remaining input-entry audit reproduces failures beyond menu/palette dispatch.
A SwiftUI action queues an unowned request instead of its supplied session.
Closing a session leaves its popup callable, and replacing/dismissing a popup
runs completion under another caller's context. The three isolated reproductions
fail with five assertion issues in
`/tmp/compositor-entry-owner-before-safe-tests.log` (wrapper exit 1). Real
`NSMenu.popUp`, selector targets and close delegates exercise the popup lifecycle;
targets/delegates are retained through the assertions despite their weak menu
references.

Nested entry also crashes before ownership assertions. The SDK GDB trace in
`/tmp/compositor-entry-owner-reentry-gdb.log` stops at
`__DISPATCH_WAIT_FOR_QUEUE__`, called from `onMain` → `withEntry` → SwiftUI action
dispatch while already on the main queue. On Linux that queue can run on a worker
with `Thread.isMainThread == false`. The debugger wrapper's exit 0 is diagnostic,
not a passing test. The initial and broader crashing runs are retained in
`/tmp/compositor-entry-owner-before-tests.log` and
`/tmp/compositor-entry-owner-before-all-tests.log`. This fixes the main-actor ABI
entry limitation avoided with detached callers in the earlier checkpoint below.

`SessionABI.swift` now recognizes the main dispatch queue with the same queue-key
pattern already used by the notification helper. `withEntry` binds the supplied
handle for its whole callback and restores the caller afterward; nested drops
and deferred tasks retain their own correct owner. `AppMenus.swift` captures a
popup's presentation owner and uses it for validation, choice, replacement,
dismissal and completion. Closing its owner cancels that popup before removing
queued work; a later choice cannot invoke the stale target. These changes affect
two production files. Tests are in `ShellRequestOwnershipTests.swift` and the new
`PopUpRequestOwnershipTests.swift`.

All 12 focused tests in five suites pass in
`/tmp/compositor-entry-owner-fixed-tests.log` (0.066 seconds), including the
existing nested/disabled popup, button-event and sheet-binding/dismissal tests.
`/tmp/compositor-entry-owner-fixed.exit` is 0 and required protected-source/
generator/shader/ledger integrity passes in its companion integrity log.

The full framework phase passes 147 XCTest + 961 Swift Testing tests (1,108
total; 160 suites, 112.477 seconds) in
`/tmp/compositor-entry-owner-regression-framework.log`. Its wrapper stops at Grid
Settings with disabled OK after rapidly typed valid values (session 79142, exit
1). The diagnostic driver confirms visible 24/3/75 with the previous invalid
hint; dumping render trees shows the model reaching the correct values and
makes the full journey pass. The modal redraw runs every 16 ms. The driver now
waits for actual enabled OK and the valid hint before confirming; its fresh
release-build controls pass in session 58208. The direct restart attempt in that
wrapper incorrectly retains XCTest defaults isolation, so it exits 1. The
repository's normal-startup `test_grid_settings` helper clears that flag and
passes controls plus actual separate-process persistence, with required
integrity (session 18926, `/tmp/compositor-entry-owner-grid-complete.exit` is 0).
Logs: `/tmp/compositor-entry-owner-grid-{verified,complete}-*.log`.
Evidence: `/tmp/compositor-entry-owner-{regression-grid,grid-diagnostic-native,grid-tree}.log`.
The other six native journeys and required integrity pass in the resumed
wrapper, session 11153, exit 0:
`/tmp/compositor-entry-owner-regression-{canvas,visibility,preview,transform,dialog,sizing,integrity}.log`.
The original failing wrapper is retained rather than relabeled successful.

Native Wayland passes all 24 sizing/ownership markers using a private executable
copy. Preview then fails at rename-editor Copy: Qt reports
`Can't set clipboard contents with no wl_seats available`. The private headless
Weston compositor is stopped and its socket lock is absent. The wrapper (session 36075) exits 1; this is not counted
as a passing Wayland preview/clipboard check. Logs:
`/tmp/compositor-entry-owner-wayland-{sizing,preview}.log`. The current 36-gate
contract is running in session 25384 using `/tmp/compositor-mask-load-build`:
`/tmp/compositor-entry-owner-full-contract.{log,exit}` and companion integrity
log; no final result is available. The earlier 36-gate session 87491 remains
running in `/tmp/compositor-crash-recovery-build` on the preceding menu/deep-sizing
build and does not cover this entry/popup fix.
Direct app-level/`onMain`-only callbacks and teardown beyond popup cancellation
still need an ownership audit; broader platform and physical/Mac acceptance
remain open. The 90-row inventory and historical 70-row accounting are unchanged.

## Session-owned menu requests and deep sizing, 2026-10-16

Extending row 57 to native 16-bit/HDR sizing exposes a real two-window routing
defect. The first window's timer drains a global Image Size request intended for
the second window, while the global sheet presenter retains the second window.
The command waits indefinitely for a sheet on the wrong session. The original
probe is stopped with exit 130 after diagnosis, not counted as passing:
`/tmp/compositor-deep-size-before-native.log` and the symbolized/main/owner-values
backtraces under `/tmp/compositor-deep-size-`. The owner-values trace confirms
different requesting and presenting windows with the presentation guard false.

Requests now carry a session handle and each Qt window drains only its displayed
session's queue. Closing a handle drops its pending requests. Sheet presentation
and long-operation repainting resolve the live owning window from the session,
including the explicit session when rendering and checking sheet lifetime.
An intermediate scoped-queue correction exposes a second race: an asynchronous
menu task queues Image Size for session 5 instead of its dispatch owner 1.
`/tmp/compositor-deep-size-task-owner-before-native.log` retains that failure.
Task-local ownership alone still allows an intermittent wrong owner when sampled
from global selection: workspace bootstrap can register several handles for the
same tab, and a first-match lookup can select another window's alias. The
identical executable passes one profile and fails another (`/tmp/compositor-deep-size-owned{,-prototype}-native.log`). Qt now passes
its handle explicitly through `compositor_session_app_menu_perform`; the task
retains that dispatch owner through deferral. Menu and palette actions share
this ownership context. Generated command-palette/canvas-only overrides and their
generator/patch sources use the same enqueue path.

All 41 focused tests pass (original ImageSizeTests/DeepLayerTests plus three new
ownership tests). The first unit driver called the foreign-thread C ABI directly
from Swift Testing's main actor and crashed before assertions; its output is
retained in `/tmp/compositor-deep-size-unit-entry-before-build.log`. Matching the
existing detached-thread bridge-test convention corrects that harness error.
The final focused wrapper and required integrity exit 0 in
`/tmp/compositor-deep-size-bound.exit` and
`/tmp/compositor-deep-size-bound-{build,native,integrity}.log`.

Two independent offscreen profiles pass all 24 native markers. Native Wayland
passes the same 24 plus four Hide cases; its private headless compositor is
stopped afterwards. Logs: `/tmp/compositor-deep-size-bound-prototype-native.log`,
`/tmp/compositor-deep-size-wayland-{native,visibility}.log`; wrapper exits are 0.
The original 17 RGBA8 checks remain, with six additional deep checks and a window
ownership check. Both 16-bit PNG and HDR EXR fixtures contain transparent,
partial-alpha and opaque pixels. Print-only DPI edits retain saved source
channels; Nearest 2× resampling matches an independent every-channel oracle
(16-bit tolerance 2; float tolerance 0.008 for codec/half-float rounding), including
Undo/Redo and saved-package reopen. Canvas crop/re-expansion retains those deep
assets and verifies saved dimensions, center translation and separate Undo steps.
The older window is exercised while each newer window lives and after newer
window destruction. Other sampling algorithms, masked/grouped/transformed deep
sizing combinations and physical/Mac acceptance remain open.

The full framework/six-native regression wrapper exits 0 in session 34499:
147 XCTest + 956 Swift Testing tests (1,103 total; 159 suites, 105.055 seconds),
Grid, Canvas Size, Hide, preview, transform/save/reopen, dialog and required
integrity all pass. Logs:
`/tmp/compositor-deep-size-regression-{framework,grid,canvas,visibility,preview,transform,dialog,integrity}.log`;
`/tmp/compositor-deep-size-regression.exit` is 0.

The current 36-gate full contract is running in session 87491 using
`/tmp/compositor-crash-recovery-build`:
`/tmp/compositor-deep-size-full-contract.{log,exit}` and companion integrity log.
It has no final result yet. The preceding 35-gate session 66977 has now completed
with exit 0: all 1,100 framework tests, all 33 host-native commands and two
standalone gates, required backends/coverage and integrity pass in
`/tmp/compositor-canvas-size-full-contract.{log,exit}` and companion integrity
log. That build includes numeric-field/Canvas Size and Hide/popup fixes, but
predates Image Size/deep-sizing probes and this ownership correction. The earlier
34-gate session 94463 also completed with exit 0 and required integrity. Older
sections retain descriptions from their checkpoints; this section gives the
latest full-run state.

## Image Size visible units, resampling and print dimensions, 2026-10-16

Historical row 57 now has direct native Image Size acceptance in
`host/ImageSizeJourney.h`, dispatched by `--image-size-controls-probe`.
The actual Image menu opens the upstream sheet over an opaque patterned 64×48
RGBA8 source at 100 DPI. All checks pass in
`/tmp/compositor-image-size-native.log`; wrapper session 79035 exits 0 and
`/tmp/compositor-image-size-native.exit` is 0:

- Six print-only edits: Inches/Centimeters × Width/Height/Resolution. Turning
  Resample off filters the picker to those two units, hides Sampling and disables
  aspect-lock editing. Entering a print dimension refreshes Resolution while
  focus/text/cursor remain intact. Committing 200 DPI retains every source pixel,
  layer record and canvas dimension, with exact single Undo/Redo.
- Eight resampling cases: Pixels/Percent/Inches/Centimeters × locked/unlocked
  aspect. Nearest sampling produces uniform 2× or horizontal-only 2× output;
  an independent integer-coordinate oracle checks every pixel, retained target
  identity and exact single Undo/Redo.
- Two print-unit DPI resizes retain the displayed print dimensions while
  doubling pixel dimensions. Exact nearest pixels, committed DPI and Undo/Redo
  pass independently of the dimension-entry path.
- Cancel retains original pixels/state, reopening restores default Resample,
  Pixels and original DPI, and 9,601 DPI disables Resize while still focused.

The first attempt opened the units popup before the asynchronous Resample
refresh finished, preserving the old popup's items. Its failure is retained in
`/tmp/compositor-image-size-picker-initial-native.log`. Waiting for the two-item
picker before opening it makes the check pass; no production change is needed.
The passing probe extends the existing numeric-field correction. It is compiled
and linked to `/tmp/compositor-image-size-native/CompositorHostBootstrap` using
read-only existing Swift/host objects, with only DialogJourney replaced in an
isolated object list. Neither executable used by the running full contracts is
rebuilt or replaced.

The same 17 acceptance cases also pass on Qt's native Wayland backend using a
private headless Weston compositor (`/tmp/compositor-image-size-wayland.log`,
wrapper session 36214 exit 0; `/tmp/compositor-image-size-wayland.exit` is 0).
The owned compositor is stopped afterwards and its socket lock is absent.
Missing decoration icons and the headless GDK keyboard-seat warning remain
nonfatal environment messages; physical hardware/input acceptance is separate.

Required protected-source/generator/shader/ledger integrity passes in
`/tmp/compositor-image-size-integrity.log` (exit 0). The current 35-gate full run,
session 66977, passes its framework phase: 147 XCTest + 953 Swift Testing tests
(1,100 total; 158 suites, 107.387 seconds), including all three original
ImageSizeTests. Its native phases remain running and it predates this added
probe. The older 34-gate session 94463 now exits 0, including all native gates
and required integrity. Its framework phase passed 1,100 tests (104.472 seconds
for Swift Testing); that build predates the numeric-field correction. Evidence:
`/tmp/compositor-hide-panels-full-contract.{log,exit}` and the companion integrity
log. The canonical runner
now contains 36 gates, including this separately passing Image Size probe;
a complete 36-gate run has not yet finished. These new native cases cover opaque
RGBA8 and Nearest sampling; other sampling algorithms, alpha/deep/HDR sizing
combinations and physical/Mac acceptance still need direct native evidence.

## Canvas Size live fields, units and anchors, 2026-10-16

Historical row 57 now has direct native Canvas Size evidence. The actual Image
menu opens the upstream sheet over a patterned 64×48 RGBA8 image at 100 DPI,
with half-alpha and opaque pixels. The corrected asynchronous presentation
probe reproduces enabled OK after typing invalid width 0 while retaining focus:
`/tmp/compositor-canvas-size-before-native.log`, wrapper exit 1. The first probe
did not wait for the menu's async task; that harness-only failure is retained
in `/tmp/compositor-canvas-size-initial-task-wait-native.log`.

The renderer now recognizes its value-backed numeric fields during editing and
refreshes enabled state, validation text and other bound fields without replacing
the focused field. Sibling updates block Qt signals; the active text, focus and
cursor remain exact. Initial construction and sibling updates share the existing
numeric formatting policy. The native probe verifies invalid 0/30001, valid
recovery, live size/warning text, locked-ratio Height updates, relative dimensions
and exact draft/Cancel isolation. Upstream deliberately disables history use
during a project sheet; document/history content is checked while open and full
Undo/Redo readiness after Cancel. A first overstrict readiness assertion is
retained in `/tmp/compositor-canvas-size-modal-readiness-before-native.log`.

All four original `CanvasSizeTests` pass. All 36 combinations of Pixels/Percent/
Inches/Centimeters and nine anchors pass visible picker, field and anchor-button
paths. Independent all-pixel translations use odd expansion deltas 31×17 and
floor the half-delta for center anchors; one Undo/Redo restores exact pixels and
records. Nine additional cases crop by 11 pixels, then expand by 13: all source
pixels outside the cropped canvas reappear at independently calculated offsets,
with separate Undo steps and retained identity. Evidence:
`/tmp/compositor-canvas-size-fixed-{build,native,integrity}.log`;
`/tmp/compositor-canvas-size-fixed.exit` is 0.

The shared renderer follow-up passes Grid controls/forced popup refresh/restart,
eight transform-field cases, label scrubbing, native dialog and preview journeys,
147 XCTest + 953 Swift Testing tests (1,100 total; 158 suites, 107.588 seconds)
and required protected-source/generator/shader/ledger integrity. A final four-case
native Wayland Hide check on this same numeric-field build also passes in
`/tmp/compositor-canvas-size-wayland-native.log` (wrapper exit 0); the private
headless Weston compositor is stopped afterwards. Logs for the other phases use
`/tmp/compositor-canvas-size-regression-`; framework and resumed-wrapper exit
markers are 0. The initial dialog check incorrectly enabled XCTest pasteboard
isolation while expecting the system clipboard; its output is retained in
`/tmp/compositor-canvas-size-dialog-test-isolation-before.log`. Removing that
flag makes the dialog and subsequent phases pass. Passing Grid/transform/scrub
phases are retained rather than repeated by the resume script.

The canonical runner now has 35 gates (33 host-native commands and two standalone
probes). Its current full run is session 66977:
`/tmp/compositor-canvas-size-full-contract.{log,exit}`, using
`/tmp/compositor-mask-load-build`. Session 94463 remains an earlier 34-gate run
using `/tmp/compositor-crash-recovery-build`; it predates this numeric-field
production change and the Canvas probe. Image Size unit/no-resample controls,
HDR sizing combinations and physical/Mac acceptance remain unverified by this
RGBA8 Canvas Size probe.

## Keyboard popup ownership during refresh, 2026-10-16

The expanded Hide checks pass offscreen and under native Wayland, but their
regression wrapper stops at Grid Settings' first picker:
`/tmp/compositor-hide-panels-activation-grid.log` (wrapper exit 1). The missing
popup is not counted as a passing Grid check.

The strengthened Grid driver opens the actual combo popup, releases its mouse
grab for keyboard navigation, and forces the same panel refresh used by the
modal timer. Before the correction, refresh returns a replacement root while
the popup is still visible: `/tmp/compositor-grid-popup-before-native.log`,
wrapper exit 1. The old manipulation guard covers sliders, buttons, mouse
grabs and text focus, but not an open combo view without a grab. It now retains
the owning panel while any of its combo views is visible. The probe also uses
QPointer across focus, opening and event dispatch rather than retaining a raw
combo pointer.

The corrected source passes in session 48896:
`/tmp/compositor-grid-popup-fixed-{build,grid,native,wayland,clear,preview,framework,integrity}.log`.
All 14 original guide tests, forced popup refresh/navigation, separate-process
persistence, four Hide cases on each backend, eight Clear cases and the native
preview journey pass. The full framework suite passes 147 XCTest + 953 Swift
Testing tests (1,100 total; 158 Swift Testing suites, 104.499 seconds), and required
protected-source/generator/shader/ledger integrity passes. Both phase and wrapper
exit markers are 0: `/tmp/compositor-grid-popup-fixed{,-framework}.exit`.
A fresh 34-gate contract is running in session 94463 at
`/tmp/compositor-hide-panels-full-contract.{log,exit}` using the same corrected
Swift scratch build. Its complete combined result remains pending.

## Floating tools across minimization and activation, 2026-10-16

The expanded `--app-visibility-probe` opens the actual Gaussian Blur editor,
types Radius 3 and hides both project windows. Normal and maximized owners must
keep the panel unexposed across refresh ticks, then restore the same panel,
value and exact preview through activation. Cancel must restore the committed
image with exact layer/history/target/palette isolation in both projects.

Before the correction, the floating panel remains exposed in both Qt offscreen
and native Wayland: `/tmp/compositor-hide-panels-before-native.log` and
`/tmp/compositor-hide-panels-wayland-before-native.log` (each wrapper exit 1).
The periodic refresh unconditionally showed any open-but-hidden panel. Gating
it on the owner's visible/minimized flags fixes offscreen: all four Hide cases,
Grid/Clear, the native preview journey, all 1,100 framework tests (953 Swift
Testing in 158 suites, 104.671 seconds, plus 147 XCTest) and required integrity
pass in `/tmp/compositor-hide-panels-fixed-*.log` (wrapper exit 0).

Native Wayland reveals a second problem: the owner becomes `WindowNoState` and
the panel is remapped about 40 ms after Hide. Diagnostics and protocol evidence:
`/tmp/compositor-hide-panels-wayland-{diagnostic,trace}-native.log`. GDB's Qt
platform-state trace in
`/tmp/compositor-hide-panels-wayland-platform-stack-native.log` shows a queued
`NoState` callback issued by `QWaylandWindow::handleWindowStatesChanged` inside
`QWindow::setWindowStates`/`QWidget::showMinimized`; the public QWidget setter
trace does not contain a later user restoration. The GDB wrapper's own exit
code is diagnostic only; its inferior fails the visibility assertion. A
snapshot guard around panel hiding also fails and is removed.

The current correction retains panel suppression from the minimize state change
until the project is activated again, rather than trusting the later Wayland
state bits. It hides the panel without closing its model or canceling its edit.
The probe explicitly activates the restored project. All four native Hide cases
pass on each backend in `/tmp/compositor-hide-panels-activation-{native,wayland}.log`
(session 45469). Its wrapper exits 1 at the Grid popup failure described above;
later regression phases are not reached in that run. After the popup correction,
the complete focused regression set passes in session 48896 (wrapper exit 0),
including both-backend Hide checks, native preview, all 1,100 framework tests and
required integrity. The private Weston compositor is stopped after testing.

Wayland uses a private Weston 14.0.1 headless compositor, its desktop shell and
the SDK's actual `libqwayland.so` platform plugin. This is window-lifecycle
evidence; physical input, a desktop task-switcher click and Mac comparison
remain unverified. The last complete combined contract is the earlier 32-gate
session 10792 (exit 0); the canonical runner now has 34 gates and includes the
expanded Hide probe.

## Application Hide host request, 2026-10-16

The AppKit empty-method audit found an unconnected user action: upstream's
visible Hide Compositor calls `NSApp.hide`, but no host installed its existing
`hideHandler`. The corrected before-fix native probe times out after choosing
the enabled action with a ready editor:
`/tmp/compositor-app-visibility-before-native.log` (wrapper exit 1).
The first prototype missed the application menu's padded caption; its routing
failure is retained separately in
`/tmp/compositor-app-visibility-menu-match-before-native.log`. The probe now
uses the visible menu's stable `appMenu.Compositor` object name.

`AppMenus.commands` now installs the hide callback, and Qt handles its queued
request by minimizing all visible `SessionWindow` project windows. Minimization
keeps them available to the desktop task switcher. The native probe passes from
both originating windows, with different unsaved images: both windows minimize
and restore, retaining exact pixels, layer records, targets, palette, tool,
selection presence and Undo/Redo state. Evidence:
`/tmp/compositor-app-visibility-fixed-native.log`. The original popup-menu test,
Grid Settings controls/separate-process restart and all eight Clear cases also
pass in `/tmp/compositor-app-visibility-fixed-{build,grid,clear}.log`.
The corrected build passes 147 XCTest + 953 Swift Testing tests (1,100 total;
158 Swift Testing suites, 109.725 seconds) in
`/tmp/compositor-app-visibility-fixed-framework.log`, phase exit 0. Required
protected-source/generator/shader/ledger integrity passes in
`/tmp/compositor-app-visibility-fixed-integrity.log`; the wrapper exits 0 in
`/tmp/compositor-app-visibility-fixed.exit` (session 49829).

At the Hide/popup checkpoint, the runner had 34 gates: 32 host-native commands
and two standalone probes. Session 10792 exits 0 with its earlier 32-gate script and pre-Hide-fix binary;
that completed checkpoint cannot certify this later production correction. This native probe
initially tested ordinary Qt restoration; the later section above adds normal/
maximized floating-panel and native Wayland checks. Actual desktop task-switcher
delivery and Mac appearance remain unverified. The separate
cross-application Hide Others/Show All compatibility methods remain empty and
are not certified by this application-window fix.

## Visible Clear Selection Pixels, 2026-10-16

Historical row 33 now has direct visible Edit-menu coverage. The new
`--selection-clear-probe` passes eight cases: rectangle/ellipse, alpha 255/128,
and image/mask targets. Clear is disabled without a selection. Independent
rectangle/ellipse equations verify transparent interiors and unchanged exteriors;
ellipse checks omit the antialias boundary (normalized squared radius 0.75–1.3).
Alpha never increases anywhere. Target, selection presence, mask-target state
and palette stay unchanged; one Undo/Redo restores exact complete composites
and layer records. On masks, the background is explicitly black; disabling the
edited mask restores the original image exactly.

All 19 original `SelectionEditTests` pass in
`/tmp/compositor-selection-clear-build.log`. All eight native cases pass in
`/tmp/compositor-selection-clear-native.log`; required protected-source/generator/
shader/ledger integrity passes in `/tmp/compositor-selection-clear-integrity.log`.
The wrapper exits 0 in `/tmp/compositor-selection-clear.exit`. This adds acceptance
coverage; no application behavior changes are needed.

The first probe selected the shell's hidden legacy Edit menu and failed at its
mask action. Diagnostics showed a ready editor, active selection and enabled,
linked mask in `/tmp/compositor-selection-clear-mask-menu-before-native.log`.
The corrected probe explicitly requires a visible top-level menu and visible
action; all eight cases then pass. The earlier refusal is a harness-routing
failure, not evidence of an application defect.

At the Clear checkpoint, adding this probe expanded the runner to 31 host-native
commands plus two standalone gates (33 total); the later Hide gate makes 34. Completed session 10792 passes its earlier
32-gate script and executable (exit 0); this additional probe passes separately using
`/tmp/compositor-crash-recovery-build`. Transformed/HDR combinations, independent
antialias-edge equations and physical/Mac delivery remain unverified.

## Grid Settings validation and modal state lifetime, 2026-10-16

The new `test_grid_settings` driver launches an isolated native controls probe
and then a separate process against the same preferences profile. It removes
the XCTest preference-suppression flag. The View menu action opens the real
upstream sheet; actual field/picker/button events cover spacing, subdivisions,
color, style, opacity, invalid-range/relative-limit recovery, Cancel/OK, Restore
Defaults Cancel/OK, reopen and persistence. Source pixels, layer records, target,
history and palette remain exact.

Two application defects are reproduced. Under GDB, invalid spacing leaves OK
enabled while the field retains focus: `/tmp/compositor-grid-settings-before-gdb.log`.
The Qt panel refresh gate freezes the whole Grid Settings panel during typing.
It now refreshes enabled state and the validation hint's text, warning style and
wrapping in place, retaining the field, text, focus and cursor. Other panel
editing refresh behavior is retained.

After that correction, opening 3 shows canceled spacing **32** instead of the
committed **24**: `/tmp/compositor-grid-settings-stale-reopen-before-native.log`.
The retained profile's SQLite preferences contain spacing 24 and subdivisions 3.
The modal close path never resolved the closed panel, leaving its SwiftUI @State
cache alive. It now resolves a closed sheet before retiring its widgets, matching
the existing floating-panel cleanup and giving the next presentation fresh state.

All 14 original `GuideTests` pass, and both native controls and separate-process
persistence pass in `/tmp/compositor-grid-settings-{build,native}.log`. Required
protected-source/generator/shader/ledger integrity passes in
`/tmp/compositor-grid-settings-integrity.log`; `/tmp/compositor-grid-settings.exit`
is 0. The corrected build also passes the full framework suite: 147 XCTest +
953 Swift Testing (1,100 total; 158 suites, 107.552 seconds) in
`/tmp/compositor-grid-settings-full-framework.log`, phase exit 0. Native
transform-field, preview, save and transform regression checks all pass in
`/tmp/compositor-grid-settings-regression-*.log`; the wrapper exits 0 in
`/tmp/compositor-grid-settings-regression.exit` (session 24273).

Supplemental normal-startup canvas captures also pass five pixel checks:
grid off, Lines at 25% and 75%, Dashed Lines and Dots at 75%. Independent interior
color markers calibrate document coordinates. Major lines match spacing 24,
subdivision lines match spacing 8, and the major-line channel change triples
from 48 to 144 with opacity. Dashed and dotted styles have distinct gaps;
269,360 off-grid pixels per capture remain exact. Evidence is in
`/tmp/compositor-grid-render/verification.json` and the adjacent PNG captures.
The initial measurement included the canvas border; interior markers correct
that measurement without widening the two-pixel grid exclusion band. This is
seeded-preference startup rendering, not live-modal timing or Mac appearance
acceptance.

The initial synthetic controls run crashed with SIGSEGV; GDB reached the concrete
validation failure instead. Test event targets now use QPointer across key
dispatch, with explicit popup-lifetime checks. The specific original crash is
not conclusively attributed; later complete grid controls/persistence pass.
The existing full contract (session 87013) retains its pre-grid-fix executable
and earlier 30-command scope. It exits 0, including all native commands and
required integrity, but cannot validate these later production fixes. The new
full contract exits 0 in session 10792 using the corrected executable and all
32 gates: 30 host-native commands plus standalone group rotation and grid settings.
All 1,100 framework tests pass (147 XCTest + 953 Swift Testing in 158 suites,
103.415 seconds), as do native backends, eleven source-coverage checks and required
protected-source/generator/shader/ledger integrity. This checkpoint precedes the
later Hide corrections.
Its log and final exit marker are
`/tmp/compositor-grid-settings-full-contract.{log,exit}`.

## Selected-layer and folder rotation bridge, 2026-10-16

Historical row 19 had native movement/scaling coverage but no rotation-specific
group evidence. The standalone CMake target `test_group_rotation` now launches
the normal Swift host for six cases: selected layers or a folder at +90°, -90°
and 180°. Two opaque patterned assets have unequal sizes/origins (8×12 at 8,12;
6×10 at 34,20), so their shared center (24,21) differs from both individual
centers. Independent integer pixel mappings verify every pixel of the committed
and Redo composites; Before, Cancel and a single Undo match the original exactly.
An unselected third asset stays fixed. Original leaf IDs remain selectable and
SHA-256 hashes of the source manifest/assets remain unchanged.

The repository target builds and all six cases pass in
`/tmp/compositor-group-rotation-cmake-{build,native}.log`; required protected-source,
generator, shader and ledger integrity passes in
`/tmp/compositor-group-rotation-integrity.log`. The wrapper exits 0 in
`/tmp/compositor-group-rotation-cmake.exit`. This uses the existing executable in
`/tmp/compositor-crash-recovery-build`; it does not rebuild or alter the host used
by the active full contract. The fixture uses the existing v11 format; no format
change is introduced.

The canonical runner now builds and invokes this standalone probe after its 30
host-native commands. The completed session 87013 retained its earlier
script inode and 30-command scope; this new companion gate is verified separately
above. Grouping and transform commands use the real application bridge. Pointer
rotation delivery, continuous/non-quarter-turn angles and nested/masked/HDR
combinations remain unverified.

## Autosave coordination in native package assertions, 2026-10-16

The earlier combined run failed an effects-control package save without logging
its refusal reason. Two isolated reruns then passed all 54 cases; neither pass
establishes that historical failure's cause. The new deterministic
`--effects-autosave-overlap` check proves an actual race in the previous harness:
start an autosave, then attempt the immediate explicit package save before its
queued completion. The explicit save refuses with `document=1, destination=0`
and writes no destination. Waiting for the actual autosave completion makes
the same explicit save succeed with the existing exact pixels/parameters checks.

The native combination harness now waits for pending saves before its modern
adjustment, effect-control and effect Color Picker package assertions. The
natural autosave timer remains enabled. Application save/refusal behavior is
unchanged; a read-only current-tab progress query and refusal diagnostics make
the coordination observable. The contract's effects phase includes the forced
overlap, retaining all 54 independent pixel cases and existing history/isolation
checks.

All seven focused save tests, the forced overlap and 54 effects cases, the native
async save/reopen/startup journey, and required source/generator/shader/ledger
integrity pass in `/tmp/compositor-effects-autosave-overlap{,-build,-save,-integrity}.log`;
the script exits 0. The subsequent shared-helper refactor passes
a fresh complete canonical contract, session 87013:
`/tmp/compositor-autosave-coordination-contract.{log,exit}`. It uses all 30 native
commands, full framework tests, native backends and source-coverage checks.
`COMPOSITOR_CONTRACT_SWIFT_BUILD=/tmp/compositor-crash-recovery-build` now selects
the same build directory for both the framework tests and native executable;
the default remains the project's `.build`. No `--skip-build` is used in this run.
This fresh run now passes its backend/codec/font/thumbnailer and eleven source-coverage
checks, then all 147 XCTest + 953 Swift Testing tests (1,100 total; 158 Swift
Testing suites, 104.121 seconds). All 30 native commands and required integrity
also pass. The wrapper exits 0; integrity is recorded in
`/tmp/compositor-autosave-coordination-contract-integrity.log`. This complete
combined checkpoint precedes the Grid Settings production fixes above.

## Actual process-crash recovery at normal startup, 2026-10-16

The new `--autosave-crash-probe` kills an isolated writer process after a
completed snapshot and launches the normal application without smoke flags.
The previous implementation fails: the snapshot survives the confirmed
SIGKILL/CrashExit boundary, but startup opens an empty document. Evidence:
`/tmp/compositor-crash-recovery-before-native.log` (exit 1). Startup had no call
to recovery; the existing helper also bound the recovery package as a normal
project URL/watcher despite clearing the Qt save path.

Startup now recovers before opening explicit input files. A separate C bridge
entry point shares the validated package loader but leaves recovery unbound.
An invalid recovery package is kept and its path is reported. The normal loader
retains its existing save destination and watcher behavior. No protected
upstream source or project format changes are required.

The release executable passes both committed-edit and pending-gradient cases
in `/tmp/compositor-crash-recovery-release-native.log` (exit 0). Each crosses
a real process kill, then verifies exact recovered composite pixels and layer
records/IDs, unsaved state, no restored gradient draft, explicit startup image
isolation with the recovered tab retained, exact saved source PNG pixels/IDs,
recovery cleanup after a real save and a clean subsequent launch. The writer
also checks that autosave preserves its live draft, target and history. The
Linux contract runner includes this probe. All seven `ProjectSaveSnapshotTests`
methods pass, including both normal/recovery loader cases, in
`/tmp/compositor-crash-recovery-framework.log` (exit 0). The rebuilt executable
also passes the crash probe in `/tmp/compositor-crash-recovery-after-native.log`
and the existing async save, same/cross-window reopen and multi-file startup
journeys in `/tmp/compositor-crash-recovery-save-native.log`. Required protected
source, generator, shader and ledger integrity passes in
`/tmp/compositor-crash-recovery-integrity.log`. The entire verification script
exits 0 (`/tmp/compositor-crash-recovery-check.exit`). The fresh complete framework
run passes 147 XCTest + 953 Swift Testing tests (1,100 total; 158 Swift Testing
suites, 106.009 seconds) in `/tmp/compositor-crash-recovery-full-framework.log`
with exit 0. The earlier combined Invert run has now failed an effects-control
package save as recorded below; a full combined checkpoint remains open.
The isolated rerun passes all 54 effect-control cases with exit 0 in
`/tmp/compositor-effects-save-repro.{log,exit}`. That pass does not establish
the earlier failure's cause. Diagnostic-only changes now log early explicit-save
refusal reasons and the failing effect case/kind/alpha variant. Their build
and all seven focused save tests pass in
`/tmp/compositor-effects-save-diagnostics-build.log`. All 54 native effects
cases and the async save/reopen/startup journey also pass in
`/tmp/compositor-effects-save-diagnostics{,-save}.log`, script exit 0. The
deterministic `--effects-autosave-overlap` check passes with exit 0 in
`/tmp/compositor-effects-autosave-overlap{,-build,-save}.log` (session 85816, terminal).
It starts an autosave, verifies that the previous immediate explicit-save
sequence refuses, then waits for the actual completion before checking the
explicit package. The effects harness also waits for natural timer saves; the
contract runner includes the forced overlap. This does not change application
save/refusal behavior. The initial diagnostic build caught a local variable-name
collision; it was renamed, with the compiler output preserved in
`/tmp/compositor-effects-save-diagnostics-name-collision.log`.

The initial normal-load regression expectation distinguished a file URL from
the same directory URL with a trailing slash. Declaring the expected package
as a directory fixes that harness error; its initial two issues are preserved
in `/tmp/compositor-crash-recovery-url-expectation-failure.log`. Other draft
kinds, multiple recovery slots and installed desktop acceptance remain unverified.

## Invert editor refusal and pending-gradient preservation, 2026-10-16

The prior six-kind acceptance covered Invert creation, but not requesting its
nonexistent editor. The new `AdjustmentEditorLifecycleTests` reproduces a real
session lock: default-target and explicit-ID requests return success, retain
`adjustmentEditingID`/`adjustmentOriginal`, disable layer editing and prevent
the next Exposure editor from opening. Both parameter cases fail with sixteen
issues in `/tmp/compositor-invert-editor-before.log`. A third case also proves
that requesting an inactive Invert adjustment commits an unrelated pending
gradient before locking the session. The expanded before-fix run fails two
test methods / three cases with 22 issues in
`/tmp/compositor-invert-editor-gradient-before.log`.

The bridge now checks the target's existing `isEditable` property before setting
any edit state, and checks it before resolving a pending gradient. The generated
Edit Adjustment menu applies the same property. Its generator requires exactly
one recognized upstream gate, so source drift fails generation rather than
silently dropping the adaptation. Original upstream files remain unchanged;
the parity manifest documents the generated menu correction. The existing
modern native probe now checks disabled Invert Edit and a refused bridge request
with exact pixels, records, target, history and switchability.

The complete framework run passes 147 XCTest + 952 Swift Testing tests
(1,099 total; 158 Swift Testing suites, 112.915 seconds) in
`/tmp/compositor-invert-editor-framework.log`, with phase exit 0. Both new
methods / all three cases pass. The modern native phase also exits 0 in
`/tmp/compositor-invert-editor-modern-native.exit`; all six kind markers,
including the new Invert refusal, are in
`/tmp/compositor-invert-editor-native-contract.log`. Required Vulkan hardware
and the shipped subject model are enabled. Native backend/codec/font/thumbnailer
and all eleven evaluated-source coverage checks exit 0 in
`/tmp/compositor-invert-editor-backends-coverage.log`. Required protected-source,
generator, shader and ledger integrity exits 0 in
`/tmp/compositor-invert-editor-integrity.log`.

The new runner `/tmp/compositor-invert-editor-contract.sh` runs all 29 configured
native commands from the current contract, with the modern adjustment phase
first. It has now terminated with exit 1 (session 74583): after the modern,
combination, Levels and Curves phases, the effects-control phase reports
`effect controls project save failed` after its opaque cases. The log does
not identify which early save refusal guard fired. This remains unresolved;
a passing focused recovery journey does not close that combined-run failure. The earlier `/tmp/compositor-layer-autoscroll-resume.sh` run (session
23268) has now exited 0: 1,097 framework tests and every configured native journey,
including all 26 nesting cases, pass. It uses the previous executable and cannot
verify this later production fix. Require the new runner's final `.exit` result before recording
a complete combined checkpoint. Wider adjustment combinations and physical/Mac
acceptance remain open.

## All current adjustment-layer kinds: native controls and persistence, 2026-10-16

`--combo-smoke --modern-adjustment-probe` passes six cases in
`/tmp/compositor-modern-adjustment-native.log` (exit 0 in its `.exit` file):
Gaussian Blur Radius 1.5, Motion Blur Angle 90, Add Noise Amount 55,
Black & White Reds 80, Color Balance Midtones Yellow / Blue 60, and Invert.
Together with the historical six-kind native journey, this covers creation of
all twelve current `AdjustmentKind` cases and reopening all eleven editable
kinds. The five newer editors pass actual window-pointer thumbnail double-clicks
and the visible Edit Adjustment menu, live numeric changes, Cancel/OK, exact
pixel/record/identity Undo/Redo and saved numeric parameters. Invert creates no
editor and passes independent RGB-complement and exact-alpha checks.

Every case independently reads all saved source PNG channels, retaining the
original multicolor RGBA8 fixture, and loads the written package with the exact
accepted composite. `writeProjectPackage` does not bind the package path, so
these distinct paths go through package reading rather than selecting a cached
open tab. The release build passes in
`/tmp/compositor-modern-adjustment-build.log` (106.27 seconds). Required source,
generator, shader and ledger integrity exits 0 in
`/tmp/compositor-modern-adjustment-integrity.log`. The contract runner includes
the probe; shell syntax and diff checks pass.

Three harness assumptions were corrected without production changes. Accepting
resolved optional defaults can record an Edit step after the New Adjustment
step; both checkpoints now have separate exact Undo/Redo checks. The diagnostic
log is `/tmp/compositor-modern-adjustment-history-before.log`. An initial
synchronous pointer sequence could not deliver its release while the table
tracked the press; the deep stack identifies `NSWindow.nextEvent` beneath the
probe's press call in `/tmp/compositor-modern-adjustment-pointer-deep-stack.log`.
The full click/double-click sequence now queues each release, as real event
delivery does. Finally, Qt's `Black && White` text must retain its literal
ampersand when decoding menu labels; the old lookup failure is retained in
`/tmp/compositor-modern-adjustment-ampersand-before.log`.

The earlier full contract has now exited 0 on its previous script and executable;
it did not include this new probe or the thumbnail-modifier addition below.
The Invert-corrected runner includes both, but stopped on the effects-control
package-save failure recorded above before reaching these later probe commands. Wider parameters, masked/transformed/HDR stacks and
physical/Mac appearance remain unverified.

## Thumbnail selection modifiers, 2026-10-16

The new `--combo-smoke --thumbnail-selection-probe` passes twelve actual Qt
window-pointer cases: layer-image, layer-mask and folder-mask thumbnails, each
with Ctrl, Ctrl+Shift, Ctrl+Alt and Ctrl+Shift+Alt. Independent rectangular
set equations verify every pixel of Replace, Add and Subtract coverage,
including Alt's precedence over Shift. Image loading ignores the attached
mask; mask loading selects its dark regions even outside source opacity.
Each gesture preserves source pixels, layer records, active layer and the
immediate mask/pixel edit target. Reversible fills on a separate layer prove
the original selection after Undo and the loaded selection after Redo;
fill Undo/Redo restores exact pixels and records. Both layer and folder
mask proofs keep their destination outside masked folders.

The first probe incorrectly compared the second gesture's edit target with
the state before its temporary coverage-proof layer was added. Diagnostics in
`/tmp/compositor-thumbnail-selection-stale-target-before.log` show identical
pixels, records and active layer, with only the mask target changing. Unchanged
upstream `EditorSession.restore` deliberately retains a mask target only when
Undo stays on the same layer; adding/removing the proof layer clears it. The
probe now snapshots the edit target immediately before each gesture. Pixel,
record, selection and history expectations are unchanged. No production fix
was needed.

The isolated release build passes in
`/tmp/compositor-thumbnail-selection-build.log` (95.15 seconds), and the native
log `/tmp/compositor-thumbnail-selection-native.log` contains all twelve pass
markers with exit 0 in its `.exit` file. The probe uses a separate scratch build
and settings profile with required Vulkan hardware. The first scratch-build
attempt failed because copied precompiled modules embed their original cache
path; moving aside that copied cache allowed the independent build to finish.
`scripts/linux-contract-tests.sh` now includes the probe; shell syntax passes.
Required protected-source/generator/shader/ledger integrity also exits 0 in
`/tmp/compositor-thumbnail-selection-integrity.log`, and `git diff --check` passes.
The runner file was replaced atomically so the earlier contract retained
its original script and executable. That run now exits 0 as described below;
it does not include this new test-only probe. Transformed/HDR/partial-alpha
variants and physical/Mac input remain unverified.


## Collapsed folders, cross-folder drags and autoscroll investigation, 2026-10-15

The nesting probe expands from eleven to 26 cases. The additions use actual
folder-disclosure clicks, collapsed sources/targets, cross-folder multi-selection
with different inherited opacities, and stationary-pointer scrolling to an
offscreen folder in both directions, for Move and Copy. Existing exact
record/parent/ID/order, independent translucent pixel and Undo/Redo checks remain.
The scrolling cases require reaching the opposite edge of a 24-spacer viewport
while holding one pointer position, with no document change before the final drop.

The first expanded run passes the original eleven cases, then fails because the
folder disclosure is absent from accessibility
(`/tmp/compositor-layer-nesting-expanded-before-native.log`). The compatibility
NSImage symbol initializer discarded its accessibilityDescription argument; its
color-configuration copy also dropped the field. The new native symbol regression
fails on original and configured images before the fix, reporting nil metadata
and no named button in NativeLowering's accessibility snapshot (two argument
cases, six issues in `/tmp/compositor-symbol-accessibility-isolated-before-build.log`).
The compatibility image creation/configuration paths now retain the description.
The focused framework and expanded native acceptance run passes in
`/tmp/compositor-layer-nesting-both-edges-build.log` (4 XCTest + 84 Swift Testing
tests, 88 total) and `/tmp/compositor-layer-nesting-both-edges-native.log`
(all 26 cases), with exit 0 in its `.exit` file.
The initial test-wrapper build required an explicit preconcurrency view
conformance under Swift 6; that setup error is distinct from the reproduced
missing symbol metadata.

The first stationary-pointer case then reproduces an actual scrolling defect:
the offset stays at 973 of 973 after the pointer leaves the top of the viewport
(`/tmp/compositor-layer-nesting-live-viewport-native.log`). The native row's
initial mouseDown tracking has returned, stopping the Qt repeat timer, and the
compatibility drag-session path never calls table autoscroll. The host now keeps
edge repeats alive while a layer drag session exists, synchronizes native scroll
offsets after drag delivery, and stops on release or retired sessions. The
compatibility router autoscrolls before calculating drop validation coordinates.
The unchanged held-pointer assertion passes upward and downward for Move/Copy;
no extra pointer moves drive the scrolling.

Two harness lifetime issues were corrected separately: viewport readiness must
query the current Qt scroll area, and polling must reacquire it after panel
replacement. GDB identifies the latter crash in the probe's QAbstractSlider::value
call (`/tmp/compositor-layer-nesting-autoscroll-gdb.log`), not in production
scrolling. Exact model, pixel, selection and history assertions remain in place.
The original full combined contract under
`/tmp/compositor-layer-autoscroll-contract.sh` stopped during Wand repetition 5
without an exit file. On October 16, host process inspection found no remaining
runner or native test process; that log is incomplete and is not a passing
combined checkpoint. The same contract was restarted in the existing Flatpak
SDK as `/tmp/compositor-layer-autoscroll-resume.sh`, preserving the original log.
Required protected-source/generator/shader/ledger integrity passes in
`/tmp/compositor-layer-autoscroll-resume-integrity.log`. The restarted framework
run passes 147 XCTest and 950 Swift Testing cases (1,097 total; the latter in
157 suites, 114.146 seconds). Every configured native journey, all 26 nesting/
copy cases, required Vulkan hardware and the backend/coverage checks also pass.
`/tmp/compositor-layer-autoscroll-resume.exit` is 0. This is a complete combined
checkpoint before the later Invert correction and the two additional probe
commands. The current corrected build's framework/modern-native phases pass
above; its later effects-control package-save phase failed as recorded above.

## Native layer nesting and Alt-drag copies, 2026-10-15

Historical row 5 now uses `--combo-smoke --layer-nesting-probe`. Eleven actual
window-pointer cases cover single/multiple rows moved or Alt-copied into a
folder, nested-folder moves/copies, a folder copied while a descendant is also
selected (carried once), move/copy refusal into its own descendant, moving a row
back out above its folder, and Alt pressed after drag initiation. New IDs and
exact descendant-parent remapping, displayed root order, original-record
isolation, copied appearance/geometry, target selection and exact one-step
hierarchy/ID/pixel Undo/Redo are checked. Independent source-over equations use
disjoint red/blue layers at 50% opacity, with another 50% on nested outer folders,
so duplicates have a distinct, independently checked composite alpha.

The initial native run passes nine cases but fails the move-out setup in
`/tmp/compositor-layer-nesting-ready-native.log`. Failure-only Qt route and native
pointer/scroll diagnostics reproduce the same failure in
`/tmp/compositor-layer-nesting-traced-native.log`: both points hit the current
session's table, but the press returns without entering native drag tracking.
A direct C ABI accessibility snapshot, which does not resolve the panel first,
shows the native coordinator still has only the original `input` row while the
model has the renamed red/blue rows and destination folder
(`/tmp/compositor-layer-nesting-native-rows-native.log`). Qt accessibility and
keys synchronize the coordinator before input; pointer presses did not.

The production host now resolves the native panel before ordinary left/right
press hit-testing, with a lifetime guard and without refreshing inside an active
AppKit tracking loop. Middle-button tracking remains on its existing path.
The unchanged regression still sees the stale `input` cache immediately before
press, then succeeds through normal pointer dispatch. All eleven cases pass in
`/tmp/compositor-layer-nesting-press-sync-native.log`, with exit 0. Its focused
build log passes 4 lifecycle XCTest + 83 Swift Testing cases (87 total), including
original group/layer/appearance suites. The initial QJsonArray reverse-iterator
compile failure was a harness API error, corrected to indexed traversal.

The complete framework/native contract with the pointer correction and preceding
effect-control addition passes in `/tmp/compositor-layer-nesting-contract.log`,
with exit 0 in its `.exit` file: 147 XCTest + 949 Swift Testing tests (1,096 total),
all configured native journeys, required Vulkan hardware and source-coverage
checks. The native log includes all eleven nesting cases, 54 effect-control
cases, 16 disjoint rounds and 66 snap cases, plus full preview, save/recovery,
transform, tab, RAW lens and text journeys. Protected-source/generator/shader/
ledger integrity passes in `/tmp/compositor-layer-nesting-integrity.log` against
`365b574`. Coverage accounts for all 156 upstream Swift files (128 unchanged,
20 generated, 6 replaced, 2 platform) and 89 upstream test files (87 unchanged,
2 mirrors), with zero errors. Qt stylesheet, Fontconfig and offscreen portal/
D-Bus diagnostics remain in the log; these runs do not prove desktop delivery.
Masks/clipping/effects/HDR combinations, collapsed/scrolling targets, cross-folder
multi-selection and physical/Mac drag delivery remain unverified. This reproduces
a specific stale-row press failure; the exact historical intermittent mask and
Command-click failures remain unattributed.

## Native layer-effect numeric controls, 2026-10-15

Historical row 14's numeric/position-control gap is exercised by
`--combo-smoke --effects-controls-probe`. The expanded grid has 54 cases:
27 parameters on opaque and half-alpha red rectangles. Stroke covers Size 2/6,
Inside/Outside and Opacity 50/100, plus manually entered Size 50 on each side
(the displayed slider ends at 20). Drop/Inner Shadow cover angles −90/0/90/180,
Distance 8, Blur 0 and an additional Blur 4 case, at Opacity 50. Color Overlay
covers Opacity 0/25/100. Outer/Inner Glow cover Size 2/8 at Opacity 50.

Independent all-pixel equations use square dilation/erosion, directional offsets,
source-over/source-atop compositing and a normalized separable discrete Gaussian
with sigma half the Blur/Glow Size. Premultiplied RGB/alpha differences must stay
within 4/255; inner shadows/glows and overlay preserve alpha exactly. The source
has opaque upper and 128/255-alpha lower halves, so the soft variants exercise
effect compositing within translucent pixels as well as outside the shape.

Every case uses the visible fx menu, Stroke position buttons and numeric fields.
Cancel restores exact source pixels with upstream's compensating Cancel history
step; OK retains the preview. Undo/Redo of the final opacity edit restores exact
checkpoints. Layer identity/geometry, target and palette remain unchanged. Saved
parameters are checked, and the saved source PNG must have zero pixel differences from the
original raster plus an sRGB tag. The initial 25 opaque cases pass in
`/tmp/compositor-effects-controls-native.log`; all 36 focused framework tests
pass in its companion build log. The final expanded grid passes all 54 cases in
`/tmp/compositor-effects-controls-eroded-native.log`; all 36 focused tests pass
again in `/tmp/compositor-effects-controls-eroded-build.log`.
`/tmp/compositor-effects-controls-eroded.exit` is 0. Required protected-source,
generator, shader and ledger integrity passes in
`/tmp/compositor-effects-controls-integrity.log`; shell syntax and diff whitespace
checks pass. The contract runner now includes the new probe. This is a test-only
follow-up: application effect code is unchanged, and the previous complete
1,096-test/native contract predates this probe. Extreme values, effect stacks,
selections/masks/transforms/HDR, continuous pointer controls and physical/Mac
appearance remain unverified.

Early harness failures are retained separately. The saved PNG/raw-raster QImage
comparison failed solely on metadata: dimensions matched, zero pixels/channels
differed, the PNG was tagged sRGB and raw readback was untagged
(`/tmp/compositor-effects-controls-source-trace-ready-native.log`). The assertion
now checks exact channels and the sRGB tag separately. A second oracle error
used QRect containment on an over-eroded rectangle: a small standalone Qt probe
shows Width −84, invalid, yet `contains(20,20)` is true. The oracle now requires
valid positive erosion bounds, matching an empty shape. Neither issue changed
application rendering or weakened the pixel tolerance.

## Native panel session ownership investigation, 2026-10-15

A repeated create/render/close regression reproduces stale native table ownership:
31 of 32 reopened Layers panels expose no row with the current session's unique
name in `/tmp/compositor-native-session-lifetime-main-thread-before-build.log`.
The old scope was a hash of the bridge entry's allocator address. Close removed
the handle without discarding `NativeLowering`, `StateStore` or `ChangeTracker`,
allowing a reused address to select the old coordinator and its cleared document.

The bridge now gives each entry a UUID scope and discards all rendered panel
scopes, handlers, pending tree/accessibility snapshots and dirty notifications on
close. Locked live-entry tracking rejects observation callbacks after closure.
Shared-document handles retain separate panel scopes; closing one preserves the
other handle's document and native rows. The scope/close fix passes the 32-session
reopen, alias ownership and late-invalidation tests in
`/tmp/compositor-native-session-lifetime-async-after-build.log`.

That run still fails the asynchronous weak-session release assertion. Source
inspection identifies a second cycle: `arrowSteps` stores the view's change
closure in its `@State` stepper, and that captured view owns the stepper. The Linux
ContentView patch now clears its value/change callbacks on disappearance, after
stopping the key monitor. The generated output passes `--check`. All four
lifecycle tests, including weak session release, pass in `/tmp/compositor-native-session-lifetime-cycle-after-build.log`
with exit 0. Four complete preview runs (one with optional input tracing), all
16 disjoint-selection rounds across two windows, and the focused mask-scroll/
replacement probe pass in `/tmp/compositor-session-lifetime-native-*.log`.
Required source/generator/shader integrity passes; the script exit is 0. The
combined native/framework contract also passes with exit 0 in
`/tmp/compositor-session-lifetime-contract.exit`: 147 XCTest + 949 Swift Testing
tests (1,096 total), all configured native journeys and required Vulkan hardware.
`/tmp/compositor-session-lifetime-integrity.log` passes protected-source, generator,
shader and ledger checks against `365b574`. Evaluated-target coverage accounts
for all 156 upstream Swift files (128 unchanged, 20 generated, 6 replaced,
2 platform) and 89 upstream test files (87 unchanged, 2 mirrors), with zero errors.
The full native run includes 42 filter and 30 Image adjustment cases, 20 Levels
handle cases, four Curves channels, 24 Hue range-handle cases, 66 transform-snap
cases, all six historical adjustment re-editors, the 16-round two-window disjoint
probe and the complete preview, save/recovery, transform, tab, RAW lens and text
journeys. Qt stylesheet, portal/D-Bus and Fontconfig diagnostics remain in the
offscreen log; physical desktop delivery is not established by these passes.

Earlier synchronous lifetime assertions could also retain canceled Swift tasks
by blocking their executor; the final lifetime test is asynchronous and closes
through the process-main-thread C ABI. Those setup failures are not attributed
to product behavior. Ten unmodified complete preview repetitions had passed
before the stale-owner regression was added, but a subsequent preview failed
waiting for a current mask thumbnail (`/tmp/compositor-input-target-traces-preview-1.log`).
The old intermittent mask and Command-click failures are not yet conclusively
linked to the reproduced ownership defect. Failure-only Qt hit/scroll/session
and native accessibility diagnostics preserve their original assertions.

## Native Exposure, Gradient Map and Grain controls, 2026-10-15

Historical row 50 now uses `--combo-smoke --image-adjustment-controls-probe`,
sharing the filter-control harness while opening the visible Image menu. Its
30 cases split equally between whole-image and pointer-selected edits. The
selection's exact coverage is proven by a reversible all-pixel fill. Every case
checks Preview Off/On, Cancel/OK, source/target/palette/history isolation and
exact pixel/record Undo/Redo. Default Exposure and zero Grain instead require
unchanged pixels/records/history on OK, matching upstream's identity policy.

Exposure covers identity, ±1 stop, Offset ±0.05, Gamma 0.5/2 and a combined
0.5-stop/0.02-offset/1.4-gamma edit. Every nontransparent selected component is
checked against independent sRGB decode, linear-light exposure/offset/gamma and
sRGB encode equations within 3/255; alpha and all outside pixels stay exact.
Gradient Map covers red/blue defaults and custom Shadows `204060` / Highlights
`E0C0A0`, each with Reverse off/on. Both visible swatches open the app's color
picker: Hex submission, displayed RGB, live parent preview and picker Cancel/OK
are checked. Pixels follow independently calculated luminance interpolation
within 3/255, with exact alpha/outside pixels and palette isolation.

Grain covers Amount 0/20/40, with same-seed parameter checks inside each nonzero
edit: Size 1→4 must reduce normalized neighbor-difference energy; Roughness
0→100 must add finer detail, and 50 must interpolate the same two patterns within
3/255. Doubling Amount must double deviations within 4/255, zero restores exact
source pixels, and restoring Amount must restore the exact pattern. Neutral
channels, alpha, transparent/outside pixels and strength bounds are checked.
Identity cases also drive Home/End on all six Exposure/Grain sliders, including
logarithmic Gamma/Size, checking range endpoints in their model-backed numeric
fields before restoring the original values.

All 18 original tests in `ImageAdjustmentTests`, `AdjustmentLayerTests` and
`AdjustmentEditorTests` pass. The first complete 30-case native run passes in
`/tmp/compositor-image-adjustments-live-fields-native.log`; it predates the slider
endpoint additions. Earlier logs preserve harness failures: Hex is a draft
until submit/focus loss, and the picker can rebuild its widget while retaining
the visible Hex text/focus/cursor. The final harness reacquires that live field
and verifies RGB after submission, rather than asserting identity of a retired
widget. No production adjustment implementation or focus behavior changed.
The final expanded grid, including slider endpoints, passes all 30 cases in
each of `/tmp/compositor-image-adjustments-verified-native-{1,2,3}.log` (90
executions). Its focused rebuild passes all 18 tests again in
`/tmp/compositor-image-adjustments-verified-build.log`.
The related 42 filter cases pass in
`/tmp/compositor-image-adjustments-verified-filters.log`, the complete preview
passes in `/tmp/compositor-image-adjustments-verified-preview.log`, and required
protected-source/generator/shader integrity passes. The combined run terminates
with status 0 in `/tmp/compositor-image-adjustments-verified.exit`.
The contract runner includes the new probe. Transformed/masked/HDR combinations,
larger images, continuous slider/pointer gestures and physical/Mac appearance
remain unverified. The earlier full-framework checkpoint is not rerun for these
test-only changes; exact native follow-up scope is recorded separately.

## Native filter controls and Motion Blur spread, 2026-10-15

Historical row 52's Motion Blur, Add Noise and Lens Correction sheets are driven
by `--combo-smoke --filter-controls-probe` through the visible upstream Filter
menu. The grid has 42 cases, 21 whole-image and 21 with a pointer-drawn selection:
Motion Blur at −45/0/45/90 degrees and Distance 12/24; Uniform/Gaussian noise,
color/monochromatic, Amount 10/40; lens distortion −60/−20/0/20/60. The selected
rectangle's coverage is proven by a reversible all-pixel blue fill, rather than
assuming bounds from a state field. Motion's selection edge cuts its streak.

The initial native attempts found harness errors: legacy menu object IDs do not
identify the displayed upstream actions; zero lens distortion intentionally
closes without an undo step; the state ABI exposes selection presence rather
than bounds; and selection transforms are deliberately unavailable during a
filter. Those expectations were corrected against source and observable pixels,
without changing production behavior. The old logs remain in
`/tmp/compositor-filter-controls-{first,menu,identity,verified}-*.log`.

Review then found a production spread error that direction-only checks missed.
Upstream calibrates Motion Blur's Distance to radius `d / sqrt(12)`, describing
radius as the Gaussian-like standard deviation. Compat instead sampled uniformly
over ±radius. The independent floating-point impulse-moment regression fails
all 12 radius/angle combinations in `/tmp/compositor-motion-spread-before-build.log`:
radius 4 gives variance 6.6667 instead of 16, and radius 8 gives 24 instead of 64.
The compatibility kernel now normalizes Gaussian line weights through three
standard deviations, uses those weights in SIMD and boundary sampling, and
expands the reported extent and regional input margin accordingly. Protected
upstream code is unchanged. The scalar comparison follows the corrected weighted
convolution; independent impulse moments enforce the actual spread requirement.
Native acceptance also checks absolute Distance calibration, not just direction
and the ratio between two distances.

The corrected focused run passes all 12 impulse-moment combinations, the scalar
comparison across fractional/large radii, and the default 1920×1080 performance
guard: approximately 13.2/15.3/14.3 ms for 0/45/90 degrees in
`/tmp/compositor-filter-controls-spread-fixed-build.log`. Those are raw raster
kernel timings, not end-to-end UI latency. The full follow-up
`/tmp/compositor-motion-spread-final-build.log` passes 143 XCTest + 949 Swift
Testing tests in 156 suites (1,092 total), including a new regional/full-render
equivalence test sampling a source two standard deviations away. Required
source/generator/shader integrity also passes; combined terminal status
`/tmp/compositor-motion-spread-final.exit` is 0. This is a full framework run,
not a repeated complete native contract run.

Noise checks mean/variance, uniform bounds, Gaussian tails, mono/color channels,
exact alpha/transparent pixels and a stable seed across Preview Off/On. Its
random-seed, 768-sample selected case uses a 30% variance envelope (about six
Gaussian sampling standard errors). Lens pixels use an independent inverse
radial map with bilinear premultiplied samples, within 2/255 per component.
Each case checks Preview, Cancel/OK, source/target/history isolation and exact
pixel/record Undo/Redo; zero lens distortion instead requires history-free OK.
An earlier corrected-kernel native attempt passed 40 cases, then stopped because
the canvas had not acquired focus for a history key after a sheet closed. The
harness now waits up to five seconds for the visible main canvas to own focus;
the exact pixel/record assertions remain unchanged. All 42 cases pass in each
of `/tmp/compositor-filter-controls-focus-ready-native-{1,2,3}.log` (126 case
executions). The final focused rebuild also passes 16 XCTest + 14 Swift Testing
tests, including both new regressions. This is test-target readiness, not a
production focus fix or an explanation of the older intermittent input failures.
The complete preview also passes in
`/tmp/compositor-filter-controls-focus-ready-preview.log`, followed by required
source/generator/shader integrity; combined terminal status
`/tmp/compositor-filter-controls-focus-ready.exit` is 0.
The contract runner includes the probe. Mac kernel/appearance comparison,
extreme values, transformed/masked/HDR combinations and physical input remain
unverified.

## Window initialization and native disjoint selection, 2026-10-15

The focused `--combo-smoke --layer-disjoint-probe` reproduces a second-window
failure in `/tmp/compositor-disjoint-layer-route-native.log` (exit 1). Round zero
passes Command/Shift clicks and Shift arrows. After constructing and closing a
second window, Shift-Up leaves rows {2,6,7,8} selected instead of {2,5,6,7,8}.
Pointer/key traces show delivery to the current session's table, and temporary
Swift instrumentation confirms its root/window and first responder are valid.
The table's session tool changes from Brush to Move during window construction;
upstream correctly routes the arrow to its Move-tool nudge path.

`compositor_workspace_bootstrap` registers another handle for the current tab's
session. The Qt constructor used to send `selectTool(Move)` and set its foreground
to black before opening a new tab. It now reads the existing tool/palette after
building the controls. Temporary Swift instrumentation is removed. The native
probe retains exact Command/Shift-click and expanding/contracting Shift-arrow
assertions, repeats 16 rounds with eight second-window lifecycles, and checks
tool/palette retention, pixels and history. The contract runner includes it.

The first full verification stopped before native checks with nine CMYK issues
because this isolated data directory lacked the ICC fixture. Its 141 XCTest
tests passed; the failed log is `/tmp/compositor-disjoint-window-fixed-build.log`.
Installing the existing ECI-derived Generic CMYK fixture resolves that setup
error without changing application code or expectations. The corrected
`/tmp/compositor-disjoint-window-verified-build.log` passes 141 XCTest + 949 Swift
Testing tests in 156 suites (1,090 total), with required Vulkan CI/warp hardware
and the subject model. All 16 native rounds pass in
`/tmp/compositor-disjoint-window-verified-native.log`.

Three complete previews also pass in
`/tmp/compositor-disjoint-window-verified-preview-{1,2,3}.log`. Required protected
upstream/generator/shader integrity passes in
`/tmp/compositor-disjoint-window-verified-integrity.log`; the combined run exits
0 in `/tmp/compositor-disjoint-window-verified.exit`. This is a full framework
run and targeted native follow-up, not a repeated complete contract run.

Tab/window, asynchronous save and transform journeys also pass in
`/tmp/compositor-disjoint-window-{tab,save,transform}.log`, with combined terminal
status 0 in `/tmp/compositor-disjoint-window-journeys.exit`. They cover two-window
tab transfers, existing-project reopen, asynchronous save/tab switching and
pending-transform save plus 16-bit/HDR package/photo imports.

This explains the focused Shift-Up failure. It does not establish the cause of
the earlier intermittent Command-click or valid-target mask failures. Those
remain open until independently reproduced and explained.

## Distortion cache correction and native group transforms, 2026-10-15

The native `--transform-gestures-probe` initially timed out because the shared
ordinary-drag helper waits for not-busy, while distortion intentionally stays
busy until Apply/Cancel. The draft-aware event sequence then exposed a production
failure: `/tmp/compositor-transform-gestures-diagnostic-native.log` maps pixel
(0,0) to source (-13.1799,-16.0384), but it remains opaque red. Draft corners are
correct at [(8,10),(64,0),(64,64),(0,64)]. `displayedSnapshot` supplies warped
pixels, but the C ABI reused its original composite because `RenderKey` omitted
corners. The key now includes `transformEdit.corners`; the ordinary layer
transform and original asset identities remain unchanged during a distortion.
`LivePreviewTests.distortionCornersInvalidateTheCachedComposite` covers the
first and later corner updates, no draft history, and Cancel key/pixel restoration.

The fixed host completes `/tmp/compositor-transform-gestures-early-native.log`
with terminal exit 0: six corner/edge/Shift-axis cases cover Cancel/Apply,
persistent draft isolation, independent Qt perspective interior/exterior checks
away from interpolation boundaries, exact preview/committed pixels, retained
target and exact Undo/Redo. Four additional cases move/half-scale selected
layers and a folder through actual canvas pointers, retaining child geometry,
nearest-sampled pixel equations, hierarchy/target and an untouched unselected
layer. Selected-layer state is fixture setup; the visible footer creates the
folder. The contract runner includes the probe.

Required protected-source/generator/shader integrity passes in
`/tmp/compositor-transform-gestures-integrity.log`. All 33 focused tests in five
suites pass in `/tmp/compositor-transform-gestures-fixed-build.log`, including
the new cache regression. Its native companion also completes with exit 0 for
all ten cases. The first full contract attempt exits 1 in
`/tmp/compositor-transform-gestures-full-contract.log`: five CMYK issues came from
the fresh data directory's missing ECI fixture, and 19 hardware-CI issues came
from omitting `COMPOSITOR_COREIMAGE_BACKEND=vulkan` while requiring it. Its 141
XCTest tests pass, and the new cache regression passes. No test expectations or
application behavior were changed to address those setup failures. The existing
ECI fixture is copied into a fresh isolated data directory, and the corrected
required-hardware run passes 141 XCTest + 926 Swift Testing tests and all six
native Wand rounds in `/tmp/compositor-transform-gestures-verified-full-contract.log`.
It was deliberately stopped (terminal process exit 143) during later native
journeys after live upstream moved to 1.5.3. It is not a complete contract pass;
the full gate moves to the merged tree. Prior full checkpoints do not cover
this production cache change. Folded distortions, group rotation, nested/
hidden/masked/HDR cases and physical/Mac acceptance remain open.

## Verified follow-up: selection-outline movement, 2026-10-15

At GNU_Linux `11d0564` plus this test-only follow-up, the release build and all
19 original SelectionEditTests pass in `/tmp/compositor-selection-outline-build.log`.
The same SDK command then runs `--combo-smoke --selection-outline-probe` to
terminal exit 0 in `/tmp/compositor-selection-outline-native.log`.
The probe selects Rectangle/New through visible controls and routes pointer drags
and platform keys through Qt. All four directions at 1 px and Shift+10 px, a
7,-5 drag and a -25,0 drag partly outside the canvas pass. Reversible blue fills
over an existing red source check every pixel of translated/clipped coverage.
Each move preserves exact source pixels, layer records and active target and
records one Move Selection operation; Undo/Redo restore exact coverage.
The contract runner includes the new probe. No production implementation change
was needed. Shell syntax and protected-upstream integrity pass, with integrity
evidence in `/tmp/compositor-selection-outline-integrity.log`.
The complete checkpoint below predates this test-only follow-up; it was not
repeated. Other shapes/tools, feathering, fractional drags and physical/Mac input
remain unverified.

## Upstream 1.5.3 integration in progress, 2026-10-15

A live remote check returned `365b5745eda537f984f3d5bed1e53c361dbc9c91`.
Nine commits after `43d691b` are merged into GNU_Linux as `94cf71e`.
The sole conflict in `docs/project-format.md` retains the Linux descriptions
and accepts upstream's v14 schema. A binary diff comparison before adapter
regeneration proves all eight previously uncommitted files were preserved.
Their backup is `/tmp/compositor-before-upstream-2026-10-15.patch`.

Generated adapters now include upstream's shape-smoothing state, middle-button
layer handling and v14 validation. The first build detects the new Swift file
in the C-kernel target; Linux packaging now excludes it there and replaces the
Metal lookup with a Vulkan adapter. The next build identifies the missing
`CGMutablePath.addArc` and `NSClipView.constrainBoundsRect` compatibility APIs.
Those APIs and native middle-button routing are implemented. The compatibility
build linked the host but was stopped before test execution to include the
identified Linux draft-smoothing correction and isolate acceptance settings.
The first focused build detects a missing explicit `CompositorKernels` import
in the new Linux test. The early native attempt selects the wrong enclosing
scroll area; it now uses the existing named Layers viewport and settling gate.
Both are harness corrections. The focused release build passes 10 XCTest and
64 Swift Testing tests in `/tmp/compositor-upstream-153-focused-fixed-build.log`.
These include unchanged Camera Raw tests covering all 16,777,216 opaque RGB
values across five profiles, alpha/padded rows and native-resolution previews.
The new acceptance suite checks draft/
commit smoothing, explicit hardware submissions with odd padded rows and
buffer recreation, and clip constraints. The native probe checks live middle
scrolling, coordinate continuity, release/boundary behavior and visible shape controls.
The padded-row kernel checks pass in `/tmp/compositor-upstream-153-kernel-contract.log`,
including refusal of undersized rows for lookup and repair.
Protected-source, generator and shader checks passed in the first integrity
attempt; its only failure was the expanded ledger's missing evidence mappings.
The populated ledger and complete integrity checks pass in
`/tmp/compositor-upstream-153-integrity.log`: 47 commits, 37 code commits.

The first middle-scroll harness retained a deleted viewport after a normal
panel refresh; the debugger confirms `QAbstractSlider::value` at that stale
pointer. Re-querying the named Layers viewport fixes the harness. The next
native run exposes a production defect: the model has radius 12 and an enabled
Smooth Corners toggle, while Qt retains the old disabled toggle during field
focus. `/tmp/compositor-upstream-153-shape-diagnostic-native.log` records both
states. The renderer now refreshes dependent control state in place while
retaining the focused ToolHeaders field, using the existing selection-amount
validation mechanism.

The corrected release build passes all three Linux acceptance tests in
`/tmp/compositor-upstream-153-controls-fixed-build.log`, including two actual
AMD Radeon Graphics (RADV RENOIR) submissions and buffer recreation. Its native
companion `/tmp/compositor-upstream-153-controls-fixed-native.log` completes the
middle-scroll journey and both circular/smoothed shape journeys, with exact
Undo/Redo and preview/commit checks. Upstream sources/assertions remain unchanged.
The optional unchanged upstream GPU performance benchmark passes (exit 0,
158.871 seconds) in `/tmp/compositor-upstream-153-gpu-benchmark.log`, with exact
CPU/GPU pixels for every workload through 48 MP and required direct GPU calls.
[Linux measurements](camera-raw-linux-performance.md) retain all samples and
the limited preview gains, including the mixed workload's lack of improvement.
The complete required-hardware merged-tree run passes 141 XCTest + 945 Swift
Testing tests in 155 suites (1,086 framework tests) in
`/tmp/compositor-upstream-153-full-contract.log`. All 11 source-coverage checks
pass: 156 upstream Swift files (128 unchanged, 20 generated, six replaced,
two platform) and 89 upstream test files (87 unchanged, two generated mirrors).
The native phase has passed all six repeated Wand rounds, the main combination
journey, Levels/Curves/Hue handle probes, selection-outline movement, all ten
distortion/group-transform cases, the 1.5.3 Layers/Shape probes (including retained
Radius field/focus/cursor), and transform numeric/scrub controls. Proofing and
SVG import also pass. The full runner then exits 1 during the preview journey:
the mixed-font save assertion still hardcodes manifest version 13. Upstream
1.5.3 writes 14. The assertion now requires 14 separately from the unchanged
font-run equality check, retaining both schema and metadata requirements. Its
terminal `.exit` file records 1; this is not a full contract pass.

The test-only `--zoom-cursor-probe` now reproduces a production failure in
`/tmp/compositor-zoom-cursor-before-native.log` (terminal exit 1). Both left-button
Zoom cases pass, including Alt release/click and direction reversals. The first
middle-button reversal fails to change its native picture above the starting
point. Static tracing confirms that all three middle-button handlers discard
`compositor_canvas_mouse`'s returned cursor, whereas left-button handlers apply it.
`SessionWindow::applyCanvasCursor` supplies the same existing cursor/picture
logic to both paths. The first fixed isolated run passes both left-button and
both Ctrl/Meta middle-zoom cases, then exposes a second defect:
`/tmp/compositor-zoom-cursor-fixed-native.log` exits 1 because plain pan release
retains the grabbing cursor. Upstream relies on cursor-rectangle invalidation;
that AppKit compatibility hook is empty. The canvas bridge already restores
cursor rectangles on left release; it now does so on middle release as well.
The static Compositor target builds successfully (218.78 seconds), but the next
isolated link fails: its old bootstrap object expects an AppKit initializer that
the non-testing rebuild no longer exports. The build graph distinguishes the
bootstrap module from its executable. A coherent module-only bootstrap rebuild
completes in 75.58 seconds, followed by an isolated link and probe in
`/tmp/compositor-zoom-cursor-coherent-native.log` (terminal exit 0): both left Zoom
cases, both Ctrl/Meta middle-zoom reversals and plain middle pan from Move/Brush
pass, including native cursor pictures, release restoration, viewport equations
and exact source/history isolation. The module build log is
`/tmp/compositor-zoom-cursor-bootstrap-build.log`; the earlier link failure is in
`/tmp/compositor-zoom-cursor-restored-build.log`.

The isolated SDK builds replay the compile/link arguments in SwiftPM's
`.build/release.yaml`, replacing only the selected host objects and executable
output under `/tmp/compositor-zoom-isolated`. The build helper is
`/tmp/compositor-zoom-isolated-build.py`. Later module-only SwiftPM builds update
static objects without linking the baseline executable. Its checksum is pinned
in `/tmp/compositor-upstream-153-baseline-binary.sha256` and verified before the
isolated link. That full-run binary predates this cursor follow-up, and the runner
script remained unchanged during that execution. It now includes the new cursor
probe. The standard release test-product rebuild passes all 12 original
Cursor/MiddleButton tests in two suites, all six native cursor cases and the
three 1.5.3 Layers/Shape cases in the `cursor-final-` logs. Its preview phase
exits 1 at `Shift-click left stale mask coverage`, before reaching the corrected
font-save assertion. The earlier full binary passed this point. Save/transform/
tab/RAW/text phases were not reached. The terminal status is
`/tmp/compositor-upstream-153-cursor-final.exit` = 1.

The existing exact mask assertions are extracted into `--preview-smoke
--mask-toggle-probe` and remain called at the original point in the complete
preview. Failure diagnostics compare layer state, rendered alpha,
table geometry and Layers scroll position. No production mask fix is made:
`RenderKey` already includes the mask-enabled flag. Focused and full-context
diagnostic runs both pass (terminal exit 0) in
`/tmp/compositor-mask-toggle-diagnostic-{focused,context}.log`. The context run
also passes the corrected v14 exact font/color-run save and reopen assertions.
That diagnostic included an extra pre-click state read, so it does not close
the intermittent mask failure. With that read removed, the focused probe and
three complete preview repetitions pass under `/tmp/compositor-mask-toggle-repeat-*`
(combined terminal status `/tmp/compositor-mask-toggle-repeat.exit` = 0).
Separate save/transform/tab/RAW/text journeys also pass in
`/tmp/compositor-upstream-153-document-final-*.log` (combined exit 0).

The fresh complete contract checkpoint passes in
`/tmp/compositor-upstream-153-final-contract.log` (terminal exit 0):
141 XCTest + 945 Swift Testing tests in 155 suites, all 11 source-coverage
checks and every native journey. Required-shader/protected-source/generator
integrity passes in `/tmp/compositor-upstream-153-cursor-final-integrity.log`.
This checkpoint predates the following hover/keyboard and pointer-router fixes.
The earlier intermittent mask failure remains unexplained; successful repeats
do not establish its cause.

The stricter keyboard cursor probe first rejects the default arrow on Zoom
hover, then detects a retained Zoom picture after switching to Hand without
moving the pointer. The bridge now applies cursor rectangles on ordinary
hover while preserving Move/selection tools' position-specific cursors.
The host refreshes the displayed cursor at the recorded pointer position after
tool/key changes, outside active gestures and sampling. The normal package
rebuild passes Hand/Zoom shape, picture and hotspot checks before stationary
hover in `/tmp/compositor-native-followup-keyboard-cursor.log`; all six existing
Zoom/middle-pan cases and all three Layers/Shape cases pass in adjacent logs.
The contract runner now includes `--keyboard-cursor-probe`.

A separate deterministic routing regression supplies an outer middle-release
event before a Shift-click on the actual upstream mask thumbnail. It fails
before the fix in `/tmp/compositor-native-event-context-before.log`: left-button
hit testing reads that outer event and redirects the click to the table.
Hit testing now runs inside the incoming event's dispatch scope. All three
`NativeMaskGeometryTests` pass in `/tmp/compositor-native-event-context-fixed.log`,
including exact mask toggling, outer-event restoration and one-step Undo/Redo.
This proves a distinct event-context defect; it does not establish the trigger
of the earlier intermittent native failure.

The complete rerun including both follow-ups passes with terminal exit 0 in
`/tmp/compositor-upstream-153-event-cursor-contract.log`: 141 XCTest + 946 Swift
Testing tests in 155 suites (1,087 total), all 11 coverage checks and every
native journey. Both mask Shift-click cases, all six Wand rounds, both cursor
probes, 1.5.3 Layers/Shape controls, preview/save/transform/tab/RAW-lens/text
journeys pass. Required-shader/protected-source/generator integrity passes in
`/tmp/compositor-upstream-153-event-cursor-integrity.log`. The script and terminal
status are `/tmp/compositor-upstream-153-event-cursor-contract.{sh,exit}`.
These checks close the regression gate for this implementation checkpoint;
they do not close broader API, feature-combination or physical/Mac acceptance.

### Right-click hit-test event context follow-up

The next audit finds the same dispatch-order defect in `PointerRouter.rightDown`:
it selects the hit-test target before installing the incoming right-click.
`NativePointerContextTests.rightClickHitTestingAndMenuUseTheIncomingEvent`
reproduces six failures in `/tmp/compositor-right-click-context-before.log`:
an outer middle release causes the table menu to be chosen instead of the child
menu, and hit testing sees the wrong type, modifiers, location and event identity.
The first test-harness builds needed required coder initializers and the existing
Swift-5-mode LinuxOverrideTests target for native-view protocol conformance.

Moving the hit-test call inside dispatch fixes all six failures. Five focused
tests across NativePointerContextTests, NativeMaskGeometryTests and PopUpMenuTests
pass in `/tmp/compositor-right-click-context-fixed.log`. They verify incoming
right-click identity through hit testing/menu lookup/presentation and restoration
of the enclosing event, along with the earlier mask and nested-popup regressions.
Protected-source/generator/shader integrity passes in
`/tmp/compositor-right-click-context-integrity.log`. The earlier complete contract
checkpoint predates this fix. Its follow-up verification terminates with exit 0
in `/tmp/compositor-right-click-context-regression.exit`: 141 XCTest + 947 Swift
Testing tests in 156 suites (1,088 total), the complete native preview, all three
1.5.3 Layers/Shape cases, six Zoom/pan cases and both Hand/Zoom keyboard cases.
Logs are `/tmp/compositor-right-click-context-{full-tests,preview,upstream-153,zoom-cursor,keyboard-cursor}.log`.
The script is `/tmp/compositor-right-click-context-regression.sh`. It does not
repeat the entire native combination/save/transform/tab/RAW-lens/text contract;
those remain evidence from the prior complete checkpoint.

### Pointer button identity and overlapping presses

`NativePointerContextTests` now reproduces two additional defects before the
fix in `/tmp/compositor-pointer-buttons-before.log` (exit 1): right-click menu
events report button 0 instead of 1, and overlapping left/middle presses report
`[4, 1, 0, 0, 0, 4, 4, 1, 5, 5, 0]` instead of the expected
`[4, 5, 4, 4, 0, 4, 0, 1, 5, 1, 0]`. Left press/release replace the whole mask;
middle release clears its bit after its callback. The compatibility mouse-event
factory now sets right/other identities, left transitions preserve other bits,
and middle release clears its bit before dispatch.

The tracking-loop regression additionally sends release through the actual
`NSWindow.nextEvent` pump. A consumed left release preserves the held middle
button and clears the left target; a duplicate release has no target to notify.
The first focused fix passes 19 tests. The stronger hit-test assertion then
fails in `/tmp/compositor-pointer-hit-buttons-before.log`: callbacks see correct
state, but hit testing still sees `[0, 4, 0, 0, 1]`. Moving press-bit updates
before left/middle hit testing fixes that separate ordering edge. All 19 tests
in five suites pass in `/tmp/compositor-pointer-hit-buttons-fixed.log`, covering
pointer context, masks, popups and original Cursor/MiddleButton suites.

Required-shader/protected-source/generator integrity passes in
`/tmp/compositor-pointer-buttons-integrity.log`. The regression script
`/tmp/compositor-pointer-buttons-regression.sh` terminates with exit 0:
141 XCTest + 949 Swift Testing tests in 156 suites (1,090 total), complete native
preview, all three 1.5.3 Layers/Shape cases, six Zoom/pan cases and both keyboard
cursor cases pass. Logs are `/tmp/compositor-pointer-buttons-{full-tests,preview,upstream-153,zoom-cursor,keyboard-cursor}.log`;
the terminal status is `/tmp/compositor-pointer-buttons-regression.exit`.
The older complete contract checkpoint predates these changes. Its broader
combination/save/transform/tab/RAW-lens/text phases were not repeated for this
follow-up. Physical multi-button input and broader native API acceptance remain
open; this does not explain the earlier intermittent mask failure.

### Transform snapping native acceptance

Historical feature row 20 previously had only core resize/guide evidence. The
new `--transform-snap-probe` supplies 66 native cases: 33 on each axis, comprising
move gestures, side-handle resize and a proportional corner. Two opaque source
fixtures and explicit coordinates provide independent geometry and pixel
oracles. Initial imports, placements and guide creation are fixture commands;
the View menus, Zoom field, aspect/sampling controls and transform pointer
gestures use visible native Qt controls.

The 24-case initial move run passes in
`/tmp/compositor-transform-snap-before-native.log`. The 33-case horizontal
move/resize extension passes in `/tmp/compositor-transform-snap-resize-native.log`.
The completed two-axis version passes all 66 cases in
`/tmp/compositor-transform-snap-both-axes-native.log` (terminal status
`/tmp/compositor-transform-snap-both-axes.exit` = 0). Its release build also passes
all 17 original ResizeSnapTests/GuideTests in
`/tmp/compositor-transform-snap-both-axes-build.log`.

Cases cover canvas/other-layer edges and centers, visible guides, Snap/Snap To/
Show toggles, hidden/disabled targets, global Snap off and Meta mapped to
upstream Control suppression. Scale is checked at 1/2/4 screen points per
document pixel; three pixels snap at six screen points but not twelve, while
two pixels still snap at eight. Live preview preserves history and the saved
state. Release commits exact preview pixels and clears alignment targets;
interior snap-line strips also change visibly on release. One Undo returns to
the exact saved pixels/records/unmodified state and Redo restores the commit.
Unselected records and active target remain exact.

The existing upstream implementation supplies this behavior; no production
snapping code changes. The contract runner now includes the probe. Required
integrity passes in `/tmp/compositor-transform-snap-integrity.log`. Related
native transform gestures (ten cases) and numeric fields (eight cases) pass in
`/tmp/compositor-transform-snap-related-{transform-gestures,transform-fields}.log`.
The complete preview then reproduces the earlier intermittent mask failure;
`/tmp/compositor-transform-snap-regression.exit` is 1. Its failure-only diagnostics
show a single-layer model with the mask still enabled, a clicked table height
of 1,350 and two Layers scroll areas at offsets 432 and 0. The clicked table may
still represent the old many-layer viewport. Direct hit/visibility diagnostics
and a focused scroll-then-replace probe are being tested before any production
fix; exact mask alpha/Undo/Redo assertions remain unchanged. The earlier complete
contract and 1,090-test framework checkpoint predate this test-only addition.
Competing targets/grid, rotated/masked/group/HDR combinations and physical/Mac
acceptance remain open.

The first visible-target diagnostic passes three focused scroll/replacement
runs and one complete preview (`/tmp/compositor-mask-visible-target-before.exit`
= 0). Subsequent complete-context repeats reproduce the mask alpha failure in
run 1 while runs 2/3 pass. Crucially, the failing click is in the viewport, the
table is already 252×485 at offset 0, and table/current project handles both
equal 12. The diagnostic also lists many-row scroll areas elsewhere in the
widget tree, so their geometry alone did not identify the clicked table. Logs are
`/tmp/compositor-mask-visible-target-context-{1,2,3}.log`; the combined status is 1.
This rules out a clipped/wrong-project click for that occurrence. A direct native
accessibility snapshot now checks that the mask thumbnail exists at the click
point without Qt accessibility's explicit tree refresh. That diagnostic is
tested under `/tmp/compositor-mask-row-before.sh`; no production mask fix is
claimed. The focused run and complete-context run 1 pass. Run 2 fails earlier at
`native Command-click did not create disjoint selection`, before the mask checks.
Run 3 conclusively rejects an invalid synthetic click: the table is scrolled by
863 pixels and row zero maps to global y = -582, outside the viewport. Individual
logs/statuses are `/tmp/compositor-mask-row-before-context-{1,2,3}.{log,exit}`;
the combined status is 1.

The mask harness now waits up to five seconds for a table belonging to the
active project, a click point in the visible viewport with the expected Qt hit
target, and a native `Select mask:` thumbnail at that point. It queries the
existing native snapshot without Qt accessibility's explicit tree fetch, though
the snapshot can request layout. The exact alpha 0→255, Undo and Redo assertions
remain unchanged. This corrects the verified invalid-target synchronization
gap; it is not a production mask fix or proof of every earlier failure's cause.
Focused scroll/replacement and all three complete previews pass through
`/tmp/compositor-mask-visible-ready.sh` (terminal exit 0). The release build
passes three NativeMaskGeometryTests. Logs are
`/tmp/compositor-mask-visible-ready-{build,focused,context-1,context-2,context-3}.log`;
each context's `.exit` is 0. Final required integrity also passes in
`/tmp/compositor-transform-snap-final-integrity.log`. These are scoped follow-up
results, not a repeated complete contract run. The independent Command-click
failure and the cause of the earlier visible/current-project mask failure
remain open; successful repetitions do not prove their causes.

## Verified follow-up: image clipboard through the Qt desktop bridge, 2026-10-14

The new `--image-clipboard-probe` uses actual Edit menu actions and a pointer
selection over two colored layers, checking Copy/Copy Merged/Cut/Paste, PNG MIME,
all selected pixels, pasted origin/dimensions and exact Undo/Redo. It requires
XCTestConfigurationFilePath to be absent so EditorSession uses NSPasteboard.general
rather than its private per-test pasteboard. Eleven original SelectionClipboardTests
pass in `/tmp/compositor-image-clipboard-build.log`. The initial native attempt
does not find the expected clipboard PNG. Format/dimension/pixel diagnostics are
in `/tmp/compositor-image-clipboard-diagnostic-native.log` confirm no Qt MIME
formats or PNG. The normal host and older dialog-smoke entry install the Qt
bridge; the new probe now invokes that same setup. The contract script runs the
probe with XCTestConfigurationFilePath explicitly removed. The bridge-native
run produces the correct PNG dimensions and sample colors. A per-pixel check
then confirms Copy's entire PNG is exact even though QImage object equality
differs; encoded image metadata is not the pixel criterion. Placement diagnostics
prove Paste uses origin [12,12] and size [20,20]; the new test incorrectly read
these Codable arrays as objects. Copy and Copy Merged then pass their entire
native journeys. The remaining Cut assertion incorrectly expected a "Cut"
history name; upstream cutSelection calls clearSelectedPixels, recording "Clear".
`/tmp/compositor-image-clipboard-history-build.log` passes all eleven original
SelectionClipboardTests; its native companion is confirmed terminal exit 0
for all three Copy/Copy Merged/Cut > Paste cases. All PNG pixels and exposed
image MIME, 20×20 crop at origin [12,12], unchanged copy source/history, exact
cut composite, Paste and two-step Cut/Paste Undo/Redo pass. No application
clipboard implementation changes were needed. The contract script invokes the
probe without XCTestConfigurationFilePath. Physical desktop interapplication
delivery, other source types and clipping/HDR/mask combinations remain open.
The complete checkpoint below
predates this test-only follow-up.

## Latest complete checkpoint: gesture focus and Levels/Curves/Hue controls, 2026-10-14

The separate `--hue-range-handles-probe` targets all four handles in all six
color ranges (24 cases), including red wraparound, visible degree labels,
independent Qt HSL/band output, invert/Preview toggles and exact source/history/
alpha/Cancel/OK/Undo/Redo. The contract script includes the probe. Thirteen
original HueSaturationTests pass.
The first native run leaves the handle labels unchanged. Dispatch diagnostics
confirm all gesture callbacks return 0; geometry diagnostics confirm a resolved
412×12 GeometryReader and the expected local pointer coordinates. The model
oracle was also corrected to use upstream's rounded integer-degree response
sampling. `/tmp/compositor-hue-range-state-native.log` proves the Swift band
changes from 315 to 325.05 while Qt labels remain unchanged. The focused Hue
field causes isBeingManipulated to defer the panel rebuild. DragPressFilter now
ends editing of a field outside the gesture view, capturing coordinates/identity
before that focus change can replace widgets. Temporary dispatch/geometry/Swift
state logging is removed. The focus-fixed native run passes degree labels but
fails the HSL pixel comparison. First-pixel diagnostics prove that rounded
straight RGBA8 can choose a different response degree for half-alpha inputs;
using the exact premultiplied components predicts the observed half-alpha color.
An opaque mismatch then establishes that the actual filter applies a 33³ cube,
not direct per-pixel HSL. The independent model now uses Qt conversion at the
eight neighboring cube entries and trilinear interpolation, retaining fractional
unpremultiplied input and the unchanged 3/255 RGB tolerance.
`/tmp/compositor-hue-range-cube-build.log` passes all thirteen original tests;
its native companion is confirmed terminal exit 0 with all 24 cases passing.
Every gesture asserts that numeric-field editing ends; degree labels, pixel
equations, inverted bands, Preview Off/On, exact alpha, source/history isolation,
Cancel/OK, repeated preview and exact Undo/Redo pass.
The required-hardware full contract runner exits 0 in
`/tmp/compositor-hue-gesture-full-contract.log`, confirmed by its `.exit` file
and terminal process result. It passes 141 XCTest + 919 Swift Testing tests in
149 suites (1,060 framework tests), every native journey, all 24 blend modes,
the original Color Picker targets, six complete Wand rounds and all 54 new
Levels/Curves/Hue cases. Thumbnailer and 11 source-coverage checks also pass;
Vulkan executes on required AMD RADV Renoir hardware. This checkpoint includes
the shared gesture focus correction. Required protected-source,
generator and shader integrity exits 0 in
`/tmp/compositor-hue-gesture-integrity.log`.

## Verified follow-up: Curves points and four channels, 2026-10-14

`/tmp/compositor-curves-points-build.log` passes 14 original tests in
FinishingFilterTests, AdjustmentLayerTests and AdjustmentEditorTests.
`/tmp/compositor-curves-points-native.log` is confirmed terminal exit 0 with all
four visible RGB/Red/Green/Blue cases passing. The actual graph gesture adds an
identity middle point, moves it upward, removes it and restores the curve with
Reset. Remove is disabled for an endpoint. A flat gray source lies at the moved
middle knot, so independent knot-output checks cover every visible pixel within
2/255 (integer/premultiplied-alpha rounding); alpha is exact for clear, half and
opaque pixels. Unedited channels remain at their original values. Source/history
isolation, Cancel/OK, repeated preview and exact pixel/record Undo/Redo pass.

The contract script invokes `--curves-points-probe` in a separate process.
Existing upstream CurvesControls and Qt gestures supply the behavior; no
application implementation or dependency is added. This fixture verifies the
middle knot and UI routing, not the full interpolation curve for arbitrary
inputs. Multiple-point limits, other curve shapes and selected/masked/transformed/
HDR/physical/Mac combinations remain open. The earlier full framework/native
checkpoints predate these test-only additions and were not repeated here.

## Verified follow-up: Levels histogram handles, 2026-10-14

The separate `--levels-handles-probe` covers the five triangle handles in all
four channels (20 cases), actual named-coordinate-space drags, independent
per-pixel equations, exact alpha/source history, Preview Off/On, Cancel/OK and
exact Undo/Redo. The contract script includes this probe in a separate process.
All ten original LevelsTests pass in `/tmp/compositor-levels-handles-build.log`.
The first native attempt passes RGB Input black but captures an earlier Gamma
frame. `/tmp/compositor-levels-handles-diagnostic-native.log` proves the timing:
the control has Gamma 1.73, the first red pixel remains 32, then reaches the
independently expected 77 on the third diagnostic frame. The harness now waits
for the whole image to meet the same equations (RGB within 2/255, exact alpha)
before capturing its preview. No application/filter change or looser threshold
is introduced. `/tmp/compositor-levels-handles-settled-build.log` passes all ten
original LevelsTests; its native companion is confirmed terminal exit 0 with
all 20 handle/channel cases passing. Captured previews still satisfy the
independent equations after the wait. The earlier six-case Auto/pipette probe
also exits 0 on the same compiled artifact in
`/tmp/compositor-levels-handles-controls-regression.log`. The earlier full
framework/affected-native checkpoint predates these test-only additions; no
application implementation has changed in this follow-up.

## Verified follow-up: Levels Auto, eyedroppers and channels, 2026-10-14

The separate native `--levels-controls-probe` covers three Auto buttons and
Black/Gray/White sampling, all four visible channels, original/source history
isolation, Cancel/OK and exact Undo/Redo. Expected histogram endpoints, neutral
gamma and per-pixel equations are calculated independently from a colored,
skewed-histogram fixture. Transparent sampling must preserve default settings.
The contract script invokes this probe in a separate process.
`/tmp/compositor-levels-controls-build.log` passes all ten original LevelsTests.
The initial native failure is diagnosed in
`/tmp/compositor-levels-controls-diagnostic-native.log`: Green was requested but
the test's immediate key sequence still selected RGB after a panel rebuild.
The keyboard helper now refetches and focuses the visible picker between key
events and checks its actual index. `/tmp/compositor-levels-controls-focus-build.log`
passes all ten original LevelsTests; its native companion is confirmed terminal
exit 0 with all six cases passing. Each case checks all four channel ranges and
all-pixel RGB against the independent equations within 2/255, with exact alpha,
source/history isolation, Cancel/OK, repeated preview and pixel/record Undo/Redo.
The three eyedropper cases also reject transparent samples. No filter
implementation has been changed by this follow-up. The earlier 1,060-test
framework/affected-native verification below predates these test-only additions;
the entire combined contract runner was not repeated for this follow-up.

## Verified follow-up: all 24 visible blend modes, 2026-10-14

The new `--blend-mode-probe` checks the actual upstream Blend mode picker hosted
by Qt: menu highlight preview, Escape cancellation, Return selection and exact
pixel/record Undo/Redo on two colored layers with partial alpha. Its reference
images use the existing session blend-mode command; this verifies GUI routing,
not an independent proof of the blend formulas.
`/tmp/compositor-all-blend-modes-build.log` passes all five original
`LayerAppearanceTests`. The first native run passes Normal but fails the next
highlight-preview comparison. `/tmp/compositor-all-blend-modes-diagnostic-native.log`
confirms that Darken emits Qt's highlighted signal at the correct row. The render
cache key already used `displayedBlendMode`, but `displayedSnapshot` retained the
committed mode in its manifest. The bridge now substitutes the upstream displayed
mode in the preview snapshot without changing the actual document. A new
`LivePreviewTests` test covers all 24 modes, cancellation/source/history isolation
and matching commit/Undo/Redo. `/tmp/compositor-all-blend-modes-fixed-build.log`
passes nine tests in two suites, including the new 24 parameterized cases.
Its native companion exits 0 with all 24 visible blend modes passing.
Temporary signal/current-row instrumentation is removed. The final follow-up
exits 0: `/tmp/compositor-blend-preview-final-swift.log` passes 141 XCTest and
919 Swift Testing tests in 149 suites (1,060 framework tests), with required
AMD RADV Renoir Vulkan execution. `/tmp/compositor-blend-preview-final-native.log`
passes all 24 visible blend modes and the separate preview, save, transform, tab,
RAW-lens and text-backend journeys. Required integrity exits 0 in
`/tmp/compositor-blend-preview-final-integrity.log`. The entire earlier combined
native journey with six Wand repetitions was not repeated in this follow-up;
its completed result is documented below. The complete checkpoint below
predates this bridge-and-test follow-up and remains the authoritative complete
runner result.

## Earlier complete checkpoint: Scanlines scratch initialization and Menu Picker, 2026-10-14

`tests/test_scanlines_initialization.c` deterministically reproduces an
uninitialized-read defect in the protected Scanlines kernel. `draw_lines`
initializes coverage but assigns beam colors only when coverage increases.
Unlit pixels still read those colors in a multiplication by zero; a NaN in
unwritten malloc storage propagates through the color expression. With the
test's NaN-poisoned malloc, the earlier Linux wrapper returns black instead of
the selected green screen at pixel zero (exit 1).

The Linux-only wrapper now supplies zero-initialized scratch allocation using
standard `calloc`; the protected C file is unchanged. The same regression passes
all 512 opaque green-screen pixels. CMake registers the regression as
`CompositorCore.ScanlinesInitialization`, and the full contract script calls it
directly. The required-hardware complete follow-up exits 0 in
`/tmp/compositor-scanlines-scratch-fixed-full-contract.log`, confirmed by its
`.exit` file and terminal process result. It passes 141
XCTest and 918 Swift Testing tests in 149 suites, both Scanlines Color Picker
preview/commit journeys, all six visible RGB TIFF cases, every native journey,
six complete Wand rounds, thumbnailer and 11 source-coverage checks. Vulkan uses
the required AMD RADV Renoir hardware. Required shader/generator/protected-source integrity exits 0 in
`/tmp/compositor-scanlines-scratch-integrity.log`. The deterministic defect and
complete fresh regression verify the correction. This checkpoint also covers the
new Menu Picker implementation, and predates the next 24-mode GUI probe.

## Focused follow-up: visible RGB TIFF export, 2026-10-14

The Qt Menu renderer now hosts inline Picker choices using the existing
`QActionGroup`, allowing the actual Export As > More > TIFF selection.
`/tmp/compositor-rgb-tiff-document-dpi-native.log` exits 0 for six visible
Cancel/Export cases at document resolutions 72, 150 and 300 DPI. Every case
preserves source pixels, document/history/palette and busy-state isolation.
Exports preserve all-pixel alpha, including clear, half-transparent and opaque
pixels, and RGB within 2/255. Independent Pillow reads confirm exact TIFF DPI
tags, 4,096 exact alpha pixels per file and maximum RGB difference 1/255.
The build log passes the PDFMatteTests test and its four parameterized cases.

The initial DPI fixture incorrectly expected input-image DPI to become document
DPI; ordinary raster import starts at 72 DPI in upstream too. The corrected
fixture explicitly sets document resolution through the existing Image Size
command before exporting. No export-backend change was needed.

`--rgb-tiff-probe` isolates these cases from the earlier Color Picker journeys.
Earlier combined attempts intermittently failed Scanlines repeated-preview or
commit comparisons; the cause was unresolved at this checkpoint and is
investigated and corrected in the latest complete checkpoint above. The same-build combined
follow-up `/tmp/compositor-rgb-tiff-combined-native.log` exits 0, passing the
Color Picker targets, Scanlines, all six TIFF cases and 16 Gradient variants.
This successful repeat does not establish the cause of the earlier failures.
The earlier PDF checkpoint
below predates this Menu Picker implementation and these TIFF cases; its
1,059-test result must not be represented as a full check of this follow-up.
Physical/Mac comparison and other export combinations remain unverified.

## Earlier complete checkpoint: exported PDF readback and premultiplied fallback, 2026-10-14

`/tmp/compositor-pdf-matte-readback-env-fixed.log` exits 0: 35 XCTest
(CoreGraphics/Raster) and 13 Swift Testing tests in five suites pass. The new
`PDFMatteTests` test has four parameterized cases: 72/150 DPI × nil/green matte.
Public CGPDFDocument/drawPDFPage now preserves the point-sized media box,
opaque red, clear exterior without a matte, green exterior with a matte and
correct semi-transparent blue/green composition. RGB/alpha allows 2/255 rounding.

The initial fixture used the wrong bitmap row for a CoreGraphics-drawn pixel;
that is corrected by locating the blue pixel in the actual source bitmap.
`/tmp/compositor-pdf-matte-readback-fixture.log` then proves both defects:
PDFParser ignored its own export's content fills, and drawSwift multiplied
already premultiplied RGB by alpha again. The reader now attaches its exporter's
rectangle fills to the page; drawing paints them before the image and preserves
graphics state. Fallback blending now respects CGImage.alphaInfo. Foundation
handles parsing and the existing CoreGraphics/Skia path renders the fill;
no new production dependency is added. Reference tokenization is bounded to
three splits rather than tokenizing the whole PDF.

`/tmp/compositor-pdf-matte-readback-fixed.log` passed the new PDF and 35 XCTest
checks but failed five CMYK tests because the invocation omitted the isolated
XDG data/config paths holding its ICC fixture. The corrected same-build command
passes all 48 selected tests in the env-fixed log above.

The complete 1,058-test checkpoint below predates this reader/blending follow-up.
The new required-hardware full runner exits 0 in
`/tmp/compositor-pdf-matte-readback-full-contract.log`, also recorded in its
`.exit` file. It passes 141 XCTest plus 918 Swift Testing tests in 149 suites
(1,059 framework tests), every native journey, six Wand rounds, thumbnailer
and 11 source-coverage checks. The new four PDF cases are included.
Fresh artifacts from this build also pass independent validation in
`/tmp/compositor-pdf-matte-readback-independent.log`: exact PDF image/mask
composition and four-channel CMYK TIFF inks, with the same documented Poppler
resampling tolerance. Required integrity passes in
`/tmp/compositor-pdf-matte-readback-integrity.log` (exit 0).
Broader PDF input and physical/Mac acceptance remain open.

## Earlier complete checkpoint: PDF/CMYK TIFF matte and menu Toggle correction, 2026-10-14

Twenty tests in `ColorPickerTests`, `CanvasSizeTests`, `JPEGExportTests`,
`CMYKTests` and `ExportTests` pass in five suites (2.368 seconds) in
`/tmp/compositor-pdf-tiff-matte-fixed-build.log`. The native journey exits 0 in
`/tmp/compositor-pdf-tiff-matte-fixed-native.log`, including all prior picker
targets, eleven modal cases (PDF and CMYK TIFF Cancel/Export included) and the
next 16 Gradient cases.

The visible RGB/CMYK menu had no actions: its upstream Toggle nodes were omitted
by the Qt menu builder. Menu Toggle now hosts a checkable QAction with the same
isOn handler. The PDF consumer discarded CGContext.fill's page matte; its
recording now retains the fill in the page content before the image. Image/mask
bytes and CMYK ICC image embedding are preserved.

`python3 tests/check_export_matte.py /tmp/compositor-pdf-tiff-matte-artifacts`
exits 0 in `/tmp/compositor-pdf-tiff-matte-independent.log`. Existing Poppler,
pypdf and Pillow/LittleCMS validate the artifacts produced by the native
journey with `COMPOSITOR_EXPORT_MATTE_ARTIFACTS` set to that directory.
All 4,096 PDF image/mask compositions are exact against the independent green
matte fixture. Poppler's four page corners are exactly green; interior/exterior
RGB differs at most 5/255, within the measured ramp step 6/255, excluding the
interpolation transition band. TIFF has four CMYK ink channels and its embedded
ICC; all 4,096 ink pixels exactly match independent relative-colorimetric
LittleCMS conversion through that profile.

The initial `/tmp/compositor-pdf-tiff-matte-native.log` failed at an earlier
Scanlines preview/commit comparison. The same-build repeat passed Scanlines but
exposed the omitted CMYK menu in `/tmp/compositor-pdf-tiff-matte-repeat-native.log`;
its PDF artifact also revealed the missing matte. The corrected combined run
passes; the original intermittent Scanlines mismatch has no established cause.
PDF matte re-import and physical/Mac comparison remain unverified.

The required-hardware full runner exits 0 in
`/tmp/compositor-pdf-tiff-matte-full-contract.log`, also recorded in
`/tmp/compositor-pdf-tiff-matte-full-contract.exit`. It passes all 1,058 framework
tests (141 XCTest, 917 Swift Testing in 148 suites), all native journeys including
all picker targets and six Wand rounds, thumbnailer and 11 source-coverage checks.
Required Vulkan executes on AMD RADV Renoir; device-loss fallback checks also pass.
Required-shader/protected-source integrity after the corrections passes in
`/tmp/compositor-pdf-tiff-matte-integrity.log` (exit 0).
The complete 1,058-test checkpoint below predates these production corrections.

## Color Picker Canvas Size and JPEG export: follow-up

Eleven `ColorPickerTests`/`CanvasSizeTests`/`JPEGExportTests` pass in three suites
(0.103 seconds) in `/tmp/compositor-dialog-color-picker-oracle-build.log`.
`/tmp/compositor-dialog-color-picker-oracle-native.log` exits 0 with all prior
picker targets, seven modal dialog cases and the next 16 Gradient cases.
Extension Color and Export Background both pass modal ownership, actual visible
swatch RGB, Hex Return delivery, live binding, picker Cancel/OK and outer Cancel/commit.
A centered green extension to 72×72 matches every source/exterior pixel, with
exact pixel Undo/Redo. JPEG at quality 100/85/10 matches all 4,096 pixels of an
independently assembled green-matte image encoded by the installed Qt codec,
within 2/255 per RGB channel. Corner RGB actual/oracle values are identical:
0/255/1, 0/254/17 and 12/252/0 respectively. Source pixels/records/history/palette
remain exact, and export writing releases the busy hold.

The initial JPEG fixture used unspecified persisted quality and a fixed 5/255
matte limit; it failed in `/tmp/compositor-dialog-color-picker-native.log`.
An explicit 100% fixture passed in `/tmp/compositor-dialog-color-picker-quality-native.log`.
The subsequent 85% fixture's 15/255 limit failed on blue=17 in
`/tmp/compositor-dialog-color-picker-qualities-native.log`; the independent codec
oracle reproduces that value exactly. The final comparison covers all pixels at
three explicit qualities rather than widening the limit against an uncompressed color.
Only the native harness changed in this follow-up; no production code or library
was added. The complete 1,058-test checkpoint below still predates the earlier
modal-owner correction and these new fixtures. PDF/CMYK TIFF matte variants,
multiwindow geometry/HDR and physical/Mac comparison remain open.

## Color Picker filter and modal dialog targets: follow-up

Twenty `ColorPickerTests`/`FinishingFilterTests`/`RawDitherTests`/`ScanlinesTests`
pass in 0.043 seconds in `/tmp/compositor-filter-color-picker-build.log`.
The native journey exits 0 in `/tmp/compositor-filter-color-picker-native.log`:
Gradient Map Shadows/Highlights, Vignette, Dither Dark/Light and Scanlines
screen/lines colors all pass live RGB with exact alpha, picker Cancel/OK,
palette/source/history isolation and exact filter preview/commit Undo/Redo.
Existing filter observers supply these paths without filter implementation changes.

The modal Grid Settings test exposed a blocked Hex Return: Qt's active modal
sheet blocked input to a picker owned by the main window. The failure and
ownership diagnostics remain in `/tmp/compositor-grid-color-picker-{native,dispatch-native}.log`.
`SessionWindow` now parents a new Color Picker to its active modal sheet.
`/tmp/compositor-grid-color-picker-parent-build.log` passes nine picker/grid
source tests in two suites (0.023 seconds), and
`/tmp/compositor-grid-color-picker-parent-native.log` exits 0 with all previous
palette/text/effect/filter targets, modal Grid Color and the next 16 Gradient cases.
Actual Hex Return delivery, live Custom preset, picker Cancel/OK, restored original
preset on Cancel, outer sheet Cancel and exact document/history/palette isolation pass.

The complete 1,058-test checkpoint below predates this modal-owner correction;
it has not been rerun for this focused change. Required-shader/protected-source
integrity passes afterward in `/tmp/compositor-grid-color-picker-integrity.log` (exit 0).
Canvas Size/Export dialog targets,
multiwindow geometry/HDR and physical/Mac comparison remain open.

## Color Picker text/effect targets: follow-up

Thirty-two `ColorPickerTests`/`TypeToolTests`/`NativeTextEditingTests` pass in
1.310 seconds in `/tmp/compositor-text-color-picker-build.log`. The focused
native journey exits 0 in `/tmp/compositor-text-color-picker-native.log`.
Both the visible Type color swatch and foreground palette swatch preview green
on the selected middle two letters of ABCD, leaving the outer letters exact.
Cancel restores exact draft colors/local history; OK records local Undo/Redo
and updates foreground as upstream specifies, with background and document
records/global history unchanged. Existing TypeControls observers supply this.

Seventeen `ColorPickerTests`/`LayerEffectsSurviveTests`/`ColorOverlayTests` pass
in 0.393 seconds in `/tmp/compositor-effect-color-picker-menu-build.log`.
The native journey exits 0 in `/tmp/compositor-effect-color-picker-menu-native.log`
with all six effects: Stroke, Drop Shadow, Color Overlay, Inner Shadow, Outer
Glow and Inner Glow. The visible fx menu creates the effect, its swatch opens
the picker and Hex changes its actual canvas RGB while alpha stays exact.
Cancel restores exact pixels; OK preserves preview and palette isolation.
Effect edits retain upstream's Edit-effect history policy, rather than the
palette/text preview policy. Undo/Redo restores exact pixels/records/target,
and saved .comp manifests contain green RGB under the correct effect key.
EffectsSheet's existing observer supplies the preview; no production code changes.

The first effect fixture failed to locate the visible fx menu in
`/tmp/compositor-effect-color-picker-native.log`. The corrected selector chooses
the visible fx button. All targets plus the next 16 Gradient cases also pass
in `/tmp/compositor-color-picker-target-sequence-native.log` (exit 0).
The complete 1,058-test checkpoint below predates these harness additions.
Filter and Grid dialog targets are covered by the newer focused follow-up above.
Canvas Size/Export dialog targets, multiwindow geometry/HDR and physical/Mac comparison remain open.

## Earlier full-run checkpoint: Color Picker controls and position, 2026-10-14

The unfiltered release runner exits 0, also recorded in
`/tmp/compositor-color-picker-final-full-contract.exit`. All **1,058/1,058**
framework tests pass (141 XCTest in 5.243 seconds; 917 Swift Testing in 148
suites in 120.163 seconds). All native combination/preview/save/transform/tab/
RAW-lens/text journeys, thumbnailer and 11 source-coverage checks pass with
required AMD RADV Renoir Vulkan hardware in
`/tmp/compositor-color-picker-final-full-contract.log`.
The complete run includes both Color Picker targets and all prior painting,
selection/mask/clipping and six-round Wand regression cases. Required integrity
passes in `/tmp/compositor-color-picker-integrity.log` against `43d691b`.

### Color Picker visible controls and correction evidence

Nine tests in three suites pass in `/tmp/compositor-color-picker-visual-build.log`
(0.032 seconds). Both foreground/background native cases exit 0 in
`/tmp/compositor-color-picker-visual-native.log`. Actual palette swatches,
RGB clamps with Tab commit, full/shorthand/invalid Hex with Return commit,
live RGB-to-Hex updates and retained text/focus/cursor pass. Hue and
saturation/brightness gestures produce RGB 48/64/64; actual preview pixels
match within 2/255. Canvas samples and transparent refusal, Cancel/OK,
title-bar cancellation and per-window reopen position preserve exact document
pixels/records/history and the other palette color. Reviewed offscreen PNGs:
`/tmp/compositor-color-picker-{foreground,background}.png`.

The initial native diagnostic records stale 300/-20/128 fields and old Hex in
`/tmp/compositor-color-picker-diagnostic-native.log`. Color Picker refresh now
preserves editing text/cursor and ignores transient focus loss while replacing
widgets; committed fields normalize without redispatch. Gesture presses end
Hex focus before changing Hue/SB. A second failure in
`/tmp/compositor-color-picker-complete-native.log` exposes lost reopen position;
the Qt window now retains its last picker position.

The first full attempt `/tmp/compositor-color-picker-full-contract.log` exits 1:
all 1,058 framework tests and both picker cases pass, but the offscreen fixture
leaves the main window inactive before Gradient. Owner-window activation is
now restored as in other dialog journeys. Nine tests and both picker cases plus
all 16 Gradient cases pass in `/tmp/compositor-color-picker-sequence-{build,native}.log`
(native exit 0; tests 0.023 seconds).
The full rerun `/tmp/compositor-color-picker-final-full-contract.log` exits 0;
its wrapper records 0 in the matching `.exit` file. Required
integrity passes in `/tmp/compositor-color-picker-integrity.log` against `43d691b`.
Text/effect/dialog targets, multiwindow geometry/HDR and physical/Mac comparison
remain open; the older green full checkpoint below predates these changes.

## Latest successful full-run checkpoint: main-pump correction and painting controls, 2026-10-14

The unfiltered release runner exits 0 with **1,058/1,058 framework tests**:
141 XCTest in 4.913 seconds and 917 Swift Testing in 148 suites in 109.679 seconds.
All native combination/preview/save/transform/tab/RAW-lens/text journeys,
thumbnailer and 11 source-coverage checks pass with required AMD RADV Renoir
Vulkan hardware: `/tmp/compositor-main-pump-fixed-full-contract.log`.
Required-shader/protected-source integrity exits 0 in
`/tmp/compositor-main-pump-fixed-integrity.log`. The fresh remote-tip read in
`/tmp/compositor-main-pump-upstream-tip.log` still returns `43d691b`.

This includes all 16 Gradient settings, ten Eraser cases, 12 Spot Healing cases,
both Eyedropper/Alt Brush cases, and **six complete Wand rounds** (48 controls,
12 Add/Subtract and 18 sample-size cases). The ordinary Foundation main pump
now uses a positive one-millisecond deadline; the diagnostic traps/API are
removed and the five-second test gate is unchanged. All prior selection,
clipping/mask, shortcut/autosave, editing and native journeys remain green.
Wider combined-feature, physical-device and Mac acceptance remain open.

## Earlier failed full-run attempt: painting controls, 2026-10-14

`/tmp/compositor-painting-controls-full-contract.log` exits 1. All 1,058
framework tests pass (141 XCTest in 3.596 seconds; 917 Swift Testing in 148
suites in 97.431 seconds), with actual AMD RADV Renoir Vulkan submissions.
The native combination passes all 16 Gradient, ten Eraser and 12 Spot Healing
cases, then reaches Wand. All eight sampling/control cases and the visible
Add/Subtract variant pass; a later Shift/Alt mode click remains busy beyond
the unchanged five-second gate. Eyedropper and later native journeys are not
reached by this attempt. At this checkpoint the busy cause was unresolved;
the later main-pump correction and green full run above supersede that result.

Required-shader/protected-source integrity independently exits 0 in
`/tmp/compositor-painting-controls-integrity.log`, matching `43d691b`.
A first GDB `--wand-probe` reproduction passes in
`/tmp/compositor-wand-debug-stacks.log`; it does not confirm the cause or a fix.
The earlier successful full checkpoint below remains historical evidence.

### Wand timeout investigation and main-pump correction — focused verification passed

`/tmp/compositor-wand-repeat-stacks.log` captures the old pump's timeout in
repetition 2 under GDB: `busy=true`, tracking false, all worker threads idle.
The diagnostic run `/tmp/compositor-wand-pump-completion-stacks.log` captures
a queued-start variant (`busy=false`, old history). After the unchanged
five-second failure, a future-deadline RunLoop call starts the job immediately;
subsequent calls complete it in **4 ms**, with `done=true`, `busy=false` and
`undo="Magic Wand"`. This distinguishes main-queue starvation from a slow
Wand kernel.

The ordinary `compositorPumpMain` now permits ready sources at a positive
deadline bounded to one millisecond, rather than an already-expired `Date()`.
The five-second test gate and upstream Wand algorithm are unchanged.
Temporary GDB traps and the diagnostic C ABI were removed; `--wand-repeat`
retains six complete Wand rounds as native regression coverage.
Focused verification passes: 32 tests in four suites in 0.735 seconds in
`/tmp/compositor-main-pump-fixed-build.log`, and the native repeat journey exits
0 in `/tmp/compositor-main-pump-fixed-wand.log`. All six complete rounds pass:
48 sampling/control cases, 12 Add/Subtract cases and 18 sample-size cases.
The full contract runner now invokes `--wand-repeat` for this regression;
its post-correction full verification also exits 0 in
`/tmp/compositor-main-pump-fixed-full-contract.log`, including every later native
journey and all 1,058 framework tests.

A lightweight XCTest pump experiment did not reproduce the Qt condition:
`/tmp/compositor-main-pump-before-corrected.log` passes with the old pump.
It was removed and is not claimed as a failing regression. Its initial
actor-isolated synchronous entry was rejected by XCTest discovery in
`/tmp/compositor-main-pump-before.log`; that was a test-only experiment.

## Latest successful full-run checkpoint: Marquee and curved Skia holes, 2026-10-14

The unfiltered release runner exits 0 with **1,058/1,058 framework tests**:
141 XCTest in 4.531 seconds and 917 Swift Testing in 148 suites in 97.636 seconds.
All native editing/preview/save/transform/tab/RAW-lens/text journeys, thumbnailer
and 11 source-coverage checks pass with required Vulkan hardware:
`/tmp/compositor-marquee-pathops-full-contract.log`.
Required-shader/protected-source integrity exits 0:
`/tmp/compositor-marquee-pathops-integrity.log` (protected content matches `43d691b`).

This includes Skia Simplify before AsWinding and the ellipse-hole regression,
all Rectangle/Ellipse modifier and Add/Subtract pointer cases, both lasso modes
and all preceding selection/menu/clipping follow-ups. The independent ellipse
geometry oracle excludes a one-pixel curve band; Undo/Redo compares actual full
rasters exactly. Physical/Mac input and wider combinations remain open.

## Earlier full-run checkpoint: live selection Amount validation, 2026-10-14

The unfiltered release runner exits 0 with **1,057/1,057 framework tests**:
141 XCTest in 4.682 seconds and 916 Swift Testing in 147 suites in 98.955 seconds.
All native editing/preview/save/transform/tab/RAW-lens/text journeys, thumbnailer
and 11 source-coverage checks pass with required Vulkan hardware:
`/tmp/compositor-selection-menu-full-contract.log`.
Required-shader/protected-source integrity exits 0:
`/tmp/compositor-selection-menu-integrity.log` (protected content matches `43d691b`).

This run includes live SelectionAmountSheet validation and native Expand/Contract/
All/Inverse checks, plus the preceding clipping-menu and nested-popup follow-ups.
The focused Amount field stays in place while OK, hint opacity and slider update;
restoring the cached initial value works. Field/focus/cursor and Cancel/OK/coverage/
Undo/Redo pass. Existing Feather-to-mask cases also pass in this complete run.
Physical/Mac input and wider combinations remain open.

## Earlier full-run checkpoint: recursive Add Mask popup, 2026-10-14

The unfiltered release runner exits 0 with **1,057/1,057 framework tests**:
141 XCTest in 4.781 seconds and 916 Swift Testing in 147 suites in 98.294 seconds.
All native editing/preview/save/transform/tab/RAW-lens/text journeys, thumbnailer
and 11 source-coverage checks pass with required Vulkan hardware:
`/tmp/compositor-mask-submenu-full-contract.log`.
Required-shader/protected-source integrity exits 0:
`/tmp/compositor-mask-submenu-integrity.log` (protected content matches `43d691b`).

This run includes recursive popup serialization/Qt hosting and the nested-choice
regression. Four Add Mask Reveal/Hide submenu cases, layer/folder mask actions,
Ctrl image/mask thumbnail selection with separate-layer fill proof and all prior
follow-ups run in the complete native combination journey. Text-to-gradient also
passes. Physical/Mac acceptance and wider combinations remain open.

## Earlier full-run checkpoint: mask picker and Button modifiers, 2026-10-14

The unfiltered release runner exits 0 with **1,056/1,056 framework tests**:
141 XCTest in 5.098 seconds and 915 Swift Testing in 146 suites in 99.482 seconds.
All native editing/preview/save/transform/tab/RAW-lens/text journeys, thumbnailer
and 11 source-coverage checks pass with required Vulkan hardware:
`/tmp/compositor-mask-picker-final-full-contract.log`.
Required-shader/protected-source integrity exits 0:
`/tmp/compositor-mask-picker-final-integrity.log` (protected content matches `43d691b`).

This run includes all previous changes, four visible layer/folder Reveal/Hide
mask cases, Black/White picker keys and the Button event-context fix. Its new
regression verifies all modifier flags, an unmodified action, restoration of the
previous event/flags, and unchanged legacy pointer-handler semantics.

The first full attempt `/tmp/compositor-mask-picker-current-full-contract.log`
failed on the existing text-to-gradient journey: Return remained busy beyond
five seconds. After narrowing event restoration to Button actions, the repeated
full run passes that journey and exits 0. This repetition does not establish the
cause of the first timeout; its log remains available. Physical/Mac acceptance
and wider combinations remain open.

## Earlier full-run checkpoint: Boolean Picker and Clone Stamp, 2026-10-14

The unfiltered release runner exits 0 with **1,055/1,055 framework tests**:
141 XCTest in 4.795 seconds and 914 Swift Testing in 145 suites in 98.718 seconds.
All native editing/preview/save/transform/tab/RAW-lens/text journeys, thumbnailer
and 11 source-coverage checks pass with required Vulkan hardware:
`/tmp/compositor-clone-current-full-contract.log`.
Required-shader/protected-source integrity also exits 0:
`/tmp/compositor-clone-current-integrity.log` (protected trees match `43d691b`).

This run includes the Boolean Picker fix and new XCTest regression, actual Clone
Alt source/Aligned/This Layer/All Layers controls, blank-destination composite
sampling and exact Undo/Redo. It also includes the preceding Shape, Flip/Invert
and Pixel Grid follow-ups, alongside all previously passing native journeys.
Physical/Mac acceptance and wider combinations remain open.

## Earlier full-run checkpoint: 2026-10-14, upstream 1.5.2 `43d691b`

The unfiltered release runner exits 0 with **1,054/1,054 framework tests**:
140 XCTest in 4.785 seconds and 914 Swift Testing in 145 suites in 99.281 seconds.
All native editing/preview/save/transform/tab/RAW-lens/text journeys, thumbnailer
and 11 source-coverage checks pass with required Vulkan hardware:
`/tmp/compositor-shortcut-current-full-contract.log`.
Required-shader/protected-source integrity also exits 0:
`/tmp/compositor-shortcut-current-integrity.log`.

The current run includes the autosave draft-preservation fix, focused shortcut
search/cursor restoration, closed-panel state/action cleanup, conflict/removal/
Restore Defaults UI checks and all three actual-process persistence probes.
Nested folder duplication, layer/folder mask paint/fill/blur and Feather-to-mask
follow-ups also run in the complete native combination journey. The added C ABI
shortcut lifecycle regression accounts for the increase from 1,053 to 1,054.

Source coverage remains 155 upstream Swift files (128 unchanged, 20 generated,
5 replaced, 2 platform), 175 target files, and 84 unchanged/2 mirrored test files.
Hardware checks report successful Vulkan submissions on AMD RADV Renoir; the
native renderer verifies Vulkan execution and CPU fallback on device loss.
No runtime test skips are declared. Full feature/visible-control mapping and
physical/Mac acceptance remain open as recorded in the completion audit.


### Spot Healing visible modes and pointer gestures: follow-up

Twenty-two `SpotHealingTests`/`UpstreamEditorTests` pass in 0.558 seconds:
`/tmp/compositor-healing-pointer-final-build.log`. The focused native journey
`--combo-smoke --healing-probe` exits 0 in
`/tmp/compositor-healing-pointer-final-native.log`, with all 12 healing markers
and all preceding Gradient/Eraser cases.

Content-Aware, Create Texture and Proximity Match each use the upstream named
`spotHealingType` control, Size/Hardness/Opacity and real pointer stamps/strokes.
The selected segment is read back after binding dispatch. Size 20 stamps and
size 16 short strokes at hardness 100 and opacity 100/50 repair or blend an
8x8 red blemish on two-pixel gray stripes. Every blemish pixel satisfies gray
repair or half-opacity blending bounds, without requiring stochastic outputs
to match another independent run. Every pixel outside the footprint (allowing
one pixel for the tip edge) stays exact, as does opaque alpha throughout.
Target/layer count stay unchanged; Undo/Redo restores exact original and actual
committed pixels/records/target. Defaults are restored afterward.

The initial native attempt failed before any healing gesture because the test
looked for `segmentedPicker`; `.accessibilityIdentifier("spotHealingType")`
renames this widget. Evidence: `/tmp/compositor-healing-pointer-native.log`.
The selector now uses the upstream identifier; the final run passes all cases.
No production code or dependency changed. The full 1,058-test checkpoint
predates this harness addition. Natural-photo quality, soft tips,
selections/masks/transforms/HDR and physical/Mac comparison remain open.

### Eraser visible controls and selection-clipped stamps: follow-up

Twenty-two tests in three suites (`BrushTests`, `BlurBrushTests`,
`LargeCanvasBrushTests`) pass in 80.022 seconds:
`/tmp/compositor-eraser-controls-build.log`. The native focused journey
`--combo-smoke --eraser-probe` exits 0 in
`/tmp/compositor-eraser-controls-native.log`, with all ten Eraser markers and
the preceding 16 Gradient setting cases.

Visible Brush > Erase, Size, Hardness, Opacity and Smoothing controls reach the
upstream settings. Eight single pointer stamps cover size 8/16, hardness 0/100,
opacity 50/100, with Smoothing 0. Two more size-24 hard stamps at both opacities
are clipped to an actual rectangular Marquee selection. Center alpha and the
whole-stamp opacity cap allow 3/255 rounding; nontransparent pixels retain red
source RGB. Soft tips have partial-alpha edges, hard interiors are uniform, and
pixels outside the tip/selection remain exact. The hard-tip oracle excludes a
one-pixel edge band. Target/layer count stay unchanged; Undo/Redo restores exact
pixels/records/target. Brush mode/settings and selection are restored afterward.

This adds acceptance tests around existing Qt controls and unchanged upstream
destination-out painting. Production code is unchanged. The full 1,058-test
checkpoint predates this addition. Continuous strokes/smoothing, mask targets,
transforms/HDR and physical/Mac comparison remain open.

### Gradient visible shapes/settings: follow-up

Thirteen `GradientTests` and `PendingGradientTests` pass in 0.037 seconds in
`/tmp/compositor-gradient-settings-final-build.log`. The focused native journey
`--combo-smoke --gradient-settings-probe` exits 0 in
`/tmp/compositor-gradient-settings-final-native.log`, with all 16 case markers.

The existing Qt segmented picker, Colors combo box, Reverse checkbox and
Opacity field exercise Linear/Radial, Foreground to Background/Transparent,
Reverse off/on and 100/50 opacity. Real pointer drags leave an editable draft
without changing layer records or history. Visible Cancel restores exact blank
pixels; Apply commits to the same target. Every pixel is compared to an
independent linear projection or radial-distance ramp in premultiplied RGBA,
with a 3/255 tolerance for raster quantization. Undo/Redo restores exact source
and committed pixels/records/target. Settings and palette defaults are restored.

The first harness attempt passed five cases before a segmentation fault:
`/tmp/compositor-gradient-settings-native.log`. It reused the Colors widget
pointer after Home changed the setting and rebuilt the control. The harness now
finds the current combo box before each key event; all 16 cases subsequently
pass. No production code or external dependency changed. The full 1,058-test
checkpoint predates this addition. Mask/selection/transformed/HDR combinations,
endpoint editing and physical/Mac comparison remain open.

### Eyedropper and temporary Alt Brush sampling: follow-up

Twenty original `UpstreamEditorTests` pass in 0.468 seconds:
`/tmp/compositor-eyedropper-pointer-build.log`. The native log
`/tmp/compositor-eyedropper-pointer-native.log` records both successful
Eyedropper checks, after all preceding Wand checks pass.

The visible Eyedropper tool and Alt Brush each sample opaque and half-alpha
composite RGB through real pointer events, then update the foreground color
during a held-pointer drag. RGB comparisons allow 2/255 for premultiplied raster
rounding. Transparent and outside-document clicks retain the sampled color.
Document pixels, layer records, active target, background color, modified state,
Undo/Redo availability and names remain exact; temporary sampling retains Brush.
This adds acceptance coverage using existing Qt and upstream sampling code;
production code is unchanged. The full 1,058-test checkpoint predates this
addition. HDR/transformed/masked composites, other temporary tools and
physical/Mac input remain open.

### Wand Add/Subtract buttons and Shift/Alt: follow-up

Thirty-three original tests in three suites pass in 0.042 seconds:
`/tmp/compositor-wand-modes-build.log`. The final focused native journey exits 0:
`/tmp/compositor-wand-late-native.log` (`--combo-smoke --wand-probe`), including
all earlier Wand controls and averaging cases.

Visible Add/Subtract and Shift/Alt select/discard separate equal-color areas.
Every filled pixel matches the expected disconnected union/difference. Source
records/target remain unchanged by selection; reversible fills prove previous
and changed coverage through Undo/Redo. Fixture renames give a distinct history
marker before each async click so an old Magic Wand entry cannot satisfy the
completion predicate early.

Two earlier attempts fail the unchanged five-second busy gate:
`/tmp/compositor-wand-modes-native.log` (mode click) and
`/tmp/compositor-wand-modes-repeat-native.log` (averaging click after modes pass).
The final attempt passes without entering timeout follow-up observation; it does
not establish the timing cause. Failure-only diagnostic observation was removed
afterward; it never ran in the successful result. No production code changed.
The full 1,058-test checkpoint predates this harness addition. Object/combined
modifier/feathering/transform/HDR and physical/Mac combinations remain open.

### Magic Wand Point/3x3/5x5 sample-size choices: follow-up

Six original tests pass in 0.025 seconds:
`/tmp/compositor-wand-sampling-build.log`. The focused native journey exits 0:
`/tmp/compositor-wand-sampling-native.log` (`--combo-smoke --wand-probe`).

The visible sample-size menu is operated with Home/Down keys. A single white
pixel on black and tolerance 15 distinguish Point (white pixel), 3 by 3 Average
(no color matches mean 28) and 5 by 5 Average (black matches mean 10). Green
fills verify every expected pixel. Each case starts with a separate old selection,
so the no-match result proves New-mode clearing and selection Undo/Redo rather
than merely observing an already empty state. Match cases pass exact source/fill
Undo/Redo. The previous eight tolerance/connectivity/all-layer cases also pass.
Controls return to Point Sample, Contiguous, This Layer, Anti-alias and Tolerance
defaults. Production Wand code is unchanged; the full 1,058-test checkpoint
predates this harness follow-up. Mode/transform/HDR and physical/Mac input remain open.

### Magic Wand visible controls: follow-up

Six original tests pass in 0.025 seconds:
`/tmp/compositor-wand-controls-build.log`. The focused native journey exits 0:
`/tmp/compositor-wand-controls-native.log` (`--combo-smoke --wand-probe`).

Eight cases use visible Wand/New, This Layer/All Layers, Point Sample,
Anti-alias off, Tolerance 0/24 and Contiguous on/off. Two separated red areas
and an adjacent color whose red channel differs by 20 distinguish connectivity/tolerance.
Actual clicks and green fills match every expected pixel; All Layers works
with a blank destination active. Selection itself changes no pixels/records.
Target identity and exact selection/fill Undo/Redo pass. Controls return to
This Layer, Anti-alias on and Tolerance 32 for subsequent journeys.

This changes acceptance tests only; production Wand code is unchanged. The
full 1,058-test checkpoint predates these cases. Average sample sizes, Add/Subtract/
Object combinations, transforms/HDR and physical/Mac input remain unverified.

### Marquee gestures and Skia curved-hole regression

Forty-seven tests in four suites pass in 1.664 seconds:
`/tmp/compositor-marquee-pointer-build.log`. The focused native journey exits 0:
`/tmp/compositor-marquee-pointer-native.log` (`--combo-smoke --marquee-probe`).

Rectangle/Ellipse and visible Anti-alias off are exercised through Qt. Ordinary,
fresh-Shift square/circle and late-Alt captured-New gestures pass bounding limits,
interior/exterior and exact full-raster Undo/Redo. The independent ellipse equation
allows a one-pixel curve boundary band, since binary scan conversion does not
match every ideal center sample. Add/Subtract passes buttons and Shift/Alt at
press. A held Shift initially adds without squaring; a fresh Shift while dragging
constrains. Alt at press subtracts; upstream never centers Marquee on Alt.

The dedicated `EllipseSelectionBooleanTests` first fails on both CGPath winding
hit-tests and coverage for a subtracted interior ellipse. Diagnostics confirm
Skia difference has an empty center before AsWinding and a filled center afterward.
Existing Skia Simplify before AsWinding canonicalizes curved contours and fixes
this without changing upstream selection code. Geometry and mask coverage now
pass; temporary native diagnostics are removed. Antialiased/feathered/other
variants and physical/Mac input remain unverified.

### Lasso Add/Subtract controls and Shift/Alt pointers: follow-up

Forty-six original tests in three suites pass in 1.573 seconds:
`/tmp/compositor-lasso-modes-build.log`. The focused native journey exits 0:
`/tmp/compositor-lasso-modes-native.log` (`--combo-smoke --lasso-probe`).

Freehand and Polygonal each use visible Add/Subtract buttons and, separately,
Shift/Alt pointer gestures with New selected. A concave base, overlapping rectangle
and interior subtraction verify union/difference at every pixel. Source records
and active-layer identity remain exact. Reversible fills prove previous and changed
coverage through Undo/Redo; the same gesture is reapplied after a fill proof consumes
Redo. All preceding lasso closure/Backspace/Escape cases also pass.

This is an acceptance-harness addition; production selection code is unchanged.
The full 1,057-test checkpoint predates it. Other tool/modifier/feathering variants
and physical/Mac input remain unverified.

### Native Freehand and Polygonal Lasso: follow-up

Twenty-seven original tests in two suites pass in 0.018 seconds:
`/tmp/compositor-lasso-pointer-build.log`. The focused native journey exits 0:
`/tmp/compositor-lasso-pointer-native.log` (`--combo-smoke --lasso-probe`).

Visible Freehand/Polygonal mode choices and a concave L-shaped outline verify
exact all-pixel fill coverage, excluding the empty corner of its bounding box.
Freehand closes on release; Polygonal closes at its first point, on double-click
or on Return. Each polygon adds and removes an extraneous corner with Backspace.
Unfinished drafts change no committed selection/pixels/history. Selection and
fill Undo/Redo are exact. Escape cancels either mode without changing the document.

This changes acceptance tests only; production lasso code is unchanged. The full
1,057-test checkpoint predates these cases. Add/subtract modifiers, feathering/
other shapes and physical/Mac input remain unverified.

### Selection amount validation and visible Expand/Contract/All/Inverse

The focused build passes 46 original tests in three suites in 1.535 seconds:
`/tmp/compositor-selection-menu-build.log`. The native journey exits 0:
`/tmp/compositor-selection-menu-native.log` (`--combo-smoke --selection-menu-probe`).

The first native run reproduced invalid Amount values leaving OK visually enabled
because the focused-field guard froze the whole panel. The Qt renderer now
refreshes button enablement, range-hint opacity and slider position from the
current wire tree while preserving the focused field. Slider synchronization uses
QSignalBlocker. Validation updates even when input returns to the cached initial
value. Tests cover 0/501 refusal, valid 1/4, field identity/focus/cursor, hint/slider,
Cancel/OK, axis coverage/unchanged exterior and selection/fill Undo/Redo.
Visible All/Inverse also passes exact rectangular complement, whole-canvas fill
and upstream removal of selection when All is inverted, with Undo/Redo.
Other shapes/edges/extreme amounts/modifiers and physical/Mac input remain open.

### Visible Create/Release Clipping Mask: native follow-up

Fourteen unchanged LiveMask/AdjustmentLayer tests pass in three suites in 0.089
seconds: `/tmp/compositor-clipping-menu-build.log`. The focused native journey
exits 0: `/tmp/compositor-clipping-menu-native.log` (`--combo-smoke --mask-menu-probe`).

Actual right-click Create/Release Clipping Mask runs against opaque and
32/64/128/255-alpha base images. The blue top layer clips to the base with exact
alpha/color at every pixel and no fringe. Source records, layer count and target
identity remain unchanged. Pixel/record/clipping-state Undo/Redo is exact;
a saved .comp manifest points the top layer to the exact base-layer UUID.
The bottom-layer action remains disabled without changing pixels/records/history.
The context helper now addresses the correct displayed row for that refusal.

This is an acceptance-harness addition; production clipping code is unchanged.
The full 1,057-test checkpoint predates these added cases. Clipped stacks,
effects/transforms/HDR and physical/Mac combinations remain unverified.

### Recursive popup menus and nested Add Mask

The focused build exits 0 with 15 tests in three suites in 0.145 seconds:
`/tmp/compositor-mask-submenu-build.log`. The native journey also exits 0:
`/tmp/compositor-mask-submenu-native.log` (`--combo-smoke --mask-menu-probe`).

The Swift popup bridge now sends a recursive item tree and leaf IDs; Qt uses
existing QMenu submenus. Dispatch reaches each original NSMenu leaf while root
tracking closes once. Hidden items and separators retain correct choice mapping;
ancestor-disabled leaves are refused. The regression verifies nested choice
identity and disabled-parent refusal. Four native layer/folder × Reveal/Hide cases
open the actual Add Mask submenu with Right/Return, verify pixels/records through
Undo/Redo and confirm Add Mask is disabled after creation. The same journey also
passes all preceding mask-menu and Ctrl-thumbnail checks.

This resolves the flat-popup gap identified in the earlier inspection below.
Physical/Mac input, dynamically populated submenu delegates and wider mask
combinations remain unverified.

### Native mask menus and Ctrl-thumbnail selection: follow-up

Fourteen unchanged LayerMask/MaskTransform tests pass in two suites in 0.159
seconds (`/tmp/compositor-mask-menu-build.log`). The focused native journey exits
0 (`/tmp/compositor-mask-menu-native.log`, `--combo-smoke --mask-menu-probe`).

Layer/folder right-click Disable/Enable/Delete and Image > Invert Mask pass exact
pixels/records Undo/Redo and source isolation. Invert complements mask alpha
within one 8-bit value. Layer Unlink/Link works; folder Unlink remains disabled
with no document/history changes, as upstream validates it. A timer waits for
the deferred Qt context popup before choosing through its native Return key.

Actual Ctrl image-thumbnail selects opaque source pixels while ignoring the
mask; blue fill on a new layer covers the whole opaque fixture. Ctrl mask-thumbnail
selects dark/hidden areas for layer/folder targets; a fill on a separate, unmasked
layer reaches the hidden stripe and leaves the exterior exact. Fill and selection
Undo/Redo and cleanup preserve original records/pixels.

This follow-up changes acceptance tests only; the full 1,056-test checkpoint
predates it. Shift-add/Alt-subtract, transforms/HDR and physical/Mac input remain
unverified. At that checkpoint, popup Item serialization and Qt showPopUpMenu were flat.
The recursive-popup implementation above subsequently resolves the Add Mask
submenu gap; footer Reveal/Alt–Hide mask creation continues to pass.

### Mask Paint picker and Alt footer: native follow-up

`/tmp/compositor-mask-paint-picker-build.log` exits 0: nine original LayerMaskTests
pass in 0.135 seconds and the Boolean Picker XCTest regression also passes.
`/tmp/compositor-mask-paint-picker-native.log` exits 0 with all four layer/folder ×
Reveal All/Alt–Hide All cases (`--combo-smoke --mask-paint-probe`).
Visible Paint picker Home/End keys drive Black/White strokes. The tests verify
center hide/reveal, unchanged exterior, correct source-over coverage at smoothed
edges (two 8-bit values of rounding), target/hierarchy, exact pixel/layer Undo/Redo
and unchanged source images when masks are disabled.

Alt–Hide All initially failed because Qt SwiftUI Button actions did not supply
NSApp.currentEvent. A QPushButton subclass captures native activation modifiers,
consumes them before dispatch and sends the shell's existing modifier bits. The
Swift bridge scopes NSEvent/currentEvent to the callback and restores previous
values afterward. Both upstream mask creation variants now work without changing
upstream mask code. Physical/Mac input and wider combinations remain unverified.

### Clone Stamp pointer controls and Boolean picker fix

`/tmp/compositor-clone-pointer-build.log` exits 0: one XCTest regression checks
Boolean picker tags in both directions and invalid-value refusal, and two original
Clone Stamp tests pass in 0.004 seconds. The focused native journey exits 0:
`/tmp/compositor-clone-pointer-native.log` (`--combo-smoke --clone-probe`).

The native test first reproduced All Layers silently leaving the setting false.
The shared SwiftUI Picker handled enum/String/Int values but lacked Bool conversion;
it now uses Swift's existing Bool string parser. Unchanged upstream clone code
handles actual Alt source selection, visible Aligned on/off and This Layer/All Layers
controls, aligned source offset, unaligned restart and composite sampling into a
blank destination. Each stamp checks unchanged exterior, target identity/count,
source-layer isolation and exact pixels/layer geometry through Undo/Redo.
Transforms/selections/HDR, physical input and Mac appearance remain unverified.

### Visible Shape controls and pointer drawing: native follow-up

Four unchanged `ShapeToolTests` pass in 0.004 seconds:
`/tmp/compositor-shape-build.log`. The focused native journey exits 0:
`/tmp/compositor-shape-native.log` (`--combo-smoke --shape-probe`).
Existing Qt controls and unchanged upstream shape/raster code implement Rectangle,
Rectangle with Radius=6, Ellipse and Line with Width=4. Pointer drags verify
foreground color, distinct corner/interior geometry, unchanged outside pixels,
separate layer creation and exact pixels/layer identity through Undo/Redo.
The corner assertion avoids an antialiased boundary pixel. This changes acceptance
tests only; the full 1,054-test checkpoint predates it. Modifier/selection/mask/HDR
combinations, physical input and Mac appearance remain unverified.

### Visible Flip Layer/Canvas and Invert: native follow-up

Forty-one tests in four suites pass in 1.544 seconds:
`/tmp/compositor-visible-flip-invert-build.log` (exit 0).
The complete native combination journey exits 0:
`/tmp/compositor-visible-flip-invert-native.log`.
This changes acceptance tests only; the full 1,054-test checkpoint predates it.

An asymmetric, partly translucent 32x24 image sits at the origin of a 64x64
canvas. Visible Layer flips mirror it about its own center; visible Image canvas
flips mirror it about the canvas center. Horizontal and vertical variants pass
exact image and layer-geometry Undo/Redo, retained identity/count and unchanged
canvas dimensions. Visible Image > Invert complements the whole layer or a
pointer-selected rectangle. Alpha is exact; pixels outside the selection and
transparent pixels remain exact. RGB complements allow up to two 8-bit values
for premultiplication rounding; Undo/Redo images are exact. Layer identity,
geometry and selection remain unchanged. Masks/groups/guides/HDR/native-key
combinations and physical/Mac input remain unverified.

### Pixel-grid display: native follow-up

Four original tests pass in 0.037 seconds:
`/tmp/compositor-pixel-grid-build.log` (exit 0).
The entire native combination journey exits 0:
`/tmp/compositor-pixel-grid-native.log`.
This changes acceptance tests only; production rendering code is unchanged.
The current 1,054-test full runner predates this additional native case.

The visible View toggle and upstream Zoom text field exercise 799%, 800% and
1600%. The grid has no visual effect below 800%. At/above threshold, changes
inside an opaque red fixture occur only near document-pixel boundaries; cell
centers and pixels outside the document remain exact. More than 100 changed
pixels prove visible lines, rather than merely a settings flag. Turning it Off
restores the entire exact canvas frame. Every stored document pixel, layer
record and history name remains unchanged. The fixture restores the original
grid setting and Actual pixels before the remaining journeys. Physical/high-DPI/
Mac appearance remains unverified.

## Earlier full-run checkpoint: 2026-10-14, upstream 1.5.2 `43d691b`

The unfiltered release runner exits 0 with **1,053/1,053 framework tests**:
140 XCTest in 3.711 seconds and 913 Swift Testing in 145 suites in 95.631 seconds.
All native editing/preview/save/transform/tab/RAW-lens/text journeys, thumbnailer
and 11 source-coverage checks pass with required Vulkan hardware:
`/tmp/compositor-folder-merge-full-contract.log`.
Required-shader/protected-source integrity exits 0:
`/tmp/compositor-folder-merge-integrity.log`. Source coverage accounts for 155
upstream Swift files (128 unchanged, 20 generated, 5 replaced, 2 platform),
175 target Swift files and the existing 84 unchanged/2 mirrored test files.

The [four-commit catch-up](upstream-pending-2026-10-14.md) keeps upstream's
adaptive Shadows Swift/C implementation and installs its new binary resource
for runtime, launcher, tests and Flatpak. The original picture-adaptation and
tone-order tests pass. Qt hosts the generated Camera Raw… button; staged
replacement preserves the requested RAW layer across mixed batches and opens
its filter after installation. Creating the first floating panel now works
when the panel map was empty. Modal window rejection completes the actual
staged import continuation. Native single/mixed ordinary Import and Camera Raw
checks verify target layer, visible panel, Cancel and exact import Undo/Redo.
The test fixture restores welcome after Redo before continuing folder checks.

The first full run failed only the stale RAW-sheet button-count assertion
(`/tmp/compositor-152-full-contract.log`, exit 1). The corrected test explicitly
requires Camera Raw… and all four buttons; the complete rerun above passes.
Version metadata is 1.5.2/build 48. Existing local appcast is preserved;
Linux's separate Flatpak updater is not a Mac feed deployment. No Mac is
available; physical/Mac acceptance and the full historical crosswalk remain open.

### Shortcut persistence: fresh application processes

Twelve tests in two suites pass in 2.327 seconds:
`/tmp/compositor-shortcut-restart-build.log` (exit 0).
The complete Qt combination journey exits 0:
`/tmp/compositor-shortcut-restart-native.log`.
This changes the acceptance harness only; production code is unchanged.

The visible shortcut editor saves K for Brush, removes the binding, then restores
default B. At each stage QProcess launches the actual application executable
with `--combo-smoke --shortcut-binding-probe k|none|b` and the same test profile.
The child enters a short probe instead of recursively running the full journey:
it imports a fresh fixture, checks the loaded table and tests actual K/B canvas
key routing. Each child requires exact unchanged fixture pixels and exits 0.
The parent checks exit status and the child's proof marker. All three probes
pass; the main journey restores original bindings and document invariants.
This establishes real process-to-process persistence, including cleared values.
Physical/Mac keyboard input remains unverified.

### Shortcut conflicts, removal and Restore Defaults: native follow-up

Twelve tests in two suites pass in 2.037 seconds:
`/tmp/compositor-shortcut-conflict-clear-build.log` (exit 0).
The complete Qt combination journey exits 0:
`/tmp/compositor-shortcut-conflict-clear-native.log`.
This changes the acceptance harness only; production code remains unchanged.

Recording M for Brush displays the upstream conflict message and disables Save.
Cancel retains every original binding. The visible Remove this shortcut control
clears Brush; native M still selects Marquee and B no longer selects Brush.
Restore Defaults affects only the draft: Cancel retains the saved cleared binding,
and Save restores all original bindings and native B routing. All document
pixels, layer records and history names remain exact. The fixture checks every
binding against its original before testing Restore Defaults, so it cannot replace
custom bindings accidentally. Fresh-process persistence is now verified above; physical/Mac input
remains unverified.

### Keyboard Shortcuts window: live search and closed-state cleanup

Twelve tests in two suites pass in 1.941 seconds:
`/tmp/compositor-shortcut-lifecycle-final-build.log` (exit 0).
The complete Qt combination and preview journeys pass:
`/tmp/compositor-shortcut-lifecycle-final-native.log` and
`/tmp/compositor-shortcut-lifecycle-final-preview.log` (exit 0).
The strengthened cursor follow-up passes the C ABI regression in 1.574 seconds
and the entire combination journey:
`/tmp/compositor-shortcut-cursor-build.log` and
`/tmp/compositor-shortcut-cursor-native.log` (exit 0).
The older unfiltered baseline predates this fix; the current full run above includes the fix and new test.

The visible Edit menu opens the upstream sheet. Search filters while focused;
Backspace/U edit the middle of its text without losing focus or cursor position.
Native window pointer events click the upstream recorder. The draft has no effect
before Save; Cancel/reopen discards it. Save installs K for Brush, K selects Brush
and the old B no longer does. Restoring B restores every original binding and
native B routing. Every document pixel, layer record and history name remains exact.

Qt formerly skipped resolving an entire panel while a text field was focused.
Search now refreshes its results and restores the new field's focus/cursor/selection;
other editable fields retain their existing behavior. Closed models now pass through
the existing SwiftUI discard path on their content's owning session. Nil-panel
resolution also clears actions, preventing canceled drafts and stale handlers from
surviving reopening. The C ABI lifecycle test fails before that handler cleanup in
`/tmp/compositor-shortcut-closed-handlers-before.log` (exit 1).

The earlier recorder failures remain in `/tmp/compositor-shortcut-listener-native.log`.
Temporary diagnostic probes proved direct/bridge/C ABI state persistence and were
reduced to one permanent lifecycle regression. The speculative dirty-panel change
was reverted. The conflict/clear/Restore Defaults UI follow-up above now passes; fresh-process persistence now passes in the follow-up above.
Physical/Mac input remains unverified.

### Autosave preserves pending gradient: production fix

Eleven tests in two suites pass in 0.173 seconds:
`/tmp/compositor-gradient-autosave-final-build.log` (exit 0).
Three complete Qt combination runs and the separate async save journey exit 0:
`/tmp/compositor-gradient-autosave-final-native-{1,2,3}.log` and
`/tmp/compositor-gradient-autosave-final-save.log` (3,661 UI ticks).
The older 1,053-test runner predates this fix; the current full run above now includes it.

The 60-second autosave timer called startProjectSave with autosave=true, but that
function always called prepareDocumentForProjectIO. Its transformCommitFinal
command also applied a pending gradient. This explains both earlier failures:
a line could disappear during dragging, or its raster commit could later change
layer geometry/history while unrelated invalid commands were being refused.
The temporary command trace records transformCommitFinal in
`/tmp/compositor-gradient-command-native.log`. Debugger/stage traces also show a
line created on press and already committed as Gradient during movement.

The deterministic regression forces performAutosave with a live gradient and
fails before the fix: `/tmp/compositor-gradient-autosave-before-native.log`
(exit 1, autosave changed a pending gradient or its history).
Explicit saves still prepare the document; autosave now captures current layer
state without applying/canceling live drafts. The regression verifies unchanged
line, pixels, layer identity/geometry and history, then reads every pixel of the
64x64 source PNG stored in recovery. It remains exactly the original fixture.
All three runs include this case and the subsequent invalid-command invariants,
six adjustment editors and remaining native tool combinations. The async save
journey verifies frozen-worker saves, failure, tab switching, autosave/recovery
and pending close.

During investigation, the pixel observer was changed to the direct render ABI.
That alone did not fix the failure: the third observer-only repeat still failed
(`/tmp/compositor-gradient-observer-native-3.log`). The helper retains this direct
read to avoid encoding files; separate actual PNG/JPEG export checks remain.
Temporary production command logging was removed. The first recovery-image check
compared complete QImage objects and failed despite independently verified exact
RGBA bytes; it now compares dimensions and every pixel color. Other draft kinds,
actual process-crash recovery and physical/Mac acceptance remain unverified.

### All six historical adjustment editors: native follow-up

Eighteen tests in three suites pass in 0.077 seconds:
`/tmp/compositor-six-adjustment-diagnostic-build.log` (exit 0).
The whole Qt combination journey exits 0:
`/tmp/compositor-six-adjustment-diagnostic-native.log`.
This extends the acceptance harness only; the 1,053-test full runner predates it.

The shared journey now covers Levels, Hue/Saturation, Curves, Exposure,
Gradient Map and Grain. Visible menus create each adjustment. Double-clicking
its thumbnail and Edit Adjustment reopen the existing layer. Curves drags the
white endpoint; Gradient Map toggles Reverse; other editors change numeric
fields. Every case changes the composite, retains exact transparent outside
pixels, restores baseline pixels/records/history on Cancel, and retains exact
accepted pixels, source records and adjustment identity through OK/Undo/Redo.
Gradient Map and Grain may have nonidentity defaults, so their initial composite
is recorded rather than assumed equal to the original photograph.

The first expanded run failed at an incorrect Exposure expectation:
`/tmp/compositor-six-adjustment-native.log` (exit 1). Exposure -1 halves linear
light, whose sRGB encoding is approximately 188 rather than 128. The expectation
was corrected using upstream's documented linear-light rule. Production code
is unchanged.

The next run passed all six cases but failed the later pending-gradient
invalid-command invariant: `/tmp/compositor-six-adjustment-final-native.log`
(exit 1). It did not report which state field changed. The harness now reports
the field, request and before/after values. The diagnostic rerun passes without
reproducing that failure. A same-binary repeat fails earlier in the gradient
journey: `pending gradient missing before tool switch` in
`/tmp/compositor-six-adjustment-repeat-native.log` (exit 1). All six adjustment
cases pass in this repeat too. The autosave investigation and production fix above now resolve these
gradient failures within the repeated native scope. Additional modern editor
kinds, wider parameters and physical/Mac acceptance remain unverified.

### Existing Levels/Hue adjustment re-edit: native follow-up

Nine tests in two suites pass in 0.071 seconds:
`/tmp/compositor-adjustment-reedit-visible-build.log` (exit 0).
The complete Qt combination journey exits 0:
`/tmp/compositor-adjustment-reedit-visible-native.log`.
This changes the acceptance harness only; production adjustment code is unchanged.
The 1,053-test full runner above predates these additional checks.

For both Levels and Hue/Saturation, visible New Adjustment Layer menus create
an identity adjustment. Double-clicking the actual Layers thumbnail reopens its
upstream editor. Visible Output white=128 or Hue=120 changes the composite.
Cancel restores exact pixels, layer records and history. The visible Edit
Adjustment menu reopens it again; OK retains the preview and adjustment identity.
Undo/Redo restores exact original/edited pixels and hierarchy. The source layer
record remains unchanged. Other editor kinds and physical/Mac input/appearance
remain unverified.

The first run passed both new scenarios but failed the following initial
New Canvas → Undo-to-welcome check because the fixture was no longer empty:
`/tmp/compositor-adjustment-reedit-native.log` (exit 1). Moving the new cases
after initial-document acceptance resolves the harness ordering error; the
complete rerun above passes all subsequent scenarios and explicitly requires
the chosen Layer menu or adjustment submenu to remain visible before dispatch.

### Feather selection to layer/folder mask: native follow-up

Ten tests in two suites pass in 0.151 seconds:
`/tmp/compositor-feather-mask-build.log` (exit 0).
The entire Qt combination journey exits 0 with both new Feather mask cases:
`/tmp/compositor-feather-mask-native.log`.
This changes the acceptance harness only. The current 1,053-test full runner
above predates this additional check; production selection/mask code is unchanged.

Upstream exposes Feather as a selection operation. Creating a mask from that
selection copies its soft coverage through the existing SelectionClip path;
this check follows that actual workflow instead of assuming a separate mask
Feather control. Qt pointer events create a rectangle; visible Select > Feather
opens SelectionAmountSheet. Amount=6, Cancel and OK retain source/history or
record Feather Selection. Undo/Redo restores the selection step. The visible
Add layer mask footer consumes the selection into a mask with at least eight
partial-alpha pixels across its boundary, a visible center and hidden exterior.
Disabling it restores every source-image pixel exactly. Mask creation Undo
restores the feathered selection; Redo restores exact mask pixels and target ID.
Both image-layer and folder variants pass. Other selections/transforms/HDR
combinations and physical/Mac appearance remain unverified.

### Layer/folder mask paint, fill and local Blur: native follow-up

Fourteen tests in two suites pass in 0.164 seconds:
`/tmp/compositor-mask-edit-final-build.log` (exit 0).
The complete Qt combination journey also exits 0, including both new mask cases:
`/tmp/compositor-mask-edit-final-native.log`.
This follow-up changes the acceptance harness only; the current 1,053-test full
runner above predates it. Production mask/raster/Blur code remains unchanged.

The visible Add layer mask footer creates/selects a reveal mask. Qt Brush
pointer events paint a black stripe; a black foreground fill hides the entire
source. The Smear rail's Blur mode softens the stripe into partial alpha without
changing distant pixels. Each operation retains the target/hierarchy and passes
exact pixel Undo/Redo for both an image layer and a folder. Disabling the edited
mask restores every source-image pixel exactly, confirming image isolation.
The test restores brush settings before the remaining native journeys.

The first attempt used the nonexistent rail label Blur and stopped after the
paint/fill checks (`/tmp/compositor-mask-edit-native.log`, exit 1). Upstream names
the rail family Smear; the corrected scenario selects it with Blur mode and
passes. The Feather-selection → mask workflow is now verified above. Other
selection/transform/HDR combinations remain to be mapped; physical/Mac appearance is unverified.

### Nested folder duplication: native follow-up

Eleven tests in three suites pass in 0.055 seconds, including the unchanged
selector-mirror `testContextMenuDuplicateFolderPreservesHierarchy`:
`/tmp/compositor-folder-duplicate-build.log` (exit 0).
The entire Qt combination journey exits 0 with a new folder duplicate marker:
`/tmp/compositor-folder-duplicate-native.log`.
This follow-up changes only the acceptance harness. The current 1,053-test full
runner above predates this extra check; production duplication code is unchanged.

The visible New folder control builds two nested folders containing two different
image layers. The outer folder has opacity 0.5. With no canvas selection, the
visible Layer > Duplicate Layer action uses upstream's layerViaCopy branch to
duplicate the whole subtree. All copied IDs are new and unique; every parent
reference is remapped. Descendant names, appearance, geometry and original records
remain exact. Hiding the original outer folder leaves precisely the original
composite rendered by the copy, proving source visibility isolation. One Undo
removes the entire duplicate; Redo restores the same copied IDs, hierarchy,
pixels and selected root. Mask/clipping/effect/HDR variants and physical/Mac
appearance remain unverified.

### Folder opacity, all merge variants and current-raster helper export

The full runner above includes these new native checks alongside all previous
Content-Aware Fill, Levels/Hue, filter, Crop and Object cases. Focused verification
exits 0 with 21 tests in five suites in 0.162 seconds:
`/tmp/compositor-folder-merge-acceptance-build.log`.
The complete combination journey also exits 0:
`/tmp/compositor-folder-merge-acceptance-native.log`.

The visible Opacity percent field changes a folder to 50%. Its child keeps
opacity 1 and its parent ID. Rendered red pixels keep their color with half
alpha; Undo/Redo restores exact pixels and hierarchy. The visible dynamic Layer
menu invokes Merge Down, Merge Layers and Merge Group. Nonadjacent selected
layers merge while an unrelated layer remains identical. Folder opacity is
baked into the merged result. Every composite pixel remains exact; layer counts,
unselected isolation and hierarchy/ID Undo/Redo are checked. Upstream layer
appearance and merge algorithms remain unchanged. Nested/masked/effect/HDR cases
and physical/Mac appearance still need separate mapping.

The first merge check exposed an export-helper bug rather than a merge failure.
`SessionWindow.fullResolutionImage` returned `m_image` whenever display scale was
at least 1, although asynchronous painting had not caught up to a newly imported
blue layer. `/tmp/compositor-folder-export-before.log` exits 1: the exported
pixel was transparent while the current session raster was opaque blue. Earlier
merge-comparison evidence is retained in `/tmp/compositor-folder-merge-native.log`
and `/tmp/compositor-folder-merge-probe.log`.

The helper now reads current session dimensions and renders its current raster,
sets DPI from session resolution and returns failure without a stale-frame
fallback. PNG/JPEG no longer require a populated display image. Native PNG is
compared to the render ABI immediately after import; both formats are checked
at 80x72 and 300 DPI following document edits. These convenience helpers remain
RGBA8; canonical deep/HDR export uses the upstream exporter path.

### Content-Aware Fill on expanded canvas: native follow-up

Four original SmartEditTests pass in 0.012 seconds:
`/tmp/compositor-content-extend-acceptance-build.log` (exit 0).
The entire Qt combination journey also exits 0, including four new edge cases:
`/tmp/compositor-content-extend-acceptance-native.log`.
The original content-aware follow-up changed the acceptance harness only;
the current full runner above now includes it. Production content-aware code
remains unchanged upstream ContentFill/FilterEdit and PatchPixels.c.

A textured opaque 64x64 image is centered in an enlarged 80x80 canvas. Qt pointer
events select each added 8-pixel edge strip, including its corners. Crop's
selection-bound reporting verifies the requested geometry. Content-Aware Fill's
completed automatic preview supplies opaque, varying, nonblack color in the
selected area. Every other pixel remains exact. Visible Cancel restores exact
pixels, layer bounds and history. Visible OK commits the prepared image into
the existing layer, with unchanged layer count/identity and exact bounds equal
to the union of the original layer and selected strip. Undo/Redo preserves
exact original/filled pixels, layer geometry and selection.

The first tests incorrectly required synthesized RGB values to stay within the
source palette (`/tmp/compositor-content-extend-native.log` and
`/tmp/compositor-content-extend-probe.log`, exit 1). The measured selection was
correct and the pixel opaque. Upstream PatchPixels.c `adapt_color` intentionally
spreads boundary tone offsets over the fill, allowing colors beyond that range.
The corrected check requires full opacity, texture variation and a nonblack
average color signal, while keeping all exact outside/Cancel/history checks.
All four sides pass. Natural-photo/Apple appearance and masked/transformed/HDR
extension cases remain unverified; no fill algorithm or dependency was replaced.

### RGB Levels/Master Hue selection previews and native work readiness

The current full runner above includes the new Levels/Hue native cases and the
corrected bridge work state. Focused verification passes 28 tests in three suites
in 0.122 seconds (`/tmp/compositor-levels-hue-fixed-build.log`). Three consecutive
complete Qt combination journeys also exit 0:
`/tmp/compositor-levels-hue-fixed-1.log`,
`/tmp/compositor-levels-hue-fixed-2.log` and
`/tmp/compositor-levels-hue-fixed-3.log`.

The actual Output white field sets RGB Levels to 128; the Hue field sets Master
Hue/Saturation to 120. A selected red pixel becomes half red or green, confirming
the intended settings have finished rendering. Every outside pixel remains exact.
Visible Preview toggles restore the original/prepared images. Visible Cancel
retains pixels, layers and history; visible OK matches the prepared preview.
Undo/Redo restores exact original/committed pixels, selection and layer identity.
These scopes use unchanged upstream controls, preview jobs and pixel kernels.
Other channels/ranges and HDR/transformed/masked combinations still need mapping;
physical/Mac appearance remains unverified.

The additional panels exposed an existing timing bug in the native work state.
A moved-pixel preview was already visible while its raster commit remained in
flight. The bridge reported `busy=false`; the test moved on and clicked Gradient,
which upstream correctly refused. Diagnostic output confirms a real clicked
signal and an available callback, with `busy=false` and `canSwitch=false` before
the click (`/tmp/compositor-levels-hue-probe-2.log`, exit 1). Earlier intermittent
failures are retained in `/tmp/compositor-levels-hue-native.log` and
`/tmp/compositor-levels-hue-repeat-1.log`.

A deterministic held-raster-worker assertion in PendingGradientTests reproduces
the incorrect native state in both target-change cases:
`/tmp/compositor-native-busy-before.log` exits 1 with two busy-state issues.
Bridge `busy` now includes `isProjectBusy` and an active pixel move, covering the
gap before finalization starts as well as the background write. Both held-worker
cases, three native repetitions and the full runner pass after this change.
The test retains clicked-signal and readiness diagnostics. No upstream adjustment
or pixel-move algorithm was changed.

### Selection-clipped live filter previews and worker state

The full runner above includes the new Gaussian Blur and Black & White native
preview checks, previous Crop/Object acceptance and all other native journeys.
Focused checks also exit 0: 34 tests in three suites in 0.496 seconds
(`/tmp/compositor-selection-filter-acceptance-build.log`) and the complete
combination journey (`/tmp/compositor-selection-filter-acceptance-native.log`).

Qt pointer events create a rectangle selection. The existing render ABI reads
actual displayed preview pixels. Every pixel outside that rectangle remains
exact. Preview Off restores the original image; On restores the completed
preview. The visible Cancel button preserves source pixels, layers and history.
The visible OK button commits exactly the prepared image; Undo/Redo restores
exact original/committed pixels, selection and active-layer identity. These two
cases exercise spatial blur and color conversion through upstream's common
SelectionClip/PixelAdjust blend. RGB Levels/Master Hue paths are now verified above. Other
preview combinations and filter-family acceptance remain to be mapped; physical/Mac appearance
is unverified.

Bridge state now adds `filterPreviewRendering`, true while a filter worker or
queued settings exist. `busy` still means the edit prevents other operations;
an open filter can have a completed preview. The native test waits for worker
completion before capturing the comparison frame. Upstream intentionally keeps
the previous frame while a newer render finishes; the first test captured that
intermediate frame (`/tmp/compositor-selection-filter-native.log`, exit 1).
After waiting on worker state, a later attempt reached exact OK pixels but
needed document-window activation before offscreen Undo
(`/tmp/compositor-selection-filter-final-native.log`, exit 1). The corrected
scenario activates its owner as the existing Qt tests do, and the focused/full
runs above pass. No upstream filter or clipping algorithm was changed.

### Native Object mode follow-up at the same 1.5.2 production source

`/tmp/compositor-object-build.log` exits 0 with both required model acceptance
tests (1.562 seconds). `/tmp/compositor-object-native.log` exits 0 with the full
Qt combination journey, including the previous Crop check and the new Object
check. Diagnostic output confirms the shipped `u2netp.onnx` loads and actual
128x96 inference reports one subject for each foreground/background click.
The native scenario requires model installation success; a classical fallback
cannot satisfy this acceptance check.

A synthetic ellipse matches the existing learned-model fixture. The visible
Magic rail/Object control and Qt pointer events invoke unchanged upstream
ObjectSelection. The foreground click creates upstream Object Selection history
without altering source layers. Selection Undo/Redo works. Filling the selection
changes its center to blue while leaving a background pixel exact; fill Undo
restores every source pixel. A background click clears the selection, and
Undo/Redo restores/clears it again without changing source layers.

The original Object follow-up changed the acceptance harness only. The current
full runner above includes both native Object and Crop checks alongside the later
bridge-state addition. Linux uses learned confidence and connected-component instance
labels; this synthetic case does not establish natural-photo instance quality,
Apple Vision model equivalence or physical/Mac pointer acceptance.

### Native crop follow-up at the same 1.5.2 production source

`/tmp/compositor-crop-final-build.log` exits 0 with all seven original CropTests;
`/tmp/compositor-crop-final.log` exits 0 with the complete Qt combination journey
and its new Crop gesture marker. This Crop follow-up changed only the native acceptance harness. The current
full runner above also includes it; production crop code remains unchanged upstream.

The test uses the visible Crop rail and Qt pointer/key events. Ordinary and
Alt creation and Alt resize require exact document-coordinate geometry.
Snapping reaches canvas edges; Linux Meta maps to upstream Control and disables
it for the held gesture. Drafts retain layers/history; Escape retains exact
pixels. Apply retains layer identity, Undo restores exact 64x64 pixels and
Redo restores the cropped dimensions. The first native attempt did not snap
because Fit enlarged the 64-pixel fixture beyond the intended 8-screen-point
snap distance (`/tmp/compositor-crop-probe.log`, exit 1). Selecting Actual pixels
sets 100% and the corrected same-coordinate gesture passes. No crop algorithm
or snap threshold was changed. Physical/Mac acceptance remains open.

## Earlier checkpoint: `e8c9e29`

### Native held-Shift brush axes and freehand recovery

The full log records **1,052/1,052 framework tests** (140 XCTest in 3.571 seconds;
912 Swift Testing in 145 suites in 93.598 seconds), required Vulkan hardware,
the strengthened Shift test and all native acceptance markers in
`/tmp/compositor-shift-brush-full-contract.log`. Its process handle was no longer
available at the final poll; the final text-backend phase was separately
rechecked with exit 0 in `/tmp/compositor-shift-brush-text-final.log`.
Required-shader/protected-source integrity passes in
`/tmp/compositor-shift-brush-integrity.log` (exit 0), against cached `e8c9e29`.

The historical Partial claim for straight brush movement is now checked through
the visible Brush rail and actual Qt pointer/modifier delivery. Both horizontal
and vertical fixtures read the live stroke through the existing render ABI,
verify changed pixels only within the chosen axis band and no paint at the
off-axis pointer, then release Shift and continue freehand. Committed endpoints
have visible blue paint; layer ownership stays intact. One Undo restores every
source pixel and Redo restores every committed pixel. The fixture restores the
previous brush settings and foreground color afterwards.

The original CanvasView supplies axis selection and freehand recovery; no
production brush algorithm or dependency changes. The focused release run
passes 22 tests in three BrushTests-matching suites (78.571 seconds), and the
complete native combination journey passes in
`/tmp/compositor-shift-brush-native.log` (exit 0). The final acceptance also
drives the pointer across the other dominant direction while Shift remains held
and requires nonzero alpha at painted checkpoints.

Changed files: `host/DialogJourney.cpp`, this baseline, the current inventory,
the completion audit and `TODOS.md`. Physical keyboard/tablet/desktop/Mac input
remains unverified.

### Learned subject commands preserve source images and Undo/Redo

The full runner passes **1,052/1,052 tests** (140 XCTest in 3.671 seconds;
912 Swift Testing in 145 suites in 94.786 seconds), all native journeys,
thumbnailer acceptance and 11 source-coverage checks in
`/tmp/compositor-subject-commands-full-contract.log` (exit 0), with required
Vulkan hardware on AMD Renoir. Both required model methods execute (1.439 seconds
for their suite). Required-shader and protected-source integrity pass in
`/tmp/compositor-subject-commands-integrity.log` (exit 0).

The required real-model suite now also executes the router used by the Qt
session bridge. `selectSubject` finds the generated object's center and excludes
the background corner; Undo removes the selection and Redo restores its bounds.
After removing the selection, `removeBackground` creates a correctly sized,
enabled, linked mask with no separate placement. The source CGImage and active
layer ID remain identical. Every command completes without project busy state;
filter commit leaves no draft or selection. Undo removes the mask and Redo
restores the same mask while retaining the source image.

Both model acceptance methods pass in `/tmp/compositor-subject-commands-check.log`
(exit 0, 1.489 seconds). The original per-pixel confidence-mask test remains in
the same suite; the generated fixture is shared. This adds acceptance evidence
only, using the existing OpenCV model, bridge router and upstream history/filter
code. Physical UI/natural-photo/Mac quality acceptance remains unverified.

Changed files: `Tests/LinuxOverrideTests/SubjectModelAcceptanceTests.swift`,
this baseline, the current inventory and `TODOS.md`.

### Required shipped-model segmentation and upstream background mask

The full runner passes **1,051/1,051 tests** (140 XCTest in 4.339 seconds;
911 Swift Testing in 145 suites in 93.555 seconds), all native journeys,
thumbnailer acceptance and 11 source-coverage checks in
`/tmp/compositor-subject-model-full-contract.log` (exit 0), with required Vulkan
hardware on AMD Renoir. The model acceptance suite executes and passes in this
run (0.781 seconds); it is not skipped or replaced by the classical backend.
Required-shader and protected-source integrity pass in
`/tmp/compositor-subject-model-integrity.log` (exit 0).

The model file, OpenCV DNN build and Flatpak installation already existed. The
existing Vision soft-mask tests use injected backends, so they alone do not
prove that the shipped model executes. The contract runner now sets
`COMPOSITOR_REQUIRE_SUBJECT_MODEL=1`; the additional acceptance test requires
`U2NetSegmenter.install()` and checks the selected backend's concrete type.
Portable builds outside that required contract keep their existing fallback and
do not run this model-dependent test.

A generated 128x96 high-contrast object exercises actual ONNX inference. The
test verifies output dimensions/counts, foreground/background labels, finite
confidence within 0...1 and a soft fringe. It then runs unchanged upstream
`SubjectRemoval.subjectMask` in Basic mode and compares every output pixel with
the learned confidence, allowing two gray levels for 8-bit rendering. It
restores the previous Vision backend after the check. The focused test passes
in `/tmp/compositor-subject-model-check.log` (exit 0, 0.786 seconds).

No model, production algorithm, dependency or project-format change is needed.
U²-Net supplies saliency and Linux derives instance labels from connected
components; this does not prove Apple Vision object equivalence or natural-photo
quality. Actual photo/UI/Mac acceptance remains unverified. Changed files:
`Tests/LinuxOverrideTests/SubjectModelAcceptanceTests.swift`,
`scripts/linux-contract-tests.sh`, this baseline, the current inventory and
`TODOS.md`.

### Qt menu tracking restores current modifiers after release

The full runner passes **1,050/1,050 tests** (140 XCTest in 4.449 seconds;
910 Swift Testing in 144 suites in 92.702 seconds), all native journeys,
thumbnailer acceptance and 11 source-coverage checks in
`/tmp/compositor-menu-tracking-full-contract.log` (exit 0), with required Vulkan
hardware on AMD Renoir. All Qt journeys in `DialogJourney.cpp` use the shared
setup that installs the production menu bridge. Required-shader and
protected-source integrity pass in `/tmp/compositor-menu-tracking-integrity-final.log`
(exit 0).

The native regression opens the real View menu and a submenu, then delivers an
unmodified navigation key to the submenu to model release/input without editor
key-up. Closing the submenu leaves its parent tracking and options temporarily
flipped; closing the parent previously left those options stale. It fails in
`/tmp/compositor-menu-tracking-before.log` (exit 1).

An application-owned Qt event filter now batches menu-hide events and defers
processing until no QMenu remains active. It shares the application-activity
platform modifier poll and visible-header refresh, then posts upstream's
`NSMenu.didEndTrackingNotification` for Qt menus. Hosted `NSMenu.popUp` already
posts its own completion notification; its Qt menu carries an ownership marker
so that notification is not duplicated. The deferred callback captures the
application-owned filter rather than a closing menu or project window.

The four original transform-press tests pass in
`/tmp/compositor-menu-tracking-build-fixed.log` (exit 0). The complete native
transform journey passes in `/tmp/compositor-menu-tracking-fixed.log` (exit 0),
verifying real root/submenu popups, nested-close deferral, release recovery,
visible option restoration and unchanged document/history/Auto Select state.
The shared setup for native Qt journeys now installs the production menu filter
as well, allowing the complete runner to exercise it beyond this focused test.
Offscreen input is simulated; actual desktop/Mac menu tracking remains
unverified. No dependency or project-format change is needed.

Changed files: `Sources/LinuxBridge/AppMenus.swift`, `host/host_run.cpp`,
`host/include/compositor_host_run.h`, `host/SessionWindow.cpp`,
`host/DialogJourney.cpp`, this baseline, the current inventory and `TODOS.md`.

### Application activity resets and refreshes held modifiers

The full runner passes **1,050/1,050 tests** (140 XCTest in 3.700 seconds;
910 Swift Testing in 144 suites in 93.139 seconds), all native journeys,
thumbnailer acceptance and 11 source-coverage checks in
`/tmp/compositor-app-activation-full-contract.log` (exit 0), with required Vulkan
hardware on AMD Renoir. Required-shader and protected-source integrity pass in
`/tmp/compositor-app-activation-integrity.log` (exit 0).

Qt's host previously forwarded only become-active, leaving upstream
`HeldModifiers` without its resign-active notification. The native regression
fails after application deactivation with held Shift/Control in
`/tmp/compositor-app-activation-before.log` (exit 1).

The shared, once-per-application Qt connection now resets modifiers and posts
the original resign-active notification for background states. On becoming
active it uses `QGuiApplication::queryKeyboardModifiers` before posting the
existing notification, preserving the recent-project refresh path. Visible
project windows refresh their option headers. Upstream remains responsible for
temporary option bindings and its application-notification observers.

Native checks invoke the production application's state signal, verify inactive
reset, compare returned options with Qt's polled state while keys remain held,
then simulate release/input in a separate widget and verify return without a
SessionWindow key-up. Document/history and stored Auto Select stay unchanged.
Offscreen Qt caches modifiers on key-down, so the separate-widget fixture also
sends ordinary unmodified input after key-up; an independent Qt probe confirmed
this behavior. The initial return fixture incorrectly assumed keys were already
released, then the key-up-only fixture failed to update Qt's offscreen cache.
These fixture corrections do not change the production behavior.

The release build and four original `TransformPressTests` pass in
`/tmp/compositor-app-activation-build-acceptance.log` (exit 0); the complete
native transform journey passes in `/tmp/compositor-app-activation-acceptance.log`
(exit 0). Physical desktop/window-manager/keyboard and Mac acceptance remain
unverified. No dependency or project-format change is needed.

Changed files: `Sources/LinuxBridge/AppMenus.swift`, `host/host_run.cpp`,
`host/include/compositor_host_run.h`, `host/DialogJourney.cpp`, this baseline,
the current inventory and `TODOS.md`.

### Released transform modifiers restore the visible options

The full runner passes **1,050/1,050 tests** (140 XCTest in 5.356 seconds;
910 Swift Testing in 144 suites in 92.800 seconds), all native journeys,
thumbnailer acceptance and 11 source-coverage checks in
`/tmp/compositor-held-modifiers-full-contract.log` (exit 0), with required Vulkan
hardware on AMD Renoir. Required-shader and protected-source integrity pass in
`/tmp/compositor-held-modifiers-integrity.log` (exit 0).

Qt release previously removed Control from the forwarded mask but retained
Shift/Alt/Meta if `QKeyEvent.modifiers()` still reported them. Native delivery
reproduces a stuck visible aspect-ratio toggle after Shift release in
`/tmp/compositor-held-modifiers-red.log` (exit 1). The first fixture supplied
the wrong raw mask for a modifier-key press; the corrected fixture accounts for
Qt's accessor adjustment and asserts the flags actually delivered to the host.

Release now clears the bit for the released modifier, preserving other held
keys and the existing Control suppression/reset logic. Original `HeldModifiers`
and `TransformInspector` continue supplying temporary option bindings.
Native visible-header checks verify Shift inversion/restoration, combined
Shift/Control inversion, Shift release with Control still held, Control release,
and unchanged stored Auto Select, document and Undo/Redo state.

All four original `TransformPressTests` pass in
`/tmp/compositor-held-modifiers-build-fixed.log` (exit 0). The complete native
transform journey passes in `/tmp/compositor-held-modifiers-fixed.log` (exit 0),
including existing pinch, ruler, draft-save and deep-pixel checks. These native
option assertions cover Shift/Control; physical keyboard and Mac acceptance
remain unverified. No new dependency or project-format change is needed.

Changed files: `host/SessionWindow.cpp`, `host/DialogJourney.cpp`, this baseline,
the current inventory and `TODOS.md`.

### Native ruler coordinate conversion and guide history

The complete runner passes **1,050/1,050 tests** (140 XCTest in 4.604 seconds;
910 Swift Testing in 144 suites in 93.874 seconds), all native journeys,
thumbnailer acceptance and 11 source-coverage checks in
`/tmp/compositor-ruler-full-contract.log` (exit 0), with required Vulkan hardware
on AMD Renoir. This run includes the new ruler and pinch checks. Required shaders,
generators, ledgers and protected-source integrity pass in
`/tmp/compositor-ruler-integrity.log` (exit 0).

The Qt ruler and canvas are sibling widgets. Ruler input previously called
`canvas->mapFrom(ruler, position.toPoint())`, which Qt rejects because the
argument is outside the canvas's parent hierarchy. After independently fixing
the test's coordinate conversion, native drag still fails the document-position
assertion with three Qt hierarchy warnings in `/tmp/compositor-ruler-before.log`
(exit 1). The earlier test attempt also selected a hidden legacy menu; the
regression now searches only visible menu roots and uses global coordinates.

Ruler press, movement and release now use the event's global position and Qt's
`mapFromGlobal`, preserving fractional positions and determining ruler-return
deletion in canvas coordinates. The two rulers expose the same accessibility
labels as upstream. Native pointer events and the visible upstream menu verify
horizontal/vertical creation after zoom/pan, correct document positions, one
New Guide edit, dragging an existing guide back to a ruler, Delete Guide Undo,
creation Undo, discarded new-guide history, Lock Guides refusal/recovery and
show/hide behavior. Existing guide drag/model/history code is reused.

All 14 original `GuideTests` pass in `/tmp/compositor-ruler-build-fixed.log`
(exit 0). The complete native transform journey passes in
`/tmp/compositor-ruler-fixed.log` (exit 0), including pinch/wheel navigation,
PNG16/HDR persistence and external-corruption recovery.

Changed files: `host/SessionWindow.cpp`, `host/DialogJourney.cpp`, this baseline,
the current inventory and `TODOS.md`. Physical desktop/Mac ruler appearance and
input acceptance remain unverified; no dependency or format change is needed.

### Supplemental native pinch acceptance

The existing Qt-to-upstream pinch path now has a native-event regression in
`--transform-smoke`. Real `QNativeGestureEvent` delivery verifies positive and
negative magnification with upstream `1 + magnification` gain, pointer anchoring,
active-brush refusal and recovery, exact document pixels and unchanged history.
Unsupported rotation leaves the viewport unchanged. The complete transform
journey passes in `/tmp/compositor-pinch-native.log` (exit 0), including the
existing wheel, draft-save, PNG16/HDR and external-corruption checks. Its release
build and two lifecycle regression methods also pass in
`/tmp/compositor-pinch-build.log` (exit 0).

This adds acceptance checks only to `host/DialogJourney.cpp`; no production
behavior or dependency changes. The complete 1,050-test/native checkpoint below
predates these supplemental checks. Physical trackpad and Mac behavior remain
unverified. The current inventory and `TODOS.md` record the same scope.

### Accepted close releases sessions and preserves other owners

The complete runner passes **1,050/1,050 tests** (140 XCTest in 4.236 seconds;
910 Swift Testing in 144 suites in 100.719 seconds), all native journeys,
thumbnailer acceptance and 11 source-coverage checks:
`/tmp/compositor-close-lifecycle-full-contract.log` (exit 0), with required
Vulkan hardware on AMD Renoir. Required-shader and protected-source integrity
pass in `/tmp/compositor-close-lifecycle-integrity.log` (exit 0).

Accepted Qt close previously hid the window without releasing its session until
destruction; bridge close also retained the cached canvas and project watcher.
The native pending-save regression fails on the retained handle in
`/tmp/compositor-close-lifecycle-before.log` (exit 1). The corrected Swift
regression harness records 19 issues before the fix in
`/tmp/compositor-session-lifecycle-before.log` (exit 1). Its first version
incorrectly called the synchronous bridge directly from MainActor cleanup and
crashed; bridge calls now run through detached tasks, as existing ABI tests do.

Qt now stops autosave and releases its handles on accepted close. Shared bridge
cleanup removes each cached canvas and closes its compatibility window. It
retains a document used by another registered handle and rebinds its controller
window; after the last owner closes, it stops observation and uses upstream
controller, document and workspace cleanup. Closing a workspace tab follows the
same ownership rule. Cancellation and busy/pending-save gates still run first.

Two regression methods (one with two cases) verify standalone cleanup and both
workspace/session close APIs, released canvas/window references, watcher and
digest cleanup, another owner's document/window preservation and final tab
removal. The focused eight-test run and native save journey pass in
`/tmp/compositor-session-lifecycle-check.log` and
`/tmp/compositor-close-lifecycle-check.log`. Native accepted-close checks verify
that the handle becomes invalid and autosave stops after pending save finishes.
No new dependency or project-format change is needed.

Changed files: `Sources/LinuxBridge/SessionABI.swift`,
`Tests/LinuxOverrideTests/SessionLifecycleTests.swift`, `host/SessionWindow.h`,
`host/SessionWindow.cpp`, `host/DialogJourney.cpp`, this baseline, the current
inventory and `TODOS.md`. Physical desktop and Mac acceptance remain unverified.

### Reopen selects the existing project and preserves unsaved work

The complete runner passes **1,048/1,048 tests** (140 XCTest in 4.242 seconds;
908 Swift Testing in 143 suites in 96.904 seconds), all native journeys,
thumbnailer acceptance and 11 coverage checks:
`/tmp/compositor-reopen-full-contract.log` (exit 0), with required Vulkan hardware
on AMD Renoir. Required shaders, generators, ledgers and protected content pass
in `/tmp/compositor-reopen-integrity.log` (exit 0).

Upstream's workspace selects an already-open resolved project URL. Qt's public
open wrapper previously always loaded a new tab; the native test reproduces it
with unsaved local work (`/tmp/compositor-reopen-before.log`, exit 1). The fixed
`loadProject` wrapper resolves requested and known paths using Qt and selects
the matching tab before considering another package load. It uses the existing
workspace/readiness gates and activates the owner when another visible window
requested the file. Tab switching returns its actual success/refusal and keeps
the visible tab/overflow selection synchronized. Direct package reading remains
available for explicit load/recovery paths.

The expanded save journey checks same-window and cross-window reopening, file
URIs and an alias symlink to the already-open package. It verifies unchanged
tab counts, session identity, unsaved layer name, exact pixels and history.
Busy attempts from another tab, the current project and another window refuse
without creating a copy; release restores selection. The requesting window's
dimensions/layers/selection and Undo/Redo state remain intact. Undo in the owner
still reverses the original unsaved rename. The dedicated save/snapshot run also
passes in `/tmp/compositor-reopen-check.log` (exit 0); the final full run includes
additional pixel checks after cross-window selection and recovery.

The startup fixture now uses an independent on-disk copy, so its distinct-file
tab-count check does not accidentally require duplication of a project already
open in the parent window. Existing startup, overflow, activation, drag and
package journeys all pass. No new dependency or format change is needed.

Changed files: `host/SessionWindow.h`, `host/SessionWindow.cpp`,
`host/DialogJourney.cpp`, this baseline, the current inventory and `TODOS.md`.
Actual desktop/Mac focus and physical file delivery remain unverified.

### Mixed project/image startup arguments and independent tabs

The complete runner passes **1,048/1,048 tests** (140 XCTest in 4.755 seconds;
908 Swift Testing in 143 suites in 95.841 seconds), all native journeys,
thumbnailer acceptance and 11 coverage checks:
`/tmp/compositor-multi-launch-final-contract.log` (exit 0), with required Vulkan
hardware on AMD Renoir. Required shaders, generators, ledgers and protected
content pass in `/tmp/compositor-multi-launch-integrity.log` (exit 0).

The desktop entry passes multiple filenames with `%F`, but Qt's startup loop
stopped after the first existing file. Upstream's application delegate passes
the whole list to `ProjectWorkspace.receive`, which creates separate projects
for images. A real application subprocess given a project and two image URIs
reproduces the discarded later inputs before the fix:
`/tmp/compositor-multi-launch-before.log` (exit 1).

Startup now collects the whole list and calls `SessionWindow.openStartupFiles`,
which uses the existing project loader and image importer for each valid path.
The native save journey checks the last subprocess input's exact dimensions and
RGBA bytes. It also invokes that same startup entry against a real Qt window,
verifies three ordered tabs, reads every input's pixels/dimensions and checks
independent project/photo histories and local rename Undo. Invalid and missing
paths create no extra tab. Existing Unicode/URI single-file launch checks pass.

An initial full run passed all framework tests but failed on whole-QImage
equality (`/tmp/compositor-multi-launch-full-contract.log`, exit 1). That assertion
was corrected to independent dimensions/row-by-row RGBA comparison, matching
the existing saved-pixel oracle. The corrected standalone save journey passes
(`/tmp/compositor-multi-launch-recheck.log`, exit 0), followed by the complete
final run above.

Changed files: `host/SessionWindow.h`, `host/SessionWindow.cpp`,
`host/host_run.cpp`, `host/DialogJourney.cpp`, this baseline,
the current inventory and `TODOS.md`. No new dependency or format change is
needed. This checkpoint covered different project/image files; repeated-project
tab reuse was still open then and is verified in the newer reopen checkpoint
above. Actual desktop/Mac delivery remains unverified.

### Canvas wheel delegates to upstream operation gates

The complete runner passes **1,048/1,048 tests** (140 XCTest in 4.032 seconds;
908 Swift Testing in 143 suites in 96.945 seconds), all native journeys, the
thumbnailer acceptance and 11 coverage checks:
`/tmp/compositor-wheel-full-contract.log` (exit 0), with required Vulkan hardware
on AMD Renoir. Required shaders, generators, ledgers and protected content pass
in `/tmp/compositor-wheel-integrity.log` (exit 0).

Qt previously changed the viewport directly for wheel events. This bypassed
the active-stroke/drag checks in upstream `CanvasView.scrollWheel`. The native
regression fails before the fix with "wheel pan interrupted an active upstream
stroke" (`/tmp/compositor-wheel-before.log`, exit 1); the six snapshot methods
passed before that native failure.

Qt now maps deltas/modifiers into an AppKit scroll event through the existing
canvas bridge and calls the unchanged upstream method. Precise pan remains
point-for-point; a wheel notch retains the existing three-line/36-point pan.
Ctrl/Alt zoom retains its previous direction/gain, including the horizontal-axis
fallback. Upstream supplies the operation, pointer anchor and refusal gates.

The expanded `--transform-smoke` delivers real Qt wheel events during a live
brush stroke and checks that the entire viewport stays unchanged for pan and
Ctrl zoom. After release it checks exact precise/notch pan distances, the
existing precise zoom factor and pointer anchor, with unchanged layer/selection,
modified and Undo/Redo state. Stroke Undo and the remaining transform/package
journeys also pass. No new backend or dependency is required.

Changed files: `Sources/LinuxBridge/UpstreamCanvas.swift`,
`host/SessionWindow.cpp`, `host/DialogJourney.cpp`, this baseline,
the current inventory and `TODOS.md`. Physical trackpad/input behavior and
actual Mac comparison remain unverified; this is not complete scroll-view API
or device acceptance.

### Local file URI refusal, Save As and actual application launch

The complete runner passes **1,048/1,048 tests** (140 XCTest in 4.376 seconds;
908 Swift Testing in 143 suites in 99.131 seconds), all native journeys, the
thumbnailer acceptance and 11 coverage checks:
`/tmp/compositor-local-uri-full-contract.log` (exit 0), with required Vulkan
hardware on AMD Renoir. Required shaders, generators, ledgers and protected
content pass in `/tmp/compositor-local-uri-integrity.log` (exit 0).

Before the fix, the visible Save As action accepted `file:` and wrote `.comp`
into the current directory. The isolated native regression reproduced this in
an owned temporary directory (`/tmp/compositor-save-uri-before.log`, exit 1);
the six snapshot methods passed before the native failure.

`LocalFilePath.h` reuses strict Qt `QUrl` parsing across Save As, the Qt file
dialog, command-line startup and the thumbnailer. File URIs must identify a
nonempty absolute local path, with no query/fragment; localhost is normalized
to a local path. Ordinary filesystem paths retain their existing handling.
Save As detects invalid conversion before suffixing, creating directories,
preparing edits or capturing a snapshot, and reports an invalid local path.

The native save journey checks six rejected file URI cases against the actual
menu: empty path, relative path, malformed percent escape, query, fragment and
remote authority. It verifies no files are created and document/history state
is unchanged. A valid encoded Unicode Save As preserves the source tab through
the existing event-pumping dialog test. Two actual application subprocesses
open a project/image via encoded URI filenames containing Polish characters,
`#` and `%`, save copies and preserve exact pixels/dimensions; the project copy
also preserves exact manifest metadata. Thumbnailer checks verify localhost
and all six invalid URI refusals in addition to its existing acceptance.

Changed files: `host/LocalFilePath.h`, `host/SessionWindow.cpp`,
`host/QtPlatformServices.h`, `host/host_run.cpp`, `host/ThumbnailerMain.cpp`,
`host/DialogJourney.cpp`, `tests/test_thumbnailer.cpp`, this baseline,
the current inventory and `TODOS.md`. No new dependency or format change is
needed. Actual desktop/portal delivery and Mac acceptance remain open.

### Dedicated Flatpak updater acceptance and SDK selection

`bash scripts/test-flatpak-updates.sh` passes with **0 failures** in
`/tmp/compositor-updater-ui.log` (exit 0). The existing release workflow requires
this test in its "Test the updater and release descriptors" step. Its private
host-created DBus daemon serves only the mock portal: no installed application
update or actual relaunch is requested. Release descriptor tests (3) and release
script tests (14, using temporary local repositories) also pass.

The script previously failed before compilation when user and system SDK 6.11
were both installed: Flatpak asked which installation to use, then aborted in
noninteractive execution (`/tmp/compositor-updater-existing.log`, exit 1).
It now prefers an installed user SDK and otherwise explicitly selects system.

The expanded native test checks the visible developer-copy dialog with hidden
install/restart buttons and no portal request. On Ready to Restart, clicking the
real Qt button against a window that refuses closing preserves that window,
reshows the update dialog and retains the installed-update state without another
update transaction. Existing protocol checks cover detection, progress terminal
states, errors/retries and monitor closure. Real installed-release update and
relaunch remain unverified.

An attempted duplicate gate inside `linux-contract-tests.sh` failed because the
KDE SDK does not include DBus daemon/launcher executables
(`/tmp/compositor-updater-full-contract.log`, exit 127). That duplication was
removed; the existing release test retains the correct host/sandbox boundary.
App production code, CMake and the contract runner are unchanged from the prior
1,048-test/native green checkpoint. Required integrity checks pass in
`/tmp/compositor-updater-integrity.log` (exit 0); final protected-content,
shell syntax and whitespace checks also pass.

Changed files: `scripts/test-flatpak-updates.sh`, `tests/test_flatpak_updates.cpp`,
this baseline, the current inventory and `TODOS.md`. No new dependency is needed.

### Standalone project thumbnailer acceptance and required runner gate

The complete runner passes **1,048/1,048 tests** (140 XCTest in 4.274 seconds;
908 Swift Testing in 143 suites in 91.365 seconds), all native journeys, the new
thumbnailer acceptance and 11 coverage checks:
`/tmp/compositor-thumbnailer-full-contract.log` (exit 0), with required Vulkan
hardware on AMD Renoir. Required shaders, generators, ledgers and protected
content pass in `/tmp/compositor-thumbnailer-integrity.log` (exit 0).
CTest registration also passes: `CompositorCore.Thumbnailer`, 1/1 in 0.08 seconds,
`/tmp/compositor-thumbnailer-ctest.log` (exit 0).

`test_thumbnailer` launches the real packaged `compositor-thumbnailer` executable
with independent JPEG/PNG package previews. It checks PNG output, exact dimensions
and aspect ratio, independent red/blue pixels, default and explicit sizing,
Unicode filenames and percent-encoded file URIs. Successful generation leaves
the source preview unchanged. Missing package/preview and corrupt JPEG inputs
return failure without writing an output image. CMake builds and registers the
test; `linux-contract-tests.sh` requires it on every complete run.

The existing Qt implementation supplies this behavior; no new production
implementation or dependency is needed. Changed files: `CMakeLists.txt`,
`scripts/linux-contract-tests.sh`, `tests/test_thumbnailer.cpp`, this baseline,
the current inventory and `TODOS.md`. This verifies the standalone program,
not host Nautilus/Dolphin invocation through an installed Flatpak; physical
desktop and Mac/Finder acceptance remain open.

### Native half-written external package acceptance

The complete runner passes **1,048/1,048 tests** (140 XCTest in 4.816 seconds;
908 Swift Testing in 143 suites in 91.692 seconds), all native journeys and 11
coverage checks: `/tmp/compositor-watch-corruption-full-contract.log` (exit 0),
with required Vulkan hardware on AMD Renoir. Required shaders, generators,
ledgers and protected-content checks pass in
`/tmp/compositor-watch-corruption-integrity.log` (exit 0).

The expanded `--transform-smoke` corrupts the actual watched PNG16 and HDR
packages in three ways: truncated manifest, missing asset and truncated asset.
Each clean document retains its tab handle, exact rendered pixels, dimensions,
layers, selection, modified state and Undo/Redo availability/names without
presenting an external-change prompt. After restoring each package and changing
its manifest name, the watcher reloads it in the same tab with unchanged pixels.
Both explicit `Qt external package corruption recovery OK` records appear in
the full-run log. Existing dirty-work choices, stroke deferral, own-save
suppression and inactive-tab recovery also pass.

This supplies native acceptance evidence for existing upstream loader/watcher
behavior; no production implementation or dependency change was required.
Changed files: `host/DialogJourney.cpp`, this baseline, the current inventory
and `TODOS.md`. Actual desktop sync-client and Mac acceptance remain open.

### Replacement import retires the previous package watch

The complete runner passes **1,048/1,048 tests** (140 XCTest in 3.494 seconds;
908 Swift Testing in 143 suites in 91.410 seconds), all native journeys and 11
coverage checks: `/tmp/compositor-replacement-watch-full-contract.log` (exit 0),
with required Vulkan hardware on AMD Renoir. Required shaders, generators,
ledgers and protected-content checks pass in
`/tmp/compositor-replacement-watch-integrity.log` (exit 0).

`BusyImportRecoveryTests.replacementImportRetiresOldProjectWatch` exercises both
replacement-file and RGBA imports against an actual saved package. Before the fix,
the RGBA path retained the old URL, watcher and persistence generation: modifying
the former package caused an external reload that replaced the new document.
The file-import path cleared its URL but retained the watcher. Both cases fail
in `/tmp/compositor-replacement-watch-before.log` (exit 1, six assertion failures).

Successful replacements now reuse `ProjectController.stopWatchingProject()`.
RGBA replacement also clears the package URL and advances the persistence
generation; file replacement already did both. Refused/busy imports and ordinary
layer insertion retain the existing package binding. The regression verifies
that rewriting the former package leaves the replacement document/history intact
and does not increment the external reload count. No new dependency is needed.

Changed files: `Sources/LinuxBridge/UpstreamEditor.swift`,
`Tests/LinuxOverrideTests/BusyImportRecoveryTests.swift`, this baseline,
the current inventory and `TODOS.md`. Actual Mac/desktop comparison remains open.

### Native close refusal and recovery during canvas strokes

The complete runner passes **1,047/1,047 tests** (140 XCTest in 5.016 seconds;
907 Swift Testing in 143 suites in 90.107 seconds), all native journeys and 11 coverage checks:
`/tmp/compositor-close-busy-full-contract.log` (exit 0), with required Vulkan hardware on AMD Renoir.
Required shaders, generators, ledgers and protected-content checks pass in
`/tmp/compositor-close-busy-integrity.log` (exit 0).

Qt previously presented a close confirmation and removed an inactive dirty tab while upstream refused
switching during a brush stroke. The new native regression reproduces it
(`/tmp/compositor-close-busy-before.log`, exit 1). Tab close now checks the existing workspace switch
gate and native replacement-import readiness. Window-close preparation checks readiness after upstream
settles pending drafts; an active stroke remains blocked, matching `ProjectWorkspace.confirmQuit`.
No new lifecycle/backend implementation or dependency is needed.

The native tab-close signal now produces no prompt/removal while a stroke is active, preserves the
inactive target's exact pixels/layers and keeps the source selected. Closing the window is also refused.
Release restores closing: Cancel retains the target, then Don't Save removes only that target.
The complete run also retains async-save/pending-close, modal and external-change acceptance.
Physical desktop and actual Mac acceptance remain open.

Changed files: `Sources/LinuxBridge/SessionABI.swift`, `host/SessionWindow.cpp`, `host/DialogJourney.cpp`,
this baseline, the current inventory and `TODOS.md`. Protected upstream content remains unchanged.

### Inactive dirty-project changes and tab-selection recovery

The complete runner passes **1,047/1,047 tests** (140 XCTest in 4.365 seconds;
907 Swift Testing in 143 suites in 88.501 seconds), all native journeys and 11 coverage checks:
`/tmp/compositor-watch-inactive-full-contract.log` (exit 0), with required Vulkan hardware on AMD Renoir.
Production code, shaders and generators are unchanged from the previous integrity checkpoint
(`/tmp/compositor-watch-integrity.log`, exit 0); protected-content and whitespace checks pass again.

For PNG16 and HDR projects, the native journey leaves local work unsaved, opens a second document and
modifies the inactive project's manifest on disk. No prompt appears and the second document stays active.
Selecting the watched tab resumes the original controller's pending check; Keep Mine preserves its local
layer name, modified state and tab identity. Returning to the second document preserves dimensions,
layers, selection, modified state and Undo/Redo availability/names. This verifies Qt tab signals and the
upstream controller's deferral/resume path; actual desktop and Mac acceptance remain open.

Changed files: `host/DialogJourney.cpp`, this baseline, the current inventory and `TODOS.md`.
No new production implementation or dependency is needed for this acceptance extension.

### Native external project changes and unsaved-work protection

The complete runner passes **1,047/1,047 tests** (140 XCTest in 4.803 seconds;
907 Swift Testing in 143 suites in 89.703 seconds), all native journeys and 11 coverage checks:
`/tmp/compositor-watch-busy-full-contract.log` (exit 0), with required Vulkan hardware on AMD Renoir.
Required shaders, generators, ledgers and protected-source checks pass in
`/tmp/compositor-watch-integrity.log` (exit 0).

The original external-change model tests passed, but the Qt loader left `projectURL` unset and never
armed a watcher. The new native regression fails to reload a changed manifest before integration
(`/tmp/compositor-watch-native-before.log`, exit 1). Opened and successfully user-saved packages now
bind their path, known digest and canvas window to upstream `ProjectWatcher`/`ProjectController`.
The original kernel-event watcher, coalescing, digest, reload and dirty-work rules are reused.
Qt presents the original alert text/buttons through `QMessageBox`; Escape selects the final choice.
Own user writes suppress checks until the new digest is remembered. Recovery-copy autosaves do not
disable observation of the actual project. No filesystem watcher or hashing dependency was added.

For both PNG16 and HDR projects, native checks verify external manifest reload in the same tab,
identical-byte rewriting without a prompt/history reset, Keep Mine preserving modified work,
Revert installing a clean revision, deferral during a brush stroke and recovery after release,
and actual async user-save completion retaining Undo without a spurious reload. The first own-save
assertion used the serialization-only test helper; it now uses the production async save path.
The earlier focused snapshot tests and clean reload pass in `/tmp/compositor-watch-native-build.log`
and `/tmp/compositor-watch-native.log`; the final complete run is the authoritative evidence.
Inactive-tab prompt acceptance and actual desktop/Mac behavior remain open.

Changed files: `Sources/LinuxBridge/UpstreamEditor.swift`, `Sources/LinuxBridge/SessionABI.swift`,
`host/SessionWindow.cpp`, `host/DialogJourney.cpp`, this baseline, the current inventory and `TODOS.md`.
Protected upstream source and tests remain unchanged.

### Native deep photo import, save and reopen

The complete runner passes **1,047/1,047 tests** (140 XCTest in 4.914 seconds;
907 Swift Testing in 143 suites in 111.341 seconds), all native journeys and 11 coverage checks:
`/tmp/compositor-deep-photo-import-full.log` (exit 0), with required Vulkan hardware on AMD Renoir.
Required shaders, generators, ledgers and protected-source checks pass in
`/tmp/compositor-deep-photo-import-integrity.log` (exit 0).

The audit confirms that menu imports, file drops and opening images already use `importWithUpstream`.
The old static `needsUpstreamImporter` selector had no callers and was removed. The extended native
journey imports independent PNG16 and HDR EXR photographs through `SessionWindow.importImage`, checks
the new document dimensions and isolated layer set, saves it and checks the asset format, depth and all
RGBA samples before reopening. Zero, quarter, half and opaque alpha retain the previous tolerances:
one 16-bit integer step and 0.008 in HDR linear light. The existing upstream importer and codecs provide
the behavior; no conversion backend or dependency was added. Actual Mac color/desktop acceptance remains open.

Changed files: `host/SessionWindow.cpp`, `host/DialogJourney.cpp`, this baseline,
`docs/current-linux-compatibility-inventory.md` and `TODOS.md`. Native input and package checks use
temporary fixtures; protected Mac source content remains unchanged.

### Native 16-bit/HDR package persistence through upstream ProjectStore

The complete runner passes **1,047/1,047 tests** (140 XCTest in 4.593 seconds;
907 Swift Testing in 143 suites in 101.826 seconds):
`/tmp/compositor-deep-package-alpha-full-contract.log` (exit 0).
All native journeys and 11 source-coverage checks pass with required Vulkan hardware on AMD Renoir.
The runner now also requires the asynchronous save/recovery journey and the transform/package journey
that checks saved preview dimensions and high-precision assets. Required shaders, generators, ledgers
and protected-content checks pass in `/tmp/compositor-deep-package-integrity.log` (exit 0).

The corrected native fixture first fails because the saved layer loses 16-bit precision
(`/tmp/compositor-deep-native-before-fixed.log`, exit 1). Its first attempt used incorrectly keyed
CGPoint/CGSize fields and failed before reaching that check; those fields now use the documented arrays.
Qt now delegates staged encoding and complete-package decoding to unchanged upstream `ProjectStore`.
It retains header/dimension/cumulative-budget preflight, encoded-size limits, destination installation,
portal fallback, immutable save tokens and revision-aware completion. Existing OpenEXR code supplies
header preflight; existing image codecs encode/decode the full assets. No codec dependency was added.

The new parameterized snapshot test writes after replacement and close, verifies PNG/EXR filenames,
full-depth assets, alpha and color samples, optional preview/autosave behavior and bridge reopening.
The native journey creates independent 16-bit PNG and HDR EXR inputs and checks saved dimensions,
depth, every color/alpha sample and reopening. Zero, quarter, half and opaque alpha are exercised;
16-bit samples stay within one integer step and HDR linear light within 0.008.
The full async-save journey passes with 3,731 UI ticks, captured pixels/revision, live edits, tab changes,
failure recovery, autosave and pending close. Mac color and physical-desktop acceptance remain open.

The supplemental large-package journey passes in `/tmp/compositor-deep-package-limits-final.log` (exit 0):
120 MP images plus 120 MP masks, save/reopen pixel identity, invalid versions, cumulative limits and
failed-save preservation. Its first run stopped at an obsolete assertion that version 12 was unsupported;
the fixture now rejects zero, the saved version plus one and 999. New saves use version 13.

Changed implementation/acceptance files: `Sources/LinuxBridge/ProjectSaveSnapshot.swift`,
`Sources/LinuxBridge/SessionABI.swift`, `Sources/LinuxBridge/UpstreamEditor.swift`,
`host/SessionWindow.cpp`, `host/DialogJourney.cpp`, `Tests/LinuxOverrideTests/ProjectSaveSnapshotTests.swift`
and `scripts/linux-contract-tests.sh`. Documentation: this baseline, the current inventory, `TODOS.md`
and `docs/project-format.md`. Protected Mac sources remain unchanged.

### Portable package preview from the frozen save snapshot

The complete runner passes **1,046/1,046 tests** (140 XCTest in 5.657 seconds;
906 Swift Testing in 143 suites in 96.767 seconds): `/tmp/compositor-preview-full-final.log` (exit 0).
All native journeys, including the newly required pending-transform/Save As package-preview save,
and 11 coverage checks pass with required Vulkan hardware on AMD Renoir.
Required shaders, generators, ledgers and protected-source checks pass in
`/tmp/compositor-preview-integrity.log` (exit 0).

Previously the preview bridge returned zero for every document. Both new preview regressions fail
against that implementation (`/tmp/compositor-preview-before.log`, exit 1). The bridge now invokes
unchanged upstream `ImageExporter.quickLookImages` on the immutable snapshot, without a live-session
or main-actor hop, and caches the bytes for the size/copy ABI calls. Existing Qt package writing installs
the optional JPEG; autosaves retain their preview skip. No new graphics or codec dependency is needed.

All five focused save-snapshot tests pass (`/tmp/compositor-preview-focused.log`, exit 0).
Checks include exact upstream JPEG output, independently decoded red/white pixels, retained captured
content after replacement/close, stable repeated copies, undersized-buffer preservation, invalid/released
tokens, 1024-pixel long-side scaling and omission above 50 MP. Native pending-transform and Save As saves
produce a readable JPEG with expected dimensions (`/tmp/compositor-preview-transform-native.log`, exit 0).
This journey now runs in the contract script. Mac/Finder, desktop thumbnailer and broader API/device
acceptance remain open.

### Recent-document metadata through system libxml2

The latest framework run passes **1,044/1,044 tests** (140 XCTest in 4.718 seconds;
904 Swift Testing in 143 suites in 98.643 seconds):
`/tmp/compositor-recent-native-full-final.log` (exit 0). All native journeys and 11 source-coverage checks
also pass, with required Vulkan hardware on AMD Renoir.
Required shaders, generators, ledgers and protected-content checks pass in
`/tmp/compositor-recent-native-integrity.log` (exit 0).

Seven new XML regressions cover XDG data paths, escaped Unicode filenames, repeated opens, preservation
of other applications and metadata, selective clearing, namespace ownership, malformed/entity-bearing
input and absent/non-file entries. The existing controller test now reads the configured XDG location;
its old hardcoded home path caused the first full run's single failure
(`/tmp/compositor-recent-native-full-contract.log`).

The production adapter uses the runtime's libxml2 through a small C module, preserving Qt's XML ABI.
A static-Swift executable passes repeated open/escape/clear checks without `LD_LIBRARY_PATH`:
`/tmp/compositor-recent-native-static-runtime.log`; its dynamic dependencies contain `libxml2.so.16`
and no older XML ABI (`/tmp/compositor-recent-native-static-linkage.log`). No extra SDK XML library is bundled.
Host desktop visibility, Mac/device acceptance and the broader API audit remain open. The audit also
identified missing portable `QuickLook/Preview.jpg` generation in the Linux save bridge.

### Pointer reordering across hidden projects and busy overflow selection

The complete runner passes **1,037/1,037 framework tests** (133 XCTest in 3.961 seconds;
904 Swift Testing in 143 suites in 96.452 seconds), all native journeys and 11 coverage checks:
`/tmp/compositor-overflow-pointer-full-contract.log` (exit 0). Required Vulkan hardware is AMD Renoir.
Required shaders, generators, ledgers and protected-content checks pass in
`/tmp/compositor-overflow-pointer-integrity.log` (exit 0).

The expanded native journey drags a visible selected project across hidden tab indices at 800 pixels,
then checks all five handles, expected order, layers, exact pixels, modified state and Undo/Redo state.
Overflow-menu selection during an active stroke is refused without changing source or inactive projects;
release restores selection. The earlier standalone pointer/refusal check passes in
`/tmp/compositor-overflow-pointer-acceptance.log`; the full run adds explicit inactive-project assertions.
This step changes native acceptance tests only. Physical-desktop and Mac/device acceptance remain open.

### Overflow sizing, selection and reordered-menu fix

The complete runner passes **1,037/1,037 framework tests** (133 XCTest in 4.721 seconds;
904 Swift Testing in 143 suites in 95.589 seconds), all native journeys and 11 coverage checks:
`/tmp/compositor-overflow-full-contract.log` (exit 0). Vulkan hardware was enabled and required on AMD Renoir.
Required shaders, generators, ledgers and protected-content checks pass in
`/tmp/compositor-overflow-integrity.log` (exit 0).

The new native regression lost overflow after reordering (`/tmp/compositor-overflow-before.log`, exit 1).
Selection preservation and refresh alone still failed at minimum width (`/tmp/compositor-overflow-narrow.log`,
exit 1). Using the renderer's natural widths resolves the transient layout measurement. Visibility updates
also preserve selection without internal signals, moves refresh the menu and replaced menus are retired.
`/tmp/compositor-overflow-acceptance-final.log` (exit 0) verifies hidden-project selection, visible menu
targeting and Undo at 800 pixels, then all five projects' identities, relative order, pixels, modified state
and Undo/Redo state after Qt reordering. Every rebuilt menu entry selects the expected project.
Pointer dragging across overflow boundaries and physical-desktop/Mac acceptance remain unverified.
Protected sources and project-format fields are unchanged.

### Visible project-tab reorder readiness fix

The complete runner passes **1,037/1,037 framework tests** (133 XCTest in 5.206 seconds;
904 Swift Testing in 143 suites in 97.816 seconds), all native journeys and 11 coverage checks:
`/tmp/compositor-tab-reorder-full-contract.log` (exit 0). Required Vulkan hardware is AMD Renoir.
Required shaders, generators, ledgers and protected-content checks pass in
`/tmp/compositor-tab-reorder-integrity.log` (exit 0).

Qt previously allowed mouse-driven tab reordering while upstream refused a switch during an active stroke:
`/tmp/compositor-tab-reorder-busy-before.log` (expected exit 1). Drag startup now queries the exact
upstream workspace gate and Linux replacement-import readiness. Native acceptance verifies selected and
inactive moves, stepped mouse drags, document identity and pixel/history isolation, visible-menu targets
and independent Undo in reversed order, busy refusal and post-release pointer recovery:
`/tmp/compositor-tab-reorder-acceptance-final.log` (exit 0). Initial pointer fixtures jumped past Qt's
neighbor hit area; stepped motion exercises the actual mouse-drag implementation. Protected sources and
project-format fields are unchanged. Overflow, physical-desktop and Mac acceptance remain open.

### Project-window activation and menu-context fix

The complete runner passes **1,037/1,037 framework tests** (133 XCTest in 4.514 seconds;
904 Swift Testing in 143 suites in 96.782 seconds), all native journeys and 11 coverage checks:
`/tmp/compositor-window-activation-full-contract.log` (exit 0). Vulkan hardware was enabled and required
on AMD Renoir. Required shaders, generators, ledgers and protected-content checks pass in
`/tmp/compositor-window-activation-integrity.log` (exit 0).

The new regression reproduced New Blank Layer editing the other project after a Qt window reactivated:
`/tmp/compositor-window-activation-before.log` (expected exit 1). Window activation now selects its displayed
upstream tab; menu opening and dispatch recheck selection and honor upstream refusal. The strengthened
native journey verifies both activation directions, independent Undo, inactive pixels/history isolation,
stale-action refusal during an active stroke and recovery after release:
`/tmp/compositor-window-activation-busy.log` (exit 0). Protected sources and project-format fields are unchanged.
Physical-desktop and Mac acceptance remain unverified.

### Two-window folder delivery and expanded full contract

The complete runner passes **1,037/1,037 framework tests** (133 XCTest in 4.001 seconds;
904 Swift Testing in 143 suites in 97.533 seconds), all native journeys and 11 source-coverage checks:
`/tmp/compositor-two-window-full-contract.log` (exit 0). Vulkan was enabled and required on AMD Renoir.
Required shaders, generators, ledgers and protected-content checks pass in
`/tmp/compositor-two-window-integrity.log` (exit 0).

The tab journey includes multiple selected rows, folder copying and delivery between two Qt windows.
The two-window folder case verifies descendants, names, remapped layer/parent identities, source
pixels/history isolation and exact destination Undo/Redo. Standalone evidence:
`/tmp/compositor-two-window-acceptance-visible.log` (exit 0). An earlier fixture placed the target outside
the offscreen display and failed the visibility assertion; moving its header into the display made the
same delivery path pass. This is native Qt event acceptance, with physical desktop input and Mac
comparison still unverified. No protected source or project-format fields changed.

### Focused multiple-row and folder drag acceptance

The extended native tab journey passes in `/tmp/compositor-multi-drag-acceptance-final.log` (exit 0).
Multiple selected rows retain upstream's separate provider/history operations. Folder copying retains
descendants and names, remaps layer and parent identities, preserves source pixels/history, and restores
destination pixels through Undo/Redo. Its fixture creates a second source layer explicitly and exposes
both tabs in a wider offscreen window. The release build and all 11 unchanged ProjectWorkspaceTests pass
in `/tmp/compositor-multi-drag-build-hierarchy.log`. Protected-content equality and `git diff --check` pass.
The complete contract baseline below predates these test-only additions; it was not rerun for this step.
Two-window folder delivery is covered by the later checkpoint above; physical-desktop and Mac comparison remain unverified.

### Empty-header fitted-project drop update

The complete contract runner passes **1,037/1,037 framework tests** (133 XCTest in 3.845 seconds;
904 Swift Testing in 143 suites in 98.751 seconds), all native journeys and 11 source-coverage checks:
`/tmp/compositor-header-drop-full-contract.log` (exit 0). Vulkan was enabled and required on AMD Renoir.
Required shaders, generators, ledgers and protected sources pass in `/tmp/compositor-header-drop-integrity.log`.

The native row-pointer regression before the Qt destination fails to create a project on empty header space:
`/tmp/compositor-header-drop-before.log` (expected exit 1). After the fix, the strengthened journey verifies
fitted dimensions, source isolation, Undo to the welcome state and exact Redo. It covers busy header entry,
movement and drop as forbidden actions without parent fallback, queued imports or tabs, and ready file/image
payloads creating new projects with their own dimensions. Standalone evidence:
`/tmp/compositor-header-drop-acceptance-final.log` (exit 0).

The later checkpoint above adds two-window folder delivery. The existing API/GPU/Mac/device work
remains open. This adaptation changes no protected source or project-format fields.

### Native layer-row project copy and pasteboard lifetime update

The final complete contract runner passes **1,037/1,037 framework tests** (133 XCTest in 4.066 seconds;
904 Swift Testing in 143 suites in 101.810 seconds), all native journeys and 11 source-coverage checks:
`/tmp/compositor-layer-project-full-contract-final.log` (exit 0). Vulkan was enabled and required on AMD Renoir.
Required shaders, generators, ledgers and protected sources pass in
`/tmp/compositor-layer-project-integrity-final.log` (exit 0).

A real native Layers-row pointer drag now reaches another existing project tab through unchanged upstream
provider copying. The journey verifies names/new IDs, source pixel/history isolation, destination Undo/Redo,
same-project and Alt preflight refusal, retired sessions and repeated fresh copying with one-step Undo.
Standalone repeated-drag evidence: `/tmp/compositor-layer-project-repeat-native.log` (exit 0).
Disabling only the tab adapter fails at delivery: `/tmp/compositor-layer-project-control-final.log`
(expected exit 1). Original workspace tests also pass unchanged.

The two new pasteboard regressions initially failed with five issues: clearing retained stale items, subsequent
writing returned the old first item, and object destruction retained its writers. Evidence:
`/tmp/compositor-drag-lifetime-before.log` (expected exit 1). Instance-owned drag items now clear and release
correctly; both tests pass in the final runner. No protected Mac sources or test bodies changed.

Empty-header drops that create a project, broader multi-row/multiple-window drag acceptance and the existing
API/GPU/Mac/device work remain open.

### Tab-strip drop refusal and destination update

The complete contract runner passes **1,035/1,035 framework tests** (133 XCTest in 4.714 seconds;
902 Swift Testing in 142 suites in 104.779 seconds), all native journeys and 11 source-coverage checks:
`/tmp/compositor-tab-drop-full-contract-final.log` (exit 0). Vulkan was enabled and required with the same
four environment variables listed in the prior tab update below, on AMD Renoir.

The original native failure accepted a tab-strip drop during a stroke and captured another destination:
`/tmp/compositor-tab-drop-before.log` (expected exit 1). Entry-only refusal then exposed Qt's parent-window
fallback: `/tmp/compositor-tab-drop-acceptance.log` (expected exit 1). The final journey verifies forbidden
actions at busy entry, movement and drop, late refusal after ready entry, no queued import, correct ready-drop
target and unchanged inactive pixels/history: `/tmp/compositor-tab-drop-acceptance-final.log` (exit 0).
The full native preview still passes its separate waiting window-drop checks. The initial focused import run
omitted codec/renderer library settings and failed; the fully configured unfiltered run above includes those
unchanged import suites and passes. Integrity: `/tmp/compositor-tab-drop-integrity.log` (exit 0).

Live `git ls-remote upstream refs/heads/main` returned `e8c9e29701528413cc0e608d61187c1c61790add` on October 13,
confirming the cached reference is current at this check. Mac/device acceptance and the remaining broad
API/GPU work remain open.

### Existing-tab context and refusal update

The complete contract run passes **1,035/1,035 framework tests** (133 XCTest in 4.046 seconds;
902 Swift Testing in 142 suites in 100.868 seconds), every native journey including the new tab journey,
and all 11 source-coverage checks. Log: `/tmp/compositor-tab-full-contract-final.log` (exit 0).
Vulkan was enabled with `COMPOSITOR_COREIMAGE_BACKEND=vulkan` and required with
`REQUIRE_COREIMAGE_VULKAN=1`, `COMPOSITOR_REQUIRE_WARP_VULKAN=1` and
`COMPOSITOR_REQUIRE_WARP_HARDWARE=1`; checks used AMD Renoir.

The regression before the fix fails at a visible menu editing another workspace tab after a Qt tab click:
`/tmp/compositor-tab-before.log` (expected exit 1). The strengthened native journey passes actual tab clicks,
visible menu targets, active-stroke refusal, release recovery, real painting and inactive pixel/history
isolation: `/tmp/compositor-tab-pixel-acceptance.log` (exit 0). The initial full-run invocation omitted the
backend-enable variable and failed 19 hardware-context assertions; the correctly configured unfiltered rerun
above passes without weakening those assertions. Integrity: `/tmp/compositor-tab-integrity.log` (exit 0).

Mac/device acceptance, broader API inventory and full-viewport GPU performance/fidelity remain open.

### Native text and upstream command palette update

The current complete `scripts/linux-contract-tests.sh` run after these adapters passed **1,035/1,035**
framework tests (133 XCTest in 4.282 seconds; 902 Swift Testing in 142 suites in 96.694 seconds), every native
contract journey and 11 coverage checks. Vulkan hardware was required on AMD Renoir.
Log: `/tmp/compositor-text-palette-full-contract.log` (exit 0). Required-shader/generator/ledger/protected-content
integrity: `/tmp/compositor-text-palette-integrity.log` (exit 0).

The native preview now chooses visible menu actions, rather than hidden shell actions, for local text Undo/Redo.
It verifies Unicode Copy/Cut/plain Paste, Select All, read-only refusal, exact deleted font/color restoration and
synthetic IME preedit/commit. An isolated control unregisters the native responder and fails at cross-style Undo,
reproducing the former host behavior: `/tmp/compositor-native-text-control.log` (expected exit 1).

The palette catalog, tool/mask entries and fuzzy ranking come from the unchanged upstream implementation.
The native checks verify a single Copy entry, skipped system menus, disabled-entry refusal, focus restoration
and delayed dispatch. A final strengthened run verifies wrapping across multiple results and actual Polygonal
Lasso selection without pixel/layer/history changes. It also passes 13 focused tests across CommandPaletteTests
and NativeTextEditingTests: `/tmp/compositor-text-palette-acceptance.log` (exit 0). Production code did not change
between the full runner and this final test-strengthening run.

The interim `swift build --build-tests` attempt failed because its release modules lacked testable imports;
the normal `swift test` command restored the correct configuration. The final tool assertion also now uses
upstream's actual exported enum value, `Polygonal`, rather than a lowercase spelling.

Existing-tab menu context and active-stroke refusal were still open at this checkpoint; the update above resolves that item. Mac/device acceptance and
full-viewport GPU performance/fidelity work remain open. Latest code and documentation are uncommitted.

### Initial October 13 checkpoint

GNU_Linux HEAD is `8185eee`; synchronized latest upstream additions and Linux adaptations are uncommitted.
The unfiltered release `scripts/linux-contract-tests.sh` run exited **0** in KDE SDK 6.11 with Swift 6.3.3:
**1,035/1,035 framework tests passed** — **133 XCTest** (5.138 seconds) and **902 Swift Testing** across
**142 suites** (111.284 seconds), with no runtime skips. All 86 upstream test files are accounted for:
84 unchanged, one selector mirror and one defaults type-name mirror. macOS UI automation is outside this target.

Hardware was required with `REQUIRE_COREIMAGE_VULKAN=1`, `COMPOSITOR_REQUIRE_WARP_VULKAN=1` and
`COMPOSITOR_REQUIRE_WARP_HARDWARE=1`; Vulkan checks ran on AMD Radeon Graphics (RADV RENOIR).
The full runner also passed native kernels, PatchMatch, Skia, font traits, ImageIO/HEIF and embedded lens-profile
checks, all 11 source-coverage fault/control checks, and the combination, preview, RAW lens and text journeys.
Required-shader integrity passed separately, including seven protected-content fault/control checks and ledgers
through `e8c9e29`. Protected file content and executable modes match the cached reference, even for untracked additions.

Newly verified paths include all original CMYK, Progressive Blur, Camera Raw reset and shortcut assertions;
192 independent floating TIFF combinations; and 10/12-bit PQ/HLG HEIF highlight/alpha fixtures.
CMYK tests use an isolated existing ECI profile at `/tmp/compositor-parity-acceptance/share/CMYK Profiles/Generic CMYK Profile.icc`.
This is a test fixture, not Apple's bundled profile or proof of equivalent print colors. Test defaults are also
isolated under `/tmp/compositor-parity-acceptance`; production settings are not replaced.

The first full run found two stale Linux test expectations: 8-bit reduction of 16-bit canvas uploads and rejection
of a cleared shortcut. Both oracles now reflect the current protected upstream implementation. A subsequent build
was stopped by Swift because a test was edited during compilation; the final fresh run above passed completely.
The native combination journey passes now, but this does not explain the older intermittent timeout.

Full run: `/tmp/compositor-parity-full-contract-final.log` (exit 0).
Integrity: `/tmp/compositor-parity-source-integrity.log` (exit 0).
Focused latest features: `/tmp/compositor-latest-upstream-final.log` (exit 0).
Independent codec checks: `/tmp/compositor-hdr-imageio-final.log` (exit 0).
Source reports: `.build/linux-contract-native/package-description.json` and `source-coverage.json`.

No Mac is available, as confirmed by the user. Actual macOS → Linux → macOS project round trips, matching Mac
screenshots and color comparisons remain unverified. Physical touch/tablet, native Wayland and external screen-reader
acceptance remain separate from these offscreen Qt checks. Full-viewport Vulkan performance and cross-canvas SDR/HDR
fidelity gaps remain documented in the six-area tracker. A clean hosted dependency build/release CI run was not executed.

## Earlier green checkpoint: 2026-10-11, upstream `39d1257`

Merged as `74dbacf`. The final unfiltered `scripts/linux-contract-tests.sh` run inside the prepared KDE 6.11
Flatpak SDK passed **869/869 framework tests**: **121 XCTest** (2.806 seconds) and **748 Swift Testing**
across **122 suites** (146.395 seconds), with no runtime skips. All 81 upstream test files are accounted for
(80 unchanged and one selector mirror); macOS UI automation remains outside the Linux target.

The same runner passed all nine source-coverage checks, real Skia/ImageIO/HEIF/font checks, native kernel tests,
and the complete combination, preview and text journeys. PatchMatch checks include seed determinism,
outside-hole preservation, no-source refusal, ten allocation faults and both stride guards. Native editing
covers preserved blur alpha/geometry and exact Undo/Redo, queued Smudge/Liquify turns and release, and the
upstream RAW sheet’s supported controls, disabled lens explanation, Reset and Cancel. Generated Bayer DNGs
verify actual LibRaw draft/full noise and highlight pixel changes, unsupported small-sensor noise, stable
capabilities/dimensions and exact default-preview restoration at two sizes.

WarpCommitParityTests passes all five methods (14 cases) against the unchanged upstream commit oracle;
WarpTipCacheTests also passes its six cases. RawDevelopCapabilityTests verifies callbacks/defaults/reset and
all controls in the actual sheet. The compatibility fix applies modifiers to every Group sibling. The Linux
bridge blur regression now checks both canvas-edge and inset-layer behavior, solid borders and exact Undo/Redo.
Lens correction remains unsupported by the existing RAW backend. These transient controls add no project-format fields.

Complete run: `/tmp/compositor-upstream-catchup-full-contract-verified.log` (exit 0).
Focused/native Group run: `/tmp/compositor-raw-group-contract.log` (exit 0).
Required-shader integrity: `/tmp/compositor-upstream-catchup-integrity-final.log` (exit 0).
Source reports: `.build/linux-contract-native/package-description.json` and `source-coverage.json`.
Protected `Compositor/`, `CompositorTests/`, `CompositorUITests/` and `Compositor.xcodeproj/` match upstream exactly.

Earlier failures remain diagnostic evidence: `/tmp/compositor-warp-commit-before.log` captures the original
warp differences. The first catch-up full run exposed an obsolete canvas-edge blur expectation; the next
run exposed Foundation’s nested-dictionary comparison in the added Undo assertion. Geometry/pixel checks
passed, and canonical JSON comparison now verifies every transform field. The native RAW journey also
found LibRaw 0.22.2’s uninitialized OpenMP wavelet allocation count and the missing Group children; both
are fixed and covered by the final run. A clean hosted dependency build/CI run has not been executed locally.

## Earlier checkpoint: 2026-10-11 (before upstream catch-up and warp commit checks)

Release build of the current GNU/Linux worktree succeeded with Swift 6.3.3 in KDE SDK 6.11. With the Skia and
ImageIO backends explicitly configured and `CameraRawTables.bin` copied beside the test executable, the full
unfiltered run completed: **856/856 tests passed: 121 XCTest and 735 Swift Testing across 120 suites**, with no runtime
skips. Compiled target exclusions remain in `Package.swift`; these counts do not include macOS UI automation.

A subsequent audit added WarpCommitParityTests and an unchanged upstream commit oracle. Its original two methods
(eight parameter cases) failed with 19 issues: synchronous commit pixels differed, and sliced input also differed
in points/pixels (`/tmp/compositor-warp-commit-before.log`). The current implementation fixes those failures by
preserving queued segments and upstream commit coverage/sampling. The four audited commits through `39d1257`
are now merged as `74dbacf`; the historical 856-test checkpoint below predates that work. See
[the current inventory](current-linux-compatibility-inventory.md).

```sh
install -m644 Compositor/Resources/CameraRawTables.bin .build/x86_64-unknown-linux-gnu/release/
COMPOSITOR_SKIA_BRIDGE="$PWD/.build/linux-contract-native/libCompositorSkiaBridge.so" \
COMPOSITOR_IMAGEIO_BACKEND="$PWD/.build/linux-contract-native/libCompositorQtImageIO.so" \
QT_QPA_PLATFORM=offscreen swift test -c release --skip-build --no-parallel
```

Run the command inside the Flatpak SDK with its Swift extension enabled. That earlier full run took
141.924 seconds for Swift Testing and 2.880 seconds for XCTest. Native combination, preview and text journeys
also completed successfully; the complete runner returned 0. Log: `/tmp/compositor-full-contract-panel-width-final.log`.

Previous upstream `b2a0c45` was merged as `83a8cd5`, incorporating narrow-panel sizing and folder imports.
The two new ImageImportTests run unchanged: folders expand only their direct importable children in natural
name order, omit hidden/nested/non-image files, exclude project packages, and report empty folders.
The native import flow now collects mixed image/folder selections through native file and directory choosers.
Its preview journey verifies add/remove/duplicate handling and the resulting three-layer name order; the complete
853-test runner and all native journeys returned 0. Real desktop portal directory grants remain unverified.
The Qt Layers dock now resizes within upstream’s 222–352-point bounds, forwards its content width to the unchanged
LayersPanel body, and persists it without a document edit. Three LayersPanelWidthTests cover old preference clamping,
persistence, invalid offers and targeted panel invalidation; all 42 focused width/hosting/scroll tests passed. The
native preview verifies endpoint control containment and a pointer-driven splitter drag. Native custom pop-up
minimum sizing follows upstream’s sizeThatFits; the stack’s decorative border no longer consumes its content width.
The pre-change fixed-width dock fails this journey. Real desktop layout and Mac screenshot comparison remain unverified.
An initial full width-change run passed all 856 framework tests, then timed out in the native combination journey
after selection/gradient Undo. The same binary passed the standalone combination rerun; the runner now reports the
precise rail/drag/gradient action and session state on a timeout. This intermittent failure remains recorded in
`/tmp/compositor-full-contract-panel-width.log` and `/tmp/compositor-panel-width-combo-recheck.log`.
The final complete runner (`/tmp/compositor-full-contract-panel-width-final.log`) passed all 856 framework tests,
all nine source-coverage checks and all native journeys with exit 0; no framework test was skipped. The earlier
intermittent combination timeout is not considered explained by that successful rerun.

The SDK runner now evaluates SwiftPM source targets and checks all 151 protected Swift files: 124 unchanged,
20 generated adaptations, five backend replacements and two platform substitutions. All 81 upstream test files
are accounted for (80 unchanged, one selector mirror). The source gate has nine Python checks: two valid controls and seven injected faults for missing sources,
undeclared or duplicate implementations, and missing/duplicate mirrors; these are separate from the 856 framework
count. See [the current inventory](current-linux-compatibility-inventory.md). The full runner includes this gate;
its source-coverage and initial eight checks passed before the framework and native journeys. All nine final checks then passed in the SDK (`/tmp/compositor-source-coverage-sdk-final.log`); existing tip/pinned policy remains the separate drift gate’s responsibility.

`DocumentHistory` now compiles directly from upstream. The Linux first-canvas baseline patch and generated
history override have been retired: Undo of initial New Canvas restores no document, and Redo restores the
canvas, active layer and unsaved revision. All seven original HistoryTests run unchanged, including the two
previously failing cases. Both CI jobs run them; the weekly job has no per-test skips. The generator rejects
a stale history override so it cannot silently replace the upstream type again.
The native Qt journey verifies Ctrl+Z to the visible welcome screen and immediate Ctrl+Shift+Z back to exact
canvas pixels, the original active layer and modified state. After history retirement, the contract runner passed 73 Swift Testing tests
and 5 XCTest tests, native color checks and the editing/touch/Camera Raw journeys.
Log: `/tmp/compositor-upstream-history-contract.log`. The existing native `--dialog-smoke` also passed
after this history change (resize, filter preview/commit/Undo, palette, autosave, save/reopen and tool transitions).
Log: `/tmp/compositor-upstream-history-dialog.log`. Required-shader integrity checks passed.

Constrained HStack/VStack measurement now shares main-axis allocation with placement. Responsive native
views receive their allocated width/height, after spacing, fixed children and layout priority, before the
cross axis is measured. Six new checks passed (21 HostingMeasurementTests total), including vertical and
nested stacks and retention of unknown bounds for renderer-owned leaves. The first three failed against
the old implementation with oversized panel heights; all passed after the fix.
The contract runner passed 76 Swift Testing tests and 5 XCTest tests after those first three checks, followed
by native editing, synthetic touch and Camera Raw sizing journeys. The final six checks passed in the
unfiltered 816-test run above. Logs: `/tmp/compositor-constrained-hosting-regression.log` and
`/tmp/compositor-constrained-hosting-contract.log`.

Natural hosting sizes now come from the actual Qt widget builder through a registered measurement callback.
Supported text, buttons, toggles, fields, sliders, pickers and symbol labels participate in both fitting and
native placement. Font/control environments reach separately measured descendants. The callback strips
lifecycle/event modifiers, rejects unsupported descendants and measures hidden widgets without showing them.
The GUI probe checks text bounds, inherited font size, padding counted once, constrained wrapping and line
limits, button chrome, every supported control kind, placement beside a native view, no dispatched actions,
and fallback for unsupported images or an unavailable renderer. Existing 21 HostingMeasurementTests still
pass headlessly. The complete contract runner passed all 824 framework tests and native backend, combination,
preview and text/hosting journeys with process exit 0. Logs: `/tmp/compositor-hosting-gui-probe.log` and
`/tmp/compositor-full-contract-hosting-renderer.log`. Sizing options, scroll geometry and broader SwiftUI/Qt
text-layout parity remain open; natural widget measurements alone do not prove all macOS layout behavior.

Hosting intrinsic sizing now follows the option contract: `.standardBounds` combines `.minSize`,
`.intrinsicContentSize` and `.maxSize`; the intrinsic option exposes ideal metrics, while `[]` leaves those
metrics unspecified without disabling explicit fitting measurements. A known dimension survives when the
other is unknown. Root changes and native intrinsic-size invalidation schedule the parent Auto Layout pass.
Four new tests reproduced failures before the fix; all 25 HostingMeasurementTests now pass. The GUI probe
also verifies that Auto Layout consumes Qt-measured text metrics and updates a child's frame after a longer
text root replaces it. The complete runner passed 828 framework tests and all native journeys with exit 0.
Logs: `/tmp/compositor-hosting-intrinsic-before.log`, `/tmp/compositor-hosting-intrinsic-after.log` and
`/tmp/compositor-full-contract-hosting-intrinsic.log`. The contract is documented in
[Apple's sizingOptions reference](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions).
At that checkpoint, minimum/maximum constraint generation and window size bounds remained unimplemented;
the later hosting-limit implementation is described below.

The Auto Layout solver now enforces required dimension inequalities on sizes not already determined by
required equalities. It intersects constant and sibling-dimension bounds before resolving centered/trailing
positions, handles layout guides and supports multiplier inequalities with the adjustable dimension on
either side. Three initial cases failed before the fix; all four LayoutDimensionBoundsTests now pass, along
with the 25 hosting and two reused-mask geometry checks. Per-push CI includes the bounds suite. The GUI
hosting probe constrains actual Qt-measured text metrics with minimum/maximum width anchors. The complete
runner passed 832 framework tests and all native journeys with exit 0. Logs:
`/tmp/compositor-layout-bounds-before.log`, `/tmp/compositor-layout-bounds-after.log` and
`/tmp/compositor-full-contract-layout-bounds.log`. Positional inequalities, lower-priority constraints and
infeasible intervals remain outside this propagation solver's supported cases. Hosting-generated minimum/maximum constraints were still pending at that checkpoint; they are implemented
below. Window bounds remain pending, so the entire sizing-options contract is not yet complete.

Hosting views now generate required minimum/maximum dimension constraints when participating in Auto
Layout, according to their enabled sizing options. The constraint pass runs before the containing view solves
its layout. Minimum and maximum proposals are forwarded through frames, padding, stacks and representables;
unknown or infinite maxima do not create finite caps. Generated constraints follow root updates and disappear
when the corresponding option is removed or the host returns to autoresizing. Two cases reproduced missing
constraints, and a third caught an unbounded representable being incorrectly capped at its ideal size. Infinite
responses are now accepted only on axes proposed as infinite; ordinary invalid-size fallback remains tested.
All 28 hosting tests passed in the full runner, alongside 835 total framework tests and all native journeys.
The GUI probe verifies generated width limits and their update using real Qt text metrics. Logs:
`/tmp/compositor-hosting-generated-bounds-before.log`, `/tmp/compositor-hosting-generated-bounds-after.log`,
`/tmp/compositor-hosting-unbounded-before.log` and `/tmp/compositor-full-contract-hosting-limits.log`.
Apple documents the maximum proposal in its
[maxSize reference](https://developer.apple.com/documentation/swiftui/nshostingsizingoptions/maxsize).
Window content minimum/maximum sizes were still pending at this checkpoint; they are implemented below.
Constraint priority/position coverage and scroll behavior remain open.

Compatibility windows now expose content minimum/maximum sizes and apply hosting-root measurements to
those bounds. Unknown axes retain explicit window limits; disabling hosting sizing restores the underlying
explicit limits. `setContentSize` clamps to the bounds while the explicit `setFrame(_:display:)` path bypasses
them; both keep the content view sized to the window. Replacing content detaches its window association,
and moving a root to another window clears the previous window's content and hosted limits. Four cases
reproduced failures before the fix; a fifth checks unknown-axis/explicit-limit restoration. All 33 hosting
tests passed in the complete 840-test run, followed by all native journeys, with process exit 0.
The GUI probe measures window bounds using actual Qt text metrics and verifies bounded content sizing,
clearing options and detachment. Logs: `/tmp/compositor-window-hosting-bounds-before.log`,
`/tmp/compositor-window-hosting-bounds-after.log` and `/tmp/compositor-full-contract-window-bounds.log`.
Apple documents content sizing enforcement in
[contentMinSize](https://developer.apple.com/documentation/appkit/nswindow/contentminsize).
These checks exercise the compatibility window model. Qt's existing floating panels use a separate session
path with fixed fit-content layouts; native window-manager forwarding of compatibility bounds is not verified
by this probe and remains an integration audit item.

Native AppKit scroll views now exchange viewport dimensions, rendered document dimensions and offsets with
Qt. Programmatic reveals reach the native scroll bars; manual offsets return to the clip view and survive
subsequent layer updates. Drawing a full document no longer expands or resets its viewport. Deferred reveals
wait for the first usable viewport, unflipped documents convert Qt's top-left coordinates, and hosted document
dimensions survive upstream fitting fallbacks. Short native tables fill their viewport while long tables retain
their full row height. Geometry callbacks update viewport state without dispatching document edits.
Four initial regression cases failed before the fix; all six NativeScrollGeometryTests pass and run in per-push
CI. The native preview journey verifies a short table fills its viewport, a selected bottom layer is revealed
in a 25-layer list, and manual scrolling survives a visibility update without changing pixels or Undo state.
The short-table assertion also failed before its sizing fix. The complete runner passed all 846 framework
tests and existing native journeys. Logs: `/tmp/compositor-native-scroll-before.log`,
`/tmp/compositor-native-scroll-after.log`, `/tmp/compositor-short-table-before.log` and
`/tmp/compositor-full-contract-native-scroll.log`. Broader scroll fitting, wheel/autoscroll and keyboard
interaction parity remain open.

The compatibility table now handles Up/Down selection when the upstream layer table forwards those keys to
its superclass. It sends selection notifications and reveals the selected row. Shift-arrows extend and contract
a range around its anchor, including switching from plain navigation; selection changes or removed rows reset
the remembered range. Single-selection tables and row boundaries remain valid, and modified, unrelated or
disabled keys continue through the responder chain. Five NativeTableKeyboardTests run in per-push CI.
Three initial cases failed before the handler (ten assertions); the actual native journey then exposed a missing
anchor when switching from plain arrows to Shift-arrows, reproduced by the expanded regression. A separate
removed-row regression caught an out-of-range anchor. Both fixes pass in the complete 851-test run.
The Qt preview journey uses platform keyboard dispatch with verified focus, including deferred focus restoration
after panel replacement. It verifies Up/Down selection, Shift extension/contraction without an Undo step, and
the upstream Move-tool override's exact one-pixel nudge of a visible layer. Existing native editing, mask,
scrolling, font and text journeys also passed; protected Mac trees remain unchanged. Logs:
`/tmp/compositor-table-keyboard-before.log`, `/tmp/compositor-table-keyboard-anchor-before.log`,
`/tmp/compositor-table-keyboard-removed-rows-before.log` and `/tmp/compositor-full-contract-table-keyboard-bounds.log`.
Type selection, page/home/end keys, disjoint-selection semantics and actual Mac comparison remain audit items;
this checkpoint establishes the exercised arrow paths rather than complete table keyboard parity.

System font factories now retain all nine weights, fixed-pitch traits and monospaced digits in native text
and SwiftUI lowering. Native text and Qt controls share one weight mapping; semibold is matched before bold,
and ultraLight/thin map in increasing weight order. Three SystemFontTests passed, including the actual
upstream mask badge's AppKit title font. The native FontTraits test checks all weights, PostScript semibold/
italic aliases, fixed pitch and the `tnum` feature. Its isolated old-parser regression fails as expected.
The Qt text smoke verifies regular/semibold glyph pixels differ and attributed/AppKit bounds match drawing.
It also retains its mixed-font, wrapping and color checks. Both native checks now run in the CI runner;
SystemFontTests is included in per-push CI.
The final exact runner passed locally without filters or skips: all 819 framework tests followed by native
editing/touch/Camera Raw and text journeys. The filtered contract passed 87 framework tests and the same native
checks. Logs: `/tmp/compositor-full-contract-system-fonts.log`,
`/tmp/compositor-system-font-shared-contract.log`, and `/tmp/compositor-font-traits-regression.log`.

Named AppKit fonts now retain the complete name through lowering; Qt resolves family/style aliases,
PostScript names and full names from installed faces' name tables. Custom SwiftUI text and picker faces use
the same resolver. The Swift scanner includes bundled Inter, and monospaced factory names can be reopened.
The app and native journeys share UI-font setup; native system-text measurement uses the selected application
font, following the bundled Inter preference in MACOS_UI_PARITY_RULES.md. Three added font checks passed;
the filtered runner passed 90 framework tests and all native journeys. The complete runner then passed
822 framework tests without filters/skips and all native color/editing/touch/Camera Raw/text checks.
Bundled Inter's PostScript/full names produce identical semibold pixels and bounds. The isolated old resolver
reports regular weight 400 instead of semibold 600. Logs: `/tmp/compositor-full-contract-named-fonts.log`,
`/tmp/compositor-named-font-bundled-contract.log`, and `/tmp/compositor-named-font-regression.log`.

The native preview journey now passes. Its retired Qt mask-thumbnail locator was replaced with the
current upstream AppKit table. A fresh masked cell laid out correctly, but a reused cell placed the mask
at x=83 instead of x=106: `removeFromSuperview` deactivated the cell's internal constraints. Detaching a
subtree now removes only constraints connecting it to outside views, retaining its internal view/guide
constraints for reuse. The reused-row regression failed before this fix and passes afterward.
`--preview-smoke` now verifies layer/folder mask Shift-click with exact Undo/Redo pixels, live unlinked mask
transforms, selected-pixel move/duplicate previews, Unicode text editing, font-picker changes, formatting
Undo/Redo and format-11 save/reopen. It is included in the CI contract runner, and NativeMaskGeometryTests
is included in per-push CI. The complete updated runner passed all 824 framework tests, native backend
checks, tool combinations, preview and text journeys with process exit 0. Full log:
`/tmp/compositor-full-contract-mask-reuse.log`. Focused logs: `/tmp/compositor-mask-reused-row.log`,
`/tmp/compositor-mask-reuse-fix.log`, and `/tmp/compositor-mask-reuse-preview.log`.

The new `PendingGradientTests` passed, including successful, busy, failed, changed-target and held-worker paths;
the targeted PendingGradientTests / ToolCombinationTests / UpstreamEditorTests run passed all 38 tests. The full
run also passed `TouchTargetsTests` and `ColourManagementTests`; neither proves physical touch behavior or full
color-management coverage. Logs for this session: `/tmp/compositor-full-tests.log` and
`/tmp/compositor-gradient-renderer-tests.log`.

The contract and weekly workflows now provision the pinned manifest dependencies and run `scripts/linux-contract-tests.sh`
inside the build environment. Neither job uses per-test skips; the local full
baseline above is unfiltered. This runner rebuilds Skia/ImageIO, requires the native Skia smoke to pass, installs
Camera Raw tables and invokes both the selected suites and `--combo-smoke`. Through `flatpak-builder --run` locally,
it passed **73 Swift Testing tests across 12 suites and 5 XCTest color/import tests, plus initial canvas history and all 6 native combination journeys**. The journeys cover selection/gradient,
selected-pixel movement, transform release, pending-gradient/brush sequencing, selected text/local Undo/live-text
restoration, and refused switches/recovery. They compare every pixel outside selections and use Qt's window-level
key path, including menu shortcuts. Existing `--transform-smoke` and `--dialog-smoke` also passed. The combo journey
exposed a disabled stale Undo accelerator; the host now validates menu state on ShortcutOverride before Qt matches
the key equivalent. It also proves bridge refusals produce diagnostics without status-bar error text.

The four legacy format-11 test mirrors have been removed. Their original upstream TypeToolTests, GroupTests,
LayerMaskTests and LayerAppearanceTests remain unchanged and passed **40 tests across 4 suites** after the
removal, followed by the native combination and touch journeys. The format generator rejects stale copies when
tip already owns format 11; the Linux image fixture helper remains. Log: `/tmp/compositor-original-format11-tests.log`.

The same combo smoke now delivers synthetic touchscreen events through a Qt window and tablet/mouse events
through the canvas. It verifies large transform reach after touch with Qt, system and application mouse synthesis;
pen input (including explicit pen metadata) and real mouse restore normal reach. Touch in a second window remains
usable after that window closes. Each check distinguishes resizing through a corner from the ordinary Move drag
and verifies Undo. The application owns one filter with no window captures, and handle drawing stays unchanged.
The old filter fails the corrected pen-restoration check; the fixed filter passes. These are synthetic-event checks,
not physical touchscreen/tablet or native Wayland verification. Logs: `/tmp/compositor-touch-contract.log` and
`/tmp/compositor-touch-regression-old.log`.

The contract runner also requires `test_imageio_color --require-heif`, which uses the production decode/encode
callbacks and independently encoded fixtures. It verifies PNG gray/gray-alpha conversion (including 16-bit),
linear RGB alpha, P3 alpha, genuinely untagged import, actual decoded sRGB profiles in PNG/JPEG/TIFF/WebP exports,
HEIF BT.709/linear/sRGB transfer at 8/10/12 bits, ICC precedence and HEIF export profile/alpha. This exposed and fixed
Qt rejecting the nonmonotonic BT.709 table, and gray-alpha PNG profiles being dropped after RGB expansion. The latter
uses CRC-checked PNG ICC recovery with a 4 MiB decompression limit, and converts gray independently of alpha.
Qt's behavior is visible in its [PNG reader](https://code.qt.io/cgit/qt/qtbase.git/tree/src/gui/image/qpnghandler.cpp?h=6.11)
and [QImage profile assignment](https://code.qt.io/cgit/qt/qtbase.git/tree/src/gui/image/qimage.cpp?h=6.11).
The Swift untagged test now uses an independently constructed PNG containing only IHDR/IDAT/IEND. Its marker-based
export checks alone remain weaker evidence than the native decoded-profile checks. Per-push CI includes both Swift
color/import suites. HDR/PQ/HLG, floating-point TIFF and actual Mac color comparison remain unverified.
Logs: `/tmp/compositor-color-contract.log` and `/tmp/compositor-combined-color-contract.log`.

Grayscale TIFFs with alpha now decode through libtiff, preserving source precision and alpha before ICC conversion.
The prior Qt path produced opaque RGB and discarded the gray profile; a second parser confirmed that the independent
fixture contains both. Four manually assembled 8/16-bit, little/big-endian fixtures pass, including a dark 16-bit value
that catches premature reduction. A 32-case independent libtiff-writer matrix covers Deflate compression with horizontal
prediction, strips/tiles (including edge tiles), contiguous/separate planes, associated/straight alpha, black/white
photometry, BigTIFF, orientation and DPI. A truncated strip is rejected without falling back to opaque Qt decoding.
The isolated old Qt path fails the same pixel check (1 instead of sRGB 13). Block allocations and embedded profile sizes
are bounded; allocation failure returns a decode error. CMake requires libtiff 4.5+ and both host builds link it explicitly.
The exact contract runner passed 71 framework tests and all native color/editing/touch/Camera Raw checks after this change.
Logs: `/tmp/compositor-gray-tiff-contract-final.log` and `/tmp/compositor-gray-tiff-regression.log`.

`NSHostingView.fittingSize` now measures explicit frames, padding, stack spacing and native intrinsic sizes.
The initial fifteen HostingMeasurementTests passed, including native root updates without recreating the view, missing intrinsic
axes supplied by a frame, empty stacks, restored lowering state, no dispatched actions, unknown-control fallback,
and the actual upstream FloatingPanelController's content dimensions and preserved top-left position. The six
upstream FloatingPanelTests also passed. Per-push CI now includes both suites; the exact runner invocation passed
66 Swift Testing tests and 5 XCTest tests, plus the native color, editing, touch and Camera Raw sizing checks.
Unknown SwiftUI text/control sizes still use the 320×240 fallback, so complete hosting parity remains open.
`NSViewRepresentable.sizeThatFits` now reaches the existing native view and coordinator in both natural measurement
and placement. Frame and fixed-size proposals are forwarded, including through padding; invalid sizes fall back to
intrinsic bounds. Six added checks cover that callback, coordinator/view reuse, latest updated native state,
fixed-size placement, invalid results, CameraRawSlider and preservation of already assigned lowering widths.
The native Qt journey now opens Camera Raw, checks the lowered temperature slider's 22-point height before/after
panel relayout, then cancels and compares every document pixel. The existing `--dialog-smoke` also passed separately;
it does not itself open Camera Raw. Constrained native-stack allocation is now covered above; renderer-backed text/control leaf measurement is implemented above; sizing options, scroll geometry and broader text-layout parity remain.
Logs: `/tmp/compositor-custom-sizing.log`, `/tmp/compositor-custom-sizing-contract.log`, and `/tmp/compositor-custom-sizing-dialog.log`.

A fresh hosted CI dependency build has not been executed. A run without the explicitly configured renderer
libraries failed pixel checks and the initial parallel combined run crashed. The configured sequential runs above
establish the current evidence; parallel stability remains unproven. The refreshed full-suite log is
`/tmp/compositor-full-contract-named-fonts.log`; runner and native journey logs are `/tmp/compositor-combo-contract.log`,
`/tmp/compositor-native-transform.log`, and `/tmp/compositor-native-dialog.log`.

The previous October 11 run had 835 tests (833 passed, 2 failed), including 40 duplicate format-11 tests.
The deduplicated run had **795 tests (793 passed, 2 failed)**. The first nine hosting measurement tests brought it to **804 tests (802 passed, 2 failed)**.
Six custom sizing checks brought it to **810 tests (808 passed, 2 failed)**. Retiring the Linux history deviation
brought that run to **810 tests (all passed)**. Six constrained hosting checks bring the current run to
**816 tests (all passed)**. Three system-font checks brought that run to **819 tests (all passed)**. Three named/bundled-font checks
brought the earlier checkpoint to 822 tests. Two mask/subtree constraint regressions brought the checkpoint to 824 tests; four intrinsic-size regressions brought it to 828 tests. Four dimension-bound regressions brought it to 832 tests. Three hosting-limit regressions brought it to 835 tests; five window-bound/ownership regressions brought it to 840 tests. Six native scroll regressions brought it to 846 tests; five table keyboard regressions brought it to 851 tests. Two new upstream folder import tests brought it to 853 tests. Three Layers panel width regressions now bring it to **856 tests (all passed)**.

The entries below are historical checkpoints, not verification of this worktree.

Run: `COMPOSITOR_SKIA_BRIDGE=<cmake-b>/libCompositorSkiaBridge.so COMPOSITOR_IMAGEIO_BACKEND=<cmake-b>/libCompositorQtImageIO.so QT_QPA_PLATFORM=offscreen swift test --no-parallel --skip CompositorCoreTests --skip tiledLayersDrawLikeOneImage`
(`tiledLayersDrawLikeOneImage` passes but takes ~110 s on the software path. Build the libraries with
`ninja CompositorSkiaBridge CompositorQtImageIO`.)

Progress: All 211 tests across 35 active upstream test suites pass cleanly on Linux (100% green).
All confirmed upstream test regressions and platform-incompatible UI tests are quarantined and documented in `linux/UPSTREAM_TEST_EXCLUSIONS.md`.

Failing tests: None. All 211 tests in CompositorUpstreamTests pass.


## 2026-09-21 re-check: FilterTests and LayerAppearanceTests

Both files are compiled again (file-level exclusion removed). 7 of their 9 tests pass; the 2 that fail are stale
upstream tests, skipped individually (see `linux/UPSTREAM_TEST_EXCLUSIONS.md`):
`--skip gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep --skip moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo`.

## 2026-09-21 re-check: TiledLayerTests and DistortTests

Both files compile again. 5 of 9 tests pass (`distortedLayerIsTrimmedToItsVisiblePixels`, `tiledLayersDrawLikeOneImage` x3,
`paintingAtTheLayersEdgeDoesNotChangeIt` x2, `paintingAScaledDownLayersMaskDoesNotShiftItsPixels`). Skip per test:
`--skip perspectiveMappingHitsTheCorners --skip distortingWarpsTheLayerIntoTheShape`.
Distort's two are stale upstream tests. The three Tiled ones are real Linux fidelity gaps (clip rasterisation and piece
resampling), open work, not upstream problems.

Correction: `paintingAScaledDownLayerDoesNotShiftItsPixels` is not a Skia resampling gap. The AppKit shim's cached-display bitmap
(`bitmapImageRepForCachingDisplay`, `NSImage(size:flipped:drawingHandler:)`) was a top-left-origin context with an emulated
flip, so images drew mirrored inside each drawn rect, and pieces disagreed with the whole layer. Those contexts are now real
bottom-left Core Graphics bitmaps (flipped views flip them back) and the test passes. Only the two 25° tile-seam tests remain
skipped in TiledLayerTests (`translucentStrokesDrawLikeOneImage`, `maskStrokesDrawLikeOneMask`).

Fixed: the 25° tile-seam failures (`TiledLayerTests`, now fully passing, 6/6, ~7 min in a debug build). Skia rasterizes a
hard-edged clip under a rotation differently depending on what is already clipped (it trims the edge to the current clip,
which shifts fixed-point rounding at pixel-centre ties), so upstream's clear-then-draw-inside-the-clip pattern drew a
few edge pixels twice. The bridge now rasterizes such clips once, against the whole surface, and applies them as a
region, so a path has one answer as in Core Graphics (`HardClipConsistencyTests` locks it in). The earlier
"Skia vs Core Graphics rasterization" wording was only half right: the fill/clip/image-draw primitives agree; the
ancestor-dependence was the cause.

## 2026-09-22 current baseline (post upstream 1.1.8 -> 1.2.2 merge, CompositorCore retirement)

Run: `COMPOSITOR_SKIA_BRIDGE=<cmake-b>/libCompositorSkiaBridge.so COMPOSITOR_IMAGEIO_BACKEND=<cmake-b>/libCompositorQtImageIO.so
QT_QPA_PLATFORM=offscreen swift test --no-parallel --skip CompatTests --skip LinuxOverrideTests --skip tiledLayersDrawLikeOneImage
--skip gaussianBlurSoftensAHardEdge --skip moveToolNumberKeysSetSelectedLayersOpacity --skip perspectiveMappingHitsTheCorners
--skip distortingWarpsTheLayerIntoTheShape` (the test-target name is now `CompositorUpstreamTests`, not `CompositorCoreTests`
— that fork target no longer exists).

**260 of 260 run tests pass** (up from the 211/222 baselines above; 1.2.0-1.2.2 added PSD/RAW import, Outer Glow,
Invert/Black&White/Color Balance, and the full Photoshop blend-mode set, each with its own tests). Only 5 stale-upstream-test
skips remain, all previously verified as genuine upstream test bugs (not Linux fidelity gaps), each documented at its
own re-check above:
- `gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep`
- `moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo`
- `perspectiveMappingHitsTheCornersAndTwistedShapesAreRefused`
- `distortingWarpsTheLayerIntoTheShapeAsOneUndoStep`
- `tiledLayersDrawLikeOneImage` (passes; skipped only for its ~110s runtime on the software path)

`translucentStrokesDrawLikeOneImage` and `maskStrokesDrawLikeOneMask` are NOT in this list — they were fixed by the
hard-clip region change and pass (confirmed by running `TiledLayerTests` alone, 6/6, ~8 min). A stale `--skip` for both
had crept back into ad hoc test invocations after that fix; this entry is the correction.

## 2026-09-23 re-check, after the upstream v1.2.4-1.2.6 merge

Same invocation as above. **302 of 306 run tests pass.** 4 new failures, both real, neither related to the merge's
own Swift changes (CIBloom, NSPasteboard.setString):
- `InnerGlowTests`'s 3 rendering tests — InnerGlow (an upstream v1.2.x layer effect) has no Linux rendering pass
  yet. Needs its own `Sources/Overrides/MetalLayerEffects.swift` addition. Open.
- `BrushTests.bracketKeysReachTheBrushWhereverFocusIsExceptTextFields` — drives `NSHostingView<LayersPanel>`'s
  table lookup, the same `NSTableView`/Objective-C-runtime pattern already excluded for `LayerTests.swift` in
  `linux/UPSTREAM_TEST_EXCLUSIONS.md`, just surfacing in a different, not-yet-excluded file. Needs triage:
  either exclude this one test the same way, or confirm it's newly reachable and genuinely fixable.

**Resolved 2026-09-23, after the upstream `f67b46b` merge: full `swift test` green — 340 Swift Testing + 96 XCTest,
0 failures** (default parallel run, bridge + ImageIO backend set):
- InnerGlow: added to `CompositorEffectsParams` and all three C tiers (CPU, OpenCV, Vulkan shader passes 15-18),
  same blur + keep-inside + compose order as upstream's Metal renderer; `LayerEffectsBackendTests` checks it.
- `bracketKeys…`: compat `NSHostingView` now hosts a `HostedNativeContent` found anywhere in its tree, and the
  `NativeLayerList` override provides `LayerTableView` — upstream's own canvas key monitor then does the rest.
- `TransformTests.autoSelect…` (order-dependent): `ToolDefaults` skips UserDefaults only when
  `XCTestConfigurationFilePath` is set, as Xcode's runner does; `_Testing_XCTestEnvironment` sets it for the
  upstream test process, so a test's toggle no longer leaks into later tests.
- `UpstreamEditorTests` (Linux-owned, unmodified): the bridge's `new` adds "Layer 1" only when asked (`emptyLayer`).
- `TitleBarDragTests.swift`: runs and passes. `Compositor/UI/ProjectTabs.swift` is compiled unmodified (symlink;
  the Linux copy is gone) on compat `NSScrollView`/`NSClipView` and an `NSHostingView` that lays out and hosts its
  `NSViewRepresentable`s (`HostedLayout`). Full suite: 342 Swift Testing + 96 XCTest, 0 failures.

Also confirmed (see README's Known Issues correction): `AdjustmentLayerTests`/`ProjectTests` blank-render/heap-
corruption reports from earlier this session were a missing-`COMPOSITOR_SKIA_BRIDGE` invocation mistake, not a
real bug — they pass clean (19/19, no crash) under this doc's documented invocation, with or without
`--no-parallel`. `CIFilter`'s `supportedNames` allowlist was also missing `"CIBloom"` (silently fell back to the
unmodified source image instead of failing loudly), and the compat `CIBloom` implementation didn't spread alpha
past the source's opaque region the way real `CIBloom`'s glow does — both fixed, `FinishingFilterTests` now 5/5.

## 2026-10-10: upstream 1.4.9 resources

Upstream 1.4.9 reads `CameraRawTables.bin` through `Bundle.main`, which on Linux is the directory holding the
executable. Before `swift test`, copy it next to the test binary:
`install -m644 Compositor/Resources/CameraRawTables.bin .build/x86_64-unknown-linux-gnu/debug/` (the Flatpak manifest
and `scripts/run-compositor.sh` install it beside the app binary). Without it, `CameraRawTests` fails 15 of 28 tests.

**2026-10-10 (compat completion, Phase B):** 13 upstream test files run unchanged again — `CanvasEntryTests`,
`ColorPickerTests`, `GuideTests`, `LevelsTests`, `CanvasThumbnailTests`, `NavigatorTests`, `SelectionTests`,
`TypeToolTests`, `GroupTests`, `LayerMaskTests`, `LayerAppearanceTests`, `BlendShortcutTests`,
`TransformPressTests` — after `NSWindow.screen/isMovable/isSheet/sheetParent`, window close/move/resize
notifications, `NSScreen.visibleFrame` and `NSPasteboard.withUniqueName`. The single-test skips for
`FilterTests`, `DistortTests` and `LayerAppearanceTests` above are no longer needed (they pass); only the two
`HistoryTests` cases stay skipped (`.github/workflows/ci-build.yml`). Remaining exclusions: see
`linux/UPSTREAM_TEST_EXCLUSIONS.md`.
