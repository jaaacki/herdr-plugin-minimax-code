# Handoff — herdr-plugin-minimax-code

Everything researched and decided so far, so the next session doesn't have to re-derive it.
Written 2026-10-04. All claims below were verified against the herdr source at
`herdrdev/herdr` HEAD `5da0a01` (2026-10-03) and local herdr `0.9.3`.

---

## 1. What this repo is

A [Herdr](https://herdr.dev) plugin for [MiniMax Code](https://github.com/MiniMax-AI).

- GitHub: `jaaacki/herdr-plugin-minimax-code` (public, topic `herdr-plugin` set)
- Local: `/Users/noonoon/Dev/herdr-plugin-minimax-code`, branch `main` tracking `origin/main`
- Plugin id: `jaaacki.minimax-code`, `min_herdr_version = "0.9.3"`

## 2. Current state

| File | State |
|---|---|
| `herdr-plugin.toml` | valid, parses, all required keys present |
| `bin/mcode-plugin.sh` | mode `100755`, `bash -n` clean; `start` is a TODO stub |
| `README.md` | install + dev notes |
| `.gitignore` | herdr config/state dirs, `.DS_Store` |

**Not done:** `cmd_start` in the script is a stub that logs a TODO. No LICENSE yet.
`platforms` is `["linux", "macos"]` because the entrypoint is bash.

**Not verified:** the manifest has never been loaded by herdr. `herdr plugin` has no
`validate` subcommand — `herdr plugin link .` is the only way to get herdr to accept it,
and that was deliberately not run because it mutates the user's herdr registry.

## 3. The herdr model — four layers, not one

This is the most important thing to get right. "Herdr plugin" means four different things.

### Layer 1 — Integrations (shipped, in-binary)

`src/integration/`, payloads embedded at
`src/integration/assets/<agent>/herdr-agent-state.{sh,ps1,ts,js}` and installed *into the
agent's own config*. This is what `herdr integration install <name>` does.

17 targets in `src/integration/registry.rs`: `pi, omp, claude, codex, copilot, devin,
droid, kimi, opencode, kilo, hermes, qodercli, qwen, cursor, mastracode,
antigravity-cli, grok`.

Availability is `command_available(name) || integration_target_install_layout_available(...)`
— so it resolves even when the agent binary isn't on `PATH`.

Codex: `install_codex()` at `src/integration/targets.rs:160`, `uninstall_codex()` at `:615`.
OpenCode: `src/integration/opencode_config.rs` — note it uses `jsonc_parser`'s CST to
surgically append to a JSONC array without destroying comments or formatting, and handles
OpenCode's own V1→V2 `tui.json`→`cli.json` migration. That is the fiddly part of writing
an installer for a config-heavy agent.

### Layer 2 — Screen manifests (shipped, remote-updatable)

`distribution/agent-detection/*.toml` — 23 bundled rules. Source precedence is
`Bundled` → `Remote` → `Override(Path)`, tracked by `local_override_shadowing_remote`.
This is what makes agents detectable with zero configuration.

### Layer 3 — The agent skill (shipped)

`skills/herdr/SKILL.md`, 214 lines, gated on `HERDR_ENV=1`. It refuses to act outside a
Herdr pane by design. This is the "agent drives herdr" layer.

### Layer 4 — Community plugins (what this repo is)

`herdr-plugin.toml` workflow packages, discovered by the marketplace. There is **exactly
one** such manifest in the whole herdr tree — `tests/fixtures/plugin-smoke/herdr-plugin.toml`
— and it is a test fixture. Core ships zero.

## 4. Plugin manifest schema

Verified field-by-field from `src/api/schema/plugins.rs`. Not guessed.

Required top-level: `id`, `name`, `version`, `min_herdr_version`.
Optional: `description`, `platforms`, `build`, `startup`, `actions`, `events`, `panes`,
`link_handlers`.

| Section | Fields |
|---|---|
| `[[actions]]` | `id`, `title`, `description?`, `contexts`, `platforms?`, `command` |
| `[[events]]` | `on`, `platforms?`, `command` |
| `[[panes]]` | `id`, `title`, `description?`, `platforms?`, `placement`, `width?`, `height?`, `command` |
| `[[startup]]` | `platforms?`, `command` |
| `[[build]]` | `platforms?`, `command` |
| `[[link_handlers]]` | `id`, `title`, `pattern`, `action`, `platforms?` |

- `contexts`: `global`, `workspace`, `tab`, `pane`, `selection`
- `placement`: `overlay`, `popup`, `split`, `tab`, `zoomed`
- `platforms`: `linux`, `macos`, `windows`

`warnings` is non-fatal — a bad entry is kept and surfaced through `plugin.list`.

## 5. Hookable events (exact, 22)

From `PLUGIN_HOOK_EVENT_KINDS` in `src/api/schema/events.rs:286`. Deliberately narrower
than the 26-event `EventKind`. Using a non-listed name is non-fatal but warns.

```
workspace.created    workspace.updated     workspace.closed
workspace.renamed    workspace.moved       workspace.reordered
workspace.focused    worktree.created      worktree.opened
worktree.removed     tab.created           tab.closed
tab.renamed          tab.moved             tab.focused
pane.created         pane.closed           pane.focused
pane.moved           pane.exited           pane.agent_detected
pane.agent_status_changed
```

`pane.agent_detected` and `pane.agent_status_changed` are the interesting two for this plugin.

## 6. Injected environment

From `src/app/api/plugins/env.rs` and `runtime.rs`. Verified by grep, not assumed.

| Var | |
|---|---|
| `HERDR_ENV` | always `1` inside a plugin |
| `HERDR_BIN_PATH` | path to the running herdr binary — prefer over bare `herdr`, keeps it portable |
| `HERDR_PLUGIN_ROOT` | this plugin's checkout |
| `HERDR_PLUGIN_CONFIG_DIR` | user-editable config; created by `herdr plugin config-dir` |
| `HERDR_PLUGIN_STATE_DIR` | plugin-owned state |
| `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_ACTION_ID`, `HERDR_PLUGIN_ENTRYPOINT_ID` | identity |
| `HERDR_PLUGIN_CONTEXT_JSON` | invocation context |
| `HERDR_PLUGIN_EVENT`, `HERDR_PLUGIN_EVENT_JSON` | event name + payload for `[[events]]` |
| `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID` | layout ids |

Gotcha already hit once: the var is `HERDR_PLUGIN_ROOT`, **not** `HERDR_PLUGIN_DIR`.
`HERDR_PLUGIN_DIR` does not exist.

## 7. Agent CLI surface

The design bet is that **the entire Herdr CLI is the plugin API** — no SDK, no restricted
command set. Anything runnable as `herdr ...` is available to a plugin.

```bash
herdr agent list
herdr agent get <target>
herdr agent read <target> [--source visible|recent|recent-unwrapped|detection] [--lines N] [--format text|ansi]
herdr agent send-keys <target> <key> [key ...]
herdr agent start <name> --kind KIND --pane ID [--timeout MS] [-- <agent-args...>]
herdr agent explain <target>
herdr server update-agent-manifests   # fetch remote manifests now
```

Socket methods for plugins use prefix `plugin:<HERDR_PLUGIN_ID>`: `action.invoke`,
`action.list`, `pane.open`, `pane.focus`, `pane.close`, `log.list`, plus the
`link`/`list`/`enable`/`disable`/`unlink` family.

## 8. Install / link lifecycle

```bash
herdr plugin install owner/repo/subdir    # GitHub shorthand only; clones, previews, runs [[build]]
herdr plugin link ./local-dir             # dev; does NOT run [[build]] — build it yourself
herdr plugin list [--json]
herdr plugin action list --plugin <id>
herdr plugin action invoke <id>.<action>
herdr plugin config-dir <id>              # user config, separate from managed checkout
herdr plugin log list --plugin <id>
```

Registry is `plugins.json` next to `session.json`, guarded by `.plugins.lock`.
`plugin install` and `plugin link` both work with no herdr server running.

Discovery is one tag: GitHub topic `herdr-plugin` + a parseable `herdr-plugin.toml` on
the default branch. A Cloudflare Worker indexes it every ~30 min. **No review, no vetting**
— a listing means a repo tagged itself.

## 9. What to build next

The obvious next piece is `cmd_start`. Reference shape:

```bash
herdr agent start mcode --kind KIND --pane ID -- mcode
```

Open questions to settle before writing it:

1. What `--kind` does a MiniMax Code agent report as? herdr detects agents by
   screen-manifest heuristics (`distribution/agent-detection/`), and there is **no**
   `mcode.toml` — 23 bundled manifests, none for MiniMax Code. So MiniMax Code is
   currently invisible to herdr's detection. Adding a manifest is a separate, upstream
   contribution to `herdrdev/herdr`.
2. Should this be a Layer 4 plugin (what we have) or a Layer 1 integration? An integration
   would make `mcode` a first-class detectable agent, but it has to live in the herdr repo,
   not here.
3. Windows support: bash entrypoint means `platforms` excludes it today.

## 10. Corrections made during this work

Recorded so nobody re-derives them wrongly:

- Initial research was done from `herdr.dev` docs only, which document just Layer 4. It
  missed that integrations and screen manifests ship in-tree. The docs-site view is
  materially incomplete; the source is authoritative.
- `HERDR_PLUGIN_DIR` was written first and is wrong. Real name: `HERDR_PLUGIN_ROOT`.
- **`HERDR_PLUGIN_ROOT` is injected into the action's environment, but herdr does NOT expand
  shell variable syntax inside a manifest `command` array.** This one cost the most and is
  recorded so it is never repeated. `command = ["${HERDR_PLUGIN_ROOT}/bin/mcode-plugin.sh",
  "start"]` does not run — the string contains a `/`, so the OS treats it as a relative path and
  looks for a literal directory named `${HERDR_PLUGIN_ROOT}`, giving `ENOENT`. The working form
  is `command = ["/bin/sh", "-c", "\"$HERDR_PLUGIN_ROOT/bin/mcode-plugin.sh\" start"]`. Note
  the TOML escaping: inner quotes are `\"`; a `\$` escape is invalid TOML and manifests as the
  same `ENOENT`.
- **A manifest `command` is resolved against the invoking pane's cwd, not the plugin root.**
  Verified by splitting a pane with `cwd=/tmp` and invoking: a relative `bin/mcode-plugin.sh`
  failed there and succeeded from the plugin root. So "just use a relative path" is not a fix.
- **herdr 0.9.3 can record a successful plugin action as `failed` with `ENOENT`,** with empty
  stdout/stderr, when the command is a `/bin/sh -c` wrapper. Confirmed three-for-three: each run
  created a real pane with `mcode` running, and each was logged as `failed`. See issue #16.
- The docs list a `workspace.metadata_updated` and `layout.updated` event, but those are
  **not** in `PLUGIN_HOOK_EVENT_KINDS` and will warn.
- **A local manifest override only applies to an agent id Herdr already knows. A brand-new id
  is dropped in silence** — no error, no warning, the agent simply never appears. This is why
  "add a manifest for `minimax-code` locally" cannot work as a detection strategy: an override
  can change *how a known agent* is detected, never *which agents exist*.
- **`herdr pane report-agent` is the only route that can introduce a new agent.** Confirmed by
  experiment: a pane with no agent becomes one only after `report-agent`. `herdr agent start`
  cannot do it for us, because `--kind` is a closed enum with no `minimax-code` member.
- **Herdr's own Claude integration never self-reports state — it reports session identity
  only, because its state is screen-detected.** `herdr agent explain` on a Claude pane names
  the rule doing the work:
  ```
  $ herdr agent explain <claude-pane>
  agent: claude
  state: working
  manifest: remote:…/agent-detection/remote/claude.toml 2026.09.11.1
  rule: osc_title_working (region=osc_title priority=1100)
  evidence: "◑ Grant meaning"
  ```
  and on a self-reported agent it refuses outright:
  ```
  {"error":{"code":"agent_explain_unavailable","message":"agent target <pane> does not have a
   detected agent label"}}
  ```
  **There is therefore nothing to copy from the Claude integration for state parity.** Its
  `agent_session` field is identity; its state comes from a manifest rule. We would need our
  own screen manifest, which is ceiling 3.
- **`release-agent` DELETES a self-reported registration; it does not hand authority back.**
  Measured before/after on a self-registered pane: present in `herdr agent list` (count 1),
  then after `herdr pane release-agent <pane> --source minimax-code --agent mcode` the count is
  **0** and `herdr agent get <name>` returns `agent_not_found`. It does not revert to
  screen-detected state, because there is no screen detection to revert to. **A
  self-reporting integration must not call `release-agent`** expecting the agent to survive as
  a detected one.
- **`report-agent` must precede `report-agent-session` when a `resume_argv` is attached.**
  Called the other way round:
  ```
  {"error":{"code":"resume_not_accepted","message":"resume_argv requires the reporter to hold
   the pane; report its state with pane.report_agent first"}}
  ```
  The identical call succeeds once `report-agent` has run. Ordering, not capability.
- **`herdr agent rename` makes an agent name-addressable but cannot make it *active*.** After
  registering and renaming, `get` / `read` / `wait` all work by name, while `prompt` and
  `send-keys` both return `agent_not_ready` — *"is not an active named agent"*. Renaming is
  not activation; only `agent start` can activate, and its `--kind` enum has no
  `minimax-code`.
- **Correction to an earlier line in this file and in `CLAUDE.md`:** the `herdr agent start
  --kind` enum was recorded as 23 values. Re-counted from `herdr agent start --help` on
  0.9.3 it has **24** (`pi claude codex gemini cursor devin agy cline omp mastracode
  opencode copilot kimi kiro droid amp grok hermes kilo qodercli qwen letta maki muse`).
  The substantive point is unaffected — there is still no `minimax-code` — but the count was
  wrong.

## 11. Sources

- `herdrdev/herdr` @ `5da0a01` — `src/integration/`, `src/api/schema/plugins.rs`,
  `src/api/schema/events.rs`, `src/app/api/plugins/`, `distribution/agent-detection/`,
  `tests/fixtures/plugin-smoke/herdr-plugin.toml`, `skills/herdr/SKILL.md`
- <https://herdr.dev/docs/plugins/> · <https://herdr.dev/docs/integrations/> ·
  <https://herdr.dev/docs/agents/> · <https://herdr.dev/docs/marketplace/>
- Prior art worth reading: `yigitkonur/claude-code-herdr-plugin` (Claude Code → drives
  Codex over a herdr pane, one tool, JSON verdicts instead of screen-scraping — the best
  single reference for agent-to-agent delegation), `persiyanov/herdr-reviewr` and
  `plannotator/herdr-annotate` (pane-app plugins), `vercel-labs/herdr-vercel-sandbox-plugin`,
  `ogulcancelik/herdr-plugin-examples` (official, unmaintained, four languages).
