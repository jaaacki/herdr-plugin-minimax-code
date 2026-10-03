# herdr-plugin-minimax-code

A [Herdr](https://herdr.dev) plugin for [MiniMax Code](https://github.com/MiniMax-AI).

## Status

Skeleton. The manifest is valid and the entrypoint runs; the actual behaviour is
still TODO.

## Install

```bash
herdr plugin install jaaacki/herdr-plugin-minimax-code
```

For local development, link the checkout instead — note that `plugin link` does
**not** run `[[build]]` commands, so build anything yourself first:

```bash
git clone git@github.com:jaaacki/herdr-plugin-minimax-code.git
cd herdr-plugin-minimax-code
herdr plugin link .
```

Requires Herdr `0.9.3` or newer. Linux and macOS only for now.

## What it exposes

| Trigger | Kind | Does |
|---|---|---|
| `minimax-code-start` | action | TODO — start `mcode` in a new pane for the active worktree |
| `minimax-code-status` | action | `herdr agent list` |
| `pane.agent_status_changed` | event | logs the event payload |

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
| `HERDR_PLUGIN_CONTEXT_JSON` | invocation context |
| `HERDR_PLUGIN_EVENT_JSON` | event payload, for `[[events]]` hooks |
| `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID` | layout ids |

Action `contexts` are `global`, `workspace`, `tab`, `pane`, `selection`.
Pane `placement` is `overlay`, `popup`, `split`, `tab` or `zoomed`.

Only these events are hookable — anything else is non-fatal but produces a
warning visible in `herdr plugin list --json`:

```
workspace.created    workspace.updated    workspace.closed
workspace.renamed    workspace.moved      workspace.reordered
workspace.focused    worktree.created     worktree.opened
worktree.removed     tab.created          tab.closed
tab.renamed          tab.moved            tab.focused
pane.created         pane.closed          pane.focused
pane.moved           pane.exited          pane.agent_detected
pane.agent_status_changed
```

## License

Add one before publishing.
