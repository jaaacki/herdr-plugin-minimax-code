#!/usr/bin/env bash
# tests/run.sh — the plugin's test suite. Plain bash, no framework.
#
# `bats` is not installed and is not worth adding for a suite this size.
#
# Run every case:            ./tests/run.sh
# Run a subset:              ./tests/run.sh case-1 case-6
# List case names:           ./tests/run.sh --list
#
# Exits 0 only if every case passes.
#
# How it works: the entrypoint resolves herdr through ${HERDR_BIN_PATH:-herdr},
# so every case points that at tests/fake-herdr with FAKE_HERDR_LOG set to a
# per-case file. A case then asserts on the recorded invocation sequence and on
# the entrypoint's exit code and stderr. Nothing touches a real multiplexer.
#
# Scope: all six cases (issues #4 and #5).
#
#   1  happy path, HERDR_PANE_ID set          4  split succeeds, no pane id
#   2  happy path, HERDR_PANE_ID unset       5  pane run fails
#   3  pane split fails                       6  jq absent from PATH
#
# Cases 3, 4 and 5 assert on the recorded invocation sequence, not the exit code.
# That is the point of the suite: a launcher that typed into a pane and *then*
# failed still exits non-zero, so an exit-code-only assertion would call the
# defect a pass. `pane run` must be provably unreachable when the new pane cannot
# be identified.
#
# MCODE_PLUGIN_BIN overrides the entrypoint under test. It exists so the required
# mutation check can run against a deliberately broken *copy*, proving the suite
# goes red when the implementation is wrong, without editing the real
# bin/mcode-plugin.sh (which another member owns).

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"

PLUGIN_BIN="${MCODE_PLUGIN_BIN:-$repo/bin/mcode-plugin.sh}"
FAKE_HERDR="$here/fake-herdr"

# Fixed sentinels. The source pane is the same id in every case, so case 1 proves
# the env var was used by the *absence* of `pane current` in its log, and case 2
# proves the fallback by that call's presence.
SRC_PANE="wZ:p1"
# There is deliberately no NEW_PANE sentinel. The new pane id comes from the
# captured fixture, never from a value the test invents, so no constant here
# could ever drift away from reality without the suite noticing.

BASE_PATH="$PATH"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcode-plugin-tests.XXXXXX")"

# Case 6 deliberately narrows PATH, so the trap restores it before cleaning up.
# KEEP_TMP=1 leaves the sandbox in place for inspection after a failure.
cleanup() {
  PATH="$BASE_PATH"
  # Kill anything still running out of this sandbox BEFORE the directory goes,
  # and wait for the process table to clear. A stub left behind holds a pane id
  # the next run also uses, and #84 decides "already watched" by reading the
  # process table — so a survivor is not litter, it is a false result waiting to
  # happen. Scoped to $WORK's unique name, so it can only ever match this run's
  # own stubs.
  local wb
  wb="$(work_basename 2>/dev/null || true)"
  if [ -n "$wb" ]; then
    kill_watchers_matching "${wb}/.*plugin/bin/mcode-watch\.sh"
  fi
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    printf 'tests/run.sh: KEEP_TMP=1, sandbox left at %s\n' "$WORK" >&2
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

# --- reporting ---------------------------------------------------------------
# A failing assertion records its detail and marks the case failed, but does not
# abort: a case reports every problem it finds, not just the first.
note() { broke=1; printf '        %s\n' "$*"; }

# wait_for_file PATH [max_ms] - bounded poll for a DETACHED process to act.
#
# Added because the obvious probe is a deterministic false negative. cmd_start
# launches the watcher with `nohup ... &` and returns immediately, so a check for
# the marker right after the entrypoint exits runs BEFORE the backgrounded stub
# has written anything. Measured with this suite's own layout, 20 trials:
#
#   marker present immediately      0 / 20
#   marker present within 500ms    20 / 20
#
# It is worse than flaky, because case-22's probe exists to catch a leaked
# detached process: a probe that cannot see the process cannot catch it leaking
# either, so a regression to leaking would stay silent behind a green assertion.
#
# Bounded on purpose. An unbounded wait turns a missing marker into a hang
# instead of a failure, and the bound is short enough to keep the suite quick
# while being long enough for a shell and one file write.
wait_for_file() { # wait_for_file <path> [max-ms]
  local path="$1" max_ms="${2:-1000}" waited=0
  while [ "$waited" -lt "$max_ms" ]; do
    [ -e "$path" ] && return 0
    sleep 0.05
    waited=$((waited + 50))
  done
  [ -e "$path" ]
}

# wait_for_count PATH MIN [max-ms] - bounded poll until PATH holds at least MIN
# non-empty lines.
#
# wait_for_file is not enough for a second launch: the marker already exists from
# the first, so the poll returns instantly and the second launch's line is
# counted as the first's. That is how case-23 reported "two launches started the
# watcher 1 time(s)" - the second watcher had not been scheduled yet.
wait_for_count() { # wait_for_count <path> <min> [max-ms]
  local path="$1" want="$2" max_ms="${3:-1000}" waited=0 got
  while [ "$waited" -lt "$max_ms" ]; do
    got="$(grep -c . "$path" 2>/dev/null || printf 0)"
    [ "${got:-0}" -ge "$want" ] && return 0
    sleep 0.05
    waited=$((waited + 50))
  done
  got="$(grep -c . "$path" 2>/dev/null || printf 0)"
  [ "${got:-0}" -ge "$want" ]
}

# wait_for_file_content PATH NEEDLE [max-ms] - bounded poll until PATH contains
# NEEDLE.
#
# Distinct from wait_for_file on purpose. A redirected handle means the log file
# can EXIST the instant the watcher is forked and still be empty a moment later,
# because the writer had not been scheduled yet. Checking for existence alone
# would pass against an implementation that opened the file and wrote nothing to
# it — which is what the /dev/null defect looked like from the outside: a
# watcher that ran, and no record of what it said.
wait_for_file_content() { # wait_for_file_content <path> <needle> [max-ms]
  local path="$1" needle="$2" max_ms="${3:-1000}" waited=0
  while [ "$waited" -lt "$max_ms" ]; do
    if [ -f "$path" ] && grep -qF -- "$needle" "$path" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    waited=$((waited + 50))
  done
  [ -f "$path" ] && grep -qF -- "$needle" "$path" 2>/dev/null
}

# assert_one_watcher FILE LABEL - FILE records one line per watcher started, and
# this asserts exactly one, AFTER a fair chance for a duplicate to appear.
#
# The poll waits for the FAILURE SIGNAL rather than sleeping a fixed time or
# reading the count straight away, and the direction of the wait is the whole
# point. Every "only one watcher" case in this file has the same shape: trigger
# something once, then assert nothing started a second watcher. A detached stub
# has not necessarily been scheduled when the triggering command returns, so:
#
#   * an immediate read passes against a duplicate that had not written yet —
#     a green that means nothing, and the most likely way this whole file lies;
#   * a fixed sleep is a coin flip on a loaded CI runner.
#
# So: poll for the SECOND line up to the bound, and fail if it ever lands. The
# bound is the same one the rest of the suite uses; the stub writes its line as
# its first act, so a watcher that is going to start at all has started well
# inside it.
assert_one_watcher() { # assert_one_watcher <file> <label>
  local file="$1" label="$2" total
  wait_for_count "$file" 2 1000 || true
  total="$(grep -c . "$file" 2>/dev/null || printf 0)"
  if [ "${total:-0}" -ne 1 ]; then
    note "$label: expected exactly 1 watcher, found ${total:-0}"
    sed 's/^/          /' "$file" 2>/dev/null
    return 1
  fi
  return 0
}

# --- assertions --------------------------------------------------------------
assert_rc_zero() { # assert_rc_zero <rc>
  if [ "$1" -ne 0 ]; then
    note "expected exit 0, got $1"
  fi
}

assert_rc_nonzero() { # assert_rc_nonzero <rc>
  if [ "$1" -eq 0 ]; then
    note "expected a non-zero exit, got 0"
  fi
}

assert_stderr_nonempty() {
  if [ ! -s "$STDERR_FILE" ]; then
    note "stderr was empty; a failure must explain itself"
  fi
}

assert_stderr_mentions() { # assert_stderr_mentions <needle>
  if ! grep -qF -- "$1" "$STDERR_FILE"; then
    note "stderr does not mention '$1'"
  fi
}

# assert_count FILE NEEDLE WANT LABEL - how many lines of FILE contain the
# literal NEEDLE. "Mentions it at least once" is too weak for the state hint:
# the point of printing one line is that it is ONE line, and a second copy is
# noise the user cannot read past. grep -c exits non-zero on no match while
# still printing 0, hence the `|| true`.
assert_count() { # assert_count <file> <needle> <want> <label>
  local file="$1" needle="$2" want="$3" label="$4" got
  got="$(grep -cF -- "$needle" "$file" 2>/dev/null || true)"
  got="${got:-0}"
  if [ "$got" != "$want" ]; then
    note "$label: expected $want line(s) mentioning '$needle', found $got"
  fi
}

assert_log_empty() {
  if [ -s "$FAKE_HERDR_LOG" ]; then
    note "expected no herdr invocations, got:"
    sed 's/^/          /' "$FAKE_HERDR_LOG"
  fi
}

# The core assertion: the recorded invocation sequence must equal $1 exactly,
# line for line, in order. A subset or "contains" match would not catch a stray
# extra call — and a stray `pane run` is precisely the bug this suite must catch.
assert_log_exactly() { # assert_log_exactly <expected-tabbed>
  local expected="$1" actual
  actual="$(cat "$FAKE_HERDR_LOG")"
  if [ "$actual" != "$expected" ]; then
    note "herdr invocation sequence mismatch"
    note "expected:"
    printf '%s\n' "$expected" | sed $'s/\t/ /g; s/^/          /'
    note "actual:"
    printf '%s\n' "$actual" | sed $'s/\t/ /g; s/^/          /'
  fi
}

# The ORDER of two calls in the log, asserted as an ordering fact rather than
# re-derived from a hand-written expected block. The reason this exists rather
# than a comment: herdr's `pane report-agent-session` is REFUSED with
# `resume_not_accepted` unless the reporter already holds the pane via
# `pane report-agent`. A log with the two swapped is a real failure, and
# assert_log_exactly cannot express it on its own because the failing case is
# usually one whose expected block a future edit would also have to change.
#
# FIRST occurrence of each pattern is what is compared, not any pair: `pane
# report-agent` is a PREFIX of `pane report-agent-session` in a naive grep, so
# the needles are matched exactly as the stub writes them and the session needle
# carries its leading command name.
#
# A missing pattern is a failure, never a pass. A grep that finds nothing leaves
# an empty line number, and "empty is not greater than empty" would let the
# assertion succeed against an entrypoint that made neither call.
assert_log_order() { # assert_log_order <first-needle> <second-needle>
  local first="$1" second="$2"
  local first_line second_line
  first_line="$(grep -n -F "$first" "$FAKE_HERDR_LOG" 2>/dev/null | head -1 | cut -d: -f1)"
  second_line="$(grep -n -F "$second" "$FAKE_HERDR_LOG" 2>/dev/null | head -1 | cut -d: -f1)"
  if [ -z "$first_line" ] || [ -z "$second_line" ]; then
    [ -z "$first_line" ] && note "order check skipped: '${first}' never appears in the log"
    [ -z "$second_line" ] && note "order check skipped: '${second}' never appears in the log"
    return
  fi
  if [ "$first_line" -ge "$second_line" ]; then
    note "\`${second}\` (line ${second_line}) must come after \`${first}\` (line ${first_line});" \
         "herdr refuses a session report from a reporter that does not already hold the pane"
  fi
}

# --- per-case sandbox --------------------------------------------------------
# Each case gets its own directory, its own herdr log, and a PATH whose first
# entry is a bin dir holding a fake `mcode`. The entrypoint must resolve mcode
# with `command -v` and hand `pane run` the resulting absolute path, so that
# fake is what the assertions compare against.
setup_case() {
  CASE_DIR="$WORK/$CURRENT_CASE"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/project"
  FAKE_HERDR_LOG="$CASE_DIR/herdr.log"
  STDERR_FILE="$CASE_DIR/stderr"
  STDOUT_FILE="$CASE_DIR/stdout"
  : >"$FAKE_HERDR_LOG"
  : >"$STDERR_FILE"
  : >"$STDOUT_FILE"

  printf '#!/bin/sh\nexit 0\n' >"$CASE_DIR/bin/mcode"
  chmod +x "$CASE_DIR/bin/mcode"

  export FAKE_HERDR_LOG
  export FAKE_HERDR_FIXTURES="$here/fixtures"
  export FAKE_HERDR_SRC_PANE="$SRC_PANE"
  export FAKE_HERDR_CWD="$CASE_DIR/project"
  export HERDR_BIN_PATH="$FAKE_HERDR"
  export PATH="$CASE_DIR/bin:$BASE_PATH"
  # Per-case watcher state dir (issue #84). The entrypoint puts the per-pane
  # watcher log and the per-pane lock under MCODE_WATCH_LOG_DIR, and WITHOUT
  # this both would land in the shared TMPDIR - where the lock for pane wZ:p8
  # survives from one case to the next, and where a case can only pass or fail
  # depending on whether an earlier case's stub watcher has finished dying.
  # That is cross-case coupling through the filesystem, and it is the kind that
  # passes locally and flakes in CI. One case, one state dir.
  export MCODE_WATCH_LOG_DIR="$CASE_DIR/watch-state"
  # Neutralise ambient herdr context so a case only ever sees what it sets.
  unset HERDR_PLUGIN_EVENT_JSON HERDR_PLUGIN_CONTEXT_JSON
  unset HERDR_PLUGIN_STATE_DIR
  unset FAKE_HERDR_FAIL FAKE_HERDR_FAULT
  # OFF by default, and this is not tidiness. Cases 1-20 run the REAL checkout,
  # and once cmd_start auto-starts the watcher they would each spawn a detached
  # process against a real pane. Those processes happened to die on their first
  # poll, because the case's sandbox was removed and the stub's log write failed
  # - accidental, not designed, and the kind of accidental that becomes a real
  # leak the moment the stub tolerates a missing directory. A case that wants the
  # watcher sets this to 1 explicitly.
  export MCODE_WATCH_AUTOSTART=0
}

run_entrypoint() {
  run_entrypoint_at "$PLUGIN_BIN"
}

# run_entrypoint_at PATH runs a DIFFERENT entrypoint. It takes the path as an
# argument rather than reassigning $PLUGIN_BIN, because that variable is global
# and a case that changed it would silently retarget every case after it. Only
# cases 21-23 use this, and only with the copy stage_plugin hands them.
run_entrypoint_at() { # run_entrypoint_at <entrypoint>
  "$1" start >"$STDOUT_FILE" 2>"$STDERR_FILE"
  RC=$?
}

# run_event_handler_at <entrypoint> - invoke the manifest's EVENT subcommand
# rather than the launch one. Separate from run_entrypoint_at on purpose: the
# two entry paths are the thing issue #84 is about, and a helper that let a case
# accidentally drive the launcher instead of the handler would let the whole
# event path go untested while every case stayed green.
#
# The event payload is written to a file and exported, because it has to survive
# being passed through an environment variable intact - including its quotes and
# braces - which is exactly the kind of thing a hand-built string gets wrong.
run_event_handler_at() { # run_event_handler_at <entrypoint> <pane-id> <agent-label>
  local entry="$1" pane="$2" agent="$3"
  FAKE_HERDR_EVENT_JSON="$(jq -cn --arg p "$pane" --arg a "$agent" \
    '{event:"pane_agent_status_changed",
      data:{type:"pane_agent_status_changed",pane_id:$p,workspace_id:"wZ",
            agent_status:"working",agent:$a}}')"
  export HERDR_PLUGIN_EVENT_JSON="$FAKE_HERDR_EVENT_JSON"
  export HERDR_PLUGIN_EVENT="pane.agent_status_changed"
  "$entry" ensure-watcher >"$STDOUT_FILE" 2>"$STDERR_FILE"
  RC=$?
}

# What the stub will report. This mirrors the precedence documented in
# tests/fake-herdr, deliberately and in the same place, so the two cannot drift:
#
#   cwd, source pane   Knob wins. The tests own these dimensions, so the stub
#                      substitutes them into the *captured* response rather than
#                      replacing it, and announces the substitution.
#   new pane id        The captured fixture always wins, knob or not, because
#                      that value must never be faked. It is queried out of the
#                      fixture rather than hard-coded, so a re-capture cannot
#                      silently invalidate the expectation — and pinning it to
#                      `.result.pane.pane_id` asserts the documented extraction
#                      path. An implementation reading `.result.pane_id`, which
#                      resolves to `null` in the real capture, fails here.
expected_cwd() { printf '%s' "$FAKE_HERDR_CWD"; }
expected_current_pane() { printf '%s' "$FAKE_HERDR_SRC_PANE"; }

# No fallback on purpose: tests/fixtures/ is mandatory now that the captures have
# landed, and the stub exits non-zero if a fixture is missing. A quiet fallback
# here would let the suite assert against something the stub never served.
expected_new_pane() { # expected_new_pane
  local file="$FAKE_HERDR_FIXTURES/pane-split.json"
  local value
  if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
    note "cannot read the new pane id from $file (jq present: $(command -v jq >/dev/null 2>&1 && echo yes || echo no))"
    return
  fi
  value="$(jq -r '.result.pane.pane_id // empty' <"$file" 2>/dev/null)" || value=""
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    note "pane-split.json carries no .result.pane.pane_id; the fixture may be stale"
    return
  fi
  printf '%s' "$value"
}

# The `pane split` invocation, exactly as the entrypoint issues it. `--no-focus`
# is part of the sequence, not an optional extra: B's head 368e48e decided it
# deliberately (issue #4's spec predates that decision and is silent on it), so
# the expectation follows the implementation and the spec gap is reported as a
# finding rather than papered over here.
expected_split_line() { # expected_split_line <source-pane> [with-cwd: yes|no]
  local src="$1"
  if [ "${2:-yes}" = "no" ]; then
    printf 'pane\tsplit\t%s\t--direction\tright\t--no-focus' "$src"
  else
    printf 'pane\tsplit\t%s\t--direction\tright\t--no-focus\t--cwd\t%s' "$src" "$(expected_cwd)"
  fi
}

# The full expected invocation log for a launch that reaches `pane split`.
# Passing an empty second argument omits the `pane run` line — that is how cases
# 3 and 4 assert the launcher never typed into a pane, which is the property
# they exist to protect. An exit-code-only assertion would not: a script that
# called `pane run` and failed afterwards would still exit non-zero.
expected_sequence() { # expected_sequence <source-pane> <mcode-abs|""> [with-cwd] [registered]
  local src="$1"
  local mcode="$2"
  local with_cwd="${3:-yes}"
  # registered is a three-state flag, and the middle state exists because it is a
  # real branch, not a theoretical one:
  #   no        `pane run` never happened, or it died — nothing follows
  #   reported  `pane run` succeeded, `report-agent` was called and failed, so
  #             naming is skipped (renaming an unregistered pane cannot work)
  #   full      `pane run` succeeded and the pane was registered *and* named
  # It is separate from a non-empty mcode because case 5 has mcode on the
  # command line and then dies inside `pane run` — there the run line is
  # present and nothing after it is.
  #
  # It also gates the SESSION TAIL, and the honest reason is that `registered !=
  # no` is exactly the condition "the launch got past `pane run`". The tail is
  # not conceptually part of registration — it would still fire if the
  # report-agent step were deleted — but it shares that one precondition, and a
  # fifth parameter distinguishing "reached the tail" from "reached report-agent"
  # would be a distinction no case currently makes. If a future case needs it,
  # split the flag rather than bending this one.
  local registered="${4:-no}"
  local lines newpane
  newpane="$(expected_new_pane)"
  lines="$(printf 'pane\tget\t%s\n%s' "$src" "$(expected_split_line "$src" "$with_cwd")")"
  if [ -n "$mcode" ]; then
    lines="$(printf '%s\npane\trun\t%s\t%s' "$lines" "$newpane" "$mcode")"
  fi
  if [ "$registered" = "reported" ] || [ "$registered" = "full" ]; then
    lines="$(printf '%s\npane\treport-agent\t%s\t--source\therdr:minimax-code\t--agent\tmcode\t--state\tunknown' \
      "$lines" "$newpane")"
  fi
  if [ "$registered" = "full" ]; then
    lines="$(printf '%s\nagent\tlist' "$lines")"
    lines="$(printf '%s\nagent\trename\t%s\t%s' "$lines" "$newpane" "$(expected_agent_name)")"
  fi
  if [ "$registered" = "reported" ] || [ "$registered" = "full" ]; then
    lines="$(printf '%s\n%s' "$lines" "$(expected_session_tail "$newpane" "$registered")")"
  fi
  printf '%s' "$lines"
}

# The two calls that close a successful launch, in the order the sibling
# `mcode-session.sh attach` issues them (issues #75/#79). Both are pinned, and
# the second one is the reason this helper exists at all:
#
#   pane report-agent-session   sends the session identity and the resume argv
#   agent get                   reads back what herdr actually kept
#
# The read-back is a separate assertion from the report, and that is the whole
# point of #71: `pane report-agent-session` exits 0 on herdr 0.9.3 whether or not
# anything was stored, so a sequence pin that stopped at the report would pass
# against an entrypoint that reported and never checked.
#
# ORDER IS ASSERTED, NOT DESCRIBED. `pane report-agent-session` is refused with
# `resume_not_accepted` unless the reporter already holds the pane via
# `pane report-agent`, so the report must follow the launcher's own
# report-agent. A swap of these two lines in the log is a real defect, and
# `assert_log_exactly` compares line order.
#
# THE LABEL IS MEASURED, NOT ASSUMED. In the `full` state it is the name
# `agent rename` just installed, passed down by the launcher. In the `reported`
# state there is no name to pass down, the launcher sends an empty
# MCODE_AGENT_LABEL, and the sibling's `:-` default substitutes the literal
# `mcode`. That fallback is pinned here so a future change to it is a visible
# test diff rather than a silent behaviour change — it is the same
# hardcoded-label shape as the watcher defect mcode-3 raised as P1, one file
# over, and worth re-examining if the launcher's naming ever changes.
expected_session_tail() { # expected_session_tail <new-pane> <registered>
  local newpane="$1"
  local registered="$2"
  local label
  if [ "$registered" = "full" ]; then
    label="$(expected_agent_name)"
  else
    label="mcode"
  fi
  # `mcode --continue` is the sibling's documented MCODE_RESUME_CMD default, a
  # constant rather than anything derived from the resolved launcher path — so
  # it does not follow MCODE_PLUGIN_BIN when a case points the suite at a
  # different entrypoint. Pinned as the literal it is.
  printf 'pane\treport-agent-session\t--source\therdr:minimax-code\t--agent\t%s\t%s\t--\tmcode\t--continue' \
    "$label" "$newpane"
  printf '\nagent\tget\t%s' "$newpane"
}

# The name next_agent_name() should settle on, mirroring the stub's agent list.
expected_agent_name() { # expected_agent_name
  case ",${FAKE_HERDR_FAULT:-}," in
    *,agent-names-taken,*) printf 'mcode-3' ;;
    *)                   printf 'mcode' ;;
  esac
}

# watcher_path_for ENTRYPOINT - the absolute watcher path the entrypoint's hint
# must name for that entrypoint.
#
# Derived the way watcher_hint() derives it: from the entrypoint's own
# directory, one level up, because the entrypoint IS the plugin's
# bin/mcode-plugin.sh. Deriving rather than hard-coding means the expectation
# follows the checkout, and it turns the `bin/bin/` slip - appending
# "/bin/mcode-watch.sh" to a directory that is already `bin/` - into a red test
# rather than a permanently unresolvable path that still reads plausibly.
watcher_path_for() { # watcher_path_for <entrypoint>
  printf '%s/bin/mcode-watch.sh' "$(cd -- "$(dirname -- "$1")/.." && pwd -P)"
}

expected_watcher_path() { watcher_path_for "$PLUGIN_BIN"; }

# stage_plugin [none|fake] - copy the entrypoint into $CASE_DIR/plugin and print
# the copy's path, so a case can vary what sits BESIDE it.
#
# A copy, never the real checkout: bin/mcode-watch.sh belongs to another member
# and a test has no business chmod-ing or removing it there. This is the same
# mechanism MCODE_PLUGIN_BIN already exists for, used per case.
#
#   none  no watcher file at all, so watcher_hint() must take its warning branch
#   fake  a stub that records each invocation in $CASE_DIR/plugin/watcher-ran
#
# The stub sleeps before exiting. Without that, a mutant which runs the watcher
# SYNCHRONOUSLY would return instantly and the "nothing holds the action's own
# pane open" property would never be exercised.
stage_plugin() { # stage_plugin [none|fake|fail|label]
  local root="$CASE_DIR/plugin"
  # The SIBLINGS COME FROM THE SAME DIRECTORY THE ENTRYPOINT CAME FROM, not from
  # $repo. cmd_start resolves its watcher and its session reporter from its own
  # directory (`$(dirname $BASH_SOURCE)/../bin/...`), so a stage that copied the
  # entrypoint from one tree and the siblings from another would assemble a
  # plugin that never exists - and it fails silently: the reporter is missing,
  # the launcher says so and exits 0, and the case passes for a reason that has
  # nothing to do with the contract under test. Deriving the source directory
  # from $PLUGIN_BIN is what makes MCODE_PLUGIN_BIN a complete override rather
  # than a half one.
  local src_bin
  src_bin="$(cd -- "$(dirname -- "$PLUGIN_BIN")" 2>/dev/null && pwd -P || true)"
  mkdir -p "$root/bin"
  cp "$PLUGIN_BIN" "$root/bin/mcode-plugin.sh"
  chmod +x "$root/bin/mcode-plugin.sh"
  # The session sibling travels with it, for the reason the source directory
  # matters: a staged copy without bin/mcode-session.sh beside it reports
  # "reporter missing" and exits 0, which is a correct launch and would have
  # made case-24 green for the wrong reason.
  if [ -n "$src_bin" ] && [ -f "$src_bin/mcode-session.sh" ]; then
    cp "$src_bin/mcode-session.sh" "$root/bin/mcode-session.sh"
    chmod +x "$root/bin/mcode-session.sh"
  fi
  case "${1:-none}" in
    fake)
      cat >"$root/bin/mcode-watch.sh" <<'STUB'
#!/bin/sh
# Test stub. Records that it ran, then blocks. See stage_plugin.
echo ran >>"$(dirname -- "$0")/../watcher-ran"
sleep 5
STUB
      chmod +x "$root/bin/mcode-watch.sh"
      ;;
    fail)
      # Logs AND fails. A stub that only exits non-zero leaves the attempt
      # invisible, and the case would pass against an entrypoint that never
      # starts a watcher at all.
      cat >"$root/bin/mcode-watch.sh" <<'STUB'
#!/bin/sh
echo ran >>"$(dirname -- "$0")/../watcher-ran"
exit 1
STUB
      chmod +x "$root/bin/mcode-watch.sh"
      ;;
    label)
      # Records the label the watcher would report under, so a hardcoded one is
      # visible. MCODE_AGENT_LABEL is the knob the other two reporters already
      # honour; this stub reports what it was actually handed.
      cat >"$root/bin/mcode-watch.sh" <<'STUB'
#!/bin/sh
printf '%s\t%s\n' "$*" "${MCODE_AGENT_LABEL:-}" >>"$(dirname -- "$0")/../watcher-ran"
sleep 5
STUB
      chmod +x "$root/bin/mcode-watch.sh"
      ;;
    brief)
      # Records its start and exits at once. The shape of a watcher that has
      # DIED, which is what a pane looks like when its watcher crashed, when the
      # pane closed mid-poll, or when someone killed it. Used where the question
      # is whether a dead watcher still counts as a watcher.
      cat >"$root/bin/mcode-watch.sh" <<'STUB'
#!/bin/sh
echo "ran $1" >>"$(dirname -- "$0")/../watcher-ran"
exit 0
STUB
      chmod +x "$root/bin/mcode-watch.sh"
      ;;
    hook)
      # The event path's stub. Writes BOTH a marker line and a line on stdout:
      # the marker proves the watcher ran, and the stdout line is what the
      # per-pane LOG is asserted on, so "output went to a file" is checked by
      # looking at the file rather than by inferring it from the absence of
      # output somewhere else.
      #
      # It stays alive. The idempotency assertion depends on the first watcher
      # still running when the second event arrives - a stub that exited
      # immediately would make every "a second trigger starts nothing" test pass
      # for the wrong reason, because the first lock would already look dead.
      cat >"$root/bin/mcode-watch.sh" <<'STUB'
#!/bin/sh
echo "ran $1" >>"$(dirname -- "$0")/../watcher-ran"
echo "mcode-watch: watching $1"
sleep 30
STUB
      chmod +x "$root/bin/mcode-watch.sh"
      ;;
  esac
  printf '%s' "$root/bin/mcode-plugin.sh"
}

# Case 2's sequence: `pane current` first, to resolve the source pane.
expected_sequence_via_current() { # expected_sequence_via_current <mcode-abs|""> [registered]
  local mcode="$1"
  local registered="${2:-no}"
  local src rest
  src="$(expected_current_pane)"
  rest="$(expected_sequence "$src" "$mcode" yes "$registered")"
  printf 'pane\tcurrent\n%s' "$rest"
}

# Mirrors every executable on PATH into a fresh directory, skipping $1. Case 6
# uses it to make `jq` genuinely absent rather than shadowed: a shim earlier on
# PATH would still satisfy `command -v jq`, so the case would pass vacuously.
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
      [ -e "$mirror/$base" ] && continue
      ln -s "$f" "$mirror/$base" 2>/dev/null || true
    done
  done
  printf '%s' "$mirror"
}

# --- precondition: the stub's canned responses must be usable ----------------
# A stub emitting malformed JSON, or an envelope missing `.result.pane`, makes
# every case pass or fail for the wrong reason. Caught once here, up front, by
# asking the stub what it would serve rather than trusting it.
check_stub_responses() {
  local out name json fail_log

  if ! command -v jq >/dev/null 2>&1; then
    printf 'warn  jq not found; skipping the fake-herdr response self-check\n'
    return 0
  fi

  # Capture first, then validate. Piping --self-check straight into the loop
  # would make an empty or failed run vacuously pass, which is the opposite of
  # what a guard is for.
  if ! out="$("$FAKE_HERDR" --self-check 2>/dev/null)"; then
    printf 'FAIL  stub: %s --self-check exited non-zero\n' "$FAKE_HERDR"
    return 1
  fi
  if [ -z "$out" ]; then
    printf 'FAIL  stub: %s --self-check produced no output\n' "$FAKE_HERDR"
    return 1
  fi

  for name in pane-get pane-current pane-split pane-run; do
    json="$(printf '%s\n' "$out" | grep "^$name" | head -1 | cut -f2-)"
    if [ -z "$json" ]; then
      printf 'FAIL  stub: --self-check is missing the %s response\n' "$name"
      return 1
    fi
    if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
      printf 'FAIL  stub-response %s: not valid JSON\n' "$name"
      return 1
    fi
    if [ "$name" != "pane-run" ]; then
      if ! printf '%s' "$json" | jq -e '.result.pane.pane_id' >/dev/null 2>&1; then
        printf 'FAIL  stub-response %s: no .result.pane.pane_id\n' "$name"
        return 1
      fi
    fi
  done

  # Exercise the failure-injection path here so it is covered on every run
  # rather than first being trusted in C2, where cases 3 and 5 depend on it.
  fail_log="$WORK/selfcheck-fail.log"
  : >"$fail_log"
  if FAKE_HERDR_LOG="$fail_log" FAKE_HERDR_FAIL="pane split:7" \
      "$FAKE_HERDR" pane split wZ:p1 >/dev/null 2>&1; then
    printf 'FAIL  stub: FAKE_HERDR_FAIL did not make the call fail\n'
    return 1
  fi
  if ! grep -q 'pane' "$fail_log"; then
    printf 'FAIL  stub: a failing call was not recorded in the log\n'
    return 1
  fi
  return 0
}

# --- case 1 ------------------------------------------------------------------
# Happy path with HERDR_PANE_ID set. Asserts the exact ordered invocations, and
# that the absolute path of the resolved mcode — not the bare name — reaches
# `pane run`.
case_1() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"

  run_entrypoint
  assert_rc_zero "$RC"

  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode" yes full)"
}

# --- case 2 ------------------------------------------------------------------
# HERDR_PANE_ID unset: the entrypoint must fall back to `pane current` to resolve
# the source pane, then continue exactly as in case 1.
case_2() {
  setup_case
  unset HERDR_PANE_ID

  run_entrypoint
  assert_rc_zero "$RC"

  assert_log_exactly "$(expected_sequence_via_current "$CASE_DIR/bin/mcode" full)"
}

# --- case 3 ------------------------------------------------------------------
# `pane split` fails. The launcher must fail loudly and must NOT go on to type
# into a pane — so the assertion is on the invocation log, never the exit code.
# A script that called `pane run` and then failed would also exit non-zero.
case_3() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAIL="pane split:1"

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "")"
}

# --- case 4 ------------------------------------------------------------------
# The safety-critical branch: `pane split` SUCCEEDS but the response carries no
# pane id, so the new pane cannot be identified. `pane run` must never be
# invoked. Asserted on the invocation log, per the same reasoning as case 3.
case_4() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAULT="split-no-pane-id"

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "")"
}

# --- case 5 ------------------------------------------------------------------
# `pane run` fails. The launcher must exit non-zero and stderr must name the new
# pane id, so the user can find and close the orphaned pane by hand.
case_5() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAIL="pane run:1"

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_stderr_mentions "$(expected_new_pane)"
  # No state hint on a failed launch. Every failure path returns before
  # watcher_hint() is reached, and that is the property worth pinning: a hint
  # printed for a pane that never got mcode sends the operator off to watch an
  # empty window - and it would appear only in the one situation where the user
  # is already unhappy.
  if grep -qF -- "mcode-watch.sh" "$STDERR_FILE"; then
    note "stderr printed a state hint for a launch that failed; there is no pane to watch"
  fi
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode")"
}

# --- case 6 ------------------------------------------------------------------
# jq absent from PATH. Must fail loudly, naming jq, and must not reach the
# multiplexer at all: the preflight is the first step, so the log stays empty.
case_6() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"

  if ! command -v jq >/dev/null 2>&1; then
    note "jq is not installed on this machine, so 'jq absent' cannot be simulated;"
    note "any result here would be a false pass. Install jq to run this case."
    return
  fi

  PATH="$(path_without jq):$CASE_DIR/bin"
  export PATH
  if command -v jq >/dev/null 2>&1; then
    note "failed to remove jq from PATH; refusing to run a case that cannot fail"
    return
  fi

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_stderr_mentions "jq"
  assert_log_empty
}

# --- case 7 ------------------------------------------------------------------
# The source-pane guard, which had no coverage at all: `pane split` succeeds but
# its response names the *source* pane as the new one. Refusing here is what
# stops `pane run` typing into the window the user is working in — strictly more
# dangerous to lose than the unidentified-pane guard, and just as invisible to
# the suite without this case.
case_7() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAULT="split-echoes-source"

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_stderr_mentions "$SRC_PANE"
  # The whole point: the source pane must never be typed into.
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "")"
}

# --- case 8 ------------------------------------------------------------------
# `mcode` absent. The entrypoint resolves the launcher *before* splitting, so
# this must fail without ever reaching the multiplexer. If the preflight were
# removed the launcher would split, `pane run` an empty command, report success
# and leave an orphaned pane behind — so the assertion is an empty log, not just
# a non-zero exit.
case_8() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"

  PATH="$(path_without mcode)"
  export PATH
  if command -v mcode >/dev/null 2>&1; then
    note "failed to remove mcode from PATH; refusing to run a case that cannot fail"
    return
  fi

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_stderr_mentions "mcode"
  assert_log_empty
}

# --- case 9 ------------------------------------------------------------------
# `pane get` fails. The documented behaviour is a graceful degradation: warn,
# split without --cwd and let the CLI place the pane, still exiting 0. The
# stderr must name the failed read, because "the read failed" and "the pane
# reported no cwd" are different problems and collapsing them hides the cause.
case_9() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAIL="pane get:1"
  export FAKE_HERDR_STUB_MARKER="herdr-stub-failure-marker-xyz"

  run_entrypoint
  assert_rc_zero "$RC"
  assert_stderr_mentions "pane get"
  assert_stderr_mentions "$SRC_PANE"
  # The point of the pane-get-stderr fix: herdr's OWN stderr reaches the user, not
  # just the entrypoint's paraphrase of it. This marker exists only in the stub's
  # output, so finding it here proves the relay. Re-suppressing the child's stderr
  # makes the token vanish and this assertion fail - which is the point: without
  # it, reverting that fix would leave the suite green.
  assert_stderr_mentions "herdr-stub-failure-marker-xyz"
  # The entrypoint reports a *failed read* and a *pane that reported no cwd* with
  # different wording, because they are different problems. Collapsing them hides
  # the cause, so assert the failed-read branch and refuse the other one.
  assert_stderr_mentions "failed"
  if grep -qF 'reported no cwd' "$STDERR_FILE"; then
    note "stderr blames an empty cwd, but the pane get call actually failed"
  fi
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode" no full)"
}

# --- case 10 -----------------------------------------------------------------
# `pane current` succeeds but carries no pane id, and HERDR_PANE_ID is unset, so
# no source pane can be determined. Nothing may be split, and the message must
# not claim the *call* failed — it succeeded; it returned nothing usable.
case_10() {
  setup_case
  unset HERDR_PANE_ID
  export FAKE_HERDR_FAULT="current-no-pane-id"

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  # The failed-call branch says "exited non-zero"; this is the other branch.
  if grep -qF 'exited non-zero' "$STDERR_FILE"; then
    note "stderr blames a non-zero exit, but the call succeeded and returned no id"
  fi
  assert_log_exactly "$(printf 'pane\tcurrent')"
}

# --- case 11 -----------------------------------------------------------------
# The split response carries JSON `null` rather than an empty string for the pane
# id — the other shape the guard exists to catch, and one no case built before.
# Also asserts the guard's *diagnostic content*, not merely that stderr is
# non-empty: the message is the only thing telling the user a pane may exist and
# can be closed by hand. Matching prose is deliberately brittle here, because that
# diagnostic is user-facing behaviour — replacing it with a bare `die "error"`
# is a real regression, and this case is what makes it one.
case_11() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAULT="split-null-pane-id"

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_stderr_mentions "$SRC_PANE"
  # The user needs to know a pane may be orphaned, and how to clear it.
  assert_stderr_mentions "close"
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "")"
}

# --- cases 12-14 -------------------------------------------------------------
# Pane-id *shape* validation. m2 settled the guard as: jq `type == "string"`,
# then characters from [A-Za-z0-9_.:-] only, and it must contain a colon. These
# three cases pin each clause to a response shape that must be refused.
#
# They are written against m2's described guard and are therefore RED against a
# build that lacks it — which is the point: a suite that cannot fail here is not
# evidence. See the note in the PR body about the landing order.
case_12() { # pane id is a JSON number, not a string
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAULT="split-id-not-string"

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_stderr_mentions "$SRC_PANE"
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "")"
}

case_13() { # pane id contains characters outside [A-Za-z0-9_.:-]
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAULT="split-id-unsafe-chars"

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_stderr_mentions "$SRC_PANE"
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "")"
}

case_14() { # pane id is well-formed but has no colon, so it is not a pane id
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAULT="split-id-no-colon"

  run_entrypoint
  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_stderr_mentions "$SRC_PANE"
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "")"
}

# --- case 15 -----------------------------------------------------------------
# A relative PATH entry makes `command -v mcode` return a *relative* path.
# `pane run` would then resolve it against the new pane's own directory, where it
# does not exist, so the launcher must refuse before splitting rather than
# reporting a launch that cannot happen. No stub fault needed: this is PATH and
# cwd, both of which run.sh already controls.
case_15() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"

  local rc
  if ( cd "$CASE_DIR" && PATH="bin:$BASE_PATH" "$PLUGIN_BIN" start ) \
       >"$STDOUT_FILE" 2>"$STDERR_FILE"; then
    rc=0
  else
    rc=$?
  fi
  RC=$rc

  assert_rc_nonzero "$RC"
  assert_stderr_nonempty
  assert_stderr_mentions "relative"
  # The diagnostic must NAME the offending value, not merely mention the word
  # "relative": a user cannot act on "your path was relative" but they can act on
  # the exact PATH entry that caused it.
  assert_stderr_mentions "bin/mcode"
  # Must not have split: the whole point is refusing before the multiplexer.
  assert_log_empty
}

# --- driver ------------------------------------------------------------------
# --- case 16 ----------------------------------------------------------------
# `pane report-agent` errors. The launch already happened and the user can see
# mcode running, so the entrypoint must NOT turn this into a failure: exit 0,
# mcode still launched, and stderr says the registration failed. This is the
# branch most likely to be "corrected" later into a hard failure, so it is
# asserted on all three properties.
case_16() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAIL="pane report-agent:1"

  run_entrypoint
  assert_rc_zero "$RC"
  assert_stderr_mentions "could not register"
  assert_stderr_mentions "$(expected_new_pane)"
  # mcode really was started, and naming was skipped: renaming a pane that was
  # never registered cannot work, and trying would emit a second warning for
  # one root cause.
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode" yes reported)"
}

# --- case 17 ----------------------------------------------------------------
# An older Herdr with no `report-agent` verb at all. Different failure from
# case 16, same required outcome: exit 0, mcode launched, stderr explains.
case_17() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAULT="report-agent-unsupported"

  run_entrypoint
  assert_rc_zero "$RC"
  assert_stderr_mentions "could not register"
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode" yes reported)"
}

# --- case 18 ----------------------------------------------------------------
# Registration succeeds but the rename fails. The pane is then visible in
# `agent list` yet unnamed, which is a half-working state the user cannot
# diagnose on their own — so stderr must name the commands that will not work
# (prompt / send-keys), not just say "rename failed".
case_18() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAIL="agent rename:1"

  run_entrypoint
  assert_rc_zero "$RC"
  assert_stderr_mentions "could not be renamed"
  assert_stderr_mentions "send-keys"
  assert_stderr_mentions "agent_not_ready"
  # The point of the message is to stop a user renaming the agent by hand, so it
  # must name the real cause and must NOT promise that naming would help.
  assert_stderr_mentions "Herdr itself started"
  if grep -qF 'until it is named' "$STDERR_FILE"; then
    note "stderr tells the user naming would fix prompt/send-keys; on 0.9.3 it would not"
  fi
  # The registration and the name lookup both still happened.
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode" yes full)"
}

# --- case 19 ----------------------------------------------------------------
# Name collision. `mcode` and `mcode-2` are already in use, so the entrypoint
# must pick the next free slot rather than blindly renaming to `mcode` — which
# on a real Herdr fails with agent_name_taken and leaves the agent unnamed.
case_19() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  export FAKE_HERDR_FAULT="agent-names-taken"

  run_entrypoint
  assert_rc_zero "$RC"
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode" yes full)"
  if ! grep -qF "$(printf 'agent	rename	%s	mcode-3' "$(expected_new_pane)")" "$FAKE_HERDR_LOG"; then
    note "expected the rename to land on mcode-3 with mcode and mcode-2 taken"
  fi
}

# --- case 20 ----------------------------------------------------------------
# The state hint after a successful launch: exactly one line, naming the NEW
# pane and a watcher path that is actually executable. Asserted for
# executability rather than for shape, because a well-formed path to a file
# that is not there is precisely the failure a user cannot act on.
case_20() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  local watcher newpane
  watcher="$(expected_watcher_path)"
  newpane="$(expected_new_pane)"

  if [ ! -x "$watcher" ]; then
    note "$watcher is not executable, so this case cannot assert a runnable command"
    return
  fi

  run_entrypoint
  assert_rc_zero "$RC"
  # The launch line is unchanged - the hint is additive, not a replacement.
  assert_stderr_mentions "started $CASE_DIR/bin/mcode in pane $newpane"
  assert_count "$STDERR_FILE" "$watcher $newpane" 1 "state hint"
  # It must name the NEW pane. Pointing at the source pane would send the
  # operator to watch the window they launched from, which is not the one that
  # just started.
  if grep -qF -- "$watcher $SRC_PANE" "$STDERR_FILE"; then
    note "state hint points at the source pane $SRC_PANE instead of the new pane $newpane"
  fi
  # And it must name the opt-out that caused it, not just say tracking is off.
  # The suite default for every case is MCODE_WATCH_AUTOSTART=0 (so no case can
  # spawn a real detached watcher), which means this message fires on every
  # single run of the suite. A message that read only "state will not be tracked"
  # would be indistinguishable from a launch that failed to start a watcher -
  # two very different facts for the operator. Naming the variable is what makes
  # it a setting rather than a fault.
  assert_stderr_mentions "MCODE_WATCH_AUTOSTART=0"
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode" yes full)"
}

# --- case 21 ----------------------------------------------------------------
# The hint's failure policy, which is the registration policy: a watcher that
# cannot be run is a warning, the launch still exits 0, and the message must
# not hand the user a run command for a path that is not there.
case_21() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  local copy watcher newpane
  copy="$(stage_plugin none)"
  watcher="$(watcher_path_for "$copy")"
  newpane="$(expected_new_pane)"

  if [ -e "$watcher" ]; then
    note "$watcher exists, so the 'watcher missing' branch cannot be exercised"
    return
  fi

  # THE OPT-OUT IS LIFTED FOR THIS CASE, and that is not tidying - it is the
  # precondition. setup_case exports MCODE_WATCH_AUTOSTART=0 so no case can
  # spawn a real detached watcher, but the launcher checks that FIRST and
  # returns before it ever looks at whether the watcher file exists. Left at 0,
  # this case would see the "tracking is off" message, find no "state watcher"
  # wording, and fail for a reason that has nothing to do with the missing-file
  # branch it exists to cover. Setting it to 1 is what makes the staged plugin's
  # absent bin/mcode-watch.sh the thing the launcher actually reacts to.
  export MCODE_WATCH_AUTOSTART=1

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  # The launch is still reported as the success it is. That is the entire point
  # of the best-effort policy: the user asked for a pane and got a working one.
  assert_stderr_mentions "started $CASE_DIR/bin/mcode in pane $newpane"
  assert_stderr_mentions "state watcher"
  assert_stderr_mentions "The launch itself succeeded"  # No run command for a file that does not exist: that would be worse than
  # silence, because the user copies it and it cannot work.
  if grep -qF -- "run: $watcher" "$STDERR_FILE"; then
    note "stderr printed a run command for a watcher that does not exist"
  fi
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode" yes full)"
}

# --- case 22 ----------------------------------------------------------------
# THE lifecycle guarantee of issue #47 - in this design it is strictly stronger
# than the one the issue asks for. The issue asks for "no orphan outlives the
# pane"; this build starts no watcher at all, so there is nothing that can
# outlive a pane, nothing a second launch can duplicate, and nothing that can
# hold the action's own pane open.
#
# A stub watcher that records its own invocation is the honest probe. The herdr
# call log cannot see a watcher at all: a freshly backgrounded one makes no
# herdr call until its first poll, so an exact-sequence assertion would stay
# green while the entrypoint silently leaked a process.
case_22() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  local copy root
  copy="$(stage_plugin fake)"
  root="$CASE_DIR/plugin"
  # setup_case defaults autostart OFF so no case spawns a real detached watcher by
  # accident. These two were reversed by #75 to expect one, so they ask.
  export MCODE_WATCH_AUTOSTART=1

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  # REVERSED by #75. This case asserted the watcher was never started, which was
  # the correct contract for #47 and is exactly what auto-start overturns. It
  # now asserts the watcher IS started, and the poll is what makes the assertion
  # real: an immediate check would report "never started" on a build that works
  # perfectly, 0 times out of 20.
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "cmd_start did not start the state watcher; the marker never appeared" \
         "within the bounded poll, so the launch promised state it never began"
    return
  fi
  # Exactly once, for one launch. A second line would be a duplicated watcher
  # polling the same pane, which is the failure this case was built to catch.
  local starts
  starts="$(grep -c . "$root/watcher-ran" 2>/dev/null || printf 0)"
  if [ "${starts:-0}" -ne 1 ]; then
    note "one launch started the watcher ${starts:-0} time(s); it must be exactly 1"
  fi
  # Second probe, on the real tree: nothing from THIS checkout may be running
  # either. pgrep excludes itself, and the path is checkout-specific, so an
  # unrelated watcher the user has running elsewhere cannot mask a failure.
  if ! command -v pgrep >/dev/null 2>&1; then
    note "pgrep is required to assert that no watcher process is left behind"
  elif pgrep -f -- "$(expected_watcher_path)" >/dev/null 2>&1; then
    note "a watcher from this checkout is still running: $(pgrep -f -- "$(expected_watcher_path)" | tr '\n' ' ')"
  fi
}

# --- case 23 ----------------------------------------------------------------
# The same guarantee under the race the issue names: two launches in a row. With
# the watcher left to the operator there is nothing to duplicate, and asserting
# the count stays at zero is the only form of this test that would catch a
# re-introduced automatic wiring. The second launch is asserted to be a complete
# launch of its own, not a degraded one.
case_23() {
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  local copy root
  copy="$(stage_plugin fake)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  # Reset the record so the second launch's count cannot hide inside the first.
  : >"$FAKE_HERDR_LOG"
  # The first launch's watcher may still be mid-write; wait for it before
  # counting, or the second launch's line is indistinguishable from the first's.
  wait_for_file "$root/watcher-ran" 1000 || true
  local after_first
  after_first="$(grep -c . "$root/watcher-ran" 2>/dev/null || printf 0)"
  : >"$FAKE_HERDR_LOG"
  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  # ONE watcher, not two — and this expectation was WRONG until #84.
  #
  # What this case always claimed to test was "two launches, two panes, two
  # watchers: one each". It could not test that, because tests/fake-herdr serves
  # the captured pane-split.json for every split, so BOTH launches register the
  # SAME new pane (wZ:p8). CLAUDE.md is explicit that the split's pane id is the
  # one value that must never be faked, so the two-pane case cannot be modelled
  # on this path at all — and the assertion was passing for a reason unrelated
  # to its stated intent.
  #
  # What it actually exercised was one pane launched twice, expecting two
  # watchers. Issue #84 makes that the opposite of the contract: a pane gets
  # exactly one watcher however it was launched, and a second trigger starts
  # nothing. So the expectation is corrected rather than the stub faked, and the
  # genuinely-two-panes property is asserted in case_38, where the pane id comes
  # from an event payload and a test may legitimately choose it.
  assert_one_watcher "$root/watcher-ran" \
    "two launches of the SAME pane (was ${after_first:-0} after the first)"
  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode" yes full)"
}

# --- issue #79: the launch path must actually report the session -------------
# Written RED against the shipped bin/mcode-plugin.sh, which does neither of
# these things. That is the point: cmd_start's chain ends at report-agent +
# rename, so the session reporter never fires and a launched pane carries no
# session identity and no resume command.
#
# The ORDER is the law, not a detail. `pane report-agent` must precede
# `pane report-agent-session`, or herdr refuses with `resume_not_accepted`
# (measured, herdr 0.9.3, recorded in bin/mcode-session.sh's header). So these
# cases assert sequence, never just presence: a launcher that called both in the
# wrong order would pass a "was it called?" check and fail in production.
case_24() { # #79: the launch path ATTACHES identity, and attaches it once
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  # Staged, not run in place: cmd_start resolves its session reporter from its OWN
  # directory, so running an overridden copy without the sibling beside it reports
  # "reporter missing" and exits 0 - a correct launch, and a case that would then
  # be measuring the staging rather than the attach.
  local copy
  copy="$(stage_plugin none)"

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"

  # ONE report-agent-session. cmd_start already registers the pane, so the
  # session step is an ATTACH, not a second registration.
  local n
  n="$(grep -c "pane	report-agent-session" "$FAKE_HERDR_LOG" || true)"
  if [ "${n:-0}" -ne 1 ]; then
    note "expected exactly one report-agent-session, saw ${n:-0}"
  fi
  # ONE report-agent. This is the finding that changed the shape: the session
  # reporter re-asserts state for itself, so calling it wholesale after a rename
  # issues a SECOND report-agent under a different label (mcode-session.sh's
  # MCODE_AGENT_LABEL default is `minimax-code`, not the assigned `mcode`/`mcode-N`).
  # Per #74's measurement a wrong label/source pair does not error - it silently
  # fails to attach - so the symptom would be a pane whose state quietly stops
  # landing. Counting is the assertion; presence would not catch it.
  n="$(grep -c "pane	report-agent	" "$FAKE_HERDR_LOG" || true)"
  if [ "${n:-0}" -ne 1 ]; then
    note "expected exactly one report-agent, saw ${n:-0}; a second one means" \
         "the session path re-registered the pane under a different label"
  fi
  # The order herdr demands: report-agent before report-agent-session, or
  # resume_not_accepted.
  assert_log_order "pane	report-agent	" "pane	report-agent-session"
  # And a read-back AFTER the attach - that is #71's, and it is what makes the
  # one stderr line below trustworthy rather than assumed.
  local report_line readback_line
  report_line="$(grep -n "pane	report-agent-session" "$FAKE_HERDR_LOG" | head -1 | cut -d: -f1)"
  readback_line="$(grep -n "agent	get" "$FAKE_HERDR_LOG" | tail -1 | cut -d: -f1)"
  if [ -z "$readback_line" ] || [ "$readback_line" -le "$report_line" ]; then
    note "no \`agent get\` after the session report; nothing verified what herdr stored"
  fi
  # The ONE diagnostic, on 0.9.3. Measured cost of this wiring, which is why it
  # is capped at one line rather than a transcript: every successful launch
  # otherwise prints five lines saying resume is unavailable, and a warning that
  # fires on every success is one an operator learns to scroll past.
  local diag
  diag="$(grep -c "did not persist\|not stored\|unavailab" "$STDERR_FILE" || true)"
  if [ "${diag:-0}" -gt 1 ]; then
    note "the launch emitted ${diag} lines about the discarded write; the ruling" \
         "is exactly ONE, because this fires on every successful launch"
  fi
  # And the launch itself is untouched by any of it.
  if ! grep -q "pane	run	" "$FAKE_HERDR_LOG"; then
    note "mcode was never launched into the new pane"
  fi
}

case_25() { # #79: a failed session report warns and does not fail the launch
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  local copy
  copy="$(stage_plugin none)"
  export FAKE_HERDR_FAIL="pane report-agent-session:1"

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  # THE PRECONDITION, and the reason this case is not fake. Injected failure of
  # a call that is never made is indistinguishable from handling it correctly:
  # the launch exits 0, the pane id is in stderr, mcode ran - all three hold
  # whether or not the session report was attempted. Without this assertion the
  # case passes today, against code that does not call the reporter at all, which
  # is the exact "a test that cannot fail" trap.
  if ! grep -q 'report-agent-session' "$FAKE_HERDR_LOG"; then
    note "the injected session-report failure never fired because the" \
         "session report is never attempted; this case would pass vacuously"
    return
  fi
  assert_stderr_mentions "$(expected_new_pane)"
  # mcode still ran: a launch that reported failure here would not have typed
  # into the pane at all, which is the outcome this policy exists to avoid.
  if ! grep -q "pane	run	" "$FAKE_HERDR_LOG"; then
    note "the launch was abandoned because the SESSION report failed;" \
         "only identity is missing, the pane is already running mcode"
  fi
}

# --- issue #75: the watcher starts with the launch ---------------------------
# Three cases, one policy: the watcher is best-effort. Absent, failing, or
# opted out, none of it may change the launch's exit code — the pane is already
# running mcode by the time any of this happens.
case_26() { # #75: the watcher is started for the new pane
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  # Via stage_plugin, NOT a MCODE_WATCH_BIN knob. The entrypoint resolves the
  # watcher from its OWN directory - `$(dirname $BASH_SOURCE)/../bin/mcode-watch.sh`
  # - so the only honest way to observe it is to put a stub BESIDE a COPY of the
  # entrypoint, which is what cases 21-23 already do. An earlier draft of this
  # case pointed a knob at a stub instead and would have reported "never started"
  # on a build that starts the watcher perfectly: same class of bug as #74's
  # MCODE_BIN_NAME/MCODE_BIN_PATH fall-through, where a seam that silently does
  # not connect looks exactly like a feature that does not exist.
  local copy root
  copy="$(stage_plugin fake)"
  root="$CASE_DIR/plugin"
  # setup_case defaults this to 0 so cases 1-23 cannot spawn real detached
  # watchers. A case that wants one has to ask - which is the whole point of an
  # opt-out knob, and why the control in case 27 needs it too.
  export MCODE_WATCH_AUTOSTART=1

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  # Polled: the watcher is backgrounded, so an immediate check is a deterministic
  # false negative rather than a flake.
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "the watcher was never started; a launched pane reports no state" \
         "until somebody runs it by hand"
    return
  fi
  # The NEW pane, not the source pane the user is typing in. A watcher pointed at
  # the wrong pane is worse than none: it polls somebody's window and reports
  # state that is not this launch's.
  assert_stderr_mentions "$(expected_new_pane)"
  local starts
  starts="$(grep -c . "$root/watcher-ran" 2>/dev/null || printf 0)"
  if [ "${starts:-0}" -ne 1 ]; then
    note "one launch started the watcher ${starts:-0} time(s); it must be exactly 1"
  fi
}

case_27() { # #75: MCODE_WATCH_AUTOSTART=0 opts out entirely
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  local copy root
  copy="$(stage_plugin fake)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1

  # CONTROL FIRST. An off-switch test that only asserts "did not run" passes
  # against an entrypoint that never starts the watcher for ANY reason - green
  # while measuring nothing. The control proves the watcher really does start, so
  # the assertion with the switch present is about the SWITCH.
  run_entrypoint_at "$copy"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "control: the watcher did not run even with autostart enabled, so" \
         "'MCODE_WATCH_AUTOSTART=0 did not run it' would be vacuous"
    return
  fi
  local control_count
  control_count="$(grep -c . "$root/watcher-ran" 2>/dev/null || printf 0)"

  # A fresh copy, so the second launch's marker cannot hide in the first's.
  copy="$(stage_plugin fake)"
  export MCODE_WATCH_AUTOSTART=0
  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  # Compared against the control's count rather than against zero.
  local after_off
  after_off="$(grep -c . "$root/watcher-ran" 2>/dev/null || printf 0)"
  if [ "${after_off:-0}" -ne "${control_count:-0}" ]; then
    note "MCODE_WATCH_AUTOSTART=0 and the watcher started anyway" \
         "(${after_off:-0} vs ${control_count:-0} after the control launch)"
    sed 's/^/          /' "$root/watcher-ran"
  fi
  # And it must SAY so. An opt-out that is silent leaves the operator wondering
  # whether state tracking is on; the point of the switch is that it is a
  # decision they made and can see.
  assert_stderr_mentions "MCODE_WATCH_AUTOSTART=0"
}

case_28() { # #75: a watcher that fails to start is a warning, not a failure
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  local copy root
  copy="$(stage_plugin fail)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "the failing watcher was never invoked; this case would pass" \
         "vacuously against an entrypoint that never starts one"
    return
  fi
  # The launch is still the success it is. State tracking is an add-on to a
  # launch that already worked; a non-zero exit here would invite a retry, and a
  # retry means a second pane.
  assert_stderr_mentions "$(expected_new_pane)"
  if ! grep -q "pane	run	" "$FAKE_HERDR_LOG"; then
    note "the launch was abandoned because the WATCHER would not start"
  fi
}

# 29. THE WATCHER MUST INHERIT THE LABEL cmd_start CHOSE, NOT A LITERAL.
#
#     mcode-watch.sh:24 is a bare `AGENT_LABEL="mcode"`, while the other two
#     reporters are not: mcode-plugin.sh derives `mcode`, `mcode-2`, `mcode-3`
#     from the name sequence, and mcode-session.sh reads
#     ${MCODE_AGENT_LABEL:-minimax-code}. So the watcher reports under `mcode`
#     regardless of what the launch renamed the pane to. The first pane agrees by
#     luck; every pane after it does not.
#
#     Today that is latent, because per #75's own evidence the watcher is rarely
#     running and is opt-in. #75 build 1 makes it start on EVERY launch, which
#     turns a rare edge case into a guaranteed one - and #74 measured that a
#     wrong label/`--source` pair does not error, it silently fails to attach.
#     The symptom would be a pane whose state updates quietly stop landing, which
#     is precisely the stale-state bug #75 exists to fix. Worst shape: it appears
#     to work on pane one and silently fails from pane two onward.
#
#     WHY ONE LAUNCH AND NOT TWO: tests/fake-herdr's `agent list` is a fixed
#     response per invocation and does not evolve between launches, so a genuine
#     two-pane case needs a stateful stub - a change to tests/fake-herdr, which is
#     not my file this round. The `agent-names-taken` fault makes the assigned
#     name `mcode-3`, so ANY hardcoded literal fails this case and a correct
#     implementation passes. Same defect, no stub change, and the comment says so
#     so nobody "simplifies" it back to two launches later.
case_29() { # #75: the watcher inherits the label the launch chose, not a literal
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  local copy root
  copy="$(stage_plugin label)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1
  # The name the launcher will pick is mcode-3, not mcode.
  export FAKE_HERDR_FAULT="agent-names-taken"

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "the watcher was never started; nothing to assert a label on"
    return
  fi
  local want_name
  want_name="$(expected_agent_name)"
  # What the watcher must be told, and what a hardcoded literal would produce.
  if ! grep -qF "$want_name" "$root/watcher-ran"; then
    note "the watcher was started without the label the launch chose" \
         "('${want_name}'); a hardcoded literal reports state under the wrong" \
         "agent name and herdr silently fails to attach it"
    sed 's/^/          /' "$root/watcher-ran"
  fi
  # Stated explicitly, because this is the finding: a watcher hardcoded to
  # `mcode` looks correct on the very first pane.
  if grep -q "mcode"$'\t' "$root/watcher-ran"; then
    note "the watcher was given the bare label 'mcode' while the pane was" \
         "registered as '${want_name}'"
  fi
}

# Kill any watcher a case started, matched on THAT CASE'S OWN staged copy.
#
# This exists because #84 made watcher existence a process-table question, and
# that couples every watcher case to every other one. The hook stub sleeps 30s;
# without this, a case left a watcher running for its pane, and the next case
# that used the same pane id found it and declined to start its own — so the
# suite's result depended on execution order and on how busy the machine had
# been. That is not hypothetical: one run left three stubs alive and a later run
# failed three cases for reasons that had nothing to do with those cases.
#
# SCOPED TO THE STAGED PATH, and that is the whole safety argument. Cases run
# their stubs from $CASE_DIR/plugin/bin/, a temp directory unique per case, so
# this can only ever match a stub this suite started. It must never be a blanket
# `pkill -f mcode-watch.sh`: the developer's own minimax-code panes have REAL
# watchers running, their command line is a bare relative
# `bin/mcode-watch.sh <pane>`, and a blanket pattern kills those. This suite got
# that wrong once already, in a verification script, and had to report it.
kill_staged_watchers() { # kill_staged_watchers
  [ -n "${WORK:-}" ] || return 0
  [ -n "${CURRENT_CASE:-}" ] || return 0
  [ -d "$CASE_DIR/plugin" ] || return 0
  # Match a PATH SUFFIX, never an absolute path, and the reason is that two
  # different absolute paths can both be the stub this case started:
  #
  #   * the entrypoint resolves the watcher with `cd .. && pwd -P` before it
  #     execs, so a stub IT started runs out of the canonical
  #     /private/var/folders/... path;
  #   * a stub a case starts by hand, like case-39's, runs out of whatever
  #     $CASE_DIR literally is, which on macOS is the unresolved
  #     /var/folders/... (and with mktemp's doubled slash).
  #
  # An absolute pattern matches one of those and misses the other, silently.
  # $WORK's basename is unique per run and appears verbatim in both forms, so
  # matching on it covers every stub this run owns and nothing else.
  kill_watchers_matching "$(work_basename)/${CURRENT_CASE}/plugin/bin/mcode-watch\.sh"
}

# work_basename - the unique per-run directory name, safe to use as a pgrep
# pattern component. The `.` is escaped so it cannot act as "any character".
work_basename() {
  local b
  b="${WORK:-}"
  b="${b##*/}"
  case "$b" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "${b//./\\.}"
}

# kill_watchers_matching PATTERN - kill everything matching, and WAIT for the
# process table to clear.
#
# SIGKILL, not SIGTERM, and the reason is measured rather than assumed. A stub is
# `#!/bin/sh` running a foreground `sleep`, and bash DEFERS a SIGTERM while a
# foreground child is running: the signal is handled after the child finishes, so
# `kill` alone leaves the stub alive for the full 30 seconds of its sleep. That
# is not a corner case, it is what happened — six stubs from one full run were
# still alive half a minute later, holding `wZ:p8` and `wZ:p42`, and the run after
# it failed a dozen cases for that reason.
#
# SIGKILL is appropriate precisely because these are processes this suite created
# in its own temp sandbox and knows it owns. It is never aimed at anything else:
# every pattern here is scoped to a sandbox name this run generated, and a watcher
# on a real pane is not this suite's to kill.
#
# The wait is there for the same reason the signal alone was not enough:
# `pane_is_watched` reads the process table, so a process still dying in the
# background is indistinguishable from a live one, and the next case — same pane
# id, because ADOPTED_PANE and the fixture's new-pane id are constants — would
# find its predecessor still listed and decline to start a watcher.
kill_watchers_matching() { # kill_watchers_matching <pgrep-pattern>
  local pattern="$1" tries p
  [ -n "$pattern" ] || return 0
  for p in $(pgrep -f "$pattern" 2>/dev/null); do
    kill -9 "$p" 2>/dev/null
  done
  for tries in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do
    pgrep -f "$pattern" >/dev/null 2>&1 || return 0
    sleep 0.05
  done
  return 0
}

# Sweep watchers left behind by an EARLIER run of this suite that was killed
# before its own cleanup could run.
#
# #84 made "is this pane watched" a process-table question, so a stray `sleep 30`
# stub from a previous run holds a pane id and makes the next run believe panes
# are already watched. That is not a hypothetical: a run interrupted partway
# left stubs alive, and the following run failed a dozen cases, every one of
# them reporting "no watcher started" when in fact a predecessor had suppressed
# them.
#
# SCOPED TO THIS SUITE'S OWN SANDBOX NAMING, which is what makes it safe. Every
# stub this suite runs lives under a mcode-plugin-tests.XXXXXX directory, and
# the pattern requires that name plus /plugin/bin/. The developer's real
# minimax-code panes run a watcher whose command line is a bare relative
# `bin/mcode-watch.sh <pane>` with no sandbox anywhere in it, so this cannot
# reach them. A blanket `pkill -f mcode-watch.sh` would, and this suite has
# already killed the owner's watchers that way once and had to report it.
sweep_orphan_watchers() { # sweep_orphan_watchers
  kill_watchers_matching 'mcode-plugin-tests\..*/plugin/bin/mcode-watch\.sh'
}

run_case() { # run_case <name> <function>
  CURRENT_CASE="$1"
  CASES_RUN=$((CASES_RUN + 1))
  broke=0
  "$2"
  kill_staged_watchers
  if [ "$broke" -eq 0 ]; then
    printf 'ok    %s\n' "$CURRENT_CASE"
  else
    CASES_FAILED=$((CASES_FAILED + 1))
    printf 'FAIL  %s\n' "$CURRENT_CASE"
  fi
}

# ===========================================================================
# Issue #84 — a watcher for EVERY minimax-code pane, not just action-launched
# ones, with logs that are not /dev/null.
#
# The defect being pinned: the watcher only ever started from cmd_start's step
# 10, so a pane adopted by flock, a hand-run `mcode`, or a pane from before
# 0.4.1 kept whatever state herdr last saw — frozen, and frozen in both
# directions. Every case below drives the manifest's EVENT subcommand, which is
# the path that reaches those panes.
# ===========================================================================

# The pane these cases pretend flock adopted. Deliberately NOT the pane id the
# launch path produces: if the event handler only worked on panes cmd_start had
# just created, these cases would pass without testing the fix at all.
# UNIQUE PER RUN, and this is the fix for a whole class of flakiness rather than
# cosmetic tidiness.
#
# #84 decides "is this pane watched" by reading the PROCESS TABLE, and the event
# cases take their pane id from the payload — which means a test may choose it,
# and until now they all chose the same one. So a stub left alive by any earlier
# run (an interrupted run, a `kill -9`, a machine that was busy) would hold that
# pane, the next run would decide the pane was already watched, and every watcher
# case would fail for a reason that had nothing to do with the code. Observed
# repeatedly here: a run failing 13 cases, and leaving 2 stubs that made the run
# after it fail 13 more.
#
# Deriving the id from $$ makes that impossible — a stub from another run cannot
# be watching a pane id that did not exist then. The fixture-derived `wZ:p8` is
# NOT renamed: CLAUDE.md is explicit that the split's pane id must never be
# faked, so those cases keep the real id and rely on the startup sweep and the
# foreign-watcher preflight instead.
#
# The tag is $$ mod 100000, so the ids stay short and pane-shaped while being
# unique across the handful of runs a machine will do in a session. Two runs
# colliding here would need the same pid modulo 100000, which is why the preflight
# below still exists rather than being considered redundant.
RUN_TAG=$(( $$ % 100000 ))
ADOPTED_PANE="wZ:p${RUN_TAG}"
SECOND_PANE="wZ:p$(( RUN_TAG + 1 ))"
FOREIGN_PANE="wZ:p$(( RUN_TAG + 2 ))"

case_30() { # #84: an adopted pane gets a watcher even though we never launched it
  setup_case
  local copy root
  copy="$(stage_plugin hook)"
  root="$CASE_DIR/plugin"
  # setup_case defaults this to 0 so no case spawns a detached process by
  # accident, and the event path honours that opt-out exactly as the launch path
  # does. These cases are about the opt-out being ON.
  export MCODE_WATCH_AUTOSTART=1

  run_event_handler_at "$copy" "$ADOPTED_PANE" "minimax-code"
  assert_rc_zero "$RC"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "the event handler did not start a watcher for an adopted minimax-code" \
         "pane. This is issue #84 itself: without a watcher, ${ADOPTED_PANE} shows" \
         "whatever state herdr last saw and never moves again."
    return
  fi
  # For the RIGHT pane. A watcher started for some other pane - the launch path's
  # pane, or nothing at all - would also produce a marker file.
  if ! grep -qF "$ADOPTED_PANE" "$root/watcher-ran"; then
    note "a watcher started, but not for ${ADOPTED_PANE};" \
         "the event payload's pane id is the one that must be watched."
    sed 's/^/          /' "$root/watcher-ran"
  fi
  # Once, for one event.
  assert_one_watcher "$root/watcher-ran" "one event for one pane"
}

case_31() { # #84: a second trigger for a pane that IS watched starts nothing
  setup_case
  local copy root
  copy="$(stage_plugin hook)"
  root="$CASE_DIR/plugin"
  # See case_30: setup_case defaults the opt-out ON and the event path honours
  # it, so a case about a watcher existing has to ask for one.
  export MCODE_WATCH_AUTOSTART=1

  run_event_handler_at "$copy" "$ADOPTED_PANE" "minimax-code"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "the first event did not start a watcher, so this case would pass" \
         "vacuously against an implementation that never starts one"
    return
  fi
  # The first watcher sleeps 30s in the hook stub, so it is provably still
  # alive here. Assert that, because the whole case rests on it: if it were
  # dead, "a second trigger started nothing" would be true for the wrong reason.
  #
  # Checked with pgrep but NOT with the same pattern the entrypoint uses. A
  # test that reused the implementation's expression would agree with it even
  # when both were wrong, which is how a wrong anchor ships. This one is
  # deliberately looser: it looks for the stub path and the pane on the same
  # line and nothing else.
  if ! pgrep -f "bin/mcode-watch.sh $ADOPTED_PANE" >/dev/null 2>&1; then
    note "the first watcher is not running, so the idempotency assertion below" \
         "would be vacuous: a dead watcher and a suppressed second watcher look" \
         "identical from the marker file alone"
    return
  fi

  run_event_handler_at "$copy" "$ADOPTED_PANE" "minimax-code"
  assert_rc_zero "$RC"
  # CONTROL, and it has to be a control rather than a wait: "still one line" is
  # what a correctly-idempotent implementation produces AND what a stub that
  # records nothing at all would produce. Those are opposite findings wearing the
  # same output, so before concluding "started nothing", confirm the first line
  # really was written by this stub for this pane.
  if ! grep -qF "$ADOPTED_PANE" "$root/watcher-ran" 2>/dev/null; then
    note "control: the marker holds no record of ${ADOPTED_PANE}, so 'a second" \
         "trigger started nothing' would be indistinguishable from a stub that" \
         "never records anything"
    return
  fi
  assert_one_watcher "$root/watcher-ran" \
    "two events for one pane whose watcher is still alive"
}

case_32() { # #84: an event about someone else's agent starts nothing at all
  setup_case
  local copy root
  copy="$(stage_plugin hook)"
  root="$CASE_DIR/plugin"

  # Measured on herdr 0.9.3: this hook fires for agents this plugin has never
  # launched. A `claude` pane in the same session triggers it exactly as
  # reliably as one of ours does, so "do not act on it" has to be a real branch
  # and not an assumption about who is subscribing.
  #
  # The opt-out is explicitly ON here, and that is load-bearing rather than
  # incidental. With the sandbox's default the handler would stop at the opt-out
  # before reaching the scope gate at all, so removing the gate would change
  # nothing and this case would pass against an implementation that watches
  # every agent in the session. Asking for a watcher is what makes the gate the
  # only thing that can stop one.
  export MCODE_WATCH_AUTOSTART=1
  run_event_handler_at "$copy" "$FOREIGN_PANE" "claude"
  assert_rc_zero "$RC"

  if [ -e "$root/watcher-ran" ]; then
    note "the event handler started a watcher for a 'claude' pane. The event is" \
         "session-wide; acting on it would have this plugin polling panes it" \
         "does not own."
    sed 's/^/          /' "$root/watcher-ran"
  fi
  # The scope gate must come BEFORE any herdr call. Not tidiness: `agent get`
  # per foreign status change is this plugin adding load to a session it has no
  # business in, on every agent transition in it.
  if [ -s "$FAKE_HERDR_LOG" ]; then
    note "the handler made herdr calls for an agent that is not ours, before or" \
         "instead of scoping the event out"
    sed 's/^/          /' "$FAKE_HERDR_LOG"
  fi
}

case_33() { # #84: the watcher's output goes to a per-pane log, not /dev/null
  setup_case
  local copy root logf
  copy="$(stage_plugin hook)"
  root="$CASE_DIR/plugin"
  logf="$MCODE_WATCH_LOG_DIR/$ADOPTED_PANE.log"
  # See case_30: setup_case defaults the opt-out ON and the event path honours
  # it, so a case about a watcher existing has to ask for one.
  export MCODE_WATCH_AUTOSTART=1

  run_event_handler_at "$copy" "$ADOPTED_PANE" "minimax-code"
  assert_rc_zero "$RC"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "no watcher ran, so there is no output to have been logged"
    return
  fi

  # The defect in the issue: output went to /dev/null, so a watcher that died
  # left no trace. The marker is written by the stub's own redirect and would
  # appear even with stdout discarded, so the log has to be checked directly.
  if ! wait_for_file "$logf" 1000; then
    note "the watcher ran but ${logf} does not exist; its output went nowhere" \
         "discoverable, which is the /dev/null defect #84 was filed about"
    return
  fi
  if ! wait_for_file_content "$logf" "mcode-watch: watching" 1000; then
    note "the per-pane log exists but does not contain what the WATCHER printed;" \
         "a log file the watcher never writes to is no better than /dev/null." \
         "The needle is the stub's own line, not the word 'watching' — the" \
         "launcher's header line also says 'watching pane', and matching that" \
         "would pass against a watcher whose every byte is discarded."
    sed 's/^/          /' "$logf"
  fi
  # A header naming the pane, so a user with six of these can tell them apart.
  if ! grep -qF "$ADOPTED_PANE" "$logf"; then
    note "the log never names the pane it belongs to, so it cannot be matched" \
         "to a pane in \`herdr agent list\`"
  fi
  # Named after the pane, not a shared file: a shared log would interleave six
  # watchers' output into one unreadable stream.
  if [ -e "$MCODE_WATCH_LOG_DIR/all.log" ] || [ -e "$MCODE_WATCH_LOG_DIR/mcode-watch.log" ]; then
    note "the watcher log is a shared file; per-pane logs are what make the" \
         "output attributable"
  fi
}

case_34() { # #84: a watcher that has EXITED does not block a new one
  setup_case
  local copy root
  copy="$(stage_plugin brief)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1

  # The same worry the removed lock file used to answer, asked of the mechanism
  # that replaced it. A pane whose watcher died - the pane closed mid-poll, the
  # machine rebooted, someone killed it - must get a NEW watcher, because a
  # frozen pane is the defect #84 is filed about and "there is already a
  # watcher" is the one reason it would not be fixed.
  #
  # The `brief` stub records its start and exits at once, so the first watcher
  # is genuinely gone by the time the event arrives. This is the case the old
  # lock could only answer by keeping a pid file, and the reason a stale pid
  # file used to be able to freeze a pane forever.
  run_event_handler_at "$copy" "$ADOPTED_PANE" "minimax-code"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "the first event started no watcher, so this case would pass vacuously"
    return
  fi

  # Wait for it to be gone, or the second event's decline is meaningless.
  local i gone=0
  for i in $(seq 1 40); do
    if ! pgrep -f "bin/mcode-watch.sh $ADOPTED_PANE" >/dev/null 2>&1; then
      gone=1
      break
    fi
    sleep 0.25
  done
  if [ "$gone" -ne 1 ]; then
    note "control: the brief stub is still running after 10s, so this is not" \
         "actually testing what happens after a watcher exits"
    return
  fi

  run_event_handler_at "$copy" "$ADOPTED_PANE" "minimax-code"
  assert_rc_zero "$RC"
  if ! wait_for_count "$root/watcher-ran" 2 1500; then
    note "an exited watcher still blocked a new one for ${ADOPTED_PANE};" \
         "a pane whose watcher died stays frozen forever with no error anywhere"
  fi
}

case_35() { # #84: the launch path and the event path together start ONE watcher
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  local copy root
  copy="$(stage_plugin hook)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1

  # The launch path first, exactly as the action does it.
  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "the launch path started no watcher, so the cross-path assertion below" \
         "would pass vacuously"
    return
  fi

  # Now the event hook fires for that same pane. In production this is not a
  # hypothetical ordering: cmd_start's step 7 registers the pane, and that
  # registration is itself a `pane report-agent`, which is exactly what the hook
  # subscribes to. Without a shared lock the pane gets two watchers polling it.
  run_event_handler_at "$copy" "wZ:p8" "mcode"
  assert_rc_zero "$RC"

  assert_one_watcher "$root/watcher-ran" \
    "a launch plus an event for the same pane"
}

case_36() { # #84: the event handler refuses a payload with no usable pane id
  setup_case
  local copy root
  copy="$(stage_plugin hook)"
  root="$CASE_DIR/plugin"

  # The pane id is used to build a filesystem path and to name a process, and it
  # arrives from a JSON payload — which is data, not a trusted argument. A value
  # carrying a path separator is the one that would actually do damage.
  run_event_handler_at "$copy" "wZ:p42/../../etc" "minimax-code"
  assert_rc_nonzero "$RC"
  if [ -e "$root/watcher-ran" ]; then
    note "a watcher was started for a pane id containing a path separator," \
         "from an untrusted event payload"
    sed 's/^/          /' "$root/watcher-ran"
  fi
  # And it must say why, rather than exiting non-zero in silence.
  assert_stderr_nonempty
  if ! grep -qiF "pane id" "$STDERR_FILE"; then
    note "the refusal does not explain that the pane id was the problem"
  fi
}

case_37() { # #84: the manifest really declares the hook, in the dotted vocabulary
  # A manifest entry that parses is not a working hook — that conflation is the
  # Epic 1 defect, and it is invisible to every other case here because they all
  # invoke the entrypoint directly and never consult the manifest.
  setup_case
  local manifest="$repo/herdr-plugin.toml"

  if [ ! -f "$manifest" ]; then
    note "no manifest at $manifest"
    return
  fi
  # The underscored spelling parses and warns at runtime; only the dotted
  # subscription vocabulary binds. A grep for `pane.agent_status_changed`
  # would not catch `pane_agent_status_changed`, so both are checked.
  if ! grep -q 'on[[:space:]]*=[[:space:]]*"pane\.agent_status_changed"' "$manifest"; then
    note "the manifest does not subscribe to pane.agent_status_changed; without" \
         "it the event handler is unreachable and every #84 case above tests" \
         "a code path herdr will never run"
    return
  fi
  if grep -q 'on[[:space:]]*=[[:space:]]*"pane_agent_status_changed"' "$manifest"; then
    note "the manifest subscribes with the UNDERSCORED event name, which herdr" \
         "accepts as a parse and then warns about at runtime"
  fi
  # And it must name the subcommand this suite just tested, or the manifest and
  # the code disagree about what the hook runs.
  # The inner quotes are TOML-escaped on disk (mcode-plugin.sh\" ensure-watcher),
  # so the pattern has to tolerate the backslash. Matching the unescaped form
  # would report a correct manifest as missing its handler.
  if ! grep -q 'mcode-plugin\.sh\\\" ensure-watcher' "$manifest"; then
    note "the event hook does not invoke \`mcode-plugin.sh ensure-watcher\`, so" \
         "the handler the cases above exercise is not the one herdr would run"
  fi
}

case_38() { # #84: a watcher on ONE pane does not suppress another pane
  setup_case
  local copy root
  copy="$(stage_plugin hook)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1

  # The property case-23 could not test, asserted where it can be tested: the
  # event path takes its pane id from the payload, so a test may legitimately
  # choose it, and two distinct ids are two distinct panes as far as the handler
  # is concerned.
  #
  # This is the whole risk of deciding "already watched" by looking at the
  # process table. A bare `pgrep -f mcode-watch.sh` asks whether ANY watcher is
  # running and answers yes for every pane in the session, which looks exactly
  # like idempotency working and leaves panes 2..N frozen - the #84 symptom
  # rebuilt inside the fix for it. So: one pane watched, a DIFFERENT pane
  # triggered, and the second must still get its own watcher.
  run_event_handler_at "$copy" "wZ:p42" "minimax-code"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "the first pane got no watcher, so the per-pane assertion below would" \
         "pass vacuously"
    return
  fi
  if ! pgrep -f "bin/mcode-watch.sh wZ:p42" >/dev/null 2>&1; then
    note "control: no watcher is running for wZ:p42, so the second event has" \
         "nothing to be wrongly suppressed by"
    return
  fi

  run_event_handler_at "$copy" "$SECOND_PANE" "mcode"
  if ! wait_for_count "$root/watcher-ran" 2 1500; then
    note "${ADOPTED_PANE} has a watcher and ${SECOND_PANE} got none; the check is session-wide," \
         "so every pane after the first stays frozen with no error anywhere"
    sed 's/^/          /' "$root/watcher-ran"
    return
  fi
  if ! grep -qF "$SECOND_PANE" "$root/watcher-ran"; then
    note "no watcher was started for ${SECOND_PANE}"
  fi
  # And both alive at once, which is the point: one per pane, not one overall.
  local both=0
  pgrep -f "bin/mcode-watch.sh wZ:p42" >/dev/null 2>&1 && both=$((both + 1))
  pgrep -f "bin/mcode-watch.sh $SECOND_PANE" >/dev/null 2>&1 && both=$((both + 1))
  if [ "$both" -ne 2 ]; then
    note "expected a live watcher per pane (2), found $both"
  fi
}

case_39() { # #84: a watcher started OUTSIDE ensure_watcher is respected
  setup_case
  local copy root
  copy="$(stage_plugin hook)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1

  # The defect this case exists for. The first version of #84 decided "already
  # watched" from a pid lock file this code wrote, which records only OUR spawns
  # and is therefore blind to:
  #
  #   * every watcher a 0.4.1 launcher started - all of them, at the moment
  #     someone upgrades, and
  #   * the hand-run `bin/mcode-watch.sh <PANE_ID>` the README tells people to
  #     run as the fix for a frozen state.
  #
  # Both are live processes holding a pane. So the watcher below is started the
  # way a person or an older launcher starts one - by hand, from the test, with
  # no involvement from the entrypoint - and the event must then start NOTHING.
  # Against the lock-file version this case fails, because the lock has no
  # record of it and the handler concludes the pane is unwatched.
  #
  # Started with a flag, deliberately: `mcode-watch.sh <pane> --interval 1` is
  # what the README tells a user to type, and an end-anchored pattern on the
  # pane id does not match it. That is measured, not assumed - see
  # pane_is_watched in bin/mcode-plugin.sh.
  "$root/bin/mcode-watch.sh" "$ADOPTED_PANE" --interval 1 >/dev/null 2>&1 &
  local outsider=$!
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "the hand-started watcher never recorded itself, so this case would" \
         "pass vacuously"
    kill "$outsider" 2>/dev/null
    return
  fi
  if ! pgrep -f "bin/mcode-watch.sh $ADOPTED_PANE" >/dev/null 2>&1; then
    note "control: the hand-started watcher is not running, so 'started nothing'" \
         "below would be vacuous"
    kill "$outsider" 2>/dev/null
    return
  fi

  # Now the event path runs, and must decline.
  run_event_handler_at "$copy" "$ADOPTED_PANE" "minimax-code"
  assert_rc_zero "$RC"

  # A second watcher on top of the first means two processes reporting one pane
  # for the rest of its life, which is the duplicate the lock file could not
  # prevent and the reason this case is here.
  local n
  n="$(pgrep -f "bin/mcode-watch.sh $ADOPTED_PANE" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -ne 1 ]; then
    note "a watcher the plugin did not start was not respected: ${n} watchers are" \
         "now running for ${ADOPTED_PANE}. On upgrade every 0.4.1 watcher, and" \
         "every watcher the README tells a user to start by hand, gets doubled."
    sed 's/^/          /' "$root/watcher-ran"
  fi

  # Leave nothing behind. Scoped to this pane's stub, never a blanket pkill:
  # the developer's own mcode panes have real watchers running, and a test that
  # kills those is worse than no test.
  local p
  for p in $(pgrep -f "bin/mcode-watch.sh $ADOPTED_PANE" 2>/dev/null); do
    kill "$p" 2>/dev/null
  done
}

case_40() { # #84: the event path reports under the pane's NAME when it has one
  setup_case
  local copy root
  copy="$(stage_plugin label)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1
  # A pane that HAS a name. The launcher renames every pane it starts, so this
  # is the launch path's shape; a flock-adopted pane often has no name at all,
  # which is the other shape and the fallback's job.
  export FAKE_HERDR_AGENT_NAME="mcode-7"

  run_event_handler_at "$copy" "$ADOPTED_PANE" "minimax-code"
  assert_rc_zero "$RC"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "no watcher was started, so there is no label to assert on"
    return
  fi

  # The name, not the event's label. The event payload carries `agent`, which for
  # a launched pane is the literal `mcode`; the pane's NAME is `mcode-7`. A
  # watcher handed `mcode` for a pane called `mcode-7` reports every state under
  # a name that pane does not have — the second-pane divergence CLAUDE.md
  # records, reintroduced through the event path.
  if ! grep -qF "mcode-7" "$root/watcher-ran"; then
    note "the watcher was not given the pane's name 'mcode-7'; it was given the" \
         "event's agent label instead, so every state it reports is attributed to" \
         "an agent name this pane does not have"
    sed 's/^/          /' "$root/watcher-ran"
    return
  fi
  if grep -q "mcode"$'\t' "$root/watcher-ran"; then
    note "the watcher was handed the bare label 'mcode' for a pane named mcode-7"
  fi

  # And the read is not decorative: with herdr reporting no name, the fallback
  # is the label, and that is correct rather than a failure. Asserted so the
  # difference between the two shapes is pinned from both sides.
  #
  # A DIFFERENT pane id, and that is load-bearing rather than tidiness:
  # setup_case reuses $WORK/$CURRENT_CASE, so the staged stub and its marker file
  # are the same ones the first half already wrote. Re-checking `mcode-7` here
  # would read the first half's own line and pass for the wrong reason — which
  # is exactly what happened the first time this was written.
  unset FAKE_HERDR_AGENT_NAME
  run_event_handler_at "$copy" "$SECOND_PANE" "minimax-code"
  if ! wait_for_file_content "$root/watcher-ran" "$SECOND_PANE" 1000; then
    note "an unnamed pane got no watcher; the label is enough to watch a pane," \
         "so the fallback must still start one"
    return
  fi
  if ! grep -F "$SECOND_PANE" "$root/watcher-ran" | grep -qF "minimax-code"; then
    note "for a pane herdr reports no name for, the watcher should fall back to" \
         "the event's own agent label"
    sed 's/^/          /' "$root/watcher-ran"
  fi
}

case_41() { # #84: a process merely NAMED notmcode-watch.sh is not the watcher
  setup_case
  local copy root decoy
  copy="$(stage_plugin hook)"
  root="$CASE_DIR/plugin"
  export MCODE_WATCH_AUTOSTART=1

  # The left-hand anchor of the check, pinned.
  #
  # `mcode-watch.sh` is a substring of `notmcode-watch.sh`, so a check written
  # without a left anchor is satisfied by any process whose command line merely
  # CONTAINS that text. The consequence is not a duplicate watcher, it is the
  # opposite and worse one: the pane is treated as already watched, so no
  # watcher is ever started and the pane stays frozen — the #84 symptom, rebuilt
  # inside the fix for it.
  #
  # This exists because the anchor was an addition of mine that no test covered,
  # and an unverified claim in a comment is exactly what m4's review of #93
  # (and the architect's) refused to accept about the lock's read-back. Either
  # the code is proven or it is not there.
  decoy="$root/bin/notmcode-watch.sh"
  cat >"$decoy" <<'STUB'
#!/bin/sh
echo "decoy $1" >>"$(dirname -- "$0")/../decoy-ran"
sleep 5
STUB
  chmod +x "$decoy"
  "$decoy" "$ADOPTED_PANE" >/dev/null 2>&1 &
  local decoy_pid=$!
  sleep 0.5
  if ! kill -0 "$decoy_pid" 2>/dev/null; then
    note "the decoy did not start, so this case would pass vacuously"
    return
  fi

  run_event_handler_at "$copy" "$ADOPTED_PANE" "minimax-code"
  assert_rc_zero "$RC"
  if ! wait_for_file "$root/watcher-ran" 1000; then
    note "a process merely NAMED notmcode-watch.sh suppressed the real watcher" \
         "for ${ADOPTED_PANE}; the check is satisfied by any command line that" \
         "CONTAINS the name, so the pane is never watched at all"
    return
  fi
  if ! grep -qF "$ADOPTED_PANE" "$root/watcher-ran"; then
    note "a watcher started, but not for ${ADOPTED_PANE}"
  fi

  # Scoped to this pane's decoy. Never a blanket pkill.
  kill "$decoy_pid" 2>/dev/null
}

ALL_CASES=(case-1 case-2 case-3 case-4 case-5 case-6 case-7 case-8 case-9 case-10 case-11 case-12 case-13 case-14 case-15 case-16 case-17 case-18 case-19 case-20 case-21 case-22 case-23 case-24 case-25 case-26 case-27 case-28 case-29 case-30 case-31 case-32 case-33 case-34 case-35 case-36 case-37 case-38 case-39 case-40 case-41)

if [ ! -x "$FAKE_HERDR" ]; then
  printf 'tests/run.sh: %s is missing or not executable\n' "$FAKE_HERDR" >&2
  exit 2
fi
if [ ! -f "$PLUGIN_BIN" ]; then
  printf 'tests/run.sh: entrypoint not found: %s\n' "$PLUGIN_BIN" >&2
  exit 2
fi

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "${ALL_CASES[@]}"
  exit 0
fi

# Clear watchers an earlier run of this suite left behind, before any case runs. See
# sweep_orphan_watchers for why this is required now and why the pattern cannot
# reach the developer's own panes.
sweep_orphan_watchers

# Preflight: refuse to run if something OUTSIDE this suite is watching a pane id
# the cases below use.
#
# #84 decides "is this pane watched" by reading the process table, and the cases
# use fixed pane ids — wZ:p8 comes from the captured split fixture and must never
# be faked, and wZ:p42/43/99 are constants. So any other process watching one of
# those panes makes the entrypoint decline to start a watcher, and every watcher
# case then fails with a message describing the wrong thing: "the first event did
# not start a watcher", when the event did its job and something else was already
# holding the pane.
#
# That is not hypothetical. Debris from ad-hoc probing of the pgrep pattern —
# stubs in /tmp, started outside any sandbox, watching wZ:p8 and wZ:p42 — turned
# fourteen cases red with fourteen different lies, and the real cause was one
# stale process. Diagnosing that from the failure text alone would have been
# slow. This file's own test-design note ("stubs are started inside a unique temp
# sandbox so they can never collide with anything on the machine") assumes every
# watcher on the box belongs to the suite, and that assumption is not safe on a
# machine where a developer is also hand-running watchers.
#
# So: name it once, before anything runs. Nothing is killed here. A watcher
# belonging to the developer may be perfectly legitimate, and this suite does not
# get to decide that — it reports and stops.
foreign_watcher_preflight() { # foreign_watcher_preflight
  local pattern p cmd found=""
  # The fixture's wZ:p8 plus this run's three derived ids, so the check covers
  # exactly the panes the cases below can be suppressed on.
  local pane
  for pane in wZ:p8 "$ADOPTED_PANE" "$SECOND_PANE" "$FOREIGN_PANE"; do
    pattern="(^|[[:space:]/])mcode-watch\\.sh[[:space:]]+${pane}([[:space:]]|\$)"
    for p in $(pgrep -f "$pattern" 2>/dev/null); do
      cmd="$(ps -o command= -p "$p" 2>/dev/null)"
      case "$cmd" in
        *mcode-plugin-tests.*) continue ;;   # ours, and already swept
      esac
      found="${found}  pid ${p}: ${cmd}
"
    done
  done
  if [ -n "$found" ]; then
    printf 'tests/run.sh: refusing to run.\n\n' >&2
    printf 'These panes are watched by processes this suite does not own:\n' >&2
    printf '%s' "$found" | sed 's/^/  /' >&2
    printf '\n' >&2
    printf 'The cases use fixed pane ids, and the entrypoint decides "already\n' >&2
    printf 'watched" from the process table, so a foreign watcher on any of them\n' >&2
    printf 'makes every watcher case fail for the wrong reason. Stop those, or run\n' >&2
    printf 'somewhere they are not running. This suite will not kill them for you:\n' >&2
    printf 'a watcher on a real pane is the developer'"'"'s business, not a fixture'"'"'s.\n' >&2
    exit 2
  fi
}
foreign_watcher_preflight

if ! check_stub_responses; then
  printf 'tests/run.sh: fake-herdr canned responses are unusable; refusing to run\n' >&2
  exit 2
fi

if [ "$#" -gt 0 ]; then
  SELECTED=("$@")
else
  SELECTED=("${ALL_CASES[@]}")
fi

for name in "${SELECTED[@]}"; do
  case "$name" in
    case-1) run_case case-1 case_1 ;;
    case-2) run_case case-2 case_2 ;;
    case-3) run_case case-3 case_3 ;;
    case-4) run_case case-4 case_4 ;;
    case-5) run_case case-5 case_5 ;;
    case-6) run_case case-6 case_6 ;;
    case-7) run_case case-7 case_7 ;;
    case-8) run_case case-8 case_8 ;;
    case-9) run_case case-9 case_9 ;;
    case-10) run_case case-10 case_10 ;;
    case-11) run_case case-11 case_11 ;;
    case-12) run_case case-12 case_12 ;;
    case-13) run_case case-13 case_13 ;;
    case-14) run_case case-14 case_14 ;;
    case-15) run_case case-15 case_15 ;;
    case-16) run_case case-16 case_16 ;;
    case-17) run_case case-17 case_17 ;;
    case-18) run_case case-18 case_18 ;;
    case-19) run_case case-19 case_19 ;;
    case-20) run_case case-20 case_20 ;;
    case-21) run_case case-21 case_21 ;;
    case-22) run_case case-22 case_22 ;;
    case-23) run_case case-23 case_23 ;;
    case-24) run_case case-24 case_24 ;;
    case-25) run_case case-25 case_25 ;;
    case-26) run_case case-26 case_26 ;;
    case-27) run_case case-27 case_27 ;;
    case-28) run_case case-28 case_28 ;;
    case-29) run_case case-29 case_29 ;;
    case-30) run_case case-30 case_30 ;;
    case-31) run_case case-31 case_31 ;;
    case-32) run_case case-32 case_32 ;;
    case-33) run_case case-33 case_33 ;;
    case-34) run_case case-34 case_34 ;;
    case-35) run_case case-35 case_35 ;;
    case-36) run_case case-36 case_36 ;;
    case-37) run_case case-37 case_37 ;;
    case-38) run_case case-38 case_38 ;;
    case-39) run_case case-39 case_39 ;;
    case-40) run_case case-40 case_40 ;;
    case-41) run_case case-41 case_41 ;;
    *) printf 'unknown case: %s (try --list)\n' "$name" >&2; exit 2 ;;
  esac
done

printf -- '---\n'
if [ "$CASES_FAILED" -eq 0 ]; then
  printf '%d case(s), all passed\n' "$CASES_RUN"
  exit 0
fi
printf '%d case(s), %d failed\n' "$CASES_RUN" "$CASES_FAILED"
exit 1
