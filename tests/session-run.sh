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

SESSION_BIN="${MCODE_SESSION_BIN:-$repo/bin/mcode-session.sh}"
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

# --- expectations ------------------------------------------------------------
# The agent state herdr already records for the pane, as the stub serves it.
EXPECTED_STATE="working"
EXPECTED_SOURCE="jaaacki.minimax-code"
EXPECTED_LABEL="minimax-code"

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
  printf '%s' "$session_line"
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
  # Omission must be stated, not silent.
  assert_stderr_mentions "Resume is unaffected"
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
