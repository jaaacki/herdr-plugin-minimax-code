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

# --- the task-list footer: the Ctrl+T defect (issue #83) ---------------------
#
# `Ctrl+T expand` is part of mcode's task-list footer, and the footer is a
# RESTING shape: it stays on screen after a turn ends. Both idle fixtures are
# real captures (a live `Message · Enter send` prompt with a task list above it),
# both carry `Ctrl+T expand` inside the 8-line tail classify() reads, and both
# were classified `working` because the working rules are tested before the idle
# ones. A live watcher therefore reported busy on a finished turn.
#
# These fixtures come from panes this plugin does not own, so they are banked
# tail-only: the last 10 non-blank lines, with third-party task titles withheld
# as `[redacted]`. That is why each is exactly 10 lines and carries no scrollback
# - see the rule in tests/fixtures/detection/README.md. The footer and the live
# status line both sit inside the retained window, which is what makes these
# cases falsifiable.
#
# The two idle cases are the fix's falsification surface: put the rule back and
# both go red.

case_idle_task_list_footer_is_idle() {
  setup
  WATCH_SNAPSHOTS="$FIX/idle-with-task-list-footer.txt"; export WATCH_SNAPSHOTS
  run_watch wT:p7Y --once
  if [ "$(reported_states)" = "idle" ]; then ok
  else bad "an idle screen whose tail carries the task-list footer must classify 'idle', got '$(reported_states)'"; fi
}

case_idle_task_list_footer_2_is_idle() {
  setup
  WATCH_SNAPSHOTS="$FIX/idle-with-task-list-footer-2.txt"; export WATCH_SNAPSHOTS
  run_watch wT:p81 --once
  if [ "$(reported_states)" = "idle" ]; then ok
  else bad "second idle task-list-footer capture must classify 'idle', got '$(reported_states)'"; fi
}

# The other half, and the one that stops the fix from being a regression: the
# footer must not be the thing that DETECTS working either. These two captures
# carry the same footer AND a live `Esc stop` status line, and they must stay
# `working` on the strength of that status line alone.
case_working_task_list_footer_is_working() {
  setup
  WATCH_SNAPSHOTS="$FIX/working-with-task-list-footer.txt"; export WATCH_SNAPSHOTS
  run_watch wT:p7Z --once
  if [ "$(reported_states)" = "working" ]; then ok
  else bad "a working screen carrying the task-list footer must still classify 'working', got '$(reported_states)'"; fi
}

case_working_task_list_footer_2_is_working() {
  setup
  WATCH_SNAPSHOTS="$FIX/working-with-task-list-footer-2.txt"; export WATCH_SNAPSHOTS
  run_watch wT:p82 --once
  if [ "$(reported_states)" = "working" ]; then ok
  else bad "second working task-list-footer capture must classify 'working', got '$(reported_states)'"; fi
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
# The watcher must NEVER call release-agent.
#
# It used to, on every exit path, on the theory that it hands lifecycle authority
# back so herdr's screen detection can resume. release-agent actually DELETES the
# entry, so a single --once poll made the pane vanish from `herdr agent list`,
# destroying the registration cmd_start had just made. There is no screen
# manifest to fall back to, so nothing is "resumed".
case_never_releases() {
  setup
  WATCH_SNAPSHOTS="$FIX/idle.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p1 --once
  if grep -qF 'release-agent' "$WATCH_LOG"; then
    bad "watcher called release-agent; that deletes the agent entry cmd_start made"
  else ok; fi
}

# The pane-died path must not release either.
case_pane_gone_does_not_release() {
  setup
  WATCH_PANE_GONE=1; export WATCH_PANE_GONE
  run_watch wZ:p1 --once
  if grep -qF 'release-agent' "$WATCH_LOG"; then
    bad "watcher called release-agent on the pane-gone path"
  else ok; fi
}

# The --source namespace is enforced: a reporter that drifts off
# `herdr:minimax-code` would be silently unmatchable by herdr, so the stub
# rejects it and the case must go red.
# A screen carrying the `◐ Tasks · N background active · N result ready` chip.
#
# WHAT THIS DOES AND DOES NOT PROVE, because getting that backwards is how a
# fixture that cannot fail gets written. It classifies `working`, and it
# classifies working because of `Esc stop` and `Ctrl+O details`, which are in
# RULES. The chip is in no rule. So adding the chip to the working table would
# NOT change this capture's result — this case pins the real captured shape and
# would catch a narrowing of the working table, and it is not evidence that the
# chip is inert. `chip-is-not-a-working-marker` is the case that carries that.
case_chip_bearing_screen_classifies_working() {
  setup
  WATCH_SNAPSHOTS="$FIX/working-with-tasks-chip.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p2W --once
  if [ "$(reported_states)" = "working" ]; then ok
  else bad "expected state 'working' from working-with-tasks-chip.txt, got '$(reported_states)'"; fi
}

# THE CHIP MUST NOT BE A WORKING MARKER — the negative assertion, and the only
# falsifiable form of this ruling available from real captures.
#
# The brief asked for a chip-alone screen that does not classify working. That
# cannot be written: the chip is in no rule, so a chip-alone screen has nothing
# to match and would classify `unknown` whatever the table says, and the one real
# capture carrying the chip also carries `Esc stop`. What CAN be pinned, and is
# the decision that actually matters, is the absence of the rule itself.
#
# WHY AN ABSENCE IS WORTH A TEST HERE. The chip is a *resting* shape — a pane with
# a background task in flight is not working on the foreground turn. If `◐ Tasks`
# were ever added to the working table it would report `working` for any pane
# that simply has something queued, and it would report it SILENTLY and
# permanently, because the chip does not disappear when the turn it misreports
# ends. The table is evidence-led: bare `Esc` and `tok/s` were both measured,
# found to match screens they should not, and dropped. This case is the same
# discipline pointed at the next candidate, before someone adds it.
#
# It reads the table rather than a classification because there is no screen that
# distinguishes the two, which is stated above rather than papered over. A change
# here is a change to a decision, and it should be a deliberate one.
case_chip_is_not_a_working_marker() {
  setup
  # Scoped to the RULES assignment only. A bare grep for `Tasks` over the whole
  # script would match this very comment block, and a test that fails on its own
  # documentation is a test nobody keeps.
  local rules
  rules="$(sed -n "/^RULES='/,/'$/p" "$WATCH" 2>/dev/null || true)"
  if [ -z "$rules" ]; then
    bad "could not read the RULES table from $WATCH; this case cannot assert anything"
    return
  fi
  if printf '%s\n' "$rules" | grep -qF 'Tasks'; then
    bad "the Tasks chip is in the RULES table. It is a RESTING shape - a pane with a" \
        "background task in flight is not working - so this reports working for any" \
        "queued pane, and never clears. Measured evidence first, as bare Esc and tok/s" \
        "were both given and then dropped:"
    printf '%s\n' "$rules" | sed 's/^/          /'
  else
    ok
  fi
}

# CTRL+T EXPAND MUST NOT BE A WORKING MARKER - the same discipline as the chip
# case above, pointed at a marker that actually WAS in the table and shipped.
#
# Unlike the chip, this one is pinned twice: the four classification cases prove
# the behaviour, and this case pins the decision. Both fail if the rule returns,
# so this is not a test that passes against a fiction.
case_ctrl_t_expand_is_not_a_working_marker() {
  setup
  # Scoped to the RULES assignment only, for the same reason as the chip case: a
  # bare grep over the whole script would match the comment block above that
  # explains why the marker was removed.
  local rules
  rules="$(sed -n "/^RULES='/,/'$/p" "$WATCH" 2>/dev/null || true)"
  if [ -z "$rules" ]; then
    bad "could not read the RULES table from $WATCH; this case cannot assert anything"
    return
  fi
  if printf '%s\n' "$rules" | grep -qF 'Ctrl+T expand'; then
    bad "Ctrl+T expand is back in the RULES table. It is part of the task-list" \
        "footer, which is a RESTING shape that survives the end of a turn, so it" \
        "reads as working on an idle prompt with a task list. Working rules are" \
        "tested first, so the footer wins. Every captured working screen also" \
        "carries 'Esc stop', which is what should be doing this work:"
    printf '%s\n' "$rules" | sed 's/^/          /'
  else
    ok
  fi
}

# THE HEADER MUST NOT CLAIM A LIFECYCLE THE LAUNCHER NO LONGER HAS.
#
# bin/mcode-watch.sh used to document itself as a FOREGROUND process: "the
# foreground job of whichever pane ran it, so closing that pane or pressing
# Ctrl-C ends it", "nothing is detached", "nothing is spawned per mcode pane".
# All of that stopped being true in 0.4.1, when the launcher started one watcher
# per mcode pane with `nohup ... &` + `disown` (issue #75), and the header was
# left behind as a lie. A comment that misstates how a long-lived background
# process is stopped is not cosmetic: it is the first thing a reader debugging a
# watcher that outlived its pane would rely on.
#
# Both halves are falsifiable, which is the point: the first fails if the stale
# wording comes back, the second fails if the launcher ever stops detaching.
# Reading bin/mcode-plugin.sh from here is not an ownership claim on it - the
# same cross-file read tests/source-run.sh already does across all three
# reporters.
case_detached_doc_matches_launcher() {
  setup
  local plugin="$root/bin/mcode-plugin.sh"
  local header
  # The header only: the word "detached" is legitimately used later in the file
  # when explaining why detaching needed no supervisor, so a bare grep over the
  # whole script would match the corrected text and pass for the wrong reason.
  header="$(sed -n '2,30p' "$WATCH" 2>/dev/null || true)"
  if [ -z "$header" ]; then
    bad "could not read the header of $WATCH; this case cannot assert anything"
    return
  fi
  local stale=""
  case "$header" in *"FOREGROUND process"*) stale="FOREGROUND process" ;; esac
  case "$header" in *"Nothing is detached"*) stale="${stale:+$stale, }Nothing is detached" ;; esac
  case "$header" in *"nothing is spawned per mcode pane"*) stale="${stale:+$stale, }nothing is spawned per mcode pane" ;; esac
  if [ -n "$stale" ]; then
    bad "the header still claims: $stale. The launcher nohup-disowns one watcher" \
        "per mcode pane since 0.4.1, so the watcher outlives the shell that started" \
        "it. Lifetime is tied to the WATCHED PANE via the pane-gone path, not to the" \
        "pane you launched from:"
    printf '%s\n' "$header" | sed 's/^/          /'
    return
  fi
  # The positive half. The banned strings above only catch a verbatim revert, so
  # the header must also positively name how it is ACTUALLY started. A header
  # that describes the lifecycle without naming `nohup` is describing something
  # else, and that is the paraphrase this check exists to catch. This is why the
  # corrected header explains itself in its own words rather than quoting the
  # wording it replaced: a literal ban is only meaningful if the surrounding
  # prose avoids those literals too.
  case "$header" in
    *nohup*) ;;
    *)
      bad "the header describes how this process is started and stopped but never" \
          "names nohup, so it is describing a lifecycle this file no longer has. If" \
          "the launcher genuinely stopped detaching, fix the header and this case" \
          "together, deliberately:"
      printf '%s\n' "$header" | sed 's/^/          /'
      return
      ;;
  esac
  if [ ! -f "$plugin" ]; then
    bad "$plugin is missing, so the launcher half of this case cannot be checked"
    return
  fi
  # The launcher's own spawn: nohup, the watcher path, backgrounded, then disown.
  #
  # ANCHORED TO THE START OF THE LINE, AND THAT IS THE WHOLE POINT. An earlier
  # revision of this case used `grep -qF 'disown'`, which matched the COMMENT at
  # mcode-plugin.sh:251-254 explaining what disown does - so deleting the real
  # `disown` call at :272 left this case green. A guard that a comment can satisfy
  # is not a guard, and it is worse than no guard: it reads like the lifecycle is
  # pinned when nothing is. Every comment in that file starts with `#`, so
  # requiring the token to open a line (after optional indent) matches the
  # statement and cannot match the prose about it. The `&` is required for the
  # same reason: `nohup` without `&` would still run in the foreground.
  if ! grep -qE '^[[:space:]]*nohup[[:space:]]+"?\$watcher"?.*&[[:space:]]*$' "$plugin"; then
    bad "the launcher no longer starts the watcher as a detached nohup background" \
        "job. If the watcher is no longer detached, the header must say so, and this" \
        "case wants a human decision about which way it moved."
    return
  fi
  if ! grep -qE '^[[:space:]]*disown([[:space:]]|$)' "$plugin"; then
    bad "the launcher no longer disowns the watcher. Watched on: a matching comment" \
        "is not a call, and this case is anchored to the start of the line so it can" \
        "only be satisfied by the statement itself."
    return
  fi
  ok
}

case_source_namespace_is_herdr_minimax_code() {
  setup
  WATCH_SNAPSHOTS="$FIX/idle.txt"; export WATCH_SNAPSHOTS
  run_watch wZ:p1 --once
  if grep -F 'report-agent' "$WATCH_LOG" | grep -qF -- '--source herdr:minimax-code'; then ok
  else bad "report-agent did not use --source herdr:minimax-code: $(grep -F 'report-agent' "$WATCH_LOG" | tr '\n' ' ')"; fi
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
   [ ! -f "$FIX/stale-scrollback.txt" ] ||
   [ ! -f "$FIX/idle-with-task-list-footer.txt" ] ||
   [ ! -f "$FIX/idle-with-task-list-footer-2.txt" ] ||
   [ ! -f "$FIX/working-with-task-list-footer.txt" ] ||
   [ ! -f "$FIX/working-with-task-list-footer-2.txt" ]; then
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
  idle-task-list-footer-is-idle:case_idle_task_list_footer_is_idle
  idle-task-list-footer-2-is-idle:case_idle_task_list_footer_2_is_idle
  working-task-list-footer-is-working:case_working_task_list_footer_is_working
  working-task-list-footer-2-is-working:case_working_task_list_footer_2_is_working
  ctrl-t-expand-is-not-a-working-marker:case_ctrl_t_expand_is_not_a_working_marker
  detached-doc-matches-launcher:case_detached_doc_matches_launcher
  unmatched-is-unknown-not-blocked:case_unmatched_is_unknown_not_blocked
  no-traffic-no-report:case_no_traffic_no_report
  transition-reported:case_transition_reported
  never-releases:case_never_releases
  pane-gone-does-not-release:case_pane_gone_does_not_release
  source-namespace-is-herdr-minimax-code:case_source_namespace_is_herdr_minimax_code
  chip-bearing-screen-classifies-working:case_chip_bearing_screen_classifies_working
  chip-is-not-a-working-marker:case_chip_is_not_a_working_marker
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
