# Changelog

## Unreleased

### Fixed — test isolation

- **The test suites wrote into the real `~/.minimax`.** The hook's durable log lives under
  `${MINIMAX_DATA_DIR:-$HOME/.minimax}`, and of the six places `tests/hook-run.sh` ran it,
  only the two durable-log cases passed their own `MINIMAX_DATA_DIR`; the other four — the
  stand-in pane shell's heredoc, plus three direct call sites — and `tests/e2e/run.sh` ran it
  against the developer's real `$HOME`. Measured on this repo's own machine: **48 of the 54
  fires in a real user's `hook.log` belonged to the test suite**, along with all 21 refusals
  in the file. That file is the only record of what a real session's hook did, and issue #126
  is decided by reading it — so the suite was destroying the evidence it exists to produce.
  Both suites now export `MINIMAX_DATA_DIR` once, and a new case fails if that isolation is
  ever removed.

## 0.6.1 — one watcher per pane, and a doc that stopped lying

A patch release. No new capability; two fixes, one of them behavioural.

### Fixed

- **The watcher spawn race (#120, #121).** `ensure_watcher` decided "no watcher" with
  `pgrep` and *then* spawned, so two hooks landing in that window both spawned. The
  e2e suite caught it as exactly-one-watcher failures on 2 of 10 runs. The spawn window
  is now claimed with `mkdir`, so only one caller can be inside it; `pgrep` still
  decides whether a watcher is already running, including one started by hand. The
  claim is released as soon as the child is visible or has exited, so a dead watcher
  can still be replaced — and a loser does not take a claim that has already
  disappeared.
- **Registration reads raced their own effect (#120, #121).** A pane can be visible
  before `report-agent` returns, and `agent_not_found` between a prompt and its
  `send-keys` is that same flap. Those reads now poll for up to 10 s.
  `agent_not_ready` is still returned immediately.

### Fixed — documentation

- **`CLAUDE.md` said a hook command must be anchored on `$CLAUDE_PLUGIN_ROOT` "which
  does expand".** It does not, and that sentence is why the hook shipped broken in the
  first place: an installed, enabled, loaded plugin that silently registered nothing.
  It now teaches the braced `${PLUGIN_ROOT}`, states the mechanism, and points out
  that `HERDR_PLUGIN_ROOT` — documented three lines away — obeys the *opposite* rule.

### Unchanged

The scope from 0.6.0 still stands exactly as written: sessions started by typing `mcode`
into an existing shell register; a pane created by `herdr pane run mcode` is **not yet
proven** and its cause is still open (issue #126). This release does not claim to close
it.

## 0.6.0 — a hand-started `mcode` registers itself

### What this release is

Until now, only panes this plugin *launched* were visible to Herdr. A `mcode` you
started yourself — the ordinary way you use it — was invisible: no listing, no
status, nothing. `mcode` now registers its own pane, once, at session start.

### Added

- **`install-hook` action.** Copies the mcode-side plugin into
  `~/.minimax/plugins/herdr-bootstrap` and **enables** it. Enabling is the part
  that matters: an installed-but-disabled plugin is listed by
  `mcode plugin list` and never once fires, which reads exactly like mcode being
  broken. The install **fails loudly** rather than reporting a half-install.
- **`uninstall-hook` action.** Removes the plugin via `mcode plugin remove`,
  guarded by a content check that refuses a non-empty directory at that path
  unless it carries a plugin manifest — so a wrong-path delete fails closed.
- **A durable hook log** at `~/.minimax/state/herdr-bootstrap/hook.log`: one line
  per step plus the exit code, trimmed to its tail at 64 KiB. Herdr's own
  diagnostics keep the hook's stderr, but an interactive TUI does not surface
  it, so a run that registers nothing previously left no evidence at all. The
  exit-code line is what separates *ran and refused* from *was killed* from
  *never started*.

### Fixed

- The hook command referenced `$CLAUDE_PLUGIN_ROOT` unbraced. Herdr's own
  manifest `command` arrays do not expand `${...}`, and mcode text-substitutes
  only the **braced** literal — so the path resolved to nothing and the hook
  died at `exit 127` before running. It now uses `${PLUGIN_ROOT}`, verified
  substituted to the real content-addressed plugin directory at exec time.
- macOS only: `read -t 0.5` is rejected outright by bash 3.2, leaving the
  variable empty with no error. The prefilter quietly stopped filtering on
  exactly the platform everything else was measured on, and CI runs Linux, so
  the gate could not see it.

### Scope — what is proven, and what is not

**Proven on a real machine** (mcode 0.6.2, Herdr 0.9.3, macOS arm64): six
sessions fired the hook and **six panes registered correctly**, each proved by
process ancestry rather than by cwd, each reported with `--source
herdr:minimax-code`, each exiting 0. Those were sessions started by typing
`mcode` into an existing shell — which is what people actually do.

**Not yet proven:** a pane created by `herdr pane run mcode`, with no
interactive shell. In one real run a session started that way did not fire the
hook while six others in the same window did. The cause is still open; see
below. Do not read this release as covering that path.

**Also open:** one further real-machine session missed the hook for reasons that
are *not* the caveat below — see the caveat, which is a genuine limitation but
is not an explanation for that miss.

### Caveats

- **`SessionStart` is one-shot.** mcode resolves plugin hooks per session, and
  the `SessionStart` event is not replayed. **A `mcode` session that was already
  running when you ran `install-hook` will not register.** Restart it, or report
  it by hand with `herdr pane report-agent`, once you have enabled the plugin.
  This is mcode's behaviour, not a setting.
- Until `install-hook` runs, the plugin is **inert**. Nothing changes for
  existing sessions at upgrade time; run the action, then restart `mcode`.