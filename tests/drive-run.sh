#!/usr/bin/env bash
# tests/drive-run.sh — the suite for bin/mcode-drive.sh (issue #74).
#
# Plain bash, like every other suite here. No framework; `bats` is not installed
# and is not worth adding.
#
# Run every case:   ./tests/drive-run.sh
# Run a subset:     ./tests/drive-run.sh case-name
# List case names:  ./tests/drive-run.sh --list
#
# Exits 0 only if every case passes. Exit 2 if a precondition is missing.
#
# Named tests/*run.sh on purpose: CI discovers suites by the glob
# `suites=(tests/*run.sh)`, so a file named anything else is committed and never
# executed, and nothing fails. That has already happened once in this repo.
#
# ---- WHAT IS STUBBED, AND WHY IT HAS TO BE -----------------------------------
# bin/mcode-drive.sh reaches three binaries, and none of them can be real in a
# test:
#
#   herdr    -> tests/fake-herdr      the multiplexer must not be touched
#   mcode    -> tests/fake-mcode      `mcode exec` runs a REAL turn in a live
#                                     session. On this machine every live session
#                                     belongs to a working flock member, so a real
#                                     exec would put a prompt in someone's pane
#                                     and cost real tokens.
#   sqlite3  -> tests/fake-sqlite3    the real store is a 76 MB live database the
#                                     runtime holds open; asserting against it
#                                     would be asserting against whatever the
#                                     owner's panes happen to be doing.
#
# ---- WHAT IS PROVEN HERE, AND WHAT IS NOT ------------------------------------
# PROVEN: the argv each binary receives, the order the calls happen in, the
# exit codes, what lands on stdout versus stderr, when a binding is written, and
# — the part that matters most — that an ambiguous pane is REFUSED rather than
# guessed.
#
# NOT PROVEN: that a real `mcode exec` accepts these arguments and answers. That
# is the architect's first-hand measurement (issue #74, mcode 0.6.2, herdr 0.9.3,
# 2026-10-04: a live session is drivable by id, and one whose pane is CLOSED is
# still drivable). A suite cannot re-prove it without sending turns into live
# sessions, which is the one thing it must not do. The two claims are different
# and this file is only about the second.
#
# MCODE_DRIVE_BIN overrides the script under test, so the mutation check can run
# against a deliberately broken *copy* and leave the real bin/mcode-drive.sh
# untouched (mcode-1 owns that file).

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"

# Resolved to an absolute path for the same reason tests/session-run.sh does it:
# run_drive cd's into the sandbox, so a relative override would resolve against
# the sandbox and fail — the override would work when the suite was written and
# break the first time it was actually used.
DRIVE_BIN="${MCODE_DRIVE_BIN:-$repo/bin/mcode-drive.sh}"
case "$DRIVE_BIN" in
  /*) ;;
  *) DRIVE_BIN="$(cd -- "$(dirname -- "$DRIVE_BIN")" && pwd)/$(basename -- "$DRIVE_BIN")" ;;
esac

FAKE_HERDR="$here/fake-herdr"
FAKE_MCODE="$here/fake-mcode"
FAKE_SQLITE3="$here/fake-sqlite3"

# Fixed sentinels. The pane is the same id everywhere so a case can prove the
# name path was taken by the PRESENCE of `agent get` and the pane path by its
# absence. Nothing here is a value the implementation may invent: PANE arrives
# from the stub's response and SID is either bound in the fixture or returned by
# the stub.
PANE="wZ:p7"
AGENT_NAME="mcode"
BOUND_SID="mvs_4444444444444444444444444444dddd"
SQL_SID="mvs_5555555555555555555555555555eeee"
STARTED_SID="mvs_6666666666666666666666666666ffff"
OTHER_SID="mvs_7777777777777777777777777777aaaa"

BASE_PATH="$PATH"
WORK="$(cd -- "$(mktemp -d "${TMPDIR:-/tmp}/mcode-drive-tests.XXXXXX")" && pwd -P)"

cleanup() {
  PATH="$BASE_PATH"
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    printf 'tests/drive-run.sh: KEEP_TMP=1, sandbox left at %s\n' "$WORK" >&2
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

TAB="$(printf '\t')"

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

assert_rc_equals() { # assert_rc_equals <got> <want> <label>
  if [ "$1" -ne "$2" ]; then
    note "$3: expected exit $2, got $1"
  fi
}

assert_stderr_mentions() { # assert_stderr_mentions <needle>
  if ! grep -qF -- "$1" "$STDERR_FILE"; then
    note "stderr does not mention '$1'"
  fi
}

assert_stderr_lacks() { # assert_stderr_lacks <needle>
  if grep -qF -- "$1" "$STDERR_FILE"; then
    note "stderr mentions '$1' but this case requires it to be absent"
  fi
}

assert_stdout_mentions() { # assert_stdout_mentions <needle>
  if ! grep -qF -- "$1" "$STDOUT_FILE"; then
    note "stdout does not mention '$1'"
  fi
}

# The exec argv, exactly. Ordering and spelling are both pinned: `mcode exec`
# takes the session id and cwd as flags and the prompt after `--`, so a prompt
# that arrives as two arguments, or a `--cwd` carrying an unresolved path, is a
# real failure rather than a stylistic one.
assert_exec_argv() { # assert_exec_argv <sid> <cwd> <prompt>
  local want
  want="$(printf 'exec\t--session\t%s\t--cwd\t%s\t--\t%s' "$1" "$2" "$3")"
  local got
  got="$(cat "$FAKE_MCODE_LOG" 2>/dev/null)"
  if [ "$got" != "$want" ]; then
    note "mcode exec argv mismatch"
    note "expected: $want"
    note "actual:   $got"
  fi
}

# mcode must never be called. The whole safety argument of #74 rests on an
# ambiguous or unresolvable pane producing no turn at all, so every refusal case
# asserts this rather than only the exit code.
assert_mcode_never_called() {
  if [ -s "$FAKE_MCODE_LOG" ]; then
    note "mcode WAS invoked; a refused target must send no prompt:"
    sed 's/^/          /' "$FAKE_MCODE_LOG"
  fi
}

assert_herdr_log_exactly() { # assert_herdr_log_exactly <expected, newline-separated>
  local actual
  actual="$(cat "$FAKE_HERDR_LOG" 2>/dev/null)"
  if [ "$actual" != "$1" ]; then
    note "herdr invocation sequence mismatch"
    note "expected:"
    printf '%s\n' "$1" | sed $'s/\t/ /g; s/^/          /'
    note "actual:"
    printf '%s\n' "$actual" | sed $'s/\t/ /g; s/^/          /'
  fi
}

assert_herdr_log_lacks() { # assert_herdr_log_lacks <needle>
  if grep -qF -- "$1" "$FAKE_HERDR_LOG" 2>/dev/null; then
    note "herdr invocation log should not contain '$1'"
  fi
}

assert_sqlite_queried() { # assert_sqlite_queried <substring>
  if ! grep -qF -- "$1" "$FAKE_SQLITE_LOG" 2>/dev/null; then
    note "no sqlite query containing '$1'"
    sed 's/^/          /' "$FAKE_SQLITE_LOG" 2>/dev/null
  fi
}

# The inverse, and load-bearing in its own right: a path that must not consult the
# database has to prove it, because a helper that "helpfully" re-resolved a pane
# the operator had already decided would silently override a human judgement with
# a query.
assert_sqlite_not_queried() {
  if [ -s "$FAKE_SQLITE_LOG" ]; then
    note "sqlite was queried, but this path must not consult the database:"
    sed 's/^/          /' "$FAKE_SQLITE_LOG"
  fi
}

# --- per-case sandbox --------------------------------------------------------
# The pane's workspace is a real directory in the sandbox, because the
# implementation realpath's it with `cd` + `pwd -P` and a path that does not
# exist is a different case entirely (case 7).
setup_case() {
  CASE_DIR="$WORK/$CURRENT_CASE"
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/home/v2/sqlite" "$CASE_DIR/state"

  # The implementation requires the database file to EXIST before it queries it,
  # and refuses to guess when it does not. An empty file is enough: every real
  # answer comes from the stub.
  : >"$CASE_DIR/home/v2/sqlite/runtime-state.sqlite"

  # `sqlite3` resolved by bare name, so the implementation's `command -v sqlite3`
  # preflight passes and finds the stub. Putting it on PATH rather than behind a
  # knob means the suite exercises the same resolution path a user's shell does.
  cp "$FAKE_SQLITE3" "$CASE_DIR/bin/sqlite3"
  chmod +x "$CASE_DIR/bin/sqlite3"
  PATH="$CASE_DIR/bin:$BASE_PATH"

  FAKE_HERDR_LOG="$CASE_DIR/herdr.log"
  FAKE_MCODE_LOG="$CASE_DIR/mcode.log"
  FAKE_SQLITE_LOG="$CASE_DIR/sqlite.log"
  FAKE_SQLITE_ROWS="$CASE_DIR/rows.tsv"
  STDOUT_FILE="$CASE_DIR/stdout"
  STDERR_FILE="$CASE_DIR/stderr"
  : >"$FAKE_HERDR_LOG"
  : >"$FAKE_MCODE_LOG"
  : >"$FAKE_SQLITE_LOG"
  : >"$FAKE_SQLITE_ROWS"
  : >"$STDOUT_FILE"
  : >"$STDERR_FILE"

  export FAKE_HERDR_LOG FAKE_MCODE_LOG FAKE_SQLITE_LOG FAKE_SQLITE_ROWS
  export FAKE_HERDR_FIXTURES="$here/fixtures"
  export HERDR_BIN_PATH="$FAKE_HERDR"
  # Absolute path to the stub, so the implementation's `command -v` resolves it
  # without this suite depending on where `mcode` happens to be installed.
  export MCODE_BIN_NAME="$FAKE_MCODE"
  export MCODE_HOME="$CASE_DIR/home"
  export MCODE_DRIVE_STATE_DIR="$CASE_DIR/state"
  # One pane id and one cwd, coherent across every herdr call, so no case can
  # assert a story in which `agent get` and `pane get` disagree.
  export FAKE_HERDR_SRC_PANE="$PANE"
  export FAKE_HERDR_CWD="$CASE_DIR/project"
  unset FAKE_HERDR_FAULT FAKE_HERDR_FAIL
  unset FAKE_MCODE_FAIL FAKE_MCODE_REPLY FAKE_SQLITE_FAIL
  unset MCODE_DRIVE_SESSION HERDR_PLUGIN_STATE_DIR
}

# Write the binding file the implementation will read.
write_binding_file() { # write_binding_file <pane> <sid>
  printf '{"%s":"%s"}\n' "$1" "$2" >"$CASE_DIR/state/bindings.json"
}

# Canned sqlite rows. NEWEST FIRST, matching the query's ORDER BY
# updated_at_ms DESC, because this stub does not sort — it prints the fixture in
# order. Stating the order in the fixture is what makes "the newest was chosen"
# a fact the reader can check rather than a fact the stub produced.
write_rows() { # write_rows <session-id> <status> <updated_at_ms> [more...]
  local sid status ms
  while [ "$#" -ge 3 ]; do
    sid="$1"; status="$2"; ms="$3"; shift 3
    printf '%s\t%s\t%s\t%s\n' "$sid" "$CASE_DIR/project" "$status" "$ms" \
      >>"$FAKE_SQLITE_ROWS"
  done
}

run_drive() { # run_drive <args...>
  ( cd "$CASE_DIR/project" && "$DRIVE_BIN" "$@" ) >"$STDOUT_FILE" 2>"$STDERR_FILE"
  RC=$?
}

# Mirrors every executable on PATH into a fresh directory, skipping $1. Same
# helper, same reason, as tests/run.sh's: a shim earlier on PATH would still
# satisfy `command -v jq`, so the "jq absent" case would pass without jq ever
# being missing. Mirroring rather than replacing PATH also keeps `bash` itself
# reachable — the script under test starts with `#!/usr/bin/env bash`, so a PATH
# narrowed to just the sandbox makes env fail to find an interpreter and the
# script never runs at all. That failure looks like a pass for the right
# assertion (non-zero exit) and is nothing of the kind.
path_without() { # path_without <basename>
  local drop="$1"
  local mirror="$CASE_DIR/no-$drop"
  local dir f base
  mkdir -p "$mirror"
  local IFS=:
  for dir in $PATH; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      [ -e "$f" ] || continue
      base="${f##*/}"
      [ "$base" = "$drop" ] && continue
      ln -sf -- "$f" "$mirror/$base" 2>/dev/null || true
    done
  done
  printf '%s' "$mirror"
}

# --- cases -------------------------------------------------------------------
# 1. The happy path, and the case every other case is a variation of. A NAME
#    argument resolves through `agent get` to a pane, the pane has a binding, and
#    the binding is what the turn is sent to — no sqlite, because a binding that
#    exists must be trusted rather than second-guessed.
case_name_arg_resolves_and_bound_session_is_driven() {
  setup_case
  write_binding_file "$PANE" "$BOUND_SID"

  run_drive "$AGENT_NAME" "hello there"

  assert_rc_zero "$RC"
  # Name -> pane is a real herdr call, and it happens before anything else.
  assert_herdr_log_exactly "$(printf 'agent\tget\t%s\npane\tget\t%s' "$AGENT_NAME" "$PANE")"
  # A binding hit must NOT go to the database. Re-resolving a pane that is
  # already bound is how a deliberate binding gets silently overridden by a
  # newer-but-wrong session.
  if [ -s "$FAKE_SQLITE_LOG" ]; then
    note "the binding file already had this pane, but sqlite was queried anyway"
  fi
  assert_exec_argv "$BOUND_SID" "$(cd -- "$CASE_DIR/project" && pwd -P)" "hello there"
  # stdout is the model's answer, undecorated; attribution goes to stderr.
  assert_stdout_mentions "PONG"
  assert_stderr_mentions "driving pane ${PANE}, session ${BOUND_SID}"
}

# 2. A pane id contains a colon; a name does not. The pane form must skip the
#    name lookup entirely — and it is the form the tests should prefer, because
#    mcode-1 measured that a merely-REGISTERED label is not addressable at all:
#    `agent get <label>` exits 1 with agent_not_found for an agent that is
#    plainly in `agent list`, because a name only exists after `agent rename`.
case_pane_id_arg_skips_name_resolution() {
  setup_case
  write_binding_file "$PANE" "$BOUND_SID"

  run_drive "$PANE" "hi"

  assert_rc_zero "$RC"
  assert_herdr_log_lacks "agent	get"
  assert_herdr_log_exactly "$(printf 'pane\tget\t%s' "$PANE")"
  assert_exec_argv "$BOUND_SID" "$(cd -- "$CASE_DIR/project" && pwd -P)" "hi"
}

# 3. No binding: fall back to the database, and take the single candidate. This
#    is the path that runs on a pane nobody has driven yet, which is most of
#    them, so "no binding" must be a supported state rather than an error.
case_no_binding_falls_back_to_sqlite_single_candidate() {
  setup_case
  write_rows "$SQL_SID" "started" 1791059999999

  run_drive "$PANE" "hi"

  assert_rc_zero "$RC"
  assert_sqlite_queried "local_runtime_sessions"
  assert_exec_argv "$SQL_SID" "$(cd -- "$CASE_DIR/project" && pwd -P)" "hi"
}

# 4. THE CASE THAT REPLACED A SOUNDER-LOOKING ONE. The task brief asked for
#    "multiple rows, pid-ordering resolves, correct sid". That cannot work, and
#    the reason is worth keeping: ~/.minimax-code/.mcode-active/*.json contains
#    exactly two keys — `pid` and `startedAtMs` (verified across every file on
#    this machine). No pane id, no cwd, no session id. So a live-pid list and a
#    live-session list can be shown to line up in RANK, but nothing marks which
#    rank belongs to THIS pane, and `mcode exec` has no guard that stops a wrong
#    session from accepting the prompt. Zipping a rank onto a named pane is a
#    one-in-three guess that reports success.
#
#    What is sound is the narrowing: several candidates, of which exactly one is
#    'started', is a pane mid-turn and therefore the live one. That is the case
#    here, and it is the case that would otherwise have been a guess.
case_multiple_candidates_narrow_to_the_started_one() {
  setup_case
  # Newest first, as the query orders them: the idle one is the most tempting
  # wrong answer, and the newest-started rule has to beat it.
  write_rows "$OTHER_SID" "idle"    1791160000000
  write_rows "$SQL_SID"   "aborted" 1791150000000
  write_rows "$STARTED_SID" "started" 1791059999999

  run_drive "$PANE" "hi"

  assert_rc_zero "$RC"
  # The narrowing is a second, different query — asserted so an implementation
  # that queried once and guessed cannot pass.
  assert_sqlite_queried "status = 'started'"
  # The started one, not the newest one. This is the assertion the whole
  # narrowing rule exists to make.
  assert_exec_argv "$STARTED_SID" "$(cd -- "$CASE_DIR/project" && pwd -P)" "hi"
}

# 5. THE SAFETY CASE. Two started sessions in one workspace and no binding:
#    there is no sound answer, so the helper must refuse — and must send no
#    prompt at all. This is the whole point of the helper: a registered mcode
#    pane cannot be driven through herdr, so the temptation to drive *a* session
#    and hope is strongest exactly here.
#
#    Measured on this machine, 2026-10-04: TWELVE live sessions share the single
#    workspace /Users/noonoon/Dev/herdr-plugin-minimax-code, and this repo's own
#    flock is the pathological case — three workers, three 'started' sessions
#    created 3.3 seconds apart. The wrong pick would put a prompt in a colleague's
#    pane and report success.
case_ambiguous_pane_dies_and_sends_nothing() {
  setup_case
  write_rows "$STARTED_SID" "started" 1791059999999
  write_rows "$OTHER_SID"   "started" 1791059999998

  run_drive "$PANE" "hi"

  assert_rc_nonzero "$RC"
  # The load-bearing assertion. A non-zero exit alone would also be satisfied by
  # a helper that failed AFTER sending the prompt.
  assert_mcode_never_called
  # Both candidates named, so the user can resolve it deliberately rather than
  # being told only that it failed.
  assert_stderr_mentions "$STARTED_SID"
  assert_stderr_mentions "$OTHER_SID"
  assert_stderr_mentions "$PANE"
  # And the way out is offered. Dying without a next step is a dead end; the
  # override is the documented escape hatch.
  assert_stderr_mentions "MCODE_DRIVE_SESSION="
}

# 6. `--cwd` must match the session's workspace EXACTLY or `mcode exec` refuses
#    the turn. On macOS /tmp and /private/tmp are the same directory with
#    different names, so a pane whose cwd arrives symlinked has to be resolved
#    before it is passed on. This is a correctness requirement, not tidiness.
case_symlinked_cwd_is_realpathed_before_exec() {
  setup_case
  write_binding_file "$PANE" "$BOUND_SID"
  # A symlinked workspace, the shape a pane opened under /tmp actually has.
  mkdir -p "$CASE_DIR/real-project"
  ln -s "$CASE_DIR/real-project" "$CASE_DIR/link-project"
  export FAKE_HERDR_CWD="$CASE_DIR/link-project"

  run_drive "$PANE" "hi"

  assert_rc_zero "$RC"
  local want_cwd
  want_cwd="$(cd -- "$CASE_DIR/real-project" && pwd -P)"
  # Not merely "different": the symlink must be GONE. An exec that received
  # $CASE_DIR/link-project would be refused by mcode with "Session workspace
  # does not match --cwd", so the symlink surviving into argv is the failure.
  assert_exec_argv "$BOUND_SID" "$want_cwd" "hi"
}

# 7. The exec's exit code is passed through, not swallowed and not remapped. A
#    caller that cannot distinguish "the turn ran" from "the turn failed" cannot
#    act on either. The attribution line must name the session, the pane and the
#    cwd, because a turn that lands in the wrong workspace is otherwise
#    unattributable after the fact.
case_exec_failure_passes_exit_through_with_attribution() {
  setup_case
  write_binding_file "$PANE" "$BOUND_SID"
  export FAKE_MCODE_FAIL=7

  run_drive "$PANE" "hi"

  assert_rc_equals "$RC" 7 "exec failure"
  assert_stderr_mentions "$BOUND_SID"
  assert_stderr_mentions "$PANE"
  assert_stderr_mentions "exit 7"
}

# 8. A binding is a CACHE of a pairing that has been shown to work, so it is
#    written only after a turn that exited 0. Recording it earlier would mean the
#    next drive trusts a pairing nothing has ever demonstrated — which is the
#    shape of bug #71, where a write was reported that never happened.
case_binding_is_written_only_after_a_successful_drive() {
  setup_case
  write_rows "$SQL_SID" "started" 1791059999999

  run_drive "$PANE" "hi"

  assert_rc_zero "$RC"
  local file="$CASE_DIR/state/bindings.json"
  if [ ! -f "$file" ]; then
    note "no bindings.json after a successful drive; the next drive re-resolves"
    return
  fi
  local got
  got="$(jq -r --arg p "$PANE" '.[$p] // empty' "$file" 2>/dev/null)"
  if [ "$got" != "$SQL_SID" ]; then
    note "binding recorded '${got}', expected the session that was actually driven '${SQL_SID}'"
  fi

  # And the negative half, which is the half that matters: a FAILED drive must
  # leave no binding, or the next run trusts a pairing that never worked.
  setup_case
  write_rows "$SQL_SID" "started" 1791059999999
  export FAKE_MCODE_FAIL=4
  run_drive "$PANE" "hi"
  assert_rc_nonzero "$RC"
  if [ -f "$CASE_DIR/state/bindings.json" ]; then
    note "a binding was written for a drive that FAILED; it will be trusted next time"
    sed 's/^/          /' "$CASE_DIR/state/bindings.json"
  fi
}

# 9. jq is a hard dependency and its absence must say so by name. Silently
#    producing an empty field would turn a missing parser into a confusing
#    "could not resolve the pane", which is a different bug with the same symptom.
case_missing_jq_dies_naming_it() {
  setup_case
  write_binding_file "$PANE" "$BOUND_SID"

  if ! command -v jq >/dev/null 2>&1; then
    note "jq is not installed on this machine, so 'jq absent' cannot be simulated;"
    note "any result here would be a false pass. Install jq to run this case."
    return
  fi

  PATH="$(path_without jq):$CASE_DIR/bin"
  export PATH
  # Assert the precondition rather than assuming it. If jq survived the mirror,
  # the case would pass for the wrong reason and report coverage it never had.
  if command -v jq >/dev/null 2>&1; then
    note "failed to remove jq from PATH; refusing to run a case that cannot fail"
    return
  fi

  run_drive "$PANE" "hi"

  assert_rc_nonzero "$RC"
  assert_stderr_mentions "jq"
  # A missing parser must not become a turn. This is the preflight, so nothing
  # downstream ran — not the binding read, not the exec.
  assert_mcode_never_called
}

# 10. A name that does not resolve must fail loudly. mcode-1 measured that
#     `agent get <label>` exits 1 with agent_not_found for an agent that is
#     plainly in `agent list`, because merely registering panes under a shared
#     label does not make the label addressable — only `agent rename` does. So
#     this is a real, common operator error and the message has to explain it
#     rather than passing an empty pane through to the next step.
case_unresolvable_name_fails_before_any_drive() {
  setup_case
  write_binding_file "$PANE" "$BOUND_SID"
  export FAKE_HERDR_FAIL="agent get:1"

  run_drive "$AGENT_NAME" "hi"

  assert_rc_nonzero "$RC"
  assert_mcode_never_called
  # It must not then go on to use the pane from a later call, so nothing
  # downstream may have run.
  assert_herdr_log_lacks "pane	get"
}

# 11. The escape hatch, and the only supported way to drive an ambiguous pane.
#     MCODE_DRIVE_SESSION skips every resolution step and is trusted as given —
#     so the property worth testing is that it genuinely SHORT-CIRCUITS, not that
#     it checks the id. Checking is impossible: the id is opaque, and which pane
#     owns it is exactly what is unknown. The case is deliberately seeded with an
#     ambiguous workspace, so an implementation that consulted the database at all
#     would die here instead of driving.
case_session_override_skips_resolution() {
  setup_case
  write_rows "$STARTED_SID" "started" 1791059999999
  write_rows "$OTHER_SID"   "started" 1791059999998
  export MCODE_DRIVE_SESSION="$BOUND_SID"

  run_drive "$PANE" "hi"

  assert_rc_zero "$RC"
  # The whole point: an ambiguous pane the operator resolved BY HAND is drivable.
  assert_exec_argv "$BOUND_SID" "$(cd -- "$CASE_DIR/project" && pwd -P)" "hi"
  # And resolution really was skipped, not merely overridden in its result.
  assert_sqlite_not_queried
  # The override is used as given, so the user is told it was not verified.
  assert_stderr_mentions "MCODE_DRIVE_SESSION"
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
  name-arg-resolves-and-bound-session-is-driven:case_name_arg_resolves_and_bound_session_is_driven
  pane-id-arg-skips-name-resolution:case_pane_id_arg_skips_name_resolution
  no-binding-falls-back-to-sqlite-single-candidate:case_no_binding_falls_back_to_sqlite_single_candidate
  multiple-candidates-narrow-to-the-started-one:case_multiple_candidates_narrow_to_the_started_one
  ambiguous-pane-dies-and-sends-nothing:case_ambiguous_pane_dies_and_sends_nothing
  symlinked-cwd-is-realpathed-before-exec:case_symlinked_cwd_is_realpathed_before_exec
  exec-failure-passes-exit-through-with-attribution:case_exec_failure_passes_exit_through_with_attribution
  binding-is-written-only-after-a-successful-drive:case_binding_is_written_only_after_a_successful_drive
  missing-jq-dies-naming-it:case_missing_jq_dies_naming_it
  unresolvable-name-fails-before-any-drive:case_unresolvable_name_fails_before_any_drive
  session-override-skips-resolution:case_session_override_skips_resolution
)

if [ ! -x "$FAKE_HERDR" ]; then
  printf 'tests/drive-run.sh: %s is missing or not executable\n' "$FAKE_HERDR" >&2
  exit 2
fi
if [ ! -x "$FAKE_MCODE" ]; then
  printf 'tests/drive-run.sh: %s is missing or not executable\n' "$FAKE_MCODE" >&2
  exit 2
fi
if [ ! -x "$FAKE_SQLITE3" ]; then
  printf 'tests/drive-run.sh: %s is missing or not executable\n' "$FAKE_SQLITE3" >&2
  exit 2
fi
if [ ! -f "$DRIVE_BIN" ]; then
  printf 'tests/drive-run.sh: script under test not found: %s\n' "$DRIVE_BIN" >&2
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
