#!/usr/bin/env bash
# mcode-session.sh — register this pane's mcode session with herdr, and record
# the command herdr would use to resume it after a restart.
#
# STATUS: wired, and the resume is now PROVEN (issue #85). A named herdr session
# was launched, reported, stopped, restarted and re-attached, and `mcode --continue`
# was observed running in the recreated pane. Before that, restart-restore was
# wired but unverified, and the read-back reported the wrong field — it checked
# `agent_session`, which herdr only populates for agent kinds it enumerates, and so
# called a write that WAS stored "nothing was stored". The resume half is now
# verified by the report's own exit status; the id half, which herdr discards
# silently, is still read back. Read the measurement block below before changing
# any of it: three sharp edges in the restore path are recorded there, and each one
# has already cost a debugging round trip.
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
#      herdr re-runs in a pane it recreated after a restart.
#      WORKS, and is now PROVEN end to end. See the measurement block below.
#
# ---- MEASURED: the resume IS persisted, and a restart DOES run it ------------
# Supersedes the "herdr 0.9.3 discards the session report" conclusion this file
# carried until issue #85. That conclusion was half right, and the half that was
# wrong is the half that mattered.
#
# What herdr actually does, verified in herdr source at tag v0.9.3 and then
# measured live on 0.9.3 on 2026-10-05 (see the blocks below for both):
#
#   * `pane report-agent-session --resume-argv` is recorded as a
#     `ReportedAgentResume` for ANY reporter. It is NOT gated on the closed
#     `--kind` enum (`src/agent_resume.rs:30`). Only the session *id* is.
#   * It is captured into the session snapshot as `agent_resume`
#     (`src/persist/snapshot.rs:375`, `PaneAgentResumeSnapshot`).
#   * On restore it is turned back into a plan and PREFERRED over a native agent
#     session (`src/persist/restore.rs:815` `pane_restore_startup`), gated by
#     `session.resume_agents_on_restore`, which defaults to true
#     (`src/config/model.rs:278`).
#
# MEASURED LIVE, in a named session so the owner's herdr was untouched. Launch,
# report, `server stop`, start again, attach a client:
#
#   $ cat ~/.config/herdr/sessions/<name>/session.json | jq -c \
#       '[.workspaces[].tabs[].panes[] | select(.agent_resume) | .agent_resume]'
#   [{"source":"herdr:minimax-code","agent":"mcode","argv":["mcode","--continue"]}]
#   $ herdr --session <name> server stop && herdr --session <name> server &
#   $ herdr session attach <name>          # a client must attach; see below
#   $ herdr --session <name> pane read <pane>
#     ... "No saved Session exists in the current workspace." ... Ask Mcode to do anything
#
# That last line is the REAL `mcode --continue` running in the recreated pane.
#
# THREE THINGS THAT WILL BITE, all measured, none of them guessable:
#
#   * A client must ATTACH before the resume runs. `pending_agent_resume_candidates`
#     returns nothing while the terminal area is 0x0, which is the state of a
#     headless server with no client (src/app/agent_resume.rs:99). Panes spawn as
#     plain shells and the resume is silently skipped. This is why the e2e case
#     has to attach a pty, and why "I restarted and nothing happened" is the most
#     common false alarm about this feature.
#   * `mcode --continue` resolves by CWD, not by session id. Restored in a
#     directory with no mcode session, it prints "No saved Session exists in the
#     current workspace" — which is mcode answering correctly, not a failed
#     restore. The restore ran; the session was simply not there.
#   * herdr dedupes by (source, agent, cwd, argv) — `ReportedAgentResume::plan`
#     builds exactly that key (src/agent_resume.rs:41). Two mcode panes in ONE cwd
#     therefore restore only ONE. Measured: with w1:p1 and w1:p2 both reporting
#     `mcode --continue` in the same directory, w1:p1 came back running mcode and
#     w1:p2 came back a plain shell. The winner is the lowest raw pane id, because
#     the snapshot's `panes` map is walked in key order and the first insert into
#     `resumed_sessions` wins. So the second pane silently loses its resume.
#
# ---- WHAT IS STILL NOT STORED: the session ID -------------------------------
# The id half of the old conclusion was right, and stays. `session_ref_from_report`
# returns None unless the reporter is one of the agent kinds herdr enumerates
# (`src/agent_resume.rs:116`), and mcode is not one, so:
#
#   $ herdr agent get <pane> | jq -r '.result.agent.agent_session'
#   null
#
# An absent id is expected and not a plugin fault. It is also harmless: manual
# resume re-resolves by workspace and never needed one. The two halves are now
# verified in two different ways — the resume by the report's exit status, which
# herdr makes meaningful by refusing rather than dropping, and the id by reading
# `agent get` back, because herdr accepts and discards an id with no error at all.
# The bug this file used to have was checking only the id and generalising its
# verdict to the resume.
#
# One API detail that is easy to get wrong and is load-bearing below: `agent_session`
# is an OBJECT, not a string. A pane that does have a session returns
# {"agent":..,"kind":"id","source":"herdr:claude","value":"94929c8f-…"}, so the id
# is at `.result.agent.agent_session.value`. Reading `.result.agent.agent_session`
# directly yields the whole object as text.
#
# `herdr agent get` exposes no resume field at all, and nothing needs it to: herdr
# refuses the resume report outright rather than dropping it, so the report's exit
# status is the verification. See the read-back comment above for why the resume
# half is not read back from a file.
#
# Consequence for this script: the ID half of a report is not proof — herdr accepts
# and discards an id for a non-enumerated kind without any error — so that one IS
# read back. It is a warning, never an error.
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
#             read the report back and say what herdr actually kept (issue #71,
#             corrected by #85: the id and the resume command are two fields in
#             two different files, and only one of them is ever missing)
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
# documents RESUME_ARG as "starts with a plain command name" and herdr enforces
# it: `validate_resume_argv` rejects any argv whose first element is not a plain
# command name, so an absolute path here is not merely discouraged, it is refused
# (src/agent_resume.rs:58). This is not a style preference to be "improved" later.
#
# MEASURED, since the restore is now proven: a pane restored with this argv runs
# the real mcode from a login shell's PATH. It did NOT run a stub placed earlier
# on the SERVER's PATH — the recreated pane's shell resolves commands from its own
# login environment, not from the environment the server was started with. So
# "mcode is on my PATH because I launched herdr with it on PATH" is false, and
# "mcode is on my PATH because I installed it" is what has to be true.
# Override with MCODE_RESUME_CMD if that ever stops holding.
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

# --- read-back: did herdr keep the session ID? --------------------------------
# The report writes two things, and they are NOT verified the same way.
#
#   * the resume command — verified by the REPORT'S OWN EXIT STATUS. herdr refuses
#     outright rather than silently dropping it: `report-agent-session` answers
#     `resume_not_accepted` when the reporter does not hold the pane
#     (src/app/api/plugins/panes.rs:1683). So 0 means recorded, non-zero means
#     refused, and issue_session_report says which. Reading herdr's session file to
#     double-check was tried and removed: herdr debounces session saves by five
#     seconds, so a read taken while a launch is still running reports the resume
#     "absent" on essentially every launch. A check that is wrong almost every time
#     is worse than none, and it was costing a file read and four functions.
#   * the session ID — verified by reading `agent get`, because herdr accepts and
#     discards an ID for a non-enumerated agent kind without any error at all. That
#     is the case a read-back exists for, and the only one left.
#
# WHY A WARNING AND NOT A FAILURE. The launch and the registration both already
# succeeded. Exiting non-zero would report a success as a failure and invite a
# caller to retry, which would spawn duplicate work. The one thing that is not
# negotiable is silence: exiting 0 while claiming a session was stored — or while
# claiming one was NOT stored when it was — is the exact defect #71 exists to
# close, and #85 is the same defect wearing the opposite sign. So every path here
# returns 0, and every path that did not confirm says so in words.
#
# LINES ARE SHORT ON PURPOSE. This runs on every launch and every attach. A
# paragraph per outcome is noise in a scrollback, and a reader who scrolls past
# three screens of prose has not been told anything they could not have had in one
# line.

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

# Verify the session ID herdr actually holds, and describe it in one line.
#
# The outcomes, and the wording is load-bearing — each states a different fact:
#
#   * id sent, reads back          → SAY NOTHING. A confirmed write needs no
#                                    commentary, and this is the anti-cheat case: a
#                                    read-back that always warns is as wrong as one
#                                    that never warns.
#   * id sent, absent or different → VERIFIED absent, and EXPECTED. herdr keeps a
#                                    session id only for the agent kinds it
#                                    enumerates (session_ref_from_report,
#                                    src/agent_resume.rs:116) and mcode is not one.
#                                    Reporting this as a failure was the bug #85
#                                    exists to fix: it is correct behaviour, and the
#                                    old wording dressed it as a fault.
#   * id sent, `agent get` failed  → could not confirm. NOT a claim of loss.
#   * no id sent                    → nothing to compare against, but the read-back
#                                    is still made: a session already on the pane is
#                                    one THIS RUN did not put there, and a stale
#                                    registration is worth naming.
verify_session_readback() { # verify_session_readback <pane> [session-id]
  local pane="$1" sid="${2:-}" out found

  # `if ! out=$(...)` and not a bare capture: under `set -e` a failing assignment
  # aborts before any diagnostic can print, which is the failure mode #71 is about.
  if ! out=$("$HERDR" agent get "$pane" 2>/dev/null); then
    if [ -n "$sid" ]; then
      log "mcode-session: reported session ${sid} for pane ${pane}, but \`agent get\` failed, so the id is UNVERIFIED — neither stored nor lost. The pane IS registered; exiting 0."
    else
      log "mcode-session: no session id was reported, and \`agent get\` failed, so what this pane holds is unconfirmed. The pane IS registered; exiting 0."
    fi
    return 0
  fi

  # `|| true` for the same reason: an unparseable response is "could not verify",
  # not a reason to abort a run whose registration already succeeded.
  found=$(printf '%s' "$out" | readback_session_id)

  if [ -n "$sid" ]; then
    if [ "$found" = "$sid" ]; then
      # Confirmed. Silence is the correct output; "yay it worked" would be noise on
      # the path that is supposed to be the uneventful one.
      return 0
    fi
    local reported
    if [ -n "$found" ]; then
      reported="a different session ('${found}')"
    else
      reported="no session at all"
    fi
    log "mcode-session: reported session ${sid} for pane ${pane}, but herdr holds ${reported}. The id is NOT stored, verified by the read-back — expected, not a fault: herdr keeps a session id only for the agent kinds it enumerates."
    return 0
  fi

  # No id was sent, so there is nothing to compare against — but the read-back still
  # reports something attributable: a session already on the pane is one this run
  # did not put there.
  if [ -n "$found" ]; then
    log "mcode-session: no session id was reported, and pane ${pane} already carries session '${found}', which this run did NOT report — a registration left by an earlier run or another reporter."
  else
    log "mcode-session: no session id was reported, and the read-back confirms pane ${pane} holds none — nothing was sent to be stored, so nothing is missing."
  fi
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
    # This line went through three corrections, each because it made a claim the
    # evidence did not support. The first two are kept because the shape of the
    # mistake is the thing worth remembering.
    #
    # It used to end "Resume is unaffected: '…' re-resolves by workspace". "Resume
    # is unaffected" reads as a claim about whether herdr KEPT the resume command,
    # which this line had no way to support at the time.
    #
    # The second correction: even "the command does not depend on an id" was still
    # merging two mechanisms. `mcode --continue` run by a person genuinely is
    # unaffected and needs no id. herdr restart-restore is a different mechanism
    # fed by a different write.
    #
    # The third, and the one issue #85 forced: this line used to end "…whose
    # resume command this API cannot report on at all". That was true, and it was
    # also the thing that made the file overclaim — from "no API can tell me" it
    # went on to advise assuming restart-restore was unavailable, and herdr keeps
    # the resume command and does restore it. So the claim is now scoped to MANUAL
    # resume by name, and the restart-restore half is verified where it is
    # actually decided: the report's own exit status, a few lines below.
    log "mcode-session: no session id could be resolved for this pane (no manifest records a cwd), so none is reported. MANUAL resume is unaffected: '${MCODE_RESUME_CMD}' re-resolves by workspace."
  fi

  # The session report itself is shared with `attach` (issue #79) so the argv, the
  # --source and the label cannot drift between the two verbs.
  if ! issue_session_report "$pane" "$sid"; then
    die "\`${HERDR} pane report-agent-session ${pane}\` failed. The state report above succeeded, so the pane is registered; the session identity was not attached."
  fi

  # The ID is read back after the report, unconditionally. The RESUME is not, and
  # does not need to be: issue_session_report already took its exit status, and
  # that is the only signal herdr gives for it.
  #
  # Unconditional, including when no id was sent. There is nothing to *compare*
  # against in that case, but the read-back still reports something attributable:
  # any session already on the pane is one this run did not put there, which is a
  # stale registration worth naming. Skipping the call would make the no-id path
  # the one path that reports success without looking. The resume half needs no id
  # at all, so it is checked in every case.
  verify_session_readback "$pane" "$sid"
}

# Where this process believes it is talking, and to what. OFF by default; the e2e
# turns it on with MCODE_LOG_REPORT_ENV=1.
#
# WHY IT EXISTS: an intermittent e2e failure showed the resume report being
# accepted (exit 0) while the session's own server logged no report request at
# all. A call that returns 0 without reaching the intended server is either going
# somewhere else or not happening, and the environment is the only place the
# difference shows. One line, gated, because this is a diagnostic and not
# something an operator should read on every launch.
#
# The socket is the load-bearing half: herdr rewrites HERDR_SOCKET_PATH and
# HERDR_BIN_PATH in every plugin process it spawns (src/app/api/plugins/runtime.rs:39-55),
# so a value that is not the expected session's socket names the wrong server.
log_report_env() { # log_report_env <pane>
  [ "${MCODE_LOG_REPORT_ENV:-0}" = "1" ] || return 0
  log "mcode-session: env pane=$1 socket=${HERDR_SOCKET_PATH:-<unset>} herdr=$HERDR ppid=${PPID:-?} ppid_exe=$(readlink /proc/${PPID:-0}/exe 2>/dev/null || echo n/a)"
}

issue_session_report() { # issue_session_report <pane> <session-id>; 0 only if herdr accepted
  local pane="$1" sid="$2"
  log_report_env "$pane"
  # shellcheck disable=SC2206  # deliberate word-splitting: a command line
  local -a resume_argv=(${MCODE_RESUME_CMD})
  local -a session_argv=(pane report-agent-session --source "$AGENT_SOURCE" --agent "$AGENT_LABEL")
  if [ -n "$sid" ]; then
    session_argv+=(--agent-session-id "$sid")
  fi
  session_argv+=("$pane")
  session_argv+=(--)
  session_argv+=("${resume_argv[@]}")

  # The exit status IS the verification, and that is worth saying once here rather
  # than re-deriving in a comment three functions away: herdr refuses this call
  # outright when it will not record the resume, answering `resume_not_accepted`
  # when the reporter does not hold the pane (src/app/api/plugins/panes.rs:1683).
  # So 0 means recorded and non-zero means refused, and neither needs a second
  # source to confirm it.
  #
  # ONE GAP, stated rather than papered over. herdr also re-checks the argv when it
  # captures the snapshot and drops the resume if `validate_resume_argv` rejects it
  # — an absolute path, or an argv containing an apostrophe or a control character.
  # That check runs at CAPTURE time, not at report time, so a 0 here does not cover
  # it. The default (`mcode --continue`) is well inside what validates, and
  # tests/e2e/run.sh proves the whole round trip against a real herdr rather than
  # trusting this reasoning.
  # The status is PASSED THROUGH, not swallowed. Both callers do `if ! issue_
  # session_report; then die ...`, and that contract is what makes a refusal
  # visible: the launcher treats `attach` as best-effort, so a refusal surfaces as
  # a named failure in the launch log rather than as silence. Returning 0 from both
  # branches because `log` succeeded would quietly disarm that.
  local out rc=0
  if out=$("$HERDR" "${session_argv[@]}" 2>&1); then
    log "mcode-session: resume command recorded; herdr re-runs '${MCODE_RESUME_CMD}' in this pane after a restart."
  else
    rc=$?
    # Whitespace collapsed rather than newlines deleted: two stderr lines arrive
    # with no separator otherwise, and the text is what makes this worth printing.
    # Capped so the whole line stays near 200 characters.
    log "mcode-session: resume REFUSED by herdr: $(printf '%s' "$out" | tr '\n' ' ' | tr -s ' ' | cut -c1-110). Manual resume is unaffected."
  fi
  return "$rc"
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
# unasked is noise. The ONE line that must survive is the read-back's: it is the
# only thing telling the user what herdr actually kept, and on a launch that
# silently failed to store anything it is the only line there is.
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
