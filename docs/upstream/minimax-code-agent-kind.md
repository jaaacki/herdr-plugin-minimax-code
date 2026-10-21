# Upstream ask: make MiniMax Code drivable (`prompt` / `send-keys`)

**This file is the upstream proposal, written here so it can be reviewed before
anything is posted to another project.** Nothing has been sent to `herdrdev/herdr`
from this repository, and nothing will be without the owner's explicit go-ahead.

- Tracked by: [#73](https://github.com/jaaacki/herdr-plugin-minimax-code/issues/73)
- The larger proposal, with the ACP evidence, is
  [`minimax-code-acp-support.md`](./minimax-code-acp-support.md). This file is
  the short, concrete version: the surface, the exact refusals, and the one
  line of upstream code that would fix it.
- Measured on: **herdr 0.9.5**, **MiniMax Code 0.6.12**, macOS 27.0.0 arm64,
  2026-10-21.

---

## The gap in one table

Measured against a live pane running mcode, on the same herdr and the same day
as the control runs below.

| surface | native (`claude`, `codex`, `opencode`, `grok`) | mcode |
|---|---|---|
| `agent list` | works | **works** |
| `agent get` by name | works | **works** (after `rename`) |
| `agent read --source detection` | works | **works** |
| `agent rename` / `focus` / `attach` | works | **works** |
| `agent prompt <name> <text>` | works | **`agent_not_ready`** |
| `agent send-keys <name> <key>` | works | **`agent_not_ready`** |
| `agent wait --until <status>` | works | matches only `unknown` |
| `interactive_ready` at launch | present | **absent — the field does not appear at all** |
| state without the watcher | auto | stuck `unknown` |

Exact error, reproduced:

```json
{"error":{"code":"agent_not_ready","message":"agent mcode-test is not an active named agent"},
 "id":"cli:agent:prompt"}
```

The identical envelope comes back for `send-keys`.

## Root cause

`herdr agent start --kind` is the only command that mints an **active** agent.
`pane report-agent` registers and names one but never activates it, and the
`--kind` enum is closed:

```
$ herdr agent start --help
--kind <KIND>
    [possible values: pi, claude, codex, gemini, cursor, devin, agy, cline, omp,
     mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo,
     qodercli, qwen, letta, maki, muse]
```

24 values, no `mcode` and no `minimax-code`. The enumeration grew; the gap did
not close.

## Control — the same commands against a native kind

To rule out a machine-level misconfiguration, the identical sequence was run
with `--kind opencode` and `--kind grok` on the same machine, same herdr, same
day:

| kind | launch result |
|---|---|
| `opencode` | `agent: opencode`, `interactive_ready: true`, `agent_status: idle` |
| `grok` | `agent: grok`, `interactive_ready: true`, `agent_status: idle` |

Both integrations report `current` (`herdr integration status`: opencode v13,
grok v2). So the failure is specific to mcode's absence from the enum, not to
this install.

## The fix, in one line of upstream terms

**Add `minimax-code` to the `--kind` enum, with a launch preset and a detection
entry.** The enum is the only thing standing between a registered mcode and a
driven one, and mcode satisfies everything the other kinds satisfy:

- it is an interactive TUI agent with a start prompt, so `agent start`'s
  "pane must be at its interactive shell prompt" contract is satisfiable;
- it writes a recognizable status line, so a detection entry is possible —
  `jaaacki/herdr-plugin-minimax-code` already ships a screen manifest for it
  (`agent-detection/` in that repository, with captured working and idle
  fixtures);
- it accepts a prompt on stdin, which is what `agent prompt` and `send-keys`
  need.

## Why a bespoke integration is not the end of it

MiniMax Code **already speaks ACP**, and ACP carries exactly the two things the
`--kind` route cannot give a control plane: an explicit **activation** and an
exact **turn boundary**.

Measured on mcode 0.6.12 by driving `mcode acp` over stdio:

| ACP call | Result | herdr equivalent |
|---|---|---|
| `session/activate` | `{"sessionId":"mvs_…"}` | the "active agent" that `agent start --kind` mints |
| `session/prompt` | `{"stopReason":"end_turn"}` | the exact end of a turn, which herdr otherwise infers from the screen |
| `session/list` | every session with `cwd` and `updatedAt` | the agent list for ACP-backed agents |

So the request has a small form and a large form:

- **small**: add `minimax-code` to `--kind`, with a launch preset and a
  detection entry. This is what closes `prompt`/`send-keys` for mcode.
- **large**: speak ACP, so *every* ACP-speaking agent becomes drivable and the
  hand-maintained `--kind` list stops being the bottleneck.

Both are written up, with the full evidence, in
[`minimax-code-acp-support.md`](./minimax-code-acp-support.md).

## Impact

mcode can be **seen** and **watched** today — it appears in `agent list`, and
`get`/`read`/`focus`/`attach` all resolve — but it cannot be **driven**.
`herdr agent prompt mcode "…"` is the single command an orchestration script
needs, and it is the one command mcode cannot answer.
