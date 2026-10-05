# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A [Herdr](https://herdr.dev) community plugin (herdr-plugin.toml workflow) that launches
[MiniMax Code](https://github.com/MiniMax-AI) (`mcode`) in a pane. Platform: `linux`, `macos`
only — the entrypoint is bash. Requires herdr `>= 0.9.3`.

Three entrypoints plus the manifest. Only `bin/mcode-plugin.sh` is on the launch path. The
other two are user-facing but by different routes — the README names the watcher, the
release notes name the session registrar — which is why the release tarball must ship all
three:

- `herdr-plugin.toml` — the whole contract. Actions/event hooks declare an argv command.
- `bin/mcode-plugin.sh` — the launcher, dispatching on `$1`. Invoked by the manifest action.
- `bin/mcode-watch.sh` — the state watcher. The README tells users to run this by hand.
- `bin/mcode-session.sh` — the session registrar, named in the release notes.

`agent-detection/minimax-code.toml` ships in the tarball too, and ships **inert**: nothing
installs it into herdr's agent-detection directory, so it cannot change a user's detection.
Shipping it and activating it are separate acts. It exists because `tests/agent-detection-run.sh`,
which also ships, resolves it.

`HANDOFF.md` is verified research (herdr internals, manifest schema, injected env, exact CLI
surface) — read it before re-deriving any herdr behavior. `PLAN.md` is the current epic's plan.

## Architecture

**The entire herdr CLI is the plugin API.** No SDK, no restricted command set. Anything
runnable as `herdr ...` is available to the entrypoint. The entrypoint shells out to
`$HERDR` (`${HERDR_BIN_PATH:-herdr}`) — never a bare `herdr` literal.

Manifest → entrypoint contract: every `command` array ends with the entrypoint and a
subcommand, so adding an action means adding a `cmd_*` branch. Invoked via
`herdr plugin action invoke jaaacki.minimax-code.<action>`.

MiniMax Code is **not detectable by herdr** — no `mcode.toml` screen manifest exists (23
bundled, none for MiniMax). That is why this is a plain launcher: `pane split` + `pane run`,
not `herdr agent start` (`--kind` is a closed 24-value enum with no mcode member, so that
path is unreachable). Detection is a separate upstream epic. A *launched* pane is still
registered as a herdr agent via `pane report-agent`; detection and registration are different
things, and only the second is ours to do.

## Commands

```bash
./tests/run.sh                       # the launcher suite — exits 0 only if all pass
./tests/run.sh case-4                # one case
./tests/run.sh --list                # case names
./tests/watch-run.sh                 # the state-watcher's suite
bash -n bin/mcode-plugin.sh          # syntax check
bash -n bin/mcode-watch.sh           # syntax check for the watcher
herdr plugin link .                  # load this checkout into herdr (mutates the registry)
herdr plugin log list --plugin jaaacki.minimax-code
herdr plugin action invoke jaaacki.minimax-code.minimax-code-start
```

No test framework and no `bats` — plain bash. `HERDR_BIN_PATH` is pointed at `tests/fake-herdr`,
a stub that logs every argv invocation and serves canned JSON, which is the only way to assert
on the *sequence* of calls a multiplexer plugin makes. `shellcheck` is not installed.

CI runs `jq --version`, `bash -n` and **every** suite on `ubuntu-latest` and `macos-latest`.
See the CI-glob gotcha below for how the suite list is built.

### CI also runs a real-herdr end-to-end suite

A second job installs herdr on both runners and drives the real action — `tests/e2e/run.sh`
is **not** matched by the `tests/*run.sh` glob, because bash's `*` does not cross `/`, and
that is correct rather than an accident. Widening the glob to `tests/**/run.sh` would run it
in the stub job, where herdr is absent, and it would exit non-zero on every push. That job
proves the suite *refuses* to skip when herdr is missing, so it cannot report coverage it
never had. It is what established that a launched pane appears in `herdr agent list`, and
that it is addressable both by pane id (`herdr agent get <pane-id>`) and by name
(`herdr agent get mcode`, installed by `agent rename`).

Herdr accepts a resume command for us, and a restarted herdr re-runs it *if it kept it*. **Do not
upgrade that to "works", and do not drop the "if it kept it".** Herdr keeps no session id for us
(no `agent_session`), and it can accept a resume report and still not store it — that is the #99
failure mode, and the launch line says so itself: `resume command accepted by herdr (exit 0);
after a restart herdr re-runs … in this pane if it kept it (not verified here, see #99)`. Match
that line's strength, and do not quote an older one. Proof is by hand in an isolated named
session (#85/#94); the e2e case is **opt-in** (`MCODE_E2E_RESUME=1`) because it is intermittent,
about one run in three, cause unknown. Never read a green suite as evidence for this feature.

To check the current state, read the session's **live** `session.json` — never the
`session-snapshots/*.json` history, which can still show a resume the live state no longer has.
The path comes from `herdr session list`, so it is right for a named session too; `agent get` and
`pane get` carry no `agent_resume` at all on 0.9.3.

Three caveats, all measured: **a client must attach**, or while the terminal area is `0x0`
herdr has no pane to resume into and panes come back as plain shells with nothing logged; two
`mcode` panes in one cwd restore only one, because herdr keys resume candidates on (source,
agent, cwd, argv) and keeps the first; and `mcode --continue` resolves by cwd, so a restore with
no session printing "No saved Session exists in the current workspace" is mcode answering, not
a failed restore.

### How the tests reach the real response shape

`tests/fixtures/*.json` are **captured** herdr 0.9.3 responses, with command, version and date
recorded in `tests/fixtures/README.md`. The stub always serves the real `pane-split.json` — the
new pane id is the one value that must never be faked — and the suite derives its expectation
by querying that fixture with `jq`. For `pane get` / `pane current` a test knob wins over the
fixture, and the bypass is announced on stderr. No knob is ever silently overridden.

## Gotchas

- **herdr does NOT expand shell variables in a manifest `command` array.** `HERDR_PLUGIN_ROOT`
  is genuinely present in the action's environment, but
  `command = ["${HERDR_PLUGIN_ROOT}/bin/mcode-plugin.sh", "start"]` never runs — the string has a
  `/` in it, so the OS hunts for a literal directory named `${HERDR_PLUGIN_ROOT}` and returns
  `ENOENT`. The working form is a shell wrapper: `["/bin/sh", "-c", "\"$HERDR_PLUGIN_ROOT/bin/mcode-plugin.sh\" start"]`.
  Note TOML escaping — inner quotes are `\"`, and `\$` is invalid TOML that fails identically.
- **A manifest `command` resolves against the invoking pane's cwd, not the plugin root.** A
  relative `bin/mcode-plugin.sh` works from the plugin root and fails from anywhere else. Do not
  "fix" the wrapper above into a relative path.
- **The new pane id is at `.result.pane.pane_id`** — verified against a captured response, not
  guessed. Two traps sit next to it: `result.type` is **`pane_info`**, not `pane_split` (the
  split response is shaped like `pane get`, so never branch on `result.type`), and
  `.result.pane_id` yields **`null`**. Either trap produces a launch that fails silently.
- **`herdr plugin link .` mutates the owner's herdr registry.** It is the only way to get herdr
  to accept the manifest — `herdr plugin` has **no** `validate` subcommand. `plugin link` also
  does **not** run `[[build]]`.
- **Env var is `HERDR_PLUGIN_ROOT`, not `HERDR_PLUGIN_DIR`.** `HERDR_PLUGIN_DIR` does not exist.
  This bug shipped once in the scaffold and was fixed; do not reintroduce it. It is mentioned
  by name in `PLAN.md`, `HANDOFF.md` and this file on purpose — that is the historical record.
- **`set -euo pipefail` swallows diagnostics on failure.** `out=$("$HERDR" pane split ...)`
  aborts before any stderr message prints. Use `if ! out=$(...); then` so custom errors run.
- **Never type a command into an unidentified pane.** If the new pane id cannot be extracted,
  exit non-zero *before* calling `pane run`. An earlier "tolerant" extractor that tried several
  candidate paths was rejected in review: a wide net is not a safe net, because a decoy field
  matches *something* and the guard's job gets handed to a guess.
- `pane run` passes text plus Enter, so the launch target does not need a TTY handshake. The
  split uses `--no-focus` deliberately: the action is registered for the `pane` context, so
  stealing focus would send the user's in-flight keystrokes to the brand-new pane.
- Only the 22 events in `PLUGIN_HOOK_EVENT_KINDS` are hookable (`HANDOFF.md` §5). Unknown
  names are non-fatal but warn in `herdr plugin list --json`. The docs site's event list is
  not authoritative — the herdr source is.
- Pass the **absolute** `mcode` path (from `command -v`) to `pane run`, so the launch does not
  depend on the target pane's `PATH`.
- **`herdr agent rename` makes an agent name-addressable for `get`/`read`/`wait` but cannot make
  it *active*.** After registering and renaming, those three work by name, while
  `agent prompt` and `agent send-keys` both return
  `{"code":"agent_not_ready","message":"agent <name> is not an active named agent"}`. Only
  `herdr agent start` can activate, and its `--kind` enum has no `minimax-code`. Do not read
  "the agent is listed" as "the agent is usable" — and do not try to fix this by renaming
  harder.
- **`pane report-agent` must precede `pane report-agent-session` whenever a `resume_argv` is
  attached.** The other order fails with
  `{"code":"resume_not_accepted","message":"resume_argv requires the reporter to hold the pane;
  report its state with pane.report_agent first"}`. It is an ordering requirement, not a
  capability limit — the identical call succeeds once `report-agent` has run.
- **`pane release-agent` DELETES a self-reported registration; it does not hand authority back.**
  Measured: present in `herdr agent list`, then after `release-agent` it is gone and
  `herdr agent get <name>` returns `agent_not_found`. It does *not* revert to screen-detected
  state, because there is none to revert to. **A self-reporting integration must not call
  `release-agent`** expecting the agent to survive as a detected one. The watcher calls it
  deliberately, on the principle that a stale registration is worse than no registration —
  but know what it costs before copying that.
- **CI discovers test suites by glob (`suites=(tests/*run.sh)`), not by name.** A suite whose
  filename does not match that glob is committed but never executed, and nothing fails. This
  already happened once: `tests/watch-run.sh` sat unrun for a whole PR because `ci.yml` named
  `./tests/run.sh`. Name a new suite `tests/<something>run.sh`, and check the glob's exit-1
  path still fires if you change it.
- **`pane report-agent` / `release-agent` match `--source` exactly, and a mismatch fails
  SILENTLY.** Measured on one pane:
  ```
  register --source herdr:minimax-code → agent list count 1
  release  --source herdr:minimax-code → count 0   (match: works)
  register --source herdr:minimax-code → count 1
  release  --source minimax-code       → count 1   (mismatch: no error, no release)
  ```
  No error, no warning — the call just does nothing, so a stale registration outlives the
  thing that created it. **Always pass the same `--source` you registered with.** All three
  reporters now declare `herdr:minimax-code` — `bin/mcode-plugin.sh`,
  `bin/mcode-session.sh` and `bin/mcode-watch.sh` — and `tests/source-run.sh` fails CI if
  they ever disagree again, so this cannot silently regress. A "did my release actually
  happen" check is `herdr agent list | grep -c <pane-id>`, because the call itself will not
  tell you.
- **`bin/mcode-watch.sh` deliberately does not call `release-agent` at all.** It used to, on
  every exit path, and that was wrong: the call DELETES the registration rather than handing
  authority back, so panes vanished from `herdr agent list` as the watcher exited. There is no
  `mcode` screen manifest to fall back to, so nothing would resume even if it worked;
  registration is pane-scoped and herdr drops it with the pane. If you ever add the call
  back, it must use the same `--source` the pane was registered with — see the silent-mismatch
  measurement above.
- **A self-reported state is only as fresh as the last tick, and a dead watcher never resets
  it.** `mcode-watch.sh:338` — `if [ "$state" != "$last" ]` — reports on *transitions* only,
  and the pane-gone path at `:325-330` reports nothing, so Herdr keeps the last value
  indefinitely: a pane can read `working` long after the turn ended. The watcher is `nohup`'d
  detached with no supervisor, so nothing notices. Check with
  `pgrep -f "mcode-watch.sh <PANE_ID>"`, re-sync with `bin/mcode-watch.sh <PANE_ID>` (it
  classifies once and reports, so the fix is immediate). *Those line numbers were stale once
  already, when #83 and #91 grew the header — which is why the code is quoted beside them.
  Grep the code, not the number.*
- **Any `minimax-code` pane gets a watcher, not just the ones the action launched** (#84). Herdr
  fires the `pane.agent_status_changed` hook, `bin/mcode-plugin.sh ensure-watcher` starts a
  watcher for the pane if none is running, and a flock-adopted pane is included because
  adoption registers the same label. One watcher per pane, decided by an anchored
  `pgrep -f "mcode-watch.sh <PANE_ID>"` rather than a lock file — a lock cannot see a watcher
  that was started by hand or by an older build, which would leave two watchers on one pane.
- **An `agent_session` on one of our panes may not be ours.** Where `codex` ran in a pane
  earlier, Herdr keeps the *codex* session, inherited from whatever ran there rather than stored
  by this plugin — a plugin-launched pane is a fresh split and carries none, so **read
  `agent_session.source` before concluding the plugin stored anything.** Such a pane has no
  `agent_resume`, so on restore Herdr falls back to `agent_session` (`restore.rs:824`, v0.9.3)
  and would type `codex resume <id>` into a pane now running `mcode`. Tracked in #87.
- **Herdr's own Claude integration self-reports session *identity*, never *state*.** Its state
  is screen-detected — `herdr agent explain` names the rule (`osc_title_working`, region
  `osc_title`) — and `explain` refuses outright for a self-reported agent. So there is nothing
  to copy from it for state parity, and no expectation that a registered agent can reach
  Claude's state accuracy without a screen manifest.

## Ownership

`PLAN.md` and `HANDOFF.md` are architect-only. The epic's file-ownership table is strict —
no two members touch the same file. Read `PLAN.md` §5 before editing anything; several
decisions there are locked and must not be relitigated in an issue or PR.

## Git flow

Follow the repo's issue → worktree → PR → `dev` → `main` flow (see global CLAUDE.md). `dev` is
the integration branch and `main` is released from it by a `dev` → `main` merge commit (never a
squash, or the next release conflicts on the version line), then a `v*` tag that runs
`release.yml`. PRs must be green on both CI legs before merge. Recent epics: #88 (v0.5.0).

Worktrees are plain `git worktree add <path> -b <branch> origin/dev` — always off
`origin/dev`, never `main`. (Flock v2 has no worktree verb; the old
`flock worktree add --repo <path> --issue <n>` is gone, and it branched from `main`.) Run
`git fetch origin` before creating one, and `git reset --hard origin/dev` before reviewing
or testing anything.
