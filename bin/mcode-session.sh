#!/usr/bin/env bash
# mcode-session.sh — register this pane's mcode session with herdr, and record
# the command herdr would use to resume it after a restart.
#
# STATUS: wired, and the resume is now PROVEN (issue #85). A named herdr session
# was launched, reported, stopped, restarted and re-attached, and `mcode --continue`
# was observed running in the recreated pane. Before that, restart-restore was
# wired but unverified, and the read-back reported the wrong field — it checked
# `agent_session`, which herdr only populates for agent kinds it enumerates, and so
# called a write that WAS stored "nothing was stored". Both halves are now checked
# where they actually live. Read the measurement block below before changing any of
# it: three sharp edges in the restore path are recorded there, and each one has
# already cost a debugging round trip.
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
# resume re-resolves by workspace and never needed one. So the read-back checks
# BOTH halves against the place each one actually lives — the id in `agent get`,
# the resume command in the session snapshot — and says a different thing about
# each. The bug this file used to have was checking only the first and generalising
# its verdict to the second.
#
# One API detail that is easy to get wrong and is load-bearing below: `agent_session`
# is an OBJECT, not a string. A pane that does have a session returns
# {"agent":..,"kind":"id","source":"herdr:claude","value":"94929c8f-…"}, so the id
# is at `.result.agent.agent_session.value`. Reading `.result.agent.agent_session`
# directly yields the whole object as text. `herdr agent get` exposes NO resume
# field at all — the resume is not in the agent view, which is precisely why the
# snapshot is the only place to read it back from.
#
# Consequence for this script: reporting is not proof. After the report it reads
# back both halves and says what herdr actually kept. That is a warning, never an
# error — see verify_session_readback for why.
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
#   MCODE_HERDR_SESSION_DIR  herdr session dir to read the resume read-back from.
#                         Unset: read herdr's default config dir
#                         ($XDG_CONFIG_HOME/herdr, else ~/.config/herdr).
#                         Set: read only that directory. A pane carries no
#                         session name, so a pane in a NAMED session is read back
#                         against the wrong file unless this is set — see
#                         candidate_session_dirs for why there is no
#                         `herdr session list` call to ask instead.
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

# --- read-back: did the report actually land? ---------------------------------
# Exit 0 from a CLI call is a claim about the process, not about the state, and
# the state is the only thing anyone downstream needs. So the report is read back
# and the difference is stated. It is read back in TWO places, because the report
# writes TWO things and they land in different files — see verify_session_readback.
#
# WHY A WARNING AND NOT A FAILURE. The launch and the registration both already
# succeeded. Exiting non-zero would report a success as a failure and invite a
# caller to retry, which would spawn duplicate work. The one thing that is not
# negotiable is silence: exiting 0 while claiming a session was stored — or while
# claiming one was NOT stored when it was — is the exact defect #71 exists to
# close, and #85 is the same defect wearing the opposite sign. So every path here
# returns 0, and every path that did not confirm says so in words.

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

# --- the session snapshot: where the resume command actually lands ------------
# `herdr agent get` cannot answer "did you keep my resume command", because the
# agent view has no resume field at all. The place herdr writes it is the
# persisted session snapshot, as `agent_resume`. So the resume half of the
# read-back is answered from there and the id half from `agent get`, and the two
# are reported as the two different facts they are.
#
# WHICH SNAPSHOT. A named session keeps its state in
# <config_dir>/sessions/<name>/ (src/session.rs:163) and nothing inside a pane
# carries that name — herdr exports only HERDR_ENV, HERDR_WORKSPACE_ID,
# HERDR_TAB_ID and HERDR_PANE_ID to a pane's shell (src/pane.rs:187) — so this
# process cannot work out which session it is in. Hence MCODE_HERDR_SESSION_DIR,
# which is how a caller says "the session I mean".
#
# WHY THERE IS NO `herdr session list` CALL HERE, having written one and removed
# it. Asking herdr which sessions are running does find the right directory, and
# it cost a herdr invocation on EVERY launch and on every `attach`. That is not
# free: tests/run.sh asserts the exact argv sequence the launch path issues, so
# the extra call broke another member's suite, and the fix for that is a change
# to a file this work does not own. Reinstating it needs that suite's expectations
# updated first, and that is a decision for the architect, not a side effect of a
# read-back.
#
# WHAT THAT COSTS, stated plainly rather than discovered later. Without the
# directory pinned, a pane in a NAMED session is read back against the default
# session's snapshot, which is the wrong file. The read-back never claims more
# than the file supports: it names the file it read, and when it finds nothing it
# says the finding is not conclusive for a named session rather than reporting a
# stored resume as lost. The escape hatch is MCODE_HERDR_SESSION_DIR.
candidate_session_dirs() {
  if [ -n "${MCODE_HERDR_SESSION_DIR:-}" ]; then
    printf '%s\n' "$MCODE_HERDR_SESSION_DIR"
  else
    # herdr's own default (src/config/io.rs:30 config_dir): XDG_CONFIG_HOME wins,
    # otherwise ~/.config/herdr.
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
  fi
}

# How many panes in a snapshot hold OUR resume command. Prints the count, or
# nothing if the file is unreadable or not JSON.
#
# Matching is on the reporter tuple — source, agent, and the exact argv we sent —
# and deliberately NOT on cwd. Two reasons, and the second is the important one:
# the snapshot stores herdr's RESOLVED cwd while `pwd` in the pane is whatever
# the shell considers logical (on macOS /tmp is a symlink to /private/tmp, so the
# two disagree for every sandbox under /tmp), and a cwd-keyed match would report
# a stored resume as lost for a reason that has nothing to do with persistence.
# Reporting a count rather than a single pane is honest about the same thing: the
# snapshot's pane entries carry no public pane id, so the pane this run reported
# cannot be named from the file without reconstructing herdr's internal id map.
snapshot_resume_count() { # snapshot_resume_count <snapshot-file> <expected-argv-json>
  local file="$1" argv_json="$2"
  [ -f "$file" ] || return 0
  jq -r --arg src "$AGENT_SOURCE" --arg agent "$AGENT_LABEL" --argjson argv "$argv_json" '
      [ .workspaces[]? | .id as $ws
        | .public_pane_numbers as $nums
        | .tabs[]? | .panes | to_entries[]?
        | select(.value.agent_resume != null)
        | select(.value.agent_resume.source == $src)
        | select(.value.agent_resume.agent == $agent)
        | select(.value.agent_resume.argv == $argv)
        | ($ws + ":" + (($nums[.key] // 0) | tostring))
      ] | length
    ' "$file" 2>/dev/null || true
}

# The read-back for the resume half. Three outcomes, and none of them may borrow
# another's wording:
#
#   * AVAILABLE      → herdr kept it. The file is named, so the claim is checkable
#                      rather than asserted on trust.
#   * NOT CONFIRMED  → a snapshot was readable and holds no such resume. This is
#                      explicitly NOT a claim that herdr discarded it: herdr
#                      debounces session saves by five seconds, so a snapshot read
#                      moments after a report has not necessarily caught up. It
#                      used to be a claim, and it was the #71 defect in mirror
#                      image — reporting a write as lost when it is merely not
#                      flushed. And when the session directory is a guess rather
#                      than a given, absence is not even evidence about THIS pane,
#                      which is said rather than glossed.
#   * UNVERIFIED     → nothing could be read. A third thing, not a weaker version
#                      of the other two, and saying so is the point.
verify_resume_readback() {
  local dir file n read_any=0 checked="" pinned="no" argv_json
  local -a dirs=()

  # Derived here rather than passed in, so every caller compares against the same
  # argv the report was issued with: MCODE_RESUME_CMD is word-split on the way
  # out and must be word-split identically on the way back in, or the comparison
  # is against a shape herdr never received.
  argv_json=$(expected_resume_argv_json)

  [ -n "${MCODE_HERDR_SESSION_DIR:-}" ] && pinned="yes"

  # Read line by line rather than word-splitting: a config dir may contain spaces,
  # and a for-loop over $dirs would then silently look at paths that do not exist.
  while IFS= read -r dir; do
    [ -n "$dir" ] && dirs+=("$dir")
  done < <(candidate_session_dirs)

  for dir in "${dirs[@]+"${dirs[@]}"}"; do
    file="$dir/session.json"
    [ -f "$file" ] || continue
    read_any=1
    checked="${checked:+$checked, }$file"
    n=$(snapshot_resume_count "$file" "$argv_json")
    case "$n" in
      ''|*[!0-9]*) n=0 ;;
    esac
    if [ "$n" -gt 0 ]; then
      log "mcode-session: herdr restart-restore is AVAILABLE. The herdr session snapshot ${file} holds this pane's resume command (${n} pane(s) matching source '${AGENT_SOURCE}', agent '${AGENT_LABEL}', argv '${MCODE_RESUME_CMD}'), so herdr re-runs it in the pane it recreates after a restart. The snapshot is herdr's own record and its pane entries carry no public pane id, so which pane it names is not derivable from the file."
      return 0
    fi
  done

  if [ "$read_any" -eq 0 ]; then
    log "mcode-session: the resume command ('${MCODE_RESUME_CMD}') was reported, but no herdr session snapshot could be read to check it, so whether herdr kept it is UNVERIFIED — neither confirmed stored nor confirmed lost. Not a registration failure: the pane is registered. Exiting 0."
    return 0
  fi

  if [ "$pinned" = "yes" ]; then
    log "mcode-session: the resume command ('${MCODE_RESUME_CMD}') was reported, and the herdr session snapshot ${checked} does not hold it. That is NOT a claim that herdr discarded it: herdr debounces session saves by five seconds, so a snapshot read moments after a report may not have caught up. Read the same file again in a few seconds to confirm. Manual resume is unaffected: '${MCODE_RESUME_CMD}' re-resolves by workspace and needs no session id. The pane IS registered; exiting 0."
  else
    log "mcode-session: the resume command ('${MCODE_RESUME_CMD}') was reported, and no resume for it appears in ${checked}. NOT CONFIRMED, and specifically NOT a claim that herdr discarded it — two things stand in the way of that claim. herdr debounces session saves by five seconds, so the snapshot may predate the report; and this pane's own session directory is not known from inside a pane, so the file read is herdr's default session unless MCODE_HERDR_SESSION_DIR says otherwise, and a named session's snapshot is a different file. Set MCODE_HERDR_SESSION_DIR to the session directory to make this conclusive. Manual resume is unaffected: '${MCODE_RESUME_CMD}' re-resolves by workspace and needs no session id. The pane IS registered; exiting 0."
  fi
  return 0
}

# Verify what herdr actually kept after a session report, and describe it.
#
# TWO HALVES, CHECKED IN TWO PLACES, REPORTED AS TWO FACTS. This is the whole
# point of the function. The old version checked one field — `agent_session` —
# and generalised its verdict to the resume command, which lives somewhere else
# entirely, so it reported "nothing was stored" about a write that was stored.
# Collapsing them back together is the regression to watch for.
#
#   * id sent, reads back          → say nothing about identity. A confirmed write
#                                    needs no commentary, and this is the
#                                    anti-cheat case: a read-back that always
#                                    warns is as wrong as one that never warns.
#   * id sent, absent or different → name the id, the pane, and that identity is
#                                    VERIFIED absent. This is CORRECT and expected
#                                    for mcode: herdr only persists a session id
#                                    for agent kinds it enumerates, and this is not
#                                    one. The resume command is then reported
#                                    separately by verify_resume_readback.
#   * id sent, `agent get` failed  → could not confirm identity. NOT a claim of
#                                    loss. The resume half is still checked: it
#                                    does not depend on `agent get` at all.
#   * no id sent                    → identity is a different question (nothing was
#                                    sent). The resume half is still checked, and
#                                    checked the same way.
verify_session_readback() { # verify_session_readback <pane> [session-id]
  local pane="$1" sid="${2:-}" out found reported

  # `if ! out=$(...)` and not a bare capture: under `set -e` a failing assignment
  # aborts before any diagnostic can print, which is the failure mode #71 is about.
  if ! out=$("$HERDR" agent get "$pane" 2>/dev/null); then
    if [ -n "$sid" ]; then
      log "mcode-session: reported session ${sid} for pane ${pane}, but could not verify it: \`${HERDR} agent get ${pane}\` failed. Session identity is UNVERIFIED — neither confirmed stored nor confirmed lost. The resume command is checked separately below, because it is not in this response. Not a registration failure: the pane is registered. Exiting 0."
    else
      log "mcode-session: no session id was reported, and \`${HERDR} agent get ${pane}\` failed, so the read-back could not verify what this pane holds. Identity is unconfirmed. The resume command is checked separately below, because it is not in this response. Not a registration failure: the pane is registered. Exiting 0."
    fi
    verify_resume_readback
    return 0
  fi

  # `|| true` for the same reason: an unparseable response is "could not verify",
  # not a reason to abort a run whose registration already succeeded.
  found=$(printf '%s' "$out" | readback_session_id)

  if [ -n "$sid" ]; then
    if [ "$found" = "$sid" ]; then
      # Confirmed. Silence is the correct output here; a "yay it worked" line would
      # be noise on a path that is supposed to be the uneventful one.
      verify_resume_readback
      return 0
    fi
    if [ -n "$found" ]; then
      reported="a different session ('${found}')"
    else
      reported="no session at all (agent_session is absent)"
    fi
    # Session identity, settled. Expected for mcode and not a plugin error:
    # `session_ref_from_report` returns nothing unless the reporter is one of the
    # agent kinds herdr enumerates, and mcode is not one, so herdr keeps the id
    # out of the snapshot by design. It costs nothing: manual resume resolves by
    # workspace and never needed an id.
    #
    # The resume command is NOT mentioned here. It is a different field in a
    # different file, and the sentence that used to sit here — "assume herdr
    # restart-restore is unavailable" — was an assumption dressed as a finding.
    # verify_resume_readback below now looks it up for real.
    log "mcode-session: reported session ${sid} for pane ${pane}, but herdr 0.9.3 did not persist the ID — \`agent get\` reports ${reported}. Session identity is NOT stored: that is verified by the read-back, not inferred, and it is expected here rather than a fault — herdr keeps a session id only for the agent kinds it enumerates, and mcode is not one of them. Nothing depends on that id: manual '${MCODE_RESUME_CMD}' re-resolves by workspace. The resume command is a separate field, checked on its own below. Exiting 0."
    verify_resume_readback
    return 0
  fi

  # No id was sent, so there is nothing to compare against — but the read-back is
  # still worth making, because what it finds is attributable: any session on this
  # pane is one this run did NOT put there. That is a stale registration from an
  # earlier run or another reporter, and a stale registration is worse than none.
  # Reading it and saying nothing would be the silent no-op this whole change
  # exists to remove, so the read-back is made unconditionally.
  if [ -n "$found" ]; then
    log "mcode-session: no session id was reported, and the read-back shows pane ${pane} already carries session '${found}', which this run did NOT report — a registration left by an earlier run or by another reporter. The resume command below is unaffected by that stale id."
  else
    log "mcode-session: no session id was reported, and the read-back confirms pane ${pane} holds no session ID. Nothing was sent to be stored, so nothing is missing: the id is absent because none was ever reported, which is expected — herdr keeps a session id only for the agent kinds it enumerates. The resume command is a separate field, checked on its own below."
  fi
  verify_resume_readback
  return 0
}

# The resume argv as JSON, matching how herdr was told about it: MCODE_RESUME_CMD
# is a command line and is deliberately word-split, exactly as it is when the
# report is issued. Splitting it the same way here is what lets the read-back
# compare like with like instead of against a string herdr never saw.
expected_resume_argv_json() {
  # shellcheck disable=SC2206  # deliberate word-splitting: a command line
  local -a argv=(${MCODE_RESUME_CMD})
  printf '%s\n' "${argv[@]}" | jq -R . | jq -sc .
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
    # resume command this API cannot report on at all". That is now false in the
    # strong direction — the resume command CAN be reported on, from the session
    # snapshot — and it is not read back here anyway, because this line runs
    # BEFORE the report. verify_session_readback reports it afterwards, from the
    # place it actually lands. So the claim is now scoped to MANUAL resume by
    # name, and points at the header block, which is the single authoritative
    # statement of the split.
    log "mcode-session: no session id could be resolved for this pane (no manifest records a cwd), so none is reported. MANUAL resume is unaffected: '${MCODE_RESUME_CMD}' re-resolves by workspace and needs no session id. That is separate from herdr restart-restore, which is fed by the resume command reported below and read back afterwards."
  fi

  # The session report itself is shared with `attach` (issue #79) so the argv, the
  # --source and the label cannot drift between the two verbs.
  if ! issue_session_report "$pane" "$sid"; then
    die "\`${HERDR} pane report-agent-session ${pane}\` failed. The state report above succeeded, so the pane is registered; the session identity was not attached."
  fi

  # Exit 0 from the call above is not evidence the write happened. So the pane is
  # read back afterwards, unconditionally — the id from `agent get`, and the resume
  # command from the session snapshot it actually lands in.
  #
  # Unconditional, including when no id was sent. There is nothing to *compare*
  # against in that case, but the read-back still reports something attributable:
  # any session already on the pane is one this run did not put there, which is a
  # stale registration worth naming. Skipping the call would make the no-id path
  # the one path that reports success without looking. The resume half needs no id
  # at all, so it is checked in every case.
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
