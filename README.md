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
- **It stops when the pane it watches disappears**, and that is the whole of its cleanup.
  It deliberately does *not* call `release-agent`: that call **deletes** the agent entry
  rather than handing authority back, so an earlier version of this watcher made your
  pane disappear from `herdr agent list` as soon as it exited. There is no `mcode`
  screen manifest for detection to fall back to, so nothing would resume even if it
  worked. Registration is pane-scoped and Herdr drops it with the pane.
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

## Driving a launched pane

`agent prompt` does not work, as above. But a pane's mcode session can be driven
directly, through mcode's own session surface instead of Herdr's:

```bash
bin/mcode-drive.sh <pane-id> "Reply with exactly: PONG"
```

```console
$ bin/mcode-drive.sh wZ:p8 "Reply with exactly: PONG"
mcode-drive: driving pane wZ:p8, session mvs_ae2f6e1c…, cwd /Users/you/your-repo
PONG
mcode-drive: OK pane wZ:p8 session mvs_ae2f6e1c… cwd /Users/you/your-repo
mcode-drive: last line: PONG
```

The reply goes to stdout on its own; the pane, session and cwd go to stderr, so a
driven turn is always attributable to what was actually driven. The exit code is
mcode's own.

**A session whose pane has been closed is still drivable.** This is the property
`agent prompt` cannot give you, and it works because the connection is to the
*mcode runtime*, not to the pane's process.

### Naming the target

Pass a **pane id** (it looks like `wZ:p8`), or the name of an agent that has been
`herdr agent rename`d. A merely-registered label is *not* addressable — several
panes can share one, and Herdr resolves names only for agents it was told to
rename. `herdr agent list` shows what is addressable.

### When it cannot tell which session you mean

Herdr does not record a session id for our panes, so the pane→session mapping has
to be discovered. This script looks in two places:

1. **A binding file**, `$MCODE_HOME/drive-bindings.json` — that is
   `~/.minimax/drive-bindings.json` — or `<plugin state>/mcode-drive/bindings.json`
   when Herdr sets `HERDR_PLUGIN_STATE_DIR`. Written after every drive that
   succeeded, so the *second* drive of a pane resolves on its own. Override the
   path with `MCODE_DRIVE_BINDING` if you want it somewhere else.

2. **MiniMax Code's own sqlite state**, which does record a session's workspace —
   in a `workspace_dir` column, not in the session manifest. (Issue #36 recorded
   that manifests carry no cwd; that is still true. It is only in sqlite that the
   workspace appears.)

When one workspace holds several live sessions — the normal case if you have more
than one pane on a checkout — **this script stops and lists the candidates rather
than picking one.** Nothing available to it can say which session belongs to which
pane, and a wrong pick would deliver your prompt to someone else's session, which
the exact-cwd check would not catch. Note it does not narrow by session `status`
either: that tracks whether a session is *busy*, not whether a pane exists, so a
pane sitting at its prompt is `idle` and narrowing on `started` can discard the
very session you meant.

Name the one you want:

```bash
MCODE_DRIVE_SESSION=mvs_ae2f6e1c… bin/mcode-drive.sh wZ:p8 "your prompt"
```

That drive is cached, and later drives of that pane resolve without the override.

### Honest limits

- **A busy session is unmeasured.** Nothing here has run a turn against a session
  mid-turn; what that does is unknown, and it is not the same as "it works".
- **`agent prompt` is still broken.** This is a parallel path, not a fix. It goes
  away the day Herdr gains `--kind minimax-code`, at which point #73 closes
  properly and this becomes redundant.
- **Nothing is written to the session** except the turn you asked for, and the
  binding file after a successful drive.

## Three known ceilings

Encountered in normal use, gathered here so you meet them before you go looking:

1. **No `agent prompt` / `agent send-keys`.** Upstream: `agent start --kind` has
   no `minimax-code`, so no agent of ours can be *active*. `get` / `read` /
   `wait` are unaffected. See above. There is a plugin-side workaround for
   *driving* a pane — [Driving a launched pane](#driving-a-launched-pane) — which
   routes through mcode instead of Herdr and does not lift this ceiling.
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
