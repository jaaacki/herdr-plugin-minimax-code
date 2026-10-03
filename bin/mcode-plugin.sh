#!/usr/bin/env bash
# MiniMax Code Herdr plugin entrypoint.
#
# Herdr injects the environment; do not assume these when run by hand.
#   HERDR_BIN_PATH             path to the running Herdr binary
#   HERDR_PLUGIN_ROOT          this plugin's checkout
#   HERDR_PLUGIN_ID            jaaacki.minimax-code
#   HERDR_PLUGIN_CONTEXT_JSON  invocation context
#   HERDR_WORKSPACE_ID / HERDR_TAB_ID / HERDR_PANE_ID
#
# "The entire Herdr CLI is the plugin API" - anything runnable as the Herdr
# CLI yourself, this script can run. Every invocation below goes through
# $HERDR rather than a hard-coded binary name, so the plugin always talks to
# the running instance.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"

# The launcher binary, resolved from PATH. `pane run` receives the absolute
# path so the launch does not silently depend on the target pane's PATH.
MCODE_BIN_NAME="mcode"

# The new pane's id in a `pane split` response.
#
# VERIFIED, not guessed. tests/fixtures/pane-split.json is a real captured
# response (Herdr 0.9.3, captured 2026-10-04) and:
#   jq -r '.result.pane.pane_id' tests/fixtures/pane-split.json   ->  wZ:p8
#
# Two traps this file must not walk into:
#   - The plausible-looking alternative `.result.pane_id` yields `null`. Had
#     that been used, every launch would trip the guard below and the plugin
#     would never work, with no error to explain why.
#   - `result.type` in the split response is `pane_info`, NOT `pane_split`
#     (the split response is shaped like `pane get`). Nothing here may branch
#     on `result.type`; the top-level `id` is the reliable discriminator.
NEW_PANE_ID_FIELD='.result.pane.pane_id'

log() { printf '%s\n' "$*" >&2; }
die() { log "minimax-code: $*"; exit 1; }

# json_field PATH - print PATH's value as a string, or nothing when the
# document is unparseable or the path is absent. Never fails the caller.
#
# PATH is a jq path expression including its leading dot, e.g.
# '.result.pane.pane_id'. These come from literal constants in this file,
# never from user input, so interpolating one into the filter is safe.
# Do not prepend another dot here: "..foo" is jq's recursive-descent operator,
# which matches nothing here and would make every lookup return empty.
json_field() {
  jq -r "${1} // empty" 2>/dev/null || true
}

# resolve_mcode - print the absolute path to the launcher binary, or fail.
resolve_mcode() {
  command -v "$MCODE_BIN_NAME" 2>/dev/null
}

# resolve_source_pane - print the pane to split, or fail.
#
# The action is registered for both the workspace and pane contexts, and only
# the pane context is guaranteed to set HERDR_PANE_ID, so both branches are
# live paths rather than defensive padding.
resolve_source_pane() {
  local pane="${HERDR_PANE_ID:-}"
  if [ -n "$pane" ]; then
    printf '%s\n' "$pane"
    return 0
  fi

  local out
  if ! out=$("$HERDR" pane current); then
    return 1
  fi

  pane=$(printf '%s' "$out" | json_field '.result.pane.pane_id')
  if [ -z "$pane" ]; then
    return 1
  fi
  printf '%s\n' "$pane"
}

cmd_start() {
  # 1. Preflight. jq parses the CLI's JSON output; without it a missing parser
  #    would surface as a confusing parse error instead of a real diagnostic.
  if ! command -v jq >/dev/null 2>&1; then
    die "\`jq\` is required to read Herdr's JSON output but was not found on PATH. Install it (macOS: \`brew install jq\`; Debian/Ubuntu: \`apt-get install jq\`; Fedora: \`dnf install jq\`) and retry. No pane was created."
  fi

  # Resolved before the split so a missing binary cannot orphan a fresh pane.
  local mcode_bin
  if ! mcode_bin=$(resolve_mcode); then
    die "\`${MCODE_BIN_NAME}\` is not on PATH, so there is nothing to launch. Install MiniMax Code, or add it to PATH, then retry. No pane was created."
  fi
  if [ -z "$mcode_bin" ]; then
    die "\`${MCODE_BIN_NAME}\` did not resolve to a path, so there is nothing to launch. No pane was created."
  fi

  # 2. Resolve the source pane.
  local source_pane
  if ! source_pane=$(resolve_source_pane); then
    die "could not resolve a source pane: HERDR_PANE_ID is unset and \`${HERDR} pane current\` did not yield a pane id. No pane was created."
  fi

  # 3. Resolve cwd. A missing or empty cwd degrades to the CLI's own default
  #    placement rather than failing the whole launch.
  local cwd=""
  local get_out=""
  if get_out=$("$HERDR" pane get "$source_pane" 2>/dev/null); then
    cwd=$(printf '%s' "$get_out" | json_field '.result.pane.cwd')
  fi

  local cwd_args=()
  if [ -n "$cwd" ]; then
    cwd_args=(--cwd "$cwd")
  else
    log "minimax-code: no cwd reported for pane ${source_pane}; splitting without --cwd and letting the CLI place the pane."
  fi

  # 4. Split. Direction is fixed to right for this epic; making it
  #    configurable is a follow-up, not a nit to fix here.
  #
  #    --no-focus is deliberate, not inherited from a fixture note. The
  #    action is registered for the `pane` context, so it can be fired from
  #    the pane the user is actively typing in. If the split took focus,
  #    their in-flight keystrokes would land in the brand-new pane in the
  #    window between the split and mcode starting there. It also keeps the
  #    invocation deterministic in the `workspace` context, where the source
  #    pane comes from `pane current` and need not be the focused pane at
  #    all. The trade-off: the user does not get focus stolen, but the new
  #    pane still appears beside theirs with the agent visibly starting.
  local split_out=""
  if ! split_out=$("$HERDR" pane split "$source_pane" --direction right --no-focus ${cwd_args[@]+"${cwd_args[@]}"}); then
    die "\`${HERDR} pane split ${source_pane} --direction right --no-focus\` failed, so no new pane was created and nothing was launched."
  fi

  # 5. Extract the new pane id.
  #
  #    SAFETY GATE. Both guards below call die, which exits non-zero, so
  #    `pane run` at step 6 is UNREACHABLE whenever the new pane cannot be
  #    identified. `pane run` types text into a pane id; a wrong or empty id
  #    means typing a command into the wrong window, or into no window at all.
  #    Never reorder or weaken these two conditions to "log and continue".
  local new_pane
  new_pane=$(printf '%s' "$split_out" | json_field "$NEW_PANE_ID_FIELD")

  if [ -z "$new_pane" ] || [ "$new_pane" = "null" ]; then
    die "the split of pane ${source_pane} succeeded but '${NEW_PANE_ID_FIELD}' was empty in its response, so the new pane cannot be identified. Refusing to run \`${MCODE_BIN_NAME}\` in an unidentified pane. A new pane may exist: check the layout and close it by hand if it is empty."
  fi

  # A split always produces a *different* pane, so a response naming the
  # source pane means the field layout changed and we misread it. Typing
  # there would hijack the pane the user is working in.
  if [ "$new_pane" = "$source_pane" ]; then
    die "the split of pane ${source_pane} reported that same pane as the new one, so its response was not understood. Refusing to run \`${MCODE_BIN_NAME}\` into the source pane. Check the layout; a new pane may exist."
  fi

  # 6. Run the launcher in the new pane.
  if ! "$HERDR" pane run "$new_pane" "$mcode_bin"; then
    die "\`${HERDR} pane run ${new_pane} ${mcode_bin}\` failed, so MiniMax Code was not started. Pane ${new_pane} exists but is empty; close it by hand with \`${HERDR} pane close ${new_pane}\`."
  fi

  log "minimax-code: started ${mcode_bin} in pane ${new_pane}"
}

main() {
  case "${1:-}" in
    start)
      cmd_start
      ;;
    *)
      log "usage: mcode-plugin.sh start"
      exit 2
      ;;
  esac
}

main "$@"
