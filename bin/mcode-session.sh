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
# ---- TWO RESUME MECHANISMS. Do not conflate them. ---------------------------
# Every "is resume broken?" question about this file has this answer, and the two
# halves have completely different evidence behind them. Getting them merged is
# how this file used to overclaim, so the split is stated once, here.
#
#   1. MANUAL resume — `mcode --continue`, run by a person in the pane.
#      UNAFFECTED by anything herdr does. It re-resolves the session by
#      workspace and needs no session id. This is the mechanism in daily use, and
#      it keeps working whether or not herdr stored anything.
#
#   2. herdr RESTART-RESTORE — the `resume_argv` recorded on the pane, which
#      herdr would re-run in a pane it recreated after a restart.
#      ASSUME UNAVAILABLE, and do not claim otherwise. Two separate reasons, and
#      they must not be merged:
#        * it is UNVERIFIABLE — `herdr agent get` exposes no resume field at all,
#          so no call available to this script can report whether herdr kept it;
#        * and on 0.9.3 the write is DISCARDED anyway (measured below), which is
#          good reason to assume it went with everything else.
#      Unverifiable plus discarded is not the same claim as verified-absent, and
#      this script only ever says the second about the session id, which the
#      read-back can actually see.
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
#   HERDR_PANE_ID          the pane to register — this pane. Required for
#                          `report` and `attach`.
#   MCODE_AGENT_LABEL      agent label to register under         (default: mcode)
#   MCODE_AGENT_SOURCE     --source value for the report      (default: herdr:minimax-code)
#   MCODE_HOME             mcode's data dir                   (default: $HOME/.minimax)
#   MCODE_RESUME_CMD       resume command, space-separated   (default: "mcode --continue")
#
# Dependencies: jq and coreutils. No network, no state outside the herdr registry.
#
# ---- THE LABEL DEFAULT, AND WHY IT USED TO BE WRONG --------------------------
# This used to default to `minimax-code` while bin/mcode-plugin.sh and
# bin/mcode-watch.sh both defaulted to `mcode`. Three reporters, two different
# labels for one agent. It is invisible on a single pane — and wrong from the
# second pane onwards, because the launch path hands the first pane a real name
# from its `mcode`, `mcode-2`, `mcode-3` sequence and the watcher then reports
# under a name the pane does not have. All three now default to `mcode`, and the
# launcher passes the ACTUAL name it chose (issue #75).
#
# `--source` is a separate axis and is NOT unified this way: it is the namespace
# herdr uses to tell reporters apart, so it stays fixed and identical across all
# three. One shared value, per tests/source-run.sh.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
MCODE_HOME="${MCODE_HOME:-$HOME/.minimax}"
AGENT_LABEL="${MCODE_AGENT_LABEL:-mcode}"
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

# Verify what herdr actually kept after a session report, and describe it.
#
# Outcomes, and the wording is load-bearing — each says a different fact, and
# collapsing any two of them would be a smaller version of the lie #71 is about:
#
#   * id sent, reads back          → say nothing. A confirmed write needs no
#                                    commentary, and this is the anti-cheat case:
#                                    a read-back that always warns is as wrong as
#                                    one that never warns.
#   * id sent, absent or different → name the id, the pane, the cause, and what
#                                    is verified lost. Session identity is
#                                    VERIFIED absent by the read-back; whether
#                                    herdr kept the resume command is a
#                                    SEPARATE question this API cannot answer —
#                                    see the header block.
#   * id sent, `agent get` failed  → could not confirm. NOT a claim of loss.
#   * no id sent                    → identity is a different question (nothing
#                                    was sent), and resume persistence is
#                                    structurally unverifiable either way.
verify_session_readback() { # verify_session_readback <pane> [session-id]
  local pane="$1" sid="${2:-}" out found reported

  # `if ! out=$(...)` and not a bare capture: under `set -e` a failing assignment
  # aborts before any diagnostic can print, which is the failure mode #71 is about.
  if ! out=$("$HERDR" agent get "$pane" 2>/dev/null); then
    if [ -n "$sid" ]; then
      log "mcode-session: reported session ${sid} for pane ${pane}, but could not verify it: \`${HERDR} agent get ${pane}\` failed. Session identity and the resume command are UNVERIFIED — neither confirmed stored nor confirmed lost. Not a registration failure: the pane is registered. Exiting 0."
    else
      log "mcode-session: no session id was reported, and \`${HERDR} agent get ${pane}\` failed, so the read-back could not verify what this pane holds. Identity is unconfirmed; whether the resume command was persisted is unverifiable regardless, because \`agent get\` exposes no resume field. Not a registration failure: the pane is registered. Exiting 0."
    fi
    return 0
  fi

  # `|| true` for the same reason: an unparseable response is "could not verify",
  # not a reason to abort a run whose registration already succeeded.
  found=$(printf '%s' "$out" | readback_session_id)

  if [ -n "$sid" ]; then
    if [ "$found" = "$sid" ]; then
      # Confirmed. Silence is the correct output here; a "yay it worked" line would
      # be noise on a path that is supposed to be the uneventful one.
      return 0
    fi
    if [ -n "$found" ]; then
      reported="a different session ('${found}')"
    else
      reported="no session at all (agent_session is absent)"
    fi
    # Two different resume mechanisms, and only one of them is settled here.
    # Conflating them is the mistake this wording used to make.
    #
    #   * Session identity — VERIFIED absent. The read-back just looked, and it
    #     is not there. This is a fact.
    #   * resume_argv / herdr restart-restore — UNVERIFIABLE. `agent get` has no
    #     resume field, so no API call can tell us whether herdr kept the resume
    #     command. herdr discarded this whole call, which is good reason to
    #     *assume* it went too, but assume is not verify, and saying otherwise
    #     would be asserting a measurement nobody took.
    #   * Manual `mcode --continue` — UNAFFECTED. It re-resolves by workspace and
    #     needs no session id at all, so it works whether or not herdr kept
    #     anything. That is the mechanism people actually use today.
    log "mcode-session: reported session ${sid} for pane ${pane}, but herdr 0.9.3 did not persist it — \`agent get\` reports ${reported}. Session identity is NOT stored: that is verified by the read-back, not inferred. Whether herdr kept the resume command is a separate question this API cannot answer — \`agent get\` exposes no resume field — so ASSUME herdr restart-restore is unavailable rather than rely on it. Manual resume is unaffected: '${MCODE_RESUME_CMD}' re-resolves by workspace and needs no session id. This is a herdr limitation for agent kinds it does not enumerate (mcode is not one), not a plugin error, and it is upstream. The pane IS registered; exiting 0 so no caller retries work that cannot succeed."
    return 0
  fi

  # No id was sent, so there is nothing to compare against — but the read-back is
  # still worth making, because what it finds is attributable: any session on this
  # pane is one this run did NOT put there. That is a stale registration from an
  # earlier run or another reporter, and a stale registration is worse than none.
  # Reading it and saying nothing would be the silent no-op this whole change
  # exists to remove, so the read-back is made unconditionally.
  if [ -n "$found" ]; then
    log "mcode-session: no session id was reported, and the read-back shows pane ${pane} already carries session '${found}', which this run did NOT report — a registration left by an earlier run or by another reporter. Expect resume to be unavailable until that is resolved."
  else
    log "mcode-session: no session id was reported, and the read-back confirms pane ${pane} holds no session — nothing was stored, and nothing was sent to be stored."
  fi
  # True regardless of what the read-back found, and true for a structural reason
  # rather than an unlucky one: `herdr agent get` has no resume field at all, so
  # there is no API through which to check whether herdr kept the resume command.
  log "mcode-session: herdr restart-restore is unverifiable from here. Whether herdr kept the resume command ('${MCODE_RESUME_CMD}') cannot be checked: \`herdr agent get\` exposes no resume field, and on herdr 0.9.3 the session report is discarded outright, so assume restart-restore is unavailable. Manual resume is a different mechanism and is unaffected — it re-resolves by workspace and needs no session id. The pane IS registered; exiting 0."
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

  # Narration for the operator, who ran this verb by hand and asked what it did.
  # Deliberately NOT in issue_session_report: `attach` runs inside every launch,
  # where nobody asked a question, and repeating this unasked is noise. The
  # read-back below is the one line that survives in both verbs.
  if [ -n "$sid" ]; then
    log "mcode-session: resolved session ${sid} for this pane's cwd"
  else
    # Deliberate, not accidental: the lookup above cannot succeed against today's
    # manifest schema, and reporting a wrong id is worse than reporting none.
    #
    # This line went through two corrections, both because it made claims the
    # evidence does not support.
    #
    # It used to end "Resume is unaffected: '…' re-resolves by workspace". "Resume
    # is unaffected" reads as a claim about whether herdr KEPT the resume command,
    # and herdr discarded the whole report-agent-session call on 0.9.3 —
    # resume_argv included — so we cannot say it was kept.
    #
    # The second correction is the one that mattered: even "the command does not
    # depend on an id" was still merging two mechanisms. `mcode --continue` run by
    # a person genuinely is unaffected, and needs no id. herdr restart-restore is
    # a different mechanism fed by a different write, and nothing here can report
    # on it. So the claim is now scoped to MANUAL resume by name, and points at
    # the header block, which is the single authoritative statement of the split.
    log "mcode-session: no session id could be resolved for this pane (no manifest records a cwd), so none is reported. MANUAL resume is unaffected: '${MCODE_RESUME_CMD}' re-resolves by workspace and needs no session id. That is separate from herdr restart-restore, whose resume command this API cannot report on at all."
  fi

  # The session report itself is shared with `attach` (issue #79) so the argv, the
  # --source and the label cannot drift between the two verbs.
  if ! issue_session_report "$pane" "$sid"; then
    die "\`${HERDR} pane report-agent-session ${pane}\` failed. The state report above succeeded, so the pane is registered; the session identity was not attached."
  fi

  # Exit 0 from the call above is not evidence the write happened — herdr 0.9.3
  # discards this report and still exits 0 (measurement block at the top). So the
  # pane is read back afterwards, unconditionally.
  #
  # Unconditional, including when no id was sent. There is nothing to *compare*
  # against in that case, but the read-back still reports something attributable:
  # any session already on the pane is one this run did not put there, which is a
  # stale registration worth naming. Skipping the call would make the no-id path
  # the one path that reports success without looking.
  verify_session_readback "$pane" "$sid"
}

issue_session_report() { # issue_session_report <pane> <session-id>; 0 only if herdr accepted
  local pane="$1" sid="$2"
  # shellcheck disable=SC2206  # deliberate word-splitting: a command line
  local -a resume_argv=(${MCODE_RESUME_CMD})
  local -a session_argv=(pane report-agent-session --source "$AGENT_SOURCE" --agent "$AGENT_LABEL")
  if [ -n "$sid" ]; then
    session_argv+=(--agent-session-id "$sid")
  fi
  session_argv+=("$pane")
  session_argv+=(--)
  session_argv+=("${resume_argv[@]}")
  "$HERDR" "${session_argv[@]}"
}

# Attach identity to a pane some OTHER step has already registered. This is the
# narrow half of `report`, added for issue #79.
#
# WHY IT EXISTS, and why `report` was the wrong thing to call from the launcher:
# `report` re-asserts the agent state and therefore issues its own
# `pane report-agent`. Calling it from cmd_start produced a SECOND report-agent for
# one pane — two reporters claiming the same pane in one launch, which is exactly
# the duplication the three-reporter design is supposed to avoid. The launcher
# already reported the state in its own step; repeating it is not tidiness, it is a
# second claim on the same pane.
#
# `attach` therefore issues `pane report-agent-session` and nothing else. The
# ordering law still holds, and holds for a better reason: herdr only accepts a
# session report from a reporter that already holds the pane, and the HOLDING IS
# DONE BY THE LAUNCHER's earlier report-agent. That is why this verb must not be
# reordered ahead of it, and why `attach` deliberately does not establish the
# holding itself.
#
# QUIET BY DEFAULT. `report` is a verb a person runs by hand and wants to see each
# step of. `attach` runs inside every launch, where the launch path has already said
# what it is doing; the discovery chatter ("using session store", "resolved
# session") is narration for an operator who asked a question, and repeating it
# unasked is noise. The ONE line that must survive is the read-back's, because on
# herdr 0.9.3 it is the only thing telling the user their session was discarded.
cmd_attach() {
  local pane="${HERDR_PANE_ID:-}"
  if [ -z "$pane" ]; then
    die "HERDR_PANE_ID is unset, so there is no pane to attach a session to. Nothing was sent."
  fi

  # Resolved the same way `report` resolves it, and for the same reason it cannot
  # currently succeed: today's manifest schema records no cwd, so the lookup
  # returns nothing and no id is reported. A wrong id is worse than none.
  local root sid=""
  if root=$(sessions_root); then
    sid=$(resolve_session_for_cwd "$root" "$(pwd)")
  fi

  if ! issue_session_report "$pane" "$sid"; then
    die "\`${HERDR} pane report-agent-session ${pane}\` failed, so the session identity was NOT attached. The pane's registration is untouched by this verb; only identity and the resume command are missing."
  fi

  verify_session_readback "$pane" "$sid"
}

main() {
  case "${1:-}" in
    resolve) cmd_resolve ;;
    report)  cmd_report ;;
    attach)  cmd_attach ;;
    *)
      log "usage: mcode-session.sh {resolve|report|attach}"
      log ""
      log "  resolve  print the resolution outcome; never mutates anything"
      log "  report   resolve, re-assert this pane's agent state, then attach identity"
      log "  attach   attach identity ONLY - for a caller that has already reported"
      log "           the pane's state, such as the launch path. Quieter than report."
      exit 2
      ;;
  esac
}

main "$@"
