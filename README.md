# herdr-plugin-minimax-code

A [Herdr](https://herdr.dev) plugin for [MiniMax Code](https://github.com/MiniMax-AI).

## Status

v0.2.0. The manifest is valid, the entrypoint runs, and `cmd_start` launches
`mcode` in a new pane beside the active one.

Herdr does not detect MiniMax Code, so there is no way to list the agents this
plugin has started. It launches them; that is the whole surface.

## Requirements

Check these first. The plugin will not start without them, and finding out by
watching it fail is a worse way to learn them.

| Needs | Why |
|---|---|
| Herdr `0.9.3` or newer | `min_herdr_version` in the manifest |
| [`jq`](https://jqlang.github.io/jq/) on `PATH` | reads Herdr's JSON output — `brew install jq`, `apt-get install jq`, or `dnf install jq` |
| [`mcode`](https://github.com/MiniMax-AI) on `PATH` | the MiniMax Code CLI this plugin launches |
| Linux or macOS | `platforms` in the manifest; the entrypoint is bash |

`mcode` must be the command itself on `PATH` — not a relative entry, and not
just the folder it lives in.

`jq` and `mcode` are both checked *before* any pane is created, so a missing one
fails immediately naming what is missing, rather than leaving an empty pane
behind for you to clean up.

## Install

**Pick one — these are alternatives, not steps in sequence.** `install` and
`link` register the same plugin id, so herdr refuses the second while the first
is still registered. To switch, remove the old one first with
`herdr plugin uninstall jaaacki.minimax-code` or
`herdr plugin unlink jaaacki.minimax-code`.

```bash
herdr plugin install jaaacki/herdr-plugin-minimax-code
```

This prints a preview and asks you to confirm. In a script, a pipeline, or any
other non-interactive context, add `--yes`.

For local development, link a clone instead — note that `plugin link` does
**not** run `[[build]]` commands, so build anything yourself first:

```bash
git clone git@github.com:jaaacki/herdr-plugin-minimax-code.git
cd herdr-plugin-minimax-code
herdr plugin link .
```

## Using it

In a workspace or a pane, open Herdr's action menu and choose
**Start MiniMax Code in this worktree** (action id `minimax-code-start`). A new
pane opens beside yours with `mcode` running in it.

Nothing happened? Herdr reports a failed action in its log rather than in the
pane, so the failure is silent by default. Check it with:

```bash
herdr plugin log list --plugin jaaacki.minimax-code
```

## Reporting state (optional)

Herdr shows an agent's `idle` / `working` state per pane. Nothing here reports
MiniMax Code's state by default, so a pane running `mcode` shows no state at all.

If you want that, run the watcher in a pane of your choice:

```bash
bin/mcode-watch.sh <PANE_ID>
```

`<PANE_ID>` is the pane running `mcode` — find it with `herdr pane list`. It reads
that pane's screen every two seconds, works out whether `mcode` is busy or resting,
and tells Herdr **only when the answer changes**. An unchanged screen produces no
traffic at all, so this is not a chatty poller.

Things worth knowing:

- **It is a foreground process.** Stop it with `Ctrl-C`, or by closing the pane you
  ran it in. It is deliberately *not* started for you: a detached watcher per pane
  would be an orphan if Herdr died, whereas a foreground job cannot outlive its pane.
- **It reports `idle` and `working`, and `unknown` — never `blocked`.** `blocked`
  means Herdr saw an approval prompt, and no such screen has been captured, because
  `mcode` 0.6.2 runs at `Full access` where no prompt appears. That gap is
  deliberate: a `blocked` rule that never fires would be a lie in the code. Switch a
  session's permission mode with `/permission` and a prompt becomes reachable, at
  which point the rule can be written from real evidence.
- **It stops when the pane it watches disappears**, and calls `release-agent` so a
  registration it created does not outlive it. Note that `release-agent` only removes a
  registration made with the *same* `--source`; a mismatched one is a silent no-op. So the
  watcher's cleanup only covers registrations it made itself — check with
  `herdr agent list | grep -c <pane-id>` rather than trusting the call.
- Rules live in one table at the top of `bin/mcode-watch.sh`. Each was derived from
  a real captured screen; the comments record which candidates were rejected and why.

## What Herdr can see about a launched pane

A pane this plugin opened is a first-class Herdr agent. It shows up in
`herdr agent list`, and once it has a name you can drive it by that name:

```bash
herdr agent list                 # every agent, including panes this plugin opened
herdr agent get   <name>         # one agent: pane, tab, cwd, state
herdr agent read  <name>         # the agent's screen output
herdr agent wait  <name> --until idle --timeout 5000   # block until a state
```

`<name>` is the agent's registered name. `wait` takes `--until` (repeatable) and
`--timeout` **in milliseconds**; without `--timeout` it waits indefinitely, and
without `--until` it matches `idle`, `done` or `blocked`.

### `agent prompt` and `agent send-keys` do not work — and that is Herdr's ceiling

Both refuse, with the same error:

```console
$ herdr agent prompt <name> "say ok"
{"error":{"code":"agent_not_ready","message":"agent <name> is not an active named agent"}}

$ herdr agent send-keys <name> -- Enter
{"error":{"code":"agent_not_ready","message":"agent <name> is not an active named agent"}}
```

The message says *active*, and that word is the whole story. Herdr only allows
`prompt` / `send-keys` against an agent **it** started, via
`herdr agent start --kind <KIND>`, and that `--kind` enum is a closed list which
contains no `minimax-code` entry. So there is no Herdr-side handle that would let
this plugin hand you a promptable agent.

**This is an upstream ceiling, not a bug here, and it will not be filed against
this plugin.** The agent is genuinely registered and name-addressable — `get`,
`read` and `wait` all work on it. What is missing is Herdr-side *activation*,
which only `agent start` can grant.

For genuinely interactive control, attach to the pane instead.

### Resume: wired, not demonstrated

The plugin registers a session identity and a resume command for panes it
launches, so a Herdr restart has something to resume from. **This has not been
proven to work end to end** — it has only been shown that Herdr accepts the
registration, not that a restarted session actually comes back. Treat it as
unverified, and do not rely on it for work you cannot redo.

To check the current state yourself:

```bash
herdr agent list | grep -o '"agent_session":{[^}]*}'   # session identity, if any
herdr pane report-agent-session --help                 # the resume verb
```

An agent showing `agent_session` has a registered session. One without it has
none. Panes this plugin opened may legitimately show no `agent_session`.

## Three known ceilings

Encountered in normal use, gathered here so you meet them before you go looking:

1. **No `agent prompt` / `agent send-keys`.** Upstream: `agent start --kind` has
   no `minimax-code`, so no agent of ours can be *active*. `get` / `read` /
   `wait` are unaffected. See above.
2. **Resume is wired but unverified.** The registration is accepted; that it
   restores a session has not been demonstrated. See above.
3. **No screen-manifest detection.** `mcode` ships no Herdr manifest, so Herdr
   cannot detect it from the screen the way it detects `claude`. A local override
   cannot add one either — an override only changes how an agent id Herdr
   *already knows* is detected; it cannot introduce a new id. This is precisely
   why state reporting is the opt-in watcher described above.

## What it exposes

| Trigger | Menu title | Kind | Does |
|---|---|---|---|
| `minimax-code-start` | Start MiniMax Code in this worktree | action | Launch `mcode` in a new pane for the active worktree |

One action, offered in the `workspace` and `pane` contexts. No event hooks.

## Development notes

The manifest is the whole contract. Required top-level keys are `id`, `name`,
`version` and `min_herdr_version`; a plugin is any argv command, so this could
just as well be JS, Lua or Rust.

Herdr injects the environment into every command. The useful ones:

| Var | |
|---|---|
| `HERDR_BIN_PATH` | path to the running herdr binary — prefer this over `herdr` so it stays portable |
| `HERDR_PLUGIN_ROOT` | this plugin's checkout |
| `HERDR_PLUGIN_CONFIG_DIR` | user-editable config, created by `herdr plugin config-dir` |
| `HERDR_PLUGIN_STATE_DIR` | plugin-owned state |
| `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_ACTION_ID`, `HERDR_PLUGIN_ENTRYPOINT_ID` | identity |
| `HERDR_PLUGIN_CONTEXT_JSON` | invocation context |
| `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID` | layout ids |

Action `contexts` are `global`, `workspace`, `tab`, `pane`, `selection`.
Pane `placement` is `overlay`, `popup`, `split`, `tab` or `zoomed`.

## Tests

```bash
./tests/run.sh
```

## License

[MIT](LICENSE) — Copyright (c) 2026 `jaaacki`.
