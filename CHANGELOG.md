# Changelog

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