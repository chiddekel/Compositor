# Local compatibility monitor

Run the dashboard from a Codex terminal or your regular shell:

```bash
python3 scripts/watch-compat.py
```

It uses Python's standard library and refreshes local state every second. The
Overview shows the current Git branch, commit and changed files alongside recorded
verification evidence. Evidence is labeled historical: editing a file or finding
an old successful report does not count as a new passing test.
Native motion comparisons and Swift failures beyond golden differences are shown
separately; a missing failure count appears as `?`.
It reads `.build/evidence/compatibility-verification-summary.json` when present,
falling back to the older Dither verification checkpoint.

The Patches tab previews tracked diffs and new text files. The Logs tab follows
the latest logs in `.build/evidence/` and `.build/compat-monitor/`. Checks run as
child processes and show their actual exit status; output is saved under
`.build/compat-monitor/`. Descendants in each check's process group are stopped
before it finishes, including children that close their output and ignore SIGTERM.
The dashboard itself does not edit source, commit, push,
replace golden images or apply fixes. Custom commands perform the actions you
explicitly configure.

| Key | Action |
| --- | --- |
| `Tab`, `1`–`5` | Switch views |
| `j` / `k`, arrows | Select a changed file, log or check |
| `Page Up` / `Page Down` | Scroll the current view |
| `f` | Return to the live end of the log |
| `Enter` in Checks | Run the selected check |
| `r` | Refresh local state and connected CI |
| `c` | Connect the CI view using `gh` |
| `x` | Cancel the check started by this dashboard; press again to force-stop it |
| `q`, `Esc`, `Ctrl-C` | Quit, cancelling any check started here |

The built-in `hygiene` check checks staged and unstaged whitespace errors.
`dashboard` runs the monitor tests. `upstream` reads the current upstream main
commit with `git ls-remote`; it requires network access. To enable the native
sampling check, select the bridge library explicitly:

```bash
python3 scripts/watch-compat.py --library .build/linux-contract-native/libCompositorSkiaBridge.so
```

Add project-specific commands with repeated `--check` options. Commands are
parsed into arguments without a shell; use `env` for environment variables and
a script file for pipelines or multiple commands.

```bash
python3 scripts/watch-compat.py \
  --check 'source=python3 tests/test_linux_source_coverage.py .build/package-description.json' \
  --log .build/my-build.log
```

GitHub polling is optional and uses the existing read-only workflow dashboard
client. It requires `gh` authentication and refreshes every 30 seconds:

```bash
python3 scripts/watch-compat.py --ci --repo chiddekel/Compositor --branch GNU_Linux
```

For Codex tool output, pipes or automation, use a single text or JSON snapshot:

```bash
python3 scripts/watch-compat.py --once
python3 scripts/watch-compat.py --json
python3 scripts/watch-compat.py --run-check hygiene --json
```

`--run-check` waits for the explicitly selected check and exits with status 1 if
it fails or is cancelled. Status 2 indicates a monitoring error, such as an
unreadable repository. Non-interactive terminals otherwise use continuous text
output; `--plain` selects it explicitly. Set `NO_COLOR=1` to disable colors.
If Codex exports `NO_COLOR`, enable the color theme with
`env -u NO_COLOR TERM=xterm-256color python3 scripts/watch-compat.py` in its
interactive terminal.
