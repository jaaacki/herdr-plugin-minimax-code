#!/usr/bin/env bash
# MiniMax Code herdr plugin entrypoint.
#
# Herdr injects the environment; do not assume these when run by hand.
#   HERDR_BIN_PATH             path to the running herdr binary
#   HERDR_PLUGIN_ROOT           this plugin's checkout
#   HERDR_PLUGIN_ID             jaaacki.minimax-code
#   HERDR_PLUGIN_CONTEXT_JSON   invocation context
#   HERDR_PLUGIN_EVENT          event name, for event hooks
#   HERDR_PLUGIN_EVENT_JSON     event payload, for event hooks
#   HERDR_WORKSPACE_ID / HERDR_TAB_ID / HERDR_PANE_ID
#
# "The entire Herdr CLI is the plugin API" — anything you can run as
# `herdr ...` yourself, this script can run.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"

log() { printf '%s\n' "$*" >&2; }

cmd_start() {
  local workspace="${HERDR_WORKSPACE_ID:-}"
  log "TODO: start \`mcode\` in a new pane for workspace ${workspace:-<current>}"
  log "      reference: herdr agent start mcode --kind KIND --pane ID -- mcode"
}

cmd_status() {
  # herdr agent list emits JSON; read ids and state from it rather than guessing.
  "$HERDR" agent list
}

cmd_on_status_change() {
  local event="${HERDR_PLUGIN_EVENT_JSON:-}"
  log "pane.agent_status_changed: ${event}"
}

main() {
  case "${1:-}" in
    start)             cmd_start ;;
    status)            cmd_status ;;
    on-status-change)  cmd_on_status_change ;;
    *)
      log "usage: mcode-plugin.sh {start|status|on-status-change}"
      exit 2
      ;;
  esac
}

main "$@"
