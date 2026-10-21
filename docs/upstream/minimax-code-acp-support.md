# Upstream ask: speak ACP, and MiniMax Code comes with it

**This file is the upstream proposal, written here so it can be reviewed before
anything is posted to another project.** Nothing has been sent to
`herdrdev/herdr` from this repository, and nothing will be without the owner's
explicit go-ahead.

- Tracked by: [#37](https://github.com/jaaacki/herdr-plugin-minimax-code/issues/37)
- Also relevant: [#73](https://github.com/jaaacki/herdr-plugin-minimax-code/issues/73)
- Measured on: **herdr 0.9.5**, **MiniMax Code 0.6.12**, macOS 27.0.0 arm64,
  2026-10-21.
- Everything below is reproducible with the commands shown.

---

## 1. The problem, in one paragraph

MiniMax Code (`mcode`) is a full interactive coding agent — a TUI with sessions,
resumption, forking, modes, permission levels and plugin hooks. It is **invisible
to herdr**: it does not appear in `herdr agent list`, `herdr agent prompt` and
`herdr agent send-keys` refuse it, and `herdr agent start --kind` has no value
that launches it. A community plugin can make mcode *visible* and *watchable* by
self-reporting over herdr's socket API — that is what
`jaaacki/herdr-plugin-minimax-code` does — but it cannot make mcode **drivable**,
because the only command that mints an *active* agent is
`herdr agent start --kind <KIND>`, and that enum is closed.

## 2. The specific gap

`herdr agent start --help`, herdr 0.9.5:

```
--kind <KIND>
    Supported agent kind and canonical executable

    [possible values: pi, claude, codex, gemini, cursor, devin, agy, cline, omp,
     mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo,
     qodercli, qwen, letta, maki, muse]
```

24 values. `mcode` / `minimax-code` is in none of them. The enumeration grows;
the gap does not close.

`pane report-agent` registers and names an agent but never **activates** it, so
a registered mcode answers:

```json
{"error":{"code":"agent_not_ready","message":"agent mcode-test is not an active named agent"},
 "id":"cli:agent:prompt"}
```

with the identical envelope for `send-keys`. It can be seen (`agent list`,
`agent get`, `agent read`, `agent rename`, `agent focus`, `agent attach`) and
watched, but not driven.

## 3. The proposal, and the evidence that supports it

**Proposal: make herdr an ACP client.** Not "add a MiniMax Code integration" —
that is one agent of many. ACP is an open protocol for exactly this problem, and
**mcode already speaks it richly**.

`mcode --help`, MiniMax Code 0.6.12:

```
Commands:
  init [directory]        Analyze the codebase and generate AGENTS.md …
  exec [options] [prompt] Run one prompt without starting the TUI
  acp [options]           Run MiniMax Code as an Agent Client Protocol server over stdio
  app-server [options]    Run the MCode SSH app-server
  login / logout          Sign in to use MiniMax Code Agent features
  update / provider / plugin / …
```

```sh
mcode acp --help
Usage: mcode acp [options] [command]
Run MiniMax Code as an Agent Client Protocol server over stdio
```

### 3.1 What the ACP server exposes

`initialize` over stdio, verbatim:

```json
{
  "protocolVersion": 1,
  "agentCapabilities": {
    "loadSession": true,
    "mcpCapabilities": { "http": true, "sse": true },
    "promptCapabilities": { "image": true, "audio": false, "embeddedContext": false },
    "sessionCapabilities": { "list": {}, "fork": {}, "resume": {}, "close": {} }
  },
  "agentInfo": { "name": "minimax-code", "title": "MiniMax Code", "version": "0.6.12" },
  "_meta": { "minimax-code/extensions": { "version": 1,
    "methods": [ "session/activate", "mcode/session/activate", "mcode/session/steer",
                 "mcode/session/queue/list", "mcode/session/queue/enqueue",
                 "mcode/session/queue/update", "mcode/session/queue/delete",
                 "mcode/session/queue/steer", "mcode/session/goal/get",
                 "mcode/session/goal/create", "mcode/session/goal/patch",
                 "mcode/session/goal/clear", "mcode/session/delegation/get",
                 "mcode/session/delegation/stop" ],
    "notifications": [ "mcode/session/current_session_update",
                       "mcode/session/queue_update", "mcode/session/goal_update",
                       "mcode/session/delegation_update" ] } }
}
```

### 3.2 The methods that matter to herdr, and what each one returns

Measured by driving `mcode acp` over stdio (JSON-RPC 2.0) in a scratch cwd.

| Method | Result | What it gives herdr that herdr does not have today |
|---|---|---|
| `session/new` | `{"sessionId":"mvs_…","modes":{…},"configOptions":[…]}` | a session identity, the **modes** (`default`, `plan`) and the **config options** — including `permissionMode` with the values `Ask` / `Auto` / `Full access` |
| `session/list` | `{"sessions":[{"sessionId":"mvs_…","cwd":"/…","updatedAt":"2026-10-21T06:52:22.270Z"}, …]}` | every session with its workspace and recency — the session manifest, over a protocol |
| `session/activate` | `{"sessionId":"mvs_…"}` | **the missing "active agent"**. This is what `herdr agent start --kind` mints, and what `pane report-agent` cannot |
| `session/prompt` | `{"stopReason":"end_turn"}` | **the exact turn boundary**. Today the plugin has to infer it from the screen |
| `session/fork`, `session/resume`, `session/close` | advertised in `sessionCapabilities` | session lifecycle, addressed by id |
| `session/update` (notification) | `agent_message_chunk`, `session_info_update`, `usage_update`, `available_commands_update` | a live event stream for a pane's agent |

`session/resume` takes `cwd` as well as the id — it refuses with
`Invalid params … cwd: expected string, received undefined` without it. The
workspace is part of the identity.

### 3.3 The session manifest on disk

Sessions are also persisted, which matters for a control plane that has to
reconstruct state after a restart:

```
~/.minimax/v2/sqlite/runtime-state.sqlite
  table local_runtime_sessions(
    session_id TEXT PRIMARY KEY, record_json TEXT NOT NULL, updated_at_ms INTEGER NOT NULL,
    agent_name TEXT, runtime TEXT, session_type TEXT, status TEXT,
    archived INTEGER, visibility TEXT, session_kind TEXT, purpose TEXT,
    parent_session_id TEXT, workspace_dir TEXT, project_workspace_dir TEXT,
    is_default_workspace INTEGER, title TEXT, created_at_ms INTEGER,
    error_message TEXT, error_code INTEGER, extra_data_json TEXT, project_id INTEGER,
    history_relative_dir TEXT )
```

A live row:

```
session_id          = mvs_989aa8811e14410e95974735ee907e14
agent_name          = mavis
runtime             = pi-agent
session_type        = branch
status              = idle
session_kind        = conversation
workspace_dir       = /tmp/acp-state-cwd
created_at_ms       = 1792565542270
history_relative_dir = 2026/10/21/06-52-22-270-session_bXZzXzk4OWFhODgxMWUxNDQxMGU5NTk3NDczNWVlOTA3ZTE0
```

`status` is a live state, not a constant. The same column reads `idle` for a
finished session and **`started`** for one whose turn is running — measured by
creating a session over ACP, sending one prompt, and polling the row:

```
   sqlite status=started type=branch updated=1792565630807
   sqlite status=started type=branch updated=1792565630807
   … (the row stays `started` for the whole turn)
```

and `aborted` for a session that was killed mid-turn. So the session's state is
persisted, per session, by the runtime itself.

`mcode --session <id>` opens a session by id, and `mcode --continue` continues
the latest session in the current workspace — so "resume" is a first-class
concept on the agent's side, not an invention.

### 3.4 The control-plane mapping herdr would gain

| herdr today | over ACP |
|---|---|
| `herdr agent start --kind mcode` (missing) | `session/activate` |
| `herdr agent prompt <name> "…"` (refuses) | `session/prompt` |
| `herdr agent wait --until idle` (screen-inferred) | `session/prompt` → `stopReason` |
| `herdr agent list` (no mcode) | `session/list` |
| resume by name (unavailable) | `session/resume` / `session/fork` |
| `blocked` (unreachable) | `permissionMode` = `Ask`, and ACP's permission request flow |

## 4. Why ACP and not a bespoke MiniMax integration

- **It is already implemented, on the agent's side, by the agent's author.**
  mcode ships an ACP server in its own binary, with session lifecycle, turn
  boundaries and a permission mode. Nothing has to be built for mcode.
- **It is generic.** Every ACP-speaking agent becomes drivable by the same
  client. herdr's own `integration` list is a hand-maintained enumeration of
  one-off targets; an ACP client replaces that class of work with a protocol.
- **It is the surface that carries the state herdr is missing.** The plugin
  community has to infer "working" from a screen today because the plugin
  lifecycle hooks fire at the **start of a turn** and the turn's end has to be
  guessed. ACP answers both ends exactly.

## 5. What herdr has today, so the gap is stated precisely

- `herdr integration install` accepts a fixed list of agent names
  (`pi`, `omp`, `claude`, `codex`, `copilot`, `devin`, `droid`, `kimi`,
  `opencode`, `kilo`, `hermes`, `qodercli`, `qwen`, `letta`, `cursor`,
  `mastracode`, `antigravity-cli`, `grok`, …). No MiniMax Code, and no generic
  "any ACP agent" target.
- The socket API schema does not mention ACP at all: `herdr api schema --json`
  is 272,578 bytes and contains **zero** occurrences of `acp` or
  `agent client protocol`.
- The only `acp` string in the herdr binary is inside an embedded helper's
  platform set, `_INTERACTIVE_PLATFORMS = {"cli", "tui", "desktop", "acp"}` —
  it is not a protocol implementation.

## 6. Related upstream issues, and one correction

- **herdrdev/herdr#4567** — *"Feature batch: ACP registry adoption, headless/batch
  control surface, and utilization APIs"* (closed 2026-09-24). Its first request
  is *"ACP registry sync … generate agent-detection entries and `agent start`
  launch presets from it"*. It was closed with an automated reply asking for the
  proposals to be brought to Ideas discussions, so **no ACP support was
  implemented**. It is the closest existing discussion and this proposal is the
  concrete version of its first request.
- **herdrdev/herdr#4940** — *"Inherited agent_session survives when a different
  agent takes the pane (codex session left on an mcode pane)"* (open). It names
  mcode, and it is a different defect: a stale session id surviving a handover.
- **Correction to this repo's issue #37**, which asked to cross-reference
  **herdrdev/herdr#2382** as possibly covering MiniMax detection: it does not.
  #2382 is *"fix(sidebar): highlight active agent in collapsed sidebar"* and is
  merged. There is no MiniMax detection coverage upstream to point at.

## 7. The ask, concretely

Two options, in order of value per unit of work:

1. **Speak ACP.** Let a herdr agent be backed by an ACP session: `session/activate`
   to make it active, `session/prompt` to drive it, `stopReason` to end a turn,
   `session/list` to enumerate. A `minimax-code` ACP target plus the generic
   mechanism closes this issue, and closes it for every other ACP agent too.
2. **Or** add a first-class `minimax-code` integration target (launch preset +
   detection), and accept that driving it stays out of reach until ACP lands.

Option 1 is the one the evidence supports: the work is already done on the
agent's side, and it is done in a protocol rather than in a bespoke hook.
