#!/usr/bin/env bash
# mcode-session.sh — register this pane's mcode session with herdr, and record
# the command herdr would use to resume it after a restart.
#
# STATUS: wired but UNVERIFIED. This records a resume command; nobody has yet
# watched herdr restore a pane from one. The restart needed to prove it cannot
# be run safely anywhere yet — every candidate environment is a live machine
# whose other work a restart would destroy. So: the registration is tested, the
# resume is reasoned, not demonstrated. Do not describe it as working.
#
# ---- MEASURED: herdr 0.9.3 discards the session report (issue #71) -----------
# Re-measured first-hand on 2026-10-04 against herdr 0.9.3, and the same result is
# reported independently in sparkfn/pc-client#2251 (six exit-0 reports, zero
# persisted fleet-wide). Do not re-derive this; it is the reason the read-back
# below exists.
#
#   $ herdr pane report-agent <pane> --source herdr:minimax-code \
#         --agent minimax-code --state idle -- mcode --continue
#   $ herdr pane report-agent-session <pane> --source herdr:minimax-code \
#         --agent minimax-code --agent-session-id mvs_testdeadbeef -- mcode --continue
#   $ echo $?          # 0
#   $ herdr agent get <pane> | jq -r '.result.agent.agent_session'
#   null
#
# Facts that matter, all on 0.9.3:
#
#   * `pane report-agent-session` exits 0 and the write does not happen. No error,
#     no warning, nothing persisted. This is the silent no-op shape that the
#     ${HERDR_PLUGIN_ROOT} bug used to have, and that we have now been caught by
#     three times.
#   * The id's shape, `--session-start-source`, and an enormous `--seq` make no
#     difference; the discard is unconditional. The --seq case rules out a stale
#     watermark, which was the most plausible benign explanation left.
#   * Root cause is upstream: herdr persists session identity only for the closed
#     set of agent kinds it enumerates in `agent start`, and mcode is not one of
#     them. We cannot patch that from this repo. It is a separate epic.
#   * Fleet-wide, only `herdr:claude` and `herdr:codex` panes carry a session.
#
# Two API details that are easy to get wrong and are load-bearing below:
#
#   * `agent_session` is an OBJECT, not a string. A pane that does have a session
#     returns {"agent":..,"kind":"id","source":"herdr:claude","value":"94929c8f-…"},
#     so the id is at `.result.agent.agent_session.value` and `kind` discriminates
#     it. Reading `.result.agent.agent_session` directly yields the whole object as
#     text and can never equal a bare `mvs_…` id. On an mcode pane the key is
#     ABSENT, not present-and-null.
#   * `herdr agent get` exposes NO resume field at all — there is no resume_argv
#     anywhere in the response. So resume persistence is structurally
#     unverifiable through this API, which is why the no-session-id path below
#     says exactly that instead of implying it checked.
#
# Consequence for this script: reporting is not proof. After the report it now
# reads the pane back and says what herdr actually kept. That is a warning, never
# an error — see verify_session_readback for why.
#
# Two ways this gets used:
#
#   * Operator-run today. Run it from inside the mcode pane you want registered:
#         cd <pane's workspace> && HERDR_PANE_ID=<pane> bin/mcode-session.sh report
#     `herdr pane list` gives you the pane id. Until the launch path calls this
#     automatically (issue #44 wires it; that file is in flight), running it by
#     hand is the only way a pane gets registered.
#
#   * Called by the launch path once #44 lands. It is deliberately not called
#     from bin/mcode-plugin.sh yet, because that file is #34's and in flight.
#
# It must run inside the pane it registers: herdr rejects a resume_argv whose
# reporter does not hold that pane ("resume_argv requires the reporter to hold
# the pane").
#
#   resolve   print the resolution outcome; never mutates anything
#   report    resolve, re-assert the pane's agent state, attach identity, then
#             read the report back and warn if herdr discarded it (issue #71)
#
# Environment (all optional):
#   HERDR_BIN_PATH         path to the herdr binary
#   HERDR_PANE_ID          the pane to register — this pane. Required for `report`.
#   MCODE_AGENT_LABEL      agent label to register under      (default: minimax-code)
#   MCODE_AGENT_SOURCE     --source value for the report      (default: herdr:minimax-code)
#   MCODE_HOME             mcode's data dir                   (default: $HOME/.minimax)
#   MCODE_RESUME_CMD       resume command, space-separated   (default: "mcode --continue")
#
# Dependencies: jq and coreutils. No network, no state outside the herdr registry.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
MCODE_HOME="${MCODE_HOME:-$HOME/.minimax}"
AGENT_LABEL="${MCODE_AGENT_LABEL:-minimax-code}"
# --source namespace. Must match the other two reporters, and follows herdr's
# own `herdr:<agent>` convention (see the Claude integration hook). herdr uses
# this to tell reporters apart; three different values for one agent defeats it.
# Overridable for testing, like the label above.
AGENT_SOURCE="${MCODE_AGENT_SOURCE:-herdr:minimax-code}"

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
# The most recently *updated* store under $MCODE_HOME, by the manifests' own
# updatedAtMs.
#
# Ranking by updatedAtMs rather than by filesystem mtime is deliberate, and it
# matters twice over. It is portable — no `stat`, whose -f flag means "format" on
# BSD and "filesystem" on GNU, so a `stat`-based version silently breaks on every
# Linux runner. And it is the same notion of "newest" that
# resolve_session_for_cwd already uses, so discovery and resolution agree instead
# of ranking by two unrelated clocks.
sessions_root() {
  local dir best="" best_ms=-1 newest
  for dir in "$MCODE_HOME"/*/sessions; do
    [ -d "$dir" ] || continue
    newest=$(find "$dir" -name manifest.json -type f 2>/dev/null | head -200 \
             | while IFS= read -r manifest; do
                 jq -r '(.updatedAtMs // .createdAtMs // 0) | tostring' \
                    "$manifest" 2>/dev/null
               done | sort -rn | head -1)
    newest="${newest:--1}"
    if [ "$newest" -gt "$best_ms" ]; then
      best_ms="$newest"
      best="$dir"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
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
    # No `select(type == "string")` here: the input is the manifest object, so
    # `type` is "object" and such a filter discards every row. Only the id
    # itself is type-checked.
    jq -r 'select((.sessionId | type) == "string")
           | "\(.updatedAtMs // .createdAtMs // 0)\t\(.sessionId)"' \
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

# --- read-back: did the report actually land? ---------------------------------
# herdr accepts `pane report-agent-session` and discards it (see the measurement
# block at the top of this file). Exit 0 from a CLI call is a claim about the
# process, not about the state, and the state is the only thing anyone downstream
# needs. So the report is read back and the difference is stated.
#
# WHY A WARNING AND NOT A FAILURE. The launch and the registration both already
# succeeded; what is missing is a capability herdr declined to provide. Exiting
# non-zero would report a success as a failure and invite a caller to retry,
# which would spawn duplicate work to fix something that is not ours to fix. The
# one thing that is not negotiable is silence: exiting 0 while claiming a session
# was stored is the exact defect #71 exists to close. So every path here returns
# 0, and every path that did not confirm says so in words.

# Print the session id herdr actually holds for a pane, or nothing.
#
# `.result.agent.agent_session` is an object whose id is at `.value` (see the
# header), so a plain read of that path would hand back the whole object. A bare
# string is also accepted, because that is the shape this field would most
# plausibly take if herdr ever flattened it, and rejecting it would manufacture a
# false "discarded" warning on a working setup. Anything else — absent, null, an
# object with no string `.value` — yields nothing, which the caller reports as
# "herdr holds no session id here".
readback_session_id() { # readback_session_id  — reads an `agent get` response on stdin
  jq -r '
      (.result.agent.agent_session // empty)
      | if type == "string" then .
        elif type == "object" then (.value // empty)
        else empty
        end
      | select(type == "string")
    ' 2>/dev/null || true
}

# Verify a session id that was just reported, and describe the outcome.
#
# Three outcomes, per the issue #71 table:
#   * it reads back            → say nothing. A confirmed write needs no commentary.
#   * it does not              → name the id, the pane, the cause, and what is lost.
#   * it cannot be checked     → say that, distinctly. "I could not confirm" and
#                                "I confirmed it is gone" are different facts and
#                                collapsing them would be its own small lie.
verify_session_readback() { # verify_session_readback <pane> <session-id>
  local pane="$1" sid="$2" out found

  # `if ! out=$(...)` and not a bare capture: under `set -e` a failing assignment
  # aborts before any diagnostic can print, which is the failure mode #71 is about.
  if ! out=$("$HERDR" agent get "$pane" 2>/dev/null); then
    log "mcode-session: reported session ${sid} for pane ${pane}, but could not verify it: \`${HERDR} agent get ${pane}\` failed. Session identity and the resume command are UNVERIFIED — neither confirmed stored nor confirmed lost. Not a registration failure: the pane is registered. Exiting 0."
    return 0
  fi

  # `|| true` for the same reason: an unparseable response is "could not verify",
  # not a reason to abort a run whose registration already succeeded.
  found=$(printf '%s' "$out" | readback_session_id)

  if [ "$found" = "$sid" ]; then
    # Confirmed. Silence is the correct output here; a "yay it worked" line would
    # be noise on a path that is supposed to be the uneventful one.
    return 0
  fi

  local reported
  if [ -n "$found" ]; then
    reported="a different session ('${found}')"
  else
    reported="no session at all (agent_session is absent)"
  fi

  log "mcode-session: reported session ${sid} for pane ${pane}, but herdr 0.9.3 did not persist it — \`agent get\` reports ${reported}. Session identity and the resume command are NOT stored, so expect resume to be UNAVAILABLE. This is a herdr limitation for agent kinds it does not enumerate (mcode is not one), not a plugin error, and it is upstream. The pane IS registered; exiting 0 so no caller retries work that cannot succeed."
  return 0
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
  # A resume_argv is only accepted when the reporter actually holds the pane, and
  # "holds" is stricter than it looks. Measured on herdr 0.9.3:
  #
  #   * A freshly split pane, not yet claimed by any detected agent session:
  #     both calls succeed, exit 0. This is the launch-path case and the one the
  #     plugin depends on.
  #   * A pane herdr has already attributed to a detected agent session (this
  #     one became a `claude` pane with an agent_session id mid-session):
  #     report-agent with a resume_argv is refused as `resume_not_accepted`,
  #     under *either* agent label, while the same call without a resume argv
  #     succeeds. So the rejection is not about ordering at all — herdr's hint to
  #     "report its state with pane.report_agent first" is misleading, because
  #     this call *is* report_agent.
  #
  # Both calls carry the resume command, so a refusal here means this pane cannot
  # be given a resume command, and the failure is reported rather than swallowed.
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

  # Exit 0 from the call above is not evidence the write happened — herdr 0.9.3
  # discards this report and still exits 0 (measurement block at the top). So the
  # report is read back, and the outcome is stated either way.
  #
  # Only when an id was actually sent. With no id there is nothing to compare
  # against, and reading the pane back anyway would produce a number we have no
  # right to attribute to this run — a session on the pane could be a stale one
  # from an earlier reporter. Claiming a check we cannot make is worse than
  # saying plainly that there was nothing to check.
  if [ -n "$sid" ]; then
    verify_session_readback "$pane" "$sid"
  else
    # The honest version of the line above. That one says the resume *command* is
    # usable by design; this one says what we could not establish about whether
    # herdr kept anything. Both are true and they are not the same claim, so both
    # are stated: `agent get` exposes no resume field, so resume_argv persistence
    # is unverifiable through this API, and with no id sent, identity is too.
    log "mcode-session: nothing was sent to verify. No session id was reported, so identity is unverifiable; and \`herdr agent get\` exposes no resume field at all, so whether the resume command was persisted is unverifiable too. Neither is confirmed and neither is confirmed lost. The pane IS registered; exiting 0."
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
