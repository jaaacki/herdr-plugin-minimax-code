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
bash -n bin/mcode-plugin.sh          # syntax check — the only lint here
./tests/run.sh                       # test suite (once Issue C lands)
herdr plugin link .                  # load this checkout into herdr
herdr plugin log list --plugin jaaacki.minimax-code
herdr plugin action invoke jaaacki.minimax-code.minimax-code-start
```

No test framework and no `bats` — plain bash, `HERDR_BIN_PATH` pointed at a `tests/fake-herdr`
stub that logs argv. `shellcheck` is not installed. There is no CI yet.

## Gotchas

- **`herdr plugin link .` mutates the owner's herdr registry.** It is the only way to get herdr
  to accept the manifest — `herdr plugin` has **no** `validate` subcommand. Confirm before
  running it; `plugin link` also does **not** run `[[build]]`.
- **Env var is `HERDR_PLUGIN_ROOT`, not `HERDR_PLUGIN_DIR`.** `HERDR_PLUGIN_DIR` does not exist.
  This bug was already shipped once in the scaffold and fixed; do not reintroduce it.
- **`set -euo pipefail` swallows diagnostics on failure.** `out=$("$HERDR" pane split ...)`
  aborts before any stderr message prints. Use `if ! out=$(...); then` so custom errors run.
- **Never type a command into an unidentified pane.** If the new pane id can't be extracted
  from the `pane split` response, exit non-zero *before* calling `pane run`.
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

Follow the repo's issue → worktree → PR → `dev` → `main` flow (see global CLAUDE.md). No
issue exists yet for the work in `PLAN.md` — the issues are still to be created per `PLAN.md` §7.
