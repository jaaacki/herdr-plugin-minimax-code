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

## Reporting state

Herdr shows an agent's `idle` / `working` state per pane. **Launching a pane
starts a watcher for it**, so that state follows the pane instead of freezing at
whatever it was when the pane was created.

The watcher reads the pane's screen every two seconds, works out whether `mcode` is
busy or resting, and tells Herdr **only when the answer changes**. An unchanged
screen produces no traffic at all, so this is not a chatty poller. It stops by
itself when the pane closes.

To opt out — per launch, or in your shell — set `MCODE_WATCH_AUTOSTART=0`:

```bash
MCODE_WATCH_AUTOSTART=0 bin/mcode-plugin.sh start
```

The pane then shows `unknown`, which is the only state this plugin can keep true
without a watcher, and it will **not** follow the pane: it goes stale in both
directions, so a pane that finished still reads `working` and a pane that started
still reads `idle`. If you opt out and still want tracking, run it yourself:

```bash
bin/mcode-watch.sh <PANE_ID>
```

`<PANE_ID>` is the pane running `mcode` — find it with `herdr pane list`.

Things worth knowing:

- **A state is only as fresh as its watcher.** A watcher that dies — or that was never
  started for the pane — leaves Herdr holding the last value it was told, so a pane can
  read `working` long after the turn ended, with nothing reporting an error. The watcher
  is detached and unsupervised, so nothing notices when it stops. Check with
  `pgrep -f "mcode-watch.sh <PANE_ID>"`, and re-sync by running
  `bin/mcode-watch.sh <PANE_ID>` — it classifies once and reports before waiting for a
  change, so the state is right immediately.
- **It runs detached, and is tied to the pane rather than to a supervisor.** It is
  deliberately *not* a foreground job in the pane you launched from — that pane is
  running `mcode`. It exits when the pane it watches disappears, and that is the
  whole of its cleanup.
- **It reports `idle` and `working`, and `unknown` — never `blocked`.** `blocked`
  means Herdr saw an approval prompt, and no such screen has been captured, because
  `mcode` 0.6.2 runs at `Full access` where no prompt appears. That gap is
  deliberate: a `blocked` rule that never fires would be a lie in the code. Switch a
  session's permission mode with `/permission` and a prompt becomes reachable, at
  which point the rule can be written from real evidence.
- **It deliberately does not call `release-agent`**, and never did once that call
  was understood: it **deletes** the agent entry rather than handing authority back,
  so an earlier version of this watcher made your pane vanish from
  `herdr agent list` as soon as it exited. There is no `mcode` screen manifest for
  detection to fall back to, so nothing would resume even if it worked.
  Registration is pane-scoped and Herdr drops it with the pane.
- **A turn driven by `mcode exec` does not show up here.** The runtime owns that
  turn and the pane's screen never changes, so a screen watcher cannot see it — a
  driven pane can read `idle` while it is actually working. State for driven turns
  would have to come from the session store, which is not implemented.
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

What a launched pane gets, and what it does not:

| | Status on Herdr 0.9.3 |
|---|---|
| Agent entry, so it appears in `herdr agent list` | ✅ registered at launch |
| A name, so `get` / `read` / `wait` resolve by name | ✅ renamed at launch |
| `idle` / `working` state | ✅ reported, and it follows the pane while the watcher runs |
| Session identity (`agent_session`) | ⚠️ **attempted at launch, then discarded by Herdr** — see below |
| Resume after a Herdr restart | ✅ the resume command is stored and re-run; see the caveats |
| `blocked` state | ❌ `mcode` 0.6.2 exposes no hook a plugin can read |

### The session id is discarded; the resume command is kept

Launching a pane asks Herdr to record a session id **and** a resume command, and
Herdr treats those two differently:

- the **session id** is refused — Herdr only keeps identity for the agent kinds it
  enumerates in `herdr agent start`, and `minimax-code` is not one. So there is no
  `agent_session` on our panes, and the launch says so rather than claiming success;
- the **resume command** is accepted, stored, and re-run after a restart.

This is Herdr's ceiling on identity, not a plugin bug, and it is confirmed
independently in `sparkfn/pc-client#2251`. It is also the whole of what the
`--kind` gap costs: Herdr will not store a *session id* for us until it grows
`--kind minimax-code`, but it needs no such thing to run `mcode --continue` for us
today.

**A session on one of our panes is not automatically ours.** Where `codex` ran in a
pane earlier and `mcode` was started in it afterwards, Herdr keeps the *codex* session —
inherited from whatever ran there rather than stored by this plugin, so read
`agent_session.source` before concluding anything was saved. Those panes have no
`agent_resume`, so on restore Herdr falls back to `agent_session` and would type
`codex resume <id>` into a pane now running `mcode`; tracked in #87.

```bash
herdr agent list | jq -r '.result.agents[] | select(.agent_session) | [.agent, .pane_id, .agent_session.source] | @tsv'
```

When Herdr gains `--kind minimax-code`, the session id starts being kept too, and
`herdr agent get <pane>` resolves by identity rather than by label.

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

### Resume: proven, with three caveats

Herdr keeps no session id for `mcode` — there is no `agent_session` on our panes.
What it does keep is the **resume command**, and a restarted Herdr re-runs it, so
the pane comes back running `mcode --continue`.

That was measured end to end rather than inferred: launch a pane, stop the server,
start it again, attach a client, and the recreated pane runs the real
`mcode --continue`. It is not covered by CI. The end-to-end case fails roughly one
run in three, for a reason nobody has root-caused, so it is opt-in — see #99.

Three things to know before relying on it:

- **A client has to attach.** While Herdr's terminal area is `0x0` — a headless
  server with no client — it has no pane to resume into. Panes come back as plain
  shells and nothing is logged. Restart a detached server, see no `mcode`, and
  this is the usual reason, not a bug.
- **`mcode --continue` resolves by working directory.** Restored where no session
  exists, it prints `No saved Session exists in the current workspace`. That is
  `mcode` answering correctly, not a failed restore.
- **Two `mcode` panes in one directory restore only one.** Herdr keys resume
  candidates on (source, agent, cwd, argv) and keeps the first, so the second pane
  comes back a plain shell and says nothing. Documented, not worked around.

To check the current state yourself. No `herdr` command exposes the resume command —
neither `agent get` nor `pane get` carries it — so read the session snapshot. Herdr
debounces those writes, so wait a few seconds after a launch before reading one:

```bash
SNAP="$(ls -t "${XDG_CONFIG_HOME:-$HOME/.config}/herdr/session-snapshots/"*.json | head -1)"
jq -r '[.. | objects | select(has("agent_resume")) | .agent_resume
        | "\(.source)\t\(.agent)\t\(.argv | join(" "))"] | .[]' "$SNAP"
```

Each line is one pane that has a resume command stored. Absence means that pane has
none — and remember it is a snapshot, so an empty result may just be a save that
has not landed yet.

## Driving a launched pane

`agent prompt` does not work, as above. But a pane's mcode session can be driven
directly, through mcode's own session surface instead of Herdr's:

```bash
bin/mcode-drive.sh <pane-id> "Reply with exactly: PONG"
```

```console
$ bin/mcode-drive.sh wZ:p8 "Reply with exactly: PONG"
mcode-drive: driving pane wZ:p8, session mvs_ae2f6e1c…, cwd ~/your-repo
PONG
mcode-drive: OK pane wZ:p8 session mvs_ae2f6e1c… cwd ~/your-repo
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

1. **A binding file**, `$MCODE_HOME/drive-bindings.tsv` — that is
   `~/.minimax/drive-bindings.tsv` — or `<plugin state>/mcode-drive/bindings.tsv`
   when Herdr sets `HERDR_PLUGIN_STATE_DIR`. Override the path with
   `MCODE_DRIVE_BINDING` if you want it somewhere else.

   It is plain tab-separated text, one line per drive, and it is yours to edit:

   ```
   pane_id<TAB>session_id<TAB>workspace<TAB>recorded_at_ms
   wZ:p8	mvs_ae2f6e1c…	~/your-repo	1791123133419
   ```

   A drive that succeeded appends a line, so the newest line for a pane is the
   one that counts — which means you can fix a wrong pairing by hand, or pin a
   right one, without waiting for anything to re-infer it.

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
2. **Resume needs a client, and one pane per directory.** The resume command is
   stored and re-run, so a restarted Herdr brings the pane back running
   `mcode --continue` — but only once a client attaches, and when two `mcode` panes
   share a directory only the first is restored. See above.
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
