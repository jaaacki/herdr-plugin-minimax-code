#!/usr/bin/env bash
# mcode-session.sh — resolve this pane's mcode session identity and register it
# with herdr, including a command that resumes the session after a restart.
#
# Standalone on purpose. It is NOT called from bin/mcode-plugin.sh: that file is
# owned by issue #34 and is in flight, so the wiring is left to its owner. This
# script is designed to be invoked from inside the pane it registers, because
# herdr rejects a resume_argv whose reporter does not hold the pane
# ("resume_argv requires the reporter to hold the pane").
#
#   resolve   print the resolution outcome; never mutates anything
#   report    resolve, then call `pane report-agent-session`
#
# Environment (all optional):
#   HERDR_BIN_PATH         path to the herdr binary
#   HERDR_PANE_ID          the pane to register — this pane. Required for `report`.
#   MCODE_AGENT_LABEL      agent label to register under      (default: minimax-code)
#   MCODE_AGENT_SOURCE     --source value for the report      (default: the plugin id)
#   MCODE_HOME             mcode's data dir                   (default: $HOME/.minimax)
#   MCODE_RESUME_CMD       resume command, space-separated   (default: "mcode --continue")
#
# Dependencies: jq and coreutils. No network, no state outside the herdr registry.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
MCODE_HOME="${MCODE_HOME:-$HOME/.minimax}"
AGENT_LABEL="${MCODE_AGENT_LABEL:-minimax-code}"
AGENT_SOURCE="${MCODE_AGENT_SOURCE:-jaaacki.minimax-code}"

# The resume command herdr will re-run in the restored pane.
#
# Default is the bare name `mcode --continue`, because `report-agent --help`
# documents RESUME_ARG as "starts with a plain command name". An absolute path
# would be more robust against a different PATH in the restored pane, but I have
# not established that herdr accepts a path there, and the only way to settle it
# is to actually restore a pane — which is issue #36's outstanding criterion.
# Override with MCODE_RESUME_CMD if the bare name proves unreliable.
MCODE_RESUME_CMD="${MCODE_RESUME_CMD:-mcode --continue}"

log() { printf '%s\n' "$*" >&2; }
die() { log "mcode-session: $*"; exit 1; }

# --- session store discovery ---------------------------------------------------
# The store is versioned: today ~/.minimax/v2/sessions, and each manifest carries
# layout = "v2-final-dated-session". `v2` is a layout marker and will change, so
# it is discovered rather than hard-coded. If several exist, the most recently
# modified wins and the choice is stated on stderr.
sessions_root() {
  local candidate newest="" newest_mtime=-1 dir
  for dir in "$MCODE_HOME"/*/sessions; do
    [ -d "$dir" ] || continue
    candidate="$dir"
    local mtime
    mtime=$(find "$dir" -name manifest.json -type f -print0 2>/dev/null \
             | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1)
    mtime="${mtime:--1}"
    if [ "$mtime" -gt "$newest_mtime" ]; then
      newest_mtime="$mtime"
      newest="$candidate"
    fi
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

# --- session id resolution -----------------------------------------------------
# Resolves the session belonging to $2 (a cwd) by picking the manifest with the
# greatest updatedAtMs among those that record that cwd.
#
# Today this returns nothing, and that is the correct result rather than a gap in
# the search: mcode's manifest does not record a cwd. Verified 2026-10-04 against
# every live session on this machine — all manifests carry exactly these keys and
# no others:
#
#   createdAtMs, layout, paths, schemaVersion, sessionId, source, updatedAtMs
#
# There is no cwd, no workspace, no pid and no pane id, and no session-id variable
# exists in the pane's environment, so "the newest manifest for this pane's cwd"
# cannot be evaluated at all. Selecting by pid (.mcode-active holds only
# pid+startedAtMs) or by time was measured and is unusable: 19 live pids against
# 9 sessions, offsets from +47s to -37 minutes, many pids collapsing onto one
# session.
#
# The lookup is kept because it costs nothing and becomes correct the moment mcode
# records a cwd in the manifest. Until then it deliberately resolves to nothing
# rather than guessing — a fabricated or merely-nearest id resumes the wrong
# session, or none, and says nothing when it fails.
resolve_session_for_cwd() {
  local root="$1" want_cwd="$2"
  [ -d "$root" ] || return 0
  find "$root" -name manifest.json -type f 2>/dev/null | while IFS= read -r manifest; do
    local cwd
    cwd=$(jq -r '(.cwd // .workspace.cwd // .paths.cwd // empty) | select(type == "string")' \
          "$manifest" 2>/dev/null) || continue
    [ "$cwd" = "$want_cwd" ] || continue
    jq -r 'select(type == "string") | "\(.updatedAtMs // .createdAtMs // 0)\t\(.sessionId)"' \
       "$manifest" 2>/dev/null
  done | sort -rn | head -1 | cut -f2
}

# The agent status herdr already records for a pane, or nothing if the pane is
# not registered yet.
#
# Re-asserting the existing state rather than imposing one matters: this script
# owns identity and resume, not state (issue #35 owns state tracking). Reporting
# a placeholder like `unknown` to satisfy the ordering requirement would quietly
# overwrite a real `working` status, which is exactly what happened when this was
# first tried by hand. MCODE_AGENT_STATE overrides.
current_agent_state() {
  "$HERDR" agent get "$1" 2>/dev/null \
    | jq -r '(.result.agent.agent_status // .result.agent_status // empty) | select(type == "string")' \
    2>/dev/null || true
}

# --- subcommands ---------------------------------------------------------------
cmd_resolve() {
  local root
  if ! root=$(sessions_root); then
    printf 'sessions_root\t<none found under %s>\n' "$MCODE_HOME"
    return 0
  fi
  local sid
  sid=$(resolve_session_for_cwd "$root" "$(pwd)")
  printf 'sessions_root\t%s\n' "$root"
  printf 'resume_cmd\t%s\n' "$MCODE_RESUME_CMD"
  if [ -n "$sid" ]; then
    printf 'session_id\t%s\n' "$sid"
    printf 'chosen_by\tmanifest recording this cwd, greatest updatedAtMs\n'
  else
    printf 'session_id\t<unresolved>\n'
    printf 'chosen_by\tnone - no manifest records a cwd, and an id must not be invented\n'
  fi
}

cmd_report() {
  local pane="${HERDR_PANE_ID:-}"
  if [ -z "$pane" ]; then
    die "HERDR_PANE_ID is unset. This script must run inside the pane it registers: herdr rejects a resume_argv whose reporter does not hold the pane."
  fi

  local root
  if root=$(sessions_root); then
    log "mcode-session: using session store ${root}"
  else
    log "mcode-session: no session store found under ${MCODE_HOME}; continuing without identity"
  fi

  local sid=""
  if [ -n "$root" ]; then
    sid=$(resolve_session_for_cwd "$root" "$(pwd)")
  fi

  # Establishing the reporter as this pane's holder, then attaching identity.
  #
  # The state report is not decoration, but it is not a permanent ordering
  # constraint either. Verified by execution on herdr 0.9.3: on a pane this
  # reporter had never registered, `pane report-agent-session` carrying a
  # resume_argv is rejected with
  #
  #   resume_not_accepted: resume_argv requires the reporter to hold the pane;
  #   report its state with pane.report_agent first
  #
  # Once the pane is registered, the session report alone succeeds — deleting the
  # state call from this script still exits 0. So the rule is: establish the
  # reporter once, then attach identity. Both calls carry the resume command, so
  # either ordering records it.
  local state
  state=$(current_agent_state "$pane")
  if [ -z "$state" ]; then
    state="${MCODE_AGENT_STATE:-unknown}"
    log "mcode-session: no existing agent state for pane ${pane}; reporting '${state}'"
  else
    log "mcode-session: re-asserting existing agent state '${state}' for pane ${pane}"
  fi

  # shellcheck disable=SC2206  # deliberate word-splitting: RESUME_CMD is a command line
  local -a resume_argv=(${MCODE_RESUME_CMD})

  if ! "$HERDR" pane report-agent "$pane" --source "$AGENT_SOURCE" --agent "$AGENT_LABEL" \
        --state "$state" -- "${resume_argv[@]}"; then
    die "\`${HERDR} pane report-agent ${pane}\` failed, so the pane is not registered and the resume command was not recorded."
  fi

  local -a session_argv=(pane report-agent-session --source "$AGENT_SOURCE" --agent "$AGENT_LABEL")
  if [ -n "$sid" ]; then
    session_argv+=(--agent-session-id "$sid")
    log "mcode-session: resolved session ${sid} for this pane's cwd"
  else
    # Deliberate, not accidental: the lookup above cannot succeed against today's
    # manifest schema, and reporting a wrong id is worse than reporting none.
    # Resume still works, because `mcode --continue` re-resolves by workspace at
    # restore time and needs no id.
    log "mcode-session: no session id could be resolved for this pane (no manifest records a cwd), so none is reported. Resume is unaffected: '${MCODE_RESUME_CMD}' re-resolves by workspace."
  fi
  session_argv+=("$pane")
  session_argv+=(--)
  session_argv+=("${resume_argv[@]}")

  if ! "$HERDR" "${session_argv[@]}"; then
    die "\`${HERDR} pane report-agent-session ${pane}\` failed. The state report above succeeded, so the pane is registered; the session identity was not attached."
  fi
}

main() {
  case "${1:-}" in
    resolve) cmd_resolve ;;
    report)  cmd_report ;;
    *)
      log "usage: mcode-session.sh {resolve|report}"
      exit 2
      ;;
  esac
}

main "$@"
