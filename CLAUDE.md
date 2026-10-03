# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A [Herdr](https://herdr.dev) community plugin (herdr-plugin.toml workflow) that launches
[MiniMax Code](https://github.com/MiniMax-AI) (`mcode`) in a pane. Platform: `linux`, `macos`
only — the entrypoint is bash. Requires herdr `>= 0.9.3`.

Two source files only:

- `herdr-plugin.toml` — the whole contract. Actions/event hooks declare an argv command.
- `bin/mcode-plugin.sh` — the entrypoint, dispatching on `$1`.

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
not `herdr agent start` (`--kind` is a closed 23-value enum with no mcode member, so that
path is unreachable). Detection is a separate upstream epic.

## Commands

```bash
./tests/run.sh                       # the suite — six cases, exits 0 only if all pass
./tests/run.sh case-4                # one case
./tests/run.sh --list                # case names
bash -n bin/mcode-plugin.sh          # syntax check
herdr plugin link .                  # load this checkout into herdr (mutates the registry)
herdr plugin log list --plugin jaaacki.minimax-code
herdr plugin action invoke jaaacki.minimax-code.minimax-code-start
```

No test framework and no `bats` — plain bash. `HERDR_BIN_PATH` is pointed at `tests/fake-herdr`,
a stub that logs every argv invocation and serves canned JSON, which is the only way to assert
on the *sequence* of calls a multiplexer plugin makes. `shellcheck` is not installed.

CI runs `jq --version`, `bash -n` and `./tests/run.sh` on `ubuntu-latest` and `macos-latest`.

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

## Ownership

`PLAN.md` and `HANDOFF.md` are architect-only. The epic's file-ownership table is strict —
no two members touch the same file. Read `PLAN.md` §5 before editing anything; several
decisions there are locked and must not be relitigated in an issue or PR.

## Git flow

Follow the repo's issue → worktree → PR → `dev` → `main` flow (see global CLAUDE.md). Epic #1
tracks the v0.2.0 work; `dev` is the integration branch and `main` is released from it. PRs must
be green on both CI legs before merge.

Worktrees are created **only** via `flock worktree add --repo <path> --issue <n>` — never by hand,
because cleanup trusts the recorded ownership. **It branches from `main`, not `dev`** — members
have hit this and reviewed a stale tree before noticing. Always
`git fetch origin && git reset --hard origin/dev` before reviewing or testing anything.
