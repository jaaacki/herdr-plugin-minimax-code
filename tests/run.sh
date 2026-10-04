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
  # Neutralise ambient herdr context so a case only ever sees what it sets.
  unset HERDR_PLUGIN_EVENT_JSON HERDR_PLUGIN_CONTEXT_JSON
  unset FAKE_HERDR_FAIL FAKE_HERDR_FAULT
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
  printf '%s' "$lines"
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
stage_plugin() { # stage_plugin [none|fake]
  local root="$CASE_DIR/plugin"
  mkdir -p "$root/bin"
  cp "$PLUGIN_BIN" "$root/bin/mcode-plugin.sh"
  chmod +x "$root/bin/mcode-plugin.sh"
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
  # And it must be honest about what it is telling them.
  assert_stderr_mentions "not tracked"
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

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  # The launch is still reported as the success it is. That is the entire point
  # of the best-effort policy: the user asked for a pane and got a working one.
  assert_stderr_mentions "started $CASE_DIR/bin/mcode in pane $newpane"
  assert_stderr_mentions "state watcher"
  assert_stderr_mentions "The launch itself succeeded"
  # No run command for a file that does not exist: that would be worse than
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

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  if [ -e "$root/watcher-ran" ]; then
    note "cmd_start started the state watcher $(wc -l <"$root/watcher-ran" | tr -d ' ') time(s); it must be left for the operator to run"
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

  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  # Reset the record so the second launch's count cannot hide inside the first.
  : >"$FAKE_HERDR_LOG"
  run_entrypoint_at "$copy"
  assert_rc_zero "$RC"
  if [ -e "$root/watcher-ran" ]; then
    note "two launches started the state watcher $(wc -l <"$root/watcher-ran" | tr -d ' ') time(s); it must be 0"
  fi
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

  run_entrypoint
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
  printf '#!/bin/sh\nexit 0\n' >"$CASE_DIR/bin/mcode-session.sh"
  chmod +x "$CASE_DIR/bin/mcode-session.sh"
  export FAKE_HERDR_FAIL="pane report-agent-session:1"

  run_entrypoint
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
  # MCODE_WATCH_BIN is the seam. Same reasoning as MCODE_BIN_PATH in
  # bin/mcode-drive.sh: the real watcher polls a real pane on a timer, so a test
  # that started it would leave a process behind and assert on timing.
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/watcher-ran"\n' "$CASE_DIR" \
    >"$CASE_DIR/bin/mcode-watch.sh"
  chmod +x "$CASE_DIR/bin/mcode-watch.sh"
  export MCODE_WATCH_BIN="$CASE_DIR/bin/mcode-watch.sh"

  run_entrypoint
  assert_rc_zero "$RC"
  if [ ! -f "$CASE_DIR/watcher-ran" ]; then
    note "the watcher was never started; a launched pane reports no state" \
         "until somebody runs it by hand"
    return
  fi

  # The pane it watches must be the NEW pane, not the source pane the user is
  # typing in. A watcher pointed at the wrong pane is worse than none: it polls
  # somebody's window and reports state that is not the launch's.
  assert_count "$CASE_DIR/watcher-ran" "$(expected_new_pane)" 1 "watcher argv"
}

case_27() { # #75: MCODE_WATCH_AUTOSTART=0 opts out entirely
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/watcher-ran"\n' "$CASE_DIR" \
    >"$CASE_DIR/bin/mcode-watch.sh"
  chmod +x "$CASE_DIR/bin/mcode-watch.sh"
  export MCODE_WATCH_BIN="$CASE_DIR/bin/mcode-watch.sh"

  # CONTROL FIRST. An off-switch test that only asserts "did not run" passes
  # today, against code that never runs the watcher for ANY reason - so it would
  # be green while testing nothing. Running the same launch with the switch
  # absent proves the watcher really does start, which is what makes the
  # assertion with the switch present mean something.
  unset MCODE_WATCH_AUTOSTART
  run_entrypoint
  if [ ! -f "$CASE_DIR/watcher-ran" ]; then
    note "control: the watcher did not run even with autostart enabled, so" \
         "'MCODE_WATCH_AUTOSTART=0 did not run it' would be vacuous"
    return
  fi

  export MCODE_WATCH_AUTOSTART=0
  run_entrypoint
  assert_rc_zero "$RC"
  # The opt-out has to be a real off switch, not a suggestion. An operator who
  # sets it to 0 is asking not to have a background process appear.
  if [ "$(wc -l <"$CASE_DIR/watcher-ran" 2>/dev/null || printf 0)" -gt 1 ]; then
    note "MCODE_WATCH_AUTOSTART=0 and the watcher ran again anyway"
    sed 's/^/          /' "$CASE_DIR/watcher-ran"
  fi
}

case_28() { # #75: a watcher that fails to start is a warning, not a failure
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  # Logs AND fails. A stub that only exits 1 leaves the attempt invisible, and
  # the case would then pass against code that never starts the watcher at all.
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/watcher-ran"\nexit 1\n' "$CASE_DIR" \
    >"$CASE_DIR/bin/mcode-watch.sh"
  chmod +x "$CASE_DIR/bin/mcode-watch.sh"
  export MCODE_WATCH_BIN="$CASE_DIR/bin/mcode-watch.sh"

  run_entrypoint
  assert_rc_zero "$RC"
  if [ ! -f "$CASE_DIR/watcher-ran" ]; then
    note "the failing watcher was never invoked; this case would pass" \
         "vacuously against a launcher that never starts one"
    return
  fi
  assert_stderr_mentions "$(expected_new_pane)"
  # The pane is still running mcode. State tracking is an add-on to a launch
  # that already worked.
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
#     WHY ONE LAUNCH AND NOT TWO: the natural case is "launch twice, assert the
#     second is mcode-2", but tests/fake-herdr's `agent list` is a fixed response
#     per invocation and does not evolve between launches, so the second launch
#     would be handed the same name again. Making it stateful is a change to
#     tests/fake-herdr, which is not my file this round. This case gets the same
#     guarantee from one launch: the fault below makes the assigned name
#     `mcode-3`, so ANY hardcoded literal - `mcode` or anything else - fails it,
#     and a correct implementation passes. Same defect, no stub change needed.
case_29() { # #75: the watcher inherits the label the launch chose, not a literal
  setup_case
  export HERDR_PANE_ID="$SRC_PANE"
  # Logs argv AND the label the watcher would report under, so the assertion can
  # see either mechanism. The stub exits 0 so the launch's own exit is untouched.
  printf '#!/bin/sh\nprintf "%%s\\t%%s\\n" "$*" "${MCODE_AGENT_LABEL:-}" >>"%s/watcher-ran"\n' "$CASE_DIR" \
    >"$CASE_DIR/bin/mcode-watch.sh"
  chmod +x "$CASE_DIR/bin/mcode-watch.sh"
  export MCODE_WATCH_BIN="$CASE_DIR/bin/mcode-watch.sh"
  # The name the launcher will pick is mcode-3, not mcode.
  export FAKE_HERDR_FAULT="agent-names-taken"

  run_entrypoint
  assert_rc_zero "$RC"
  if [ ! -f "$CASE_DIR/watcher-ran" ]; then
    note "the watcher was never started; nothing to assert a label on"
    return
  fi
  # The label the launch established, and the name it assigned.
  local want_name want_label
  want_name="$(expected_agent_name)"
  want_label="${MCODE_AGENT_LABEL:-$want_name}"
  if ! grep -qF "$want_label" "$CASE_DIR/watcher-ran"; then
    note "the watcher was started without the label the launch chose ('${want_label}');" \\
         "a hardcoded literal reports state under the wrong agent name and herdr" \\
         "silently fails to attach it"
    sed 's/^/          /' "$CASE_DIR/watcher-ran"
  fi
  # Stated explicitly, because this is the finding: a watcher that hardcodes
  # `mcode` looks correct on the very first pane.
  if grep -qF "mcode"$'\t' "$CASE_DIR/watcher-ran"; then
    note "the watcher was given the bare label 'mcode' while the pane was" \\
         "registered as '${want_name}'"
  fi
}

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

ALL_CASES=(case-1 case-2 case-3 case-4 case-5 case-6 case-7 case-8 case-9 case-10 case-11 case-12 case-13 case-14 case-15 case-16 case-17 case-18 case-19 case-20 case-21 case-22 case-23 case-24 case-25 case-26 case-27 case-28 case-29)

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
