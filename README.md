# herdr-plugin-minimax-code

A [Herdr](https://herdr.dev) plugin for [MiniMax Code](https://github.com/MiniMax-AI).

## Status

v0.2.0. The manifest is valid, the entrypoint runs, and `cmd_start` launches
`mcode` in a new pane beside the active one.

Herdr does not detect MiniMax Code, so there is no way to list the agents this
plugin has started. It launches them; that is the whole surface.

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
| `minimax-code-start` | action | Launch `mcode` in a new pane for the active worktree |

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

<!-- TODO(architect): confirm this is the command that passes once #C2 merges -->

## License

[MIT](LICENSE) — Copyright (c) 2026 `jaaacki`.
