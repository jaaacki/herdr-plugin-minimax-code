#!/usr/bin/env bash
# Tests for bin/mcode-watch.sh.
#
# Every classification rule is checked against a REAL captured snapshot in
# tests/fixtures/detection/, never a hand-written sample. A rule that only passes
# against a synthetic string is not a rule the watcher can actually run on.
#
# Plain bash, no framework, matching the existing tests/run.sh style.

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$here/.." && pwd)"
WATCH="$root/bin/mcode-watch.sh"
STUB="$here/fake-herdr-watch"
FIX="$here/fixtures/detection"

CASES_RUN=0
CASES_FAILED=0
CURRENT_CASE=""
broke=0

note() { broke=1; printf '        %s\n' "$*"; }
ok() { printf 'ok    %s\n' "$CURRENT_CASE"; CASES_RUN=$((CASES_RUN+1)); }
bad() { printf 'FAIL  %s\n' "$CURRENT_CASE"; printf '        %s\n' "$*"; CASES_RUN=$((CASES_RUN+1)); CASES_FAILED=$((CASES_FAILED+1)); }

BASE_PATH="$PATH"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcode-watch-tests.XXXXXX")"
cleanup() { PATH="$BASE_PATH"; rm -rf "$WORK"; }
trap cleanup EXIT

setup() {
  CASE_DIR="$WORK/$CURRENT_CASE"
  mkdir -p "$CASE_DIR"
  WATCH_LOG="$CASE_DIR/invocations.log"
  : >"$WATCH_LOG"
  export WATCH_LOG
  unset WATCH_SNAPSHOTS WATCH_PANE_GONE
  READ_N=0
}

# run_watch <args...> -> sets RC; stdout/stderr to files
run_watch() {
  PATH="$CASE_DIR/bin:$BASE_PATH" \
  HERDR_BIN_PATH="$STUB" \
    "$WATCH" "$@" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
  RC=$?
}

# The states reported, in order, one per line.
reported_states() {
  grep -F 'report-agent' "$WATCH_LOG" 2>/dev/null \
    | sed -n 's/.*--state \([^ ]*\).*/\1/p'
}

report_count() {
  grep -cF 'report-agent' "$WATCH_LOG" 2>/dev/null || true
}

run_case() { CURRENT_CASE="$1"; "$2"; }

# --- cases -------------------------------------------------------------------

# Each real snapshot classifies to the state it was captured in.
case_classify_idle() {
  setup
  WATCH_SNAPSHOTS="$FIX/idle.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p1 --once
  if [ "$(reported_states)" = "idle" ]; then ok
  else bad "expected state 'idle' from idle.txt, got '$(reported_states)'"; fi
}

case_classify_working() {
  setup
  WATCH_SNAPSHOTS="$FIX/working.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p5 --once
  if [ "$(reported_states)" = "working" ]; then ok
  else bad "expected state 'working' from working.txt, got '$(reported_states)'"; fi
}

# A pane that is still starting produces an empty detection snapshot. That is
# NOT idle: reporting idle there is the stale-lie this watcher exists to stop.
case_classify_empty_is_unknown() {
  setup
  unset WATCH_SNAPSHOTS
  run_watch wZ:p1 --once
  if [ "$(reported_states)" = "unknown" ]; then ok
  else bad "empty snapshot must classify 'unknown', got '$(reported_states)'"; fi
}

# A session that has completed a turn and is waiting for a follow-up is IDLE,
# and it looks different from a fresh session. Without a case for this shape, a
# watcher would report `unknown` for every ordinary finished session.
case_classify_post_turn_is_idle() {
  setup
  WATCH_SNAPSHOTS="$FIX/idle-after-working.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p1A --once
  if [ "$(reported_states)" = "idle" ]; then ok
  else bad "a completed turn must classify 'idle', got '$(reported_states)'"; fi
}

# A finished turn leaves its spinner in the scrollback. The live tail says idle;
# the whole snapshot says working forever. This is why classify() reads only the
# tail. Without the case, that restriction is untested and could be deleted.
case_stale_scrollback_is_idle() {
  setup
  WATCH_SNAPSHOTS="$FIX/stale-scrollback.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p5 --once
  if [ "$(reported_states)" = "idle" ]; then ok
  else bad "a stale spinner in scrollback must not read as working, got '$(reported_states)'"; fi
}

# A pane that is not mcode at all matches no marker. The watcher must say
# `unknown` and must NOT invent `blocked`. This case is the one that can actually
# fail: feeding it only idle/working snapshots would pass whether or not the
# fallback guessed blocked, because both match before the fallback is reached.
case_unmatched_is_unknown_not_blocked() {
  setup
  WATCH_SNAPSHOTS="$FIX/not-mcode.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p1 --once
  got="$(reported_states)"
  if [ "$got" = "unknown" ]; then ok
  else bad "an unmatched snapshot must be 'unknown', got '$got'"; fi
}

# The headline property: an unchanged snapshot must produce no further report.
# Five polls of one identical snapshot, exactly one report (the baseline).
case_no_traffic_no_report() {
  setup
  WATCH_SNAPSHOTS="$FIX/working.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p5 --interval 1 --max-polls 5
  n="$(report_count)"
  if [ "$n" -eq 1 ]; then ok
  else bad "5 identical polls must yield exactly 1 report (the baseline), got $n"; fi
}

# A real change must be reported, and reported once.
case_transition_reported() {
  setup
  WATCH_SNAPSHOTS="$FIX/idle.txt,$FIX/working.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p1 --interval 1 --max-polls 4
  got="$(reported_states | tr '\n' ' ')"
  if [ "$got" = "idle working " ]; then ok
  else bad "expected 'idle working', got '$got'"; fi
}

# On exit the watcher must hand lifecycle authority back.
case_releases_on_exit() {
  setup
  WATCH_SNAPSHOTS="$FIX/idle.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p1 --once
  if grep -qF 'release-agent' "$WATCH_LOG"; then ok
  else bad "no release-agent on exit; herdr's own detection cannot resume"; fi
}

# A watched pane that disappears must stop the watcher, not report for a ghost.
case_pane_gone_stops() {
  setup
  WATCH_PANE_GONE=1; export WATCH_PANE_GONE
  run_watch wZ:p1 --once
  local bad_rc=0 bad_report=0
  [ "$RC" -ne 0 ] || { note "expected non-zero exit when the pane does not exist, got 0"; bad_rc=1; }
  if [ -n "$(reported_states)" ]; then
    note "reported a state for a pane that does not exist: '$(reported_states)'"
    bad_report=1
  fi
  if [ "$bad_rc" -eq 0 ] && [ "$bad_report" -eq 0 ]; then ok; else bad "pane-gone handling wrong"; fi
}

# Never types into an unidentified pane: the pane id is passed through verbatim.
case_pane_id_passed_through() {
  setup
  WATCH_SNAPSHOTS="$FIX/idle.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:zz9 --once
  if grep -qF 'pane report-agent wZ:zz9' "$WATCH_LOG"; then ok
  else bad "pane id not passed through to report-agent"; fi
}

# --- main --------------------------------------------------------------------

if [ ! -x "$WATCH" ]; then
  printf 'FAIL  preflight: %s is not executable\n' "$WATCH" >&2
  exit 2
fi
if [ ! -f "$FIX/idle.txt" ] || [ ! -f "$FIX/working.txt" ] ||
   [ ! -f "$FIX/idle-after-working.txt" ] || [ ! -f "$FIX/not-mcode.txt" ] ||
   [ ! -f "$FIX/stale-scrollback.txt" ]; then
  printf 'FAIL  preflight: captured detection fixtures are missing\n' >&2
  exit 2
fi
# Refuse to run a "green" suite that cannot go red.
if ! "$WATCH" --help >/dev/null 2>&1; then
  printf 'FAIL  preflight: %s --help did not exit 0\n' "$WATCH" >&2
  exit 2
fi

CASES=(
  classify-idle:case_classify_idle
  classify-working:case_classify_working
  classify-empty-is-unknown:case_classify_empty_is_unknown
  classify-post-turn-is-idle:case_classify_post_turn_is_idle
  stale-scrollback-is-idle:case_stale_scrollback_is_idle
  unmatched-is-unknown-not-blocked:case_unmatched_is_unknown_not_blocked
  no-traffic-no-report:case_no_traffic_no_report
  transition-reported:case_transition_reported
  releases-on-exit:case_releases_on_exit
  pane-gone-stops:case_pane_gone_stops
  pane-id-passed-through:case_pane_id_passed_through
)

if [ "$#" -gt 0 ]; then
  SELECTED=("$@")
else
  SELECTED=()
  for pair in "${CASES[@]}"; do SELECTED+=("${pair%%:*}"); done
fi

for name in "${SELECTED[@]}"; do
  found=""
  for pair in "${CASES[@]}"; do
    [ "${pair%%:*}" = "$name" ] && found="${pair##*:}"
  done
  [ -n "$found" ] || { printf 'unknown case: %s\n' "$name" >&2; exit 2; }
  run_case "$name" "$found"
done

printf -- '---\n'
if [ "$CASES_FAILED" -eq 0 ]; then
  printf '%d case(s), all passed\n' "$CASES_RUN"
  exit 0
fi
printf '%d case(s), %d failed\n' "$CASES_RUN" "$CASES_FAILED"
exit 1
