#!/usr/bin/env bash
# tests/session-run.sh — the suite for bin/mcode-session.sh (issue #36).
#
# Plain bash, like tests/run.sh. No framework; `bats` is not installed and is not
# worth adding.
#
# Run every case:   ./tests/session-run.sh
# Run a subset:     ./tests/session-run.sh resolve-real-schema-invents-nothing
# List case names:  ./tests/session-run.sh --list
#
# Exits 0 only if every case passes. Exit 2 if a precondition is missing.
#
# This is a separate file from tests/run.sh on purpose, for two reasons. It keeps
# the session tests off the launcher's case list, so the two suites stay
# independently readable; and CI discovers suites by the `tests/*run.sh` glob, so
# adding a file here is what wires it in — naming a new suite anywhere else is
# the exact trap that left issue #35's cases unexecuted for a whole PR.
#
# MCODE_SESSION_BIN overrides the script under test, so the mutation check can
# run against a deliberately broken *copy* and leave the real
# bin/mcode-session.sh untouched.
#
# ---- WHAT IS AND IS NOT PROVEN HERE -----------------------------------------
# These cases prove *resolution and reporting*: which session id the script picks,
# and what it sends to herdr. They do NOT prove that herdr can restore a pane
# from the resume command this script records. That needs a herdr restart, and
# every candidate environment for one is a live machine whose other work the
# restart would destroy. Resume is wired and unverified. Do not describe it as
# working — see the STATUS block at the top of bin/mcode-session.sh.

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"

# Resolved to an absolute path. run_session cd's into the sandbox before
# invoking it, so a relative MCODE_SESSION_BIN would resolve against the sandbox
# and fail — the override would work when the suite was written and break the
# moment it was actually used.
SESSION_BIN="${MCODE_SESSION_BIN:-$repo/bin/mcode-session.sh}"
case "$SESSION_BIN" in
  /*) ;;
  *) SESSION_BIN="$(cd -- "$(dirname -- "$SESSION_BIN")" && pwd)/$(basename -- "$SESSION_BIN")" ;;
esac
FAKE_HERDR="$here/fake-herdr"
STORE_FIXTURE="$here/fixtures/session"

# The pane this suite registers, and the source pane the stub reports. Neither is
# a value the script under test may invent: HERDR_PANE_ID arrives in the
# environment and the pane id in the stub's response.
PANE="wZ:p7"

BASE_PATH="$PATH"
# Normalised on purpose. $TMPDIR ends in a slash on macOS, so the obvious
# `mktemp -d "${TMPDIR:-/tmp}/mcode-session-tests.XXXXXX"` yields a path
# containing `//`. The script under test compares the cwd it sees from `pwd`
# against the `cwd` recorded in a manifest, and `pwd` collapses the double slash
# while the test's own $CASE_DIR does not — so a matching cwd silently stops
# matching. Resolving once, here, keeps every path in this file canonical.
WORK="$(cd -- "$(mktemp -d "${TMPDIR:-/tmp}/mcode-session-tests.XXXXXX")" && pwd -P)"

# KEEP_TMP=1 leaves the sandbox for inspection after a failure.
cleanup() {
  PATH="$BASE_PATH"
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    printf 'tests/session-run.sh: KEEP_TMP=1, sandbox left at %s\n' "$WORK" >&2
    return
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

CASES_RUN=0
CASES_FAILED=0
CURRENT_CASE=""
CASE_DIR=""
broke=0

note() { broke=1; printf '        %s\n' "$*"; }

# --- assertions --------------------------------------------------------------
assert_rc_zero() {
  if [ "$1" -ne 0 ]; then
    note "expected exit 0, got $1"
    note "stderr:"
    sed 's/^/          /' "$STDERR_FILE"
  fi
}

assert_rc_nonzero() {
  if [ "$1" -eq 0 ]; then
    note "expected a non-zero exit, got 0"
  fi
}

assert_stderr_mentions() { # assert_stderr_mentions <needle>
  if ! grep -qF -- "$1" "$STDERR_FILE"; then
    note "stderr does not mention '$1'"
  fi
}

# Case-insensitive extended-regex match. Used only where the issue mandates the
# SUBSTANCE of a message but deliberately leaves the wording to the
# implementation — e.g. "say resume is unavailable" does not fix whether that
# reads "unavailable", "not available" or "no longer available". Every such
# assertion is paired with an exact-needle assertion on the session id, so
# breadth here can never make a case pass vacuously.
assert_stderr_matches() { # assert_stderr_matches <ere>
  if ! grep -qiE -- "$1" "$STDERR_FILE"; then
    note "stderr does not match /$1/"
  fi
}

# The negative of the above, and the half that stops a read-back which simply
# always complains. "The warning fired" is only half of issue #71; the other
# half is "and it stayed quiet when the write actually landed".
assert_stderr_lacks_match() { # assert_stderr_lacks_match <ere>
  if grep -qiE -- "$1" "$STDERR_FILE"; then
    note "stderr matches /$1/ but this case requires silence"
    grep -iE -- "$1" "$STDERR_FILE" | sed 's/^/          /'
  fi
}

assert_stdout_field() { # assert_stdout_field <key> <value>
  local got
  got="$(grep -F "$1	" "$STDOUT_FILE" 2>/dev/null | head -1 | cut -f2-)"
  if [ "$got" != "$2" ]; then
    note "stdout field '$1': expected '$2', got '$got'"
  fi
}

# The core safety assertion for this suite. A session id has the shape
# `mvs_` + 32 hex chars. While unresolved, the script must emit no such token
# anywhere on stdout — not as the answer, not as a near-miss, not in a log line
# that looks like a diagnostic but carries a real id.
assert_no_session_id_emitted() {
  local found
  found="$(grep -oE 'mvs_[0-9a-z]{8,}' "$STDOUT_FILE" 2>/dev/null | head -1)"
  if [ -n "$found" ]; then
    note "emitted something shaped like a session id ('$found') while unresolved"
  fi
}

# Ordering, not membership. herdr only accepts a resume_argv from a reporter that
# already holds the pane, and a session report without the prior state report is
# refused as `resume_not_accepted` — measured on 0.9.3. A "contains both" check
# would pass on the exact call sequence that fails in production, so this
# compares line numbers.
assert_log_order() { # assert_log_order <earlier> <later>
  local a b
  a="$(grep -nF -- "$1" "$FAKE_HERDR_LOG" 2>/dev/null | head -1 | cut -d: -f1)"
  b="$(grep -nF -- "$2" "$FAKE_HERDR_LOG" 2>/dev/null | head -1 | cut -d: -f1)"
  if [ -z "$a" ] || [ -z "$b" ]; then
    note "expected both '$1' and '$2' in the invocation log"
    note "actual:"
    sed 's/^/          /' "$FAKE_HERDR_LOG"
    return
  fi
  if [ "$a" -ge "$b" ]; then
    note "'$1' (line $a) must come before '$2' (line $b)"
  fi
}

assert_log_exactly() { # assert_log_exactly <expected-tabbed>
  local actual
  actual="$(cat "$FAKE_HERDR_LOG")"
  if [ "$actual" != "$1" ]; then
    note "herdr invocation sequence mismatch"
    note "expected:"
    printf '%s\n' "$1" | sed $'s/\t/ /g; s/^/          /'
    note "actual:"
    printf '%s\n' "$actual" | sed $'s/\t/ /g; s/^/          /'
  fi
}

assert_log_empty() {
  if [ -s "$FAKE_HERDR_LOG" ]; then
    note "expected no herdr invocations, got:"
    sed 's/^/          /' "$FAKE_HERDR_LOG"
  fi
}

assert_log_lacks() { # assert_log_lacks <needle>
  if grep -qF -- "$1" "$FAKE_HERDR_LOG"; then
    note "invocation log should not contain '$1'"
  fi
}

# Issue #71 in one assertion: the script must go back and ASK herdr what it
# actually stored, after the report it just made.
#
# Order, not membership, for the same reason assert_log_order exists — and the
# stronger point is that an `agent get` *anywhere* in the log proves nothing,
# because the script already calls it once to re-assert the agent state. Only an
# `agent get` AFTER the session report is a read-back.
assert_readback_after_session_report() {
  local session_line readback_line
  session_line="$(grep -nF 'pane	report-agent-session' "$FAKE_HERDR_LOG" 2>/dev/null \
                 | head -1 | cut -d: -f1)"
  readback_line="$(awk -F'\t' '$1 == "agent" && $2 == "get" { print NR }' \
                  "$FAKE_HERDR_LOG" 2>/dev/null | tail -1)"
  if [ -z "$session_line" ]; then
    note "no report-agent-session call in the log to read back from"
    return
  fi
  if [ -z "$readback_line" ]; then
    note "no \`agent get\` invocation at all: the report was never verified"
    return
  fi
  if [ "$readback_line" -le "$session_line" ]; then
    note "the only \`agent get\` is at line $readback_line, at or before the" \
         "session report at line $session_line — that is the pre-existing" \
         "state read, not a read-back of what was just written"
  fi
}

# --- per-case sandbox --------------------------------------------------------
# Each case gets a private copy of the session store. Copying rather than
# pointing MCODE_HOME at tests/fixtures/session matters: several cases rewrite
# manifests and timestamps in place to make two ranking strategies disagree, and
# a committed fixture must not be mutated by running the suite.
setup_case() {
  CASE_DIR="$WORK/$CURRENT_CASE"
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR/project"
  cp -R "$STORE_FIXTURE" "$CASE_DIR/store"

  FAKE_HERDR_LOG="$CASE_DIR/herdr.log"
  STDERR_FILE="$CASE_DIR/stderr"
  STDOUT_FILE="$CASE_DIR/stdout"
  : >"$FAKE_HERDR_LOG"
  : >"$STDERR_FILE"
  : >"$STDOUT_FILE"

  export FAKE_HERDR_LOG
  export FAKE_HERDR_FIXTURES="$here/fixtures"
  export HERDR_BIN_PATH="$FAKE_HERDR"
  export MCODE_HOME="$CASE_DIR/store"
  unset FAKE_HERDR_FAIL FAKE_HERDR_FAULT
  unset MCODE_AGENT_STATE MCODE_RESUME_CMD HERDR_PLUGIN_EVENT_JSON
  # Running this suite from inside a live pane would otherwise inherit that
  # pane's id, and the result would depend on where it was launched from rather
  # than on the case. Each `report` case sets the variable deliberately.
  unset HERDR_PANE_ID

  # Aim the resume read-back at a sandbox session dir, seeded with the real
  # capture. Three reasons, and the first one is not optional:
  #
  #   1. WITHOUT THIS THE SUITE READS THE DEVELOPER'S OWN ~/.config/herdr. The
  #      script asks `herdr session list --json` for the running session's
  #      directory, and the fake herdr answers with its canned reply, so the
  #      fallback lands on the real config dir. A test suite must never read — let
  #      alone assert against — someone's live session state, and on a machine
  #      where a real mcode pane exists the read-back would be answering questions
  #      about the developer's real panes.
  #   2. It keeps the invocation log free of a `session list --json` line, so the
  #      `assert_log_exactly` cases keep asserting on exactly the sequence they
  #      are about.
  #   3. The seeded capture is the HAPPY path — the resume is stored — so by
  #      default the resume read-back has nothing to complain about and the
  #      identity cases stay about identity. The cases that care about the resume
  #      replace this file; see write_session_snapshot.
  export MCODE_HERDR_SESSION_DIR="$CASE_DIR/herdr-session"
  mkdir -p "$MCODE_HERDR_SESSION_DIR"
  write_session_snapshot stored >/dev/null
}

# `resolve` and `report` both resolve against the *current* working directory,
# because that is the pane's cwd and the script has no other way to learn it. So
# the cwd is a dimension the test controls: every case runs from the same
# per-case project directory, and the one case that needs a manifest recording
# that directory writes the path in at run time.
run_session() { # run_session <subcommand>
  ( cd "$CASE_DIR/project" && "$SESSION_BIN" "$1" ) >"$STDOUT_FILE" 2>"$STDERR_FILE"
  RC=$?
}

# --- fixture builders --------------------------------------------------------
# Generate a cwd-bearing manifest. This CANNOT be a static fixture: the cwd is
# the per-case sandbox, created at run time, so no committed file could ever
# match it. The schema is the documented real one plus a `cwd` — mcode does not
# write that key today. See tests/fixtures/session/README.md.
write_manifest() { # write_manifest <store> <dir-name> <session-id> <updatedAtMs> [createdAtMs]
  local store="$1" name="$2" sid="$3" upd="$4" cre="${5:-$4}"
  local dir="$CASE_DIR/store/$store/sessions/2026/10/04/12-00-00-000-$name"
  mkdir -p "$dir"
  jq -n --arg cwd "$CASE_DIR/project" --arg sid "$sid" \
        --argjson upd "$upd" --argjson cre "$cre" '{
      createdAtMs: $cre,
      cwd: $cwd,
      layout: "v2-final-dated-session",
      paths: {sessionDir: "/tmp/'"$name"'"},
      schemaVersion: 1,
      sessionId: $sid,
      source: "local-runtime",
      updatedAtMs: $upd
    }' >"$dir/manifest.json"
  printf '%s' "$dir/manifest.json"
}

# Force a file's mtime, so a case can make "newest by mtime" and "newest by
# updatedAtMs" disagree. `touch -t` takes [[CC]YY]MMDDhhmm and is POSIX, so this
# is not the same BSD/GNU trap the removed `stat -f` was.
set_mtime() { # set_mtime <file> <YYYYMMDDhhmmss>
  touch -t "$2" "$1"
}

# The herdr session snapshot the resume read-back reads. Seeded from a REAL
# capture — a live herdr 0.9.3, named session, launcher sequence, byte-for-byte —
# rather than written by hand, because the whole point of the read-back is that it
# parses herdr's actual on-disk format. Provenance, including the exact commands,
# is in tests/e2e/fixtures/README.md.
#
# `stored`    the capture as captured: one pane holding our agent_resume.
# `no-resume` the same document with that pane's agent_resume removed, which is
#             what a snapshot looks like when herdr did not keep the command.
# `foreign`   agent_resume present but belonging to another reporter, so a
#             read-back that matched loosely instead of on the reporter tuple
#             would wrongly call this a match.
#
# The capture's `cwd` is deliberately left alone. It reads /private/tmp/… because
# that is where it was made, and the read-back does not match on cwd, so leaving
# it is more faithful than rewriting it to the sandbox — and it is what proves the
# read-back does not depend on cwd matching.
SNAPSHOT_CAPTURE="$here/e2e/fixtures/session-snapshot-agent-resume.json"
write_session_snapshot() { # write_session_snapshot stored|no-resume|foreign [source] [agent] [argv...]
  local variant="$1"; shift
  local src="${1:-$EXPECTED_SOURCE}" agent="${2:-$EXPECTED_LABEL}"
  shift 2 2>/dev/null || shift $#
  local -a argv=("$@")
  if [ "${#argv[@]}" -eq 0 ]; then
    # shellcheck disable=SC2206  # matches how the script word-splits this
    argv=($DEFAULT_RESUME_CMD)
  fi
  local argv_json
  argv_json=$(printf '%s\n' "${argv[@]}" | jq -R . | jq -sc .)

  case "$variant" in
    stored)   cp "$SNAPSHOT_CAPTURE" "$MCODE_HERDR_SESSION_DIR/session.json" ;;
    no-resume)
      jq --arg src "$src" --arg agent "$agent" \
         'del(.workspaces[].tabs[].panes[] | select(.agent_resume.source == $src
                                                    and .agent_resume.agent == $agent)
              | .agent_resume)' \
         "$SNAPSHOT_CAPTURE" > "$MCODE_HERDR_SESSION_DIR/session.json" ;;
    foreign)
      jq --arg src "$src" --arg agent "$agent" --argjson argv "$argv_json" '
          .workspaces[].tabs[].panes |= with_entries(
            .value.agent_resume = {source: $src, agent: $agent, argv: $argv})
        ' "$SNAPSHOT_CAPTURE" > "$MCODE_HERDR_SESSION_DIR/session.json" ;;
    *) note "unknown snapshot variant '$variant'"; return 1 ;;
  esac
  printf '%s' "$MCODE_HERDR_SESSION_DIR/session.json"
}

# --- expectations ------------------------------------------------------------
# The agent state herdr already records for the pane, as the stub serves it.
EXPECTED_STATE="working"
# --source must be herdr:minimax-code in all three reporters. Asserted here as a
# literal, not read from the script under test: a test that derived its own
# expectation from the implementation would agree with any value, including the
# wrong one. This is the value the other two reporters use too.
EXPECTED_SOURCE="herdr:minimax-code"
EXPECTED_LABEL="mcode"
# The resume command the script sends unless a case overrides it. Written as a
# literal here rather than read out of the script under test: a test that derived
# its own expectation from the implementation would agree with any value,
# including the wrong one. It is also the exact argv inside the captured snapshot
# in tests/e2e/fixtures, which is what lets the seeded happy path match.
DEFAULT_RESUME_CMD="mcode --continue"

expected_report_sequence() { # expected_report_sequence [session-id]
  local sid="${1:-}"
  local session_line
  session_line="$(printf 'pane\treport-agent-session\t--source\t%s\t--agent\t%s' \
    "$EXPECTED_SOURCE" "$EXPECTED_LABEL")"
  if [ -n "$sid" ]; then
    session_line="$(printf '%s\t--agent-session-id\t%s' "$session_line" "$sid")"
  fi
  session_line="$(printf '%s\t%s\t--\tmcode\t--continue' "$session_line" "$PANE")"

  printf 'agent\tget\t%s\n' "$PANE"
  printf 'pane\treport-agent\t%s\t--source\t%s\t--agent\t%s\t--state\t%s\t--\tmcode\t--continue\n' \
    "$PANE" "$EXPECTED_SOURCE" "$EXPECTED_LABEL" "$EXPECTED_STATE"
  printf '%s\n' "$session_line"
  # The read-back of issue #71, and UNCONDITIONAL — including when no id was
  # sent. Skipping it there would make the no-id path the only path that reports
  # success without ever looking, which is the exact shape #71 exists to remove.
  # What it finds in that case is still attributable: any session on the pane is
  # one this run did not put there.
  printf 'agent\tget\t%s\n' "$PANE"
}

# --- cases -------------------------------------------------------------------
# 1. THE case that matters. Today's real manifest schema records no cwd, so there
#    is nothing to resolve and the script must say exactly that. A fabricated or
#    merely-nearest id resumes the wrong session and says nothing when it fails,
#    so this is the case that protects against the harm the issue is about.
#
#    It is also the case that cannot be written without constructed fixtures:
#    mcode writes no cwd, so no real store exercises this path. See
#    tests/fixtures/session/README.md.
case_resolve_real_schema_invents_nothing() {
  setup_case

  run_session resolve
  assert_rc_zero "$RC"

  assert_stdout_field sessions_root "$CASE_DIR/store/v2/sessions"
  assert_stdout_field session_id "<unresolved>"
  assert_stdout_field resume_cmd "mcode --continue"
  # The reason must be stated, not merely implied by an empty field.
  assert_stdout_field chosen_by "none - no manifest records a cwd, and an id must not be invented"
  assert_no_session_id_emitted
}

# 2. The only case that proves the lookup works at all. If this ever goes red
#    while case 1 stays green, the resolver is broken in a way that case 1
#    cannot see — that is exactly what happened once: a `select(type == "string")`
#    aimed at the manifest document instead of the id made every lookup return
#    nothing, and case 1's "unresolved" looked identical whether the code worked
#    or was dead.
case_resolve_matching_cwd_resolves_and_names_its_rule() {
  setup_case
  local sid="mvs_4444444444444444444444444444dddd"
  write_manifest v2 session_D "$sid" 1791059999999 >/dev/null

  run_session resolve
  assert_rc_zero "$RC"

  assert_stdout_field session_id "$sid"
  # The gate asked for the rule as well as the answer.
  assert_stdout_field chosen_by "manifest recording this cwd, greatest updatedAtMs"
}

# 3. A cwd that no manifest records must resolve to nothing even though a store
#    full of real manifests exists. This is the negative control for case 2: same
#    store, same schema, only the cwd differs.
case_resolve_non_matching_cwd_invents_nothing() {
  setup_case
  write_manifest v2 session_D "mvs_4444444444444444444444444444dddd" 1791059999999 >/dev/null
  # The generated manifest records $CASE_DIR/project, but the run happens in
  # $CASE_DIR/elsewhere.
  mkdir -p "$CASE_DIR/elsewhere"

  ( cd "$CASE_DIR/elsewhere" && "$SESSION_BIN" resolve ) >"$STDOUT_FILE" 2>"$STDERR_FILE"
  RC=$?

  assert_rc_zero "$RC"
  assert_stdout_field session_id "<unresolved>"
  assert_no_session_id_emitted
}

# 4. Two versioned stores present: the newest by the manifests' own
#    `updatedAtMs` wins. The fixture's v1 is an order of magnitude older.
case_resolve_picks_newest_store_by_updated_at_ms() {
  setup_case

  run_session resolve
  assert_rc_zero "$RC"

  assert_stdout_field sessions_root "$CASE_DIR/store/v2/sessions"
  assert_log_empty   # `resolve` must never touch the multiplexer
}

# 5. The regression guard for the `stat -f '%m'` this replaced, and the reason
#    the store is not ranked by filesystem mtime.
#
#    Here the two stores' file mtimes and their `updatedAtMs` values point at
#    DIFFERENT stores: v1's manifests are the oldest files on disk but carry the
#    highest `updatedAtMs`, and v2's are the newest files but rank lower. An
#    mtime implementation picks v2; the correct one picks v1. The case therefore
#    fails on a regression instead of passing by coincidence.
case_resolve_store_choice_ignores_file_mtime() {
  setup_case
  # Swap the ranking: v1 now claims the most recently updated session.
  jq '.updatedAtMs = 2000000000000' \
    "$CASE_DIR/store/v1/sessions/2026/10/01/09-00-00-000-session_C/manifest.json" \
    >"$CASE_DIR/store/v1/tmp.json" \
    && mv "$CASE_DIR/store/v1/tmp.json" \
         "$CASE_DIR/store/v1/sessions/2026/10/01/09-00-00-000-session_C/manifest.json"
  # …while leaving v2's files newer on disk than v1's.
  set_mtime "$CASE_DIR/store/v1/sessions/2026/10/01/09-00-00-000-session_C/manifest.json" 202001010000
  set_mtime "$CASE_DIR/store/v2/sessions/2026/10/04/12-00-00-000-session_A/manifest.json" 203001010000
  set_mtime "$CASE_DIR/store/v2/sessions/2026/10/04/12-00-00-000-session_B/manifest.json" 203001010000

  run_session resolve
  assert_rc_zero "$RC"

  assert_stdout_field sessions_root "$CASE_DIR/store/v1/sessions"
  # Belt and braces: state the losing store is absent, not merely that the
  # winner is present.
  if grep -qF 'store/v2/sessions' "$STDOUT_FILE"; then
    note "picked v2, whose files are newer on disk but whose manifests are older"
  fi
}

# 6. The same disagreement, one level down: two manifests in ONE store, both
#    recording this cwd, where the lower `updatedAtMs` has the newer file. This
#    pins resolution, not just discovery, and it is the behavioural difference
#    from the `stat` version rather than a restatement of case 5.
case_resolve_prefers_updated_at_ms_over_file_mtime() {
  setup_case
  local older_ms="mvs_5555555555555555555555555555eeee"
  local newer_ms="mvs_6666666666666666666666666666ffff"
  local f_older f_newer
  f_older="$(write_manifest v2 session_E "$older_ms" 1791050000000 1791060000000)"
  f_newer="$(write_manifest v2 session_F "$newer_ms" 1791059999999 1791040000000)"

  # Invert the file mtimes relative to the manifest timestamps. The
  # higher-updatedAtMs manifest (F) is deliberately the OLDER file.
  set_mtime "$f_older" 203001010000
  set_mtime "$f_newer" 202001010000

  run_session resolve
  assert_rc_zero "$RC"

  # F has the greater updatedAtMs even though E was created later AND its file
  # is newer. A mtime-ranked implementation returns E and fails here.
  assert_stdout_field session_id "$newer_ms"
  if grep -qF "$older_ms" "$STDOUT_FILE"; then
    note "picked the manifest with the newer file but the older updatedAtMs"
  fi
}

# 7. `report` without HERDR_PANE_ID. It must refuse with a diagnostic naming the
#    variable, and must not touch the CLI at all: herdr rejects a resume_argv
#    from a reporter that does not hold the pane, so calling anything here would
#    be a call that cannot succeed.
case_report_without_pane_id_refuses() {
  setup_case
  unset HERDR_PANE_ID

  run_session report
  assert_rc_nonzero "$RC"
  assert_stderr_mentions "HERDR_PANE_ID is unset"
  assert_log_empty
}

# 8. The ordering that herdr's `resume_not_accepted` demands: establish the
#    reporter as the pane's holder, then attach identity. Asserted on order, not
#    membership — see assert_log_order.
case_report_establishes_before_attaching_identity() {
  setup_case
  export HERDR_PANE_ID="$PANE"

  run_session report
  assert_rc_zero "$RC"

  assert_log_order "pane	report-agent	" "pane	report-agent-session"
  assert_log_exactly "$(expected_report_sequence)"
}

# 9. No id resolvable, yet the pane is still registered and the resume command is
#    still recorded — on both calls. This is the whole point of shipping
#    resume-only: identity is omitted, resume is not. `mcode --continue`
#    re-resolves by workspace at restore time and needs no id.
case_report_unresolved_id_still_records_resume() {
  setup_case
  export HERDR_PANE_ID="$PANE"

  run_session report
  assert_rc_zero "$RC"

  assert_stderr_mentions "no session id could be resolved"
  # The corrected claim, and the wording has moved twice, so this asserts the
  # sentence rather than a loosened match — the distinction is the whole point of
  # the case and a regex would let it rot back unnoticed.
  #
  # What is true: the MANUAL `mcode --continue` re-resolves by workspace and needs
  # no id. What is not: that herdr restart-restore is fine, which is a different
  # mechanism fed by a different write, is discarded outright on 0.9.3, and is
  # therefore unverifiable rather than verified-absent. "Unverifiable" is not
  # "unaffected", and conflating them is the defect #71 exists to close.
  assert_stderr_mentions "MANUAL resume is unaffected: 'mcode --continue' re-resolves by workspace and needs no session id"
  # The identity flag must be absent, and the resume argv present on both calls.
  assert_log_lacks "--agent-session-id"
  assert_log_exactly "$(expected_report_sequence)"
}

# 10. With a resolvable id, the id IS reported — otherwise cases 1-3 pin a
#     resolver whose output nothing ever uses.
case_report_attaches_resolved_id() {
  setup_case
  local sid="mvs_4444444444444444444444444444dddd"
  write_manifest v2 session_D "$sid" 1791059999999 >/dev/null
  export HERDR_PANE_ID="$PANE"

  run_session report
  assert_rc_zero "$RC"

  assert_stderr_mentions "resolved session $sid"
  assert_log_exactly "$(expected_report_sequence "$sid")"
}

# 11. The state is re-asserted, never imposed. This script owns identity and
#     resume, not state (issue #35 owns state), so it must report what herdr
#     already records. Reporting a placeholder to satisfy the ordering
#     requirement overwrote a real `working` status when this was first tried by
#     hand — the bug this case exists to keep fixed.
case_report_reasserts_existing_agent_state() {
  setup_case
  export HERDR_PANE_ID="$PANE"

  run_session report
  assert_rc_zero "$RC"

  assert_stderr_mentions "re-asserting existing agent state 'working'"
  assert_log_exactly "$(expected_report_sequence)"
}

# 12. When herdr records no state for the pane, the script picks one — and says
#     so, because a state it chose is a state the user did not.
case_report_falls_back_when_no_state_recorded() {
  setup_case
  export HERDR_PANE_ID="$PANE"
  export FAKE_HERDR_FAULT="agent-get-empty"
  export MCODE_AGENT_STATE="idle"

  run_session report
  assert_rc_zero "$RC"

  assert_stderr_mentions "no existing agent state"
  # The fallback is the override, not a hard-coded `unknown`.
  if grep -qF "$(printf 'pane	report-agent	%s	--source	%s	--agent	%s	--state	unknown	--	mcode	--continue' \
        "$PANE" "$EXPECTED_SOURCE" "$EXPECTED_LABEL")" "$FAKE_HERDR_LOG"; then
    note "imposed 'unknown' over the configured state"
  fi
  if ! grep -qF "$(printf 'pane	report-agent	%s	--source	%s	--agent	%s	--state	idle	--	mcode	--continue' \
        "$PANE" "$EXPECTED_SOURCE" "$EXPECTED_LABEL")" "$FAKE_HERDR_LOG"; then
    note "did not report the configured state 'idle'"
  fi
}

# 13. MCODE_RESUME_CMD is honoured, word-split into argv. A resume command
#     containing spaces must arrive as separate arguments, since RESUME_ARG is a
#     list and a single quoted string would be re-run as one unrunnable word.
case_report_resume_cmd_is_word_split() {
  setup_case
  export HERDR_PANE_ID="$PANE"
  export MCODE_RESUME_CMD="mcode --continue --model x"

  run_session report
  assert_rc_zero "$RC"

  if ! grep -qF "$(printf 'pane	report-agent	%s	--source	%s	--agent	%s	--state	working	--	mcode	--continue	--model	x' \
        "$PANE" "$EXPECTED_SOURCE" "$EXPECTED_LABEL")" "$FAKE_HERDR_LOG"; then
    note "resume command was not split into separate argv fields"
    sed 's/^/          /' "$FAKE_HERDR_LOG"
  fi
}

# 14. `report-agent` failing is fatal to the whole registration, and says so.
#     The pane is not registered, so attaching identity afterwards cannot work
#     and must not be attempted.
case_report_aborts_when_state_report_fails() {
  setup_case
  export HERDR_PANE_ID="$PANE"
  export FAKE_HERDR_FAIL="pane report-agent:1"

  run_session report
  assert_rc_nonzero "$RC"
  assert_stderr_mentions "was not recorded"
  assert_log_lacks "pane	report-agent-session"
}

# --- issue #71: verify the report actually landed ----------------------------
# Everything above proves the script SENT the right things. Nothing above proves
# herdr KEPT them, and that is the defect: `pane report-agent-session` exits 0
# for an agent kind herdr does not enumerate and persists nothing at all
# (herdr 0.9.3, measured 2026-10-03/04; confirmed independently in
# sparkfn/pc-client#2251). A script that reports success there is reporting a
# write that did not happen.
#
# The needles below are chosen so a faithful implementation passes and a
# plausible wrong one does not:
#
#   * the session id, EXACT — mandatory, and the anchor that makes these cases
#     mutation-proof. Without a read-back the id appears in exactly one line,
#     "resolved session <id> …", which says nothing about persistence.
#   * the pane id, EXACT — the issue requires the diagnostic to name the pane.
#   * the substance of the remaining claims, case-insensitively, because the
#     issue fixes what the message must SAY and not how it must say it.
#
# The stub's session identity lives at `.result.agent.agent_session.value`, not
# at `.result.agent.agent_session` — the latter is a wrapper object, measured
# from a live herdr 0.9.3 and recorded at tests/fake-herdr emit_agent_get. A
# read-back that reads the wrapper cannot tell a landed write from a dropped
# one, and these cases are shaped so that implementation fails them.

# 15. The write landed, so the script says nothing about it. This is the half of
#     #71 that stops the cheap fix: a read-back that ALWAYS complains is not a
#     read-back, and a user who cannot tell a working report from a broken one
#     has been handed a permanently alarming plugin.
case_readback_silent_when_session_persists() {
  setup_case
  local sid="mvs_4444444444444444444444444444dddd"
  write_manifest v2 session_D "$sid" 1791059999999 >/dev/null
  export HERDR_PANE_ID="$PANE"

  run_session report
  assert_rc_zero "$RC"

  # The id was sent…
  assert_log_exactly "$(expected_report_sequence "$sid")"
  # …herdr was asked whether it kept it…
  assert_readback_after_session_report
  # …and the answer was yes, so there is nothing to report.
  assert_stderr_lacks_match 'not (persist|stored|save)|discard|unavailab|not available'
  # A panic here would be as wrong as the silence: the registration did happen.
  assert_stderr_mentions "resolved session $sid"
}

# 16. THE case issue #71 exists for. herdr accepts the session report, exits 0,
#     and throws the id away — its measured 0.9.3 behaviour for an agent kind it
#     does not enumerate. The script must notice, must name what was lost, and
#     must NOT exit non-zero: the launch and the registration both succeeded, so
#     a non-zero exit would report a success as a failure and invite a caller to
#     retry work that already happened.
case_readback_warns_when_session_dropped() {
  setup_case
  local sid="mvs_4444444444444444444444444444dddd"
  write_manifest v2 session_D "$sid" 1791059999999 >/dev/null
  export HERDR_PANE_ID="$PANE"
  export FAKE_HERDR_FAULT="agent-session-dropped"

  run_session report
  # The decided exit policy: warn, exit 0.
  assert_rc_zero "$RC"

  assert_readback_after_session_report
  # The id that was lost, named exactly.
  assert_stderr_mentions "$sid"
  # The pane it was lost for, named exactly.
  assert_stderr_mentions "$PANE"
  # THE ACCURACY PIN, and the reason this case is not merely "a warning appeared".
  #
  # Asserted as a whole sentence, not as the fragment "Session identity is NOT
  # stored". The short form would let a future edit append "…and neither is the
  # resume command" and stay green — which is precisely the over-claim that
  # shipped once, asserting a measurement nobody took. The trailing clause
  # ("verified by the read-back, not inferred") is what pins that distinction:
  # it is the difference between a fact this run established and an assumption
  # it dressed up as one.
  #
  # CHANGED BY ISSUE #85, and the change is the point. The sentence used to end
  # there, and everything after it was the bug: "Whether herdr kept the resume
  # command is a separate question this API cannot answer … so ASSUME herdr
  # restart-restore is unavailable rather than rely on it." That was an
  # assumption presented as a finding. herdr DOES keep the resume command, in
  # `agent_resume` in the session snapshot, and a restart DOES run it. So the
  # sentence now stops at the id, says the id's absence is expected rather than a
  # fault, and hands the resume command to a read-back of its own.
  #
  # The pin is now on the SCOPE: the message must point at the resume command
  # being checked separately, and must NOT tell the user to assume restart-restore
  # is unavailable. That last half is asserted negatively below, because it is the
  # sentence that has to stay gone.
  assert_stderr_mentions "Session identity is NOT stored: that is verified by the read-back, not inferred"
  assert_stderr_matches 'resume command is a separate field'
  # The id's absence is EXPECTED for mcode — herdr keeps a session id only for the
  # agent kinds it enumerates — and the user is told so, so they do not go looking
  # for a bug here that is not here.
  assert_stderr_matches 'herdr|0\.9\.3'
  assert_stderr_matches 'enumerat'
  # The retired claim, asserted absent. "assume herdr restart-restore is
  # unavailable" is false and was the defect; a future edit must not bring it back
  # in any wording, which is why the needle is the verb and not the sentence.
  assert_stderr_lacks_match 'assume.{0,40}(restart-restore|resume).{0,30}unavailab'
  # …and the resume half must now be reported as AVAILABLE from the seeded
  # capture, which is the whole of issue #85's behaviour change.
  assert_stderr_matches 'restart-restore is AVAILABLE'
}

# 17. A different failure from a dropped write, and it must not be reported as
#     one. When `agent get` itself fails the script learned nothing: it cannot
#     say the id was lost, and it must not claim it was kept. "Could not verify"
#     is the honest answer, and it is a different sentence from #16 on purpose —
#     conflating them teaches the user to ignore the warning.
case_readback_distinguishes_unverifiable_from_dropped() {
  setup_case
  local sid="mvs_4444444444444444444444444444dddd"
  write_manifest v2 session_D "$sid" 1791059999999 >/dev/null
  export HERDR_PANE_ID="$PANE"
  export FAKE_HERDR_FAIL="agent get:1"

  run_session report
  assert_rc_zero "$RC"

  # The report was still attempted — a read-back failure is not a reason to skip
  # the write, and skipping it would lose the identity on a herdr that works.
  assert_log_order "pane	report-agent	" "pane	report-agent-session"
  # Inability to read is its own message, and it is not a claim of loss.
  assert_stderr_matches 'could not verify|cannot verify|unable to verify|not be verified'
  assert_stderr_lacks_match 'not (persist|stored|save)|discard|unavailab|not available'
}

# 18. The fourth row of the issue's table. With no id sent there is nothing to
#     compare against, but the read-back is still made: what it finds is
#     attributable, because any session already on the pane is one this run did
#     NOT put there. Skipping the read-back here would make this the only path
#     that reports success without ever looking, which is the exact shape #71
#     exists to remove.
case_readback_unverifiable_when_no_id_sent() {
  setup_case
  export HERDR_PANE_ID="$PANE"

  run_session report
  assert_rc_zero "$RC"

  # The read-back happens here too: two `agent get` calls, the pre-existing state
  # read and the verification of what was just written.
  assert_log_exactly "$(expected_report_sequence)"
  if [ "$(grep -c '^agent	get	' "$FAKE_HERDR_LOG")" -ne 2 ]; then
    note "expected two \`agent get\` calls: the state read and the read-back"
  fi
  # Nothing was sent, so the script must not claim an id was reported, stored or
  # confirmed. This is the exact "must not invent an id" contract, on stderr
  # rather than stdout, and it is the invariant that separates this case from
  # case 16: there, an id was sent and lost; here, none was sent at all.
  assert_stderr_lacks_match 'mvs_[0-9a-z]{8,}'
  assert_stderr_mentions "no session id could be resolved"
  # Both halves stated as unverifiable rather than as fine.
  assert_stderr_matches 'unverifiable|nothing was sent|nothing was stored'
  assert_stderr_matches 'resume'
  # Deliberately NOT asserting the absence of "unavailable" here, though an
  # earlier draft of this case did. Expecting resume to be unavailable is the
  # honest statement for this path — `agent get` exposes no resume field, so
  # persistence is unverifiable either way — and forbidding the word would have
  # failed a correct implementation for saying the true thing.
}

# --- the resume read-back: issue #85 -----------------------------------------
# Everything above checks the session ID. These check the RESUME COMMAND, which
# is a different field in a different file, and which the old read-back never
# looked at — it read `agent_session`, found nothing (herdr only stores an id
# for the agent kinds it enumerates), and generalised "nothing was stored" to a
# command herdr had in fact kept. So each case below states which of the two
# things it is about, and the AVAILABLE/UNVERIFIED cases are the ones that go red
# if the read-back ever goes back to the wrong field.

# 19. The happy path, and the whole of #85's behaviour change. The seeded
#     snapshot is a real herdr capture holding OUR agent_resume, so the read-back
#     must find it there and say restart-restore is available.
case_readback_finds_resume_in_the_session_snapshot() {
  setup_case
  export HERDR_PANE_ID="$PANE"
  write_session_snapshot stored >/dev/null

  run_session report
  assert_rc_zero "$RC"

  # The file it actually read is named, so the claim is checkable rather than
  # asserted. A read-back that says "available" without saying where it looked
  # is the same failure as one that looks in the wrong place, just quieter.
  #
  # Asserted as the bare path, not as "session snapshot <path>": the message puts
  # the two apart ("The herdr session snapshot X holds ..."), and a needle that
  # requires them adjacent tests the sentence's layout rather than the fact. That
  # is what the first version of this assertion did, and it failed against a
  # read-back that was working perfectly.
  assert_stderr_mentions "$MCODE_HERDR_SESSION_DIR/session.json"
  assert_stderr_mentions "restart-restore is AVAILABLE"
  # The argv it matched on, so a read-back matching on something incidental
  # (any resume at all, any argv) cannot pass this.
  assert_stderr_mentions "$DEFAULT_RESUME_CMD"
  assert_stderr_mentions "$EXPECTED_SOURCE"
  assert_stderr_mentions "$EXPECTED_LABEL"
  # And it must not ALSO be claiming the resume is unverifiable, which is the
  # sentence this replaces.
  assert_stderr_lacks_match 'cannot be checked|unverifiable from here'
}

# 20. A snapshot that does not hold our resume, with the session directory
#     PINNED. herdr debounces session saves by five seconds, so on a real run the
#     snapshot usually has not caught up when the read-back runs. That is not a
#     finding about herdr, and the message must not dress it as one.
case_readback_resume_not_confirmed_when_pinned() {
  setup_case
  export HERDR_PANE_ID="$PANE"
  write_session_snapshot no-resume >/dev/null

  run_session report
  assert_rc_zero "$RC"

  # Said about the file that was actually read.
  assert_stderr_mentions "$MCODE_HERDR_SESSION_DIR/session.json"
  # THE PIN. "NOT a claim that herdr discarded it" is the clause that keeps this
  # from regressing into the #71 defect in mirror image: reporting a write as
  # lost when it is merely not flushed yet.
  assert_stderr_mentions "NOT a claim that herdr discarded it"
  assert_stderr_matches 'debounce|five seconds'
  # What to do about it: read again shortly, and know that manual resume is
  # unaffected either way.
  assert_stderr_matches 'again in a few seconds'
  assert_stderr_matches 're-resolves by workspace'
  # With the directory already pinned, telling the user to pin it would be noise,
  # so that sentence belongs to the unpinned case and only there.
  assert_stderr_lacks_match "Set MCODE_HERDR_SESSION_DIR"
  # Neither of the other two outcomes may leak in.
  assert_stderr_lacks_match 'restart-restore is AVAILABLE'
  assert_stderr_lacks_match 'no herdr session snapshot could be read'
}

# 21. The same absent resume, but with NO session directory pinned — the state of
#     every pane in a NAMED session, and of every pane whose session this process
#     simply cannot name. Absence here is weaker still, because the file read may
#     not even be this pane's session, and the message has to say so rather than
#     quietly reaching the same conclusion.
case_readback_resume_not_confirmed_when_session_unknown() {
  setup_case
  export HERDR_PANE_ID="$PANE"
  unset MCODE_HERDR_SESSION_DIR
  local xdg="$CASE_DIR/xdg"
  mkdir -p "$xdg/herdr"
  # A snapshot that exists, holds nothing of ours, and stands in for the default
  # session — the only file this path can read.
  jq 'del(.workspaces[].tabs[].panes[] | select(.agent_resume) | .agent_resume)' \
    "$SNAPSHOT_CAPTURE" > "$xdg/herdr/session.json"
  export XDG_CONFIG_HOME="$xdg"

  run_session report
  assert_rc_zero "$RC"

  assert_stderr_mentions "$xdg/herdr/session.json"
  # The two reasons absence is not a finding, both named. The session one is the
  # one a reader is most likely to miss and most likely to be wrong about.
  assert_stderr_matches 'debounce|five seconds'
  assert_stderr_mentions "not known from inside a pane"
  assert_stderr_mentions "MCODE_HERDR_SESSION_DIR"
  assert_stderr_lacks_match 'restart-restore is AVAILABLE'
  # A named session's real snapshot is a DIFFERENT file, and saying the default
  # one is what got read is what keeps this from being a false alarm.
  assert_stderr_mentions "default session"
}

# 22. A resume that is present but is NOT ours. herdr's snapshot can hold resumes
#     from several reporters, and a Claude or Codex pane in the same session will
#     have one. A read-back that matched loosely would call this a match and
#     report availability for a command it never sent.
case_readback_ignores_another_reporters_resume() {
  setup_case
  export HERDR_PANE_ID="$PANE"
  write_session_snapshot foreign herdr:claude claude claude --resume abc123 >/dev/null

  run_session report
  assert_rc_zero "$RC"

  # Herdr holds a resume; it is simply not the one this run reported.
  assert_stderr_lacks_match 'restart-restore is AVAILABLE'
  # It is not silently ignored either — the snapshot was read and did not match,
  # so the absence is reported rather than passed over.
  assert_stderr_matches 'NOT CONFIRMED|does not hold it'
  # The other reporter's identity is never quoted back as if it were ours.
  assert_stderr_lacks_match 'herdr:claude'
}

# 23. No snapshot at all. This is the "could not confirm" outcome, and it is
#     different from both 20 and 21: nothing was learned either way. It must not
#     borrow either of their wording.
case_readback_unverifiable_when_no_snapshot_readable() {
  setup_case
  export HERDR_PANE_ID="$PANE"
  rm -f "$MCODE_HERDR_SESSION_DIR/session.json"

  run_session report
  assert_rc_zero "$RC"

  assert_stderr_matches 'no herdr session snapshot could be read'
  assert_stderr_matches 'UNVERIFIED'
  # Neither of the other two outcomes may leak in.
  assert_stderr_lacks_match 'NOT CONFIRMED'
  assert_stderr_lacks_match 'restart-restore is AVAILABLE'
}

# 24. THE REASON THERE IS NO `herdr session list` CALL. An earlier draft asked
#     herdr which session was running, which found the right directory and cost a
#     herdr invocation on every launch — and broke tests/run.sh, which asserts the
#     launch path's exact argv sequence and belongs to another member. This case
#     pins the consequence so the call cannot be reintroduced casually: with no
#     session directory pinned, the read-back reads herdr's default config
#     location and issues NO herdr call to do it.
#
#     XDG_CONFIG_HOME is aimed at the sandbox so this is deterministic AND the
#     suite never reads the developer's real ~/.config/herdr.
case_readback_reads_xdg_default_without_calling_herdr() {
  setup_case
  export HERDR_PANE_ID="$PANE"
  unset MCODE_HERDR_SESSION_DIR
  local xdg="$CASE_DIR/xdg"
  mkdir -p "$xdg/herdr"
  cp "$SNAPSHOT_CAPTURE" "$xdg/herdr/session.json"
  export XDG_CONFIG_HOME="$xdg"

  run_session report
  assert_rc_zero "$RC"

  # The full sequence, and nothing else. A `session list --json` line here is the
  # regression this case exists to prevent, and it is also what broke another
  # member's suite the first time.
  assert_log_exactly "$(expected_report_sequence)"
  assert_log_lacks "session	list"
  # It read the right file, and said so.
  assert_stderr_mentions "$xdg/herdr/session.json"
  assert_stderr_mentions "restart-restore is AVAILABLE"
  # The real config dir is nowhere in the output.
  assert_stderr_lacks_match "$HOME/.config/herdr"
}


# --- driver ------------------------------------------------------------------
run_case() { # run_case <name> <function>
  CURRENT_CASE="$1"
  CASES_RUN=$((CASES_RUN + 1))
  broke=0
  "$2"
  if [ "$broke" -eq 0 ]; then
    printf 'ok    %s\n' "$CURRENT_CASE"
  else
    CASES_FAILED=$((CASES_FAILED + 1))
    printf 'FAIL  %s\n' "$CURRENT_CASE"
  fi
}

CASES=(
  resolve-real-schema-invents-nothing:case_resolve_real_schema_invents_nothing
  resolve-matching-cwd-resolves-and-names-its-rule:case_resolve_matching_cwd_resolves_and_names_its_rule
  resolve-non-matching-cwd-invents-nothing:case_resolve_non_matching_cwd_invents_nothing
  resolve-picks-newest-store-by-updated-at-ms:case_resolve_picks_newest_store_by_updated_at_ms
  resolve-store-choice-ignores-file-mtime:case_resolve_store_choice_ignores_file_mtime
  resolve-prefers-updated-at-ms-over-file-mtime:case_resolve_prefers_updated_at_ms_over_file_mtime
  report-without-pane-id-refuses:case_report_without_pane_id_refuses
  report-establishes-before-attaching-identity:case_report_establishes_before_attaching_identity
  report-unresolved-id-still-records-resume:case_report_unresolved_id_still_records_resume
  report-attaches-resolved-id:case_report_attaches_resolved_id
  report-reasserts-existing-agent-state:case_report_reasserts_existing_agent_state
  report-falls-back-when-no-state-recorded:case_report_falls_back_when_no_state_recorded
  report-resume-cmd-is-word-split:case_report_resume_cmd_is_word_split
  report-aborts-when-state-report-fails:case_report_aborts_when_state_report_fails
  readback-silent-when-session-persists:case_readback_silent_when_session_persists
  readback-warns-when-session-dropped:case_readback_warns_when_session_dropped
  readback-distinguishes-unverifiable-from-dropped:case_readback_distinguishes_unverifiable_from_dropped
  readback-unverifiable-when-no-id-sent:case_readback_unverifiable_when_no_id_sent
  readback-finds-resume-in-the-session-snapshot:case_readback_finds_resume_in_the_session_snapshot
  readback-resume-not-confirmed-when-pinned:case_readback_resume_not_confirmed_when_pinned
  readback-resume-not-confirmed-when-session-unknown:case_readback_resume_not_confirmed_when_session_unknown
  readback-ignores-another-reporters-resume:case_readback_ignores_another_reporters_resume
  readback-unverifiable-when-no-snapshot-readable:case_readback_unverifiable_when_no_snapshot_readable
  readback-reads-xdg-default-without-calling-herdr:case_readback_reads_xdg_default_without_calling_herdr
)

if [ ! -x "$FAKE_HERDR" ]; then
  printf 'tests/session-run.sh: %s is missing or not executable\n' "$FAKE_HERDR" >&2
  exit 2
fi
if [ ! -f "$SESSION_BIN" ]; then
  printf 'tests/session-run.sh: script under test not found: %s\n' "$SESSION_BIN" >&2
  exit 2
fi
if [ ! -d "$STORE_FIXTURE" ]; then
  printf 'tests/session-run.sh: session store fixture not found: %s\n' "$STORE_FIXTURE" >&2
  exit 2
fi

if [ "${1:-}" = "--list" ]; then
  for pair in "${CASES[@]}"; do printf '%s\n' "${pair%%:*}"; done
  exit 0
fi

if [ "$#" -gt 0 ]; then
  SELECTED=("$@")
else
  SELECTED=()
  for pair in "${CASES[@]}"; do SELECTED+=("${pair%%:*}"); done
fi

for name in "${SELECTED[@]}"; do
  found=""
  for pair in "${CASES[@]}"; do
    [ "${pair%%:*}" = "$name" ] && { found="${pair#*:}"; break; }
  done
  [ -n "$found" ] || { printf 'unknown case: %s (try --list)\n' "$name" >&2; exit 2; }
  run_case "$name" "$found"
done

printf -- '---\n'
if [ "$CASES_FAILED" -eq 0 ]; then
  printf '%d case(s), all passed\n' "$CASES_RUN"
  exit 0
fi
printf '%d case(s), %d failed\n' "$CASES_RUN" "$CASES_FAILED"
exit 1
