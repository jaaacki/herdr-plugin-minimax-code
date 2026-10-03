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
NEW_PANE="wZ:p2"

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
  export FAKE_HERDR_NEW_PANE="$NEW_PANE"
  export FAKE_HERDR_CWD="$CASE_DIR/project"
  export HERDR_BIN_PATH="$FAKE_HERDR"
  export PATH="$CASE_DIR/bin:$BASE_PATH"
  # Neutralise ambient herdr context so a case only ever sees what it sets.
  unset HERDR_PLUGIN_EVENT_JSON HERDR_PLUGIN_CONTEXT_JSON
  unset FAKE_HERDR_FAIL FAKE_HERDR_SPLIT_NO_PANE_ID
}

run_entrypoint() {
  "$PLUGIN_BIN" start >"$STDOUT_FILE" 2>"$STDERR_FILE"
  RC=$?
}

# What the stub will report. This mirrors the precedence documented in
# tests/fake-herdr, deliberately and in the same place, so the two cannot drift:
#
#   cwd, source pane   Knob wins. The tests own these dimensions, and the stub
#                      bypasses the fixture when the knob is set.
#   new pane id        The captured fixture always wins, knob or not, because
#                      that value must never be faked. It is queried out of the
#                      fixture rather than hard-coded, so a re-capture cannot
#                      silently invalidate the expectation — and pinning it to
#                      `.result.pane.pane_id` asserts the documented extraction
#                      path. An implementation reading `.result.pane_id`, which
#                      resolves to `null` in the real capture, fails here.
expected_cwd() { printf '%s' "$FAKE_HERDR_CWD"; }
expected_current_pane() { printf '%s' "$FAKE_HERDR_SRC_PANE"; }

expected_new_pane() { # expected_new_pane
  local file="$FAKE_HERDR_FIXTURES/pane-split.json"
  local value
  if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
    value="$(jq -r '.result.pane.pane_id // empty' <"$file" 2>/dev/null)" || value=""
    if [ -n "$value" ] && [ "$value" != "null" ]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  printf '%s' "$FAKE_HERDR_NEW_PANE"
}

# The `pane split` invocation, exactly as the entrypoint issues it. `--no-focus`
# is part of the sequence, not an optional extra: B's head 368e48e decided it
# deliberately (issue #4's spec predates that decision and is silent on it), so
# the expectation follows the implementation and the spec gap is reported as a
# finding rather than papered over here.
expected_split_line() { # expected_split_line <source-pane>
  printf 'pane\tsplit\t%s\t--direction\tright\t--no-focus\t--cwd\t%s' "$1" "$(expected_cwd)"
}

# The full expected invocation log for a launch that reaches `pane split`.
# Passing an empty second argument omits the `pane run` line — that is how cases
# 3 and 4 assert the launcher never typed into a pane, which is the property
# they exist to protect. An exit-code-only assertion would not: a script that
# called `pane run` and failed afterwards would still exit non-zero.
expected_sequence() { # expected_sequence <source-pane> <mcode-abs|"">
  local src="$1"
  local mcode="$2"
  local lines
  lines="$(printf 'pane\tget\t%s\n%s' "$src" "$(expected_split_line "$src")")"
  if [ -n "$mcode" ]; then
    lines="$(printf '%s\npane\trun\t%s\t%s' "$lines" "$(expected_new_pane)" "$mcode")"
  fi
  printf '%s' "$lines"
}

# Case 2's sequence: `pane current` first, to resolve the source pane.
expected_sequence_via_current() { # expected_sequence_via_current <mcode-abs|"">
  local mcode="$1"
  local src rest
  src="$(expected_current_pane)"
  rest="$(expected_sequence "$src" "$mcode")"
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

  assert_log_exactly "$(expected_sequence "$SRC_PANE" "$CASE_DIR/bin/mcode")"
}

# --- case 2 ------------------------------------------------------------------
# HERDR_PANE_ID unset: the entrypoint must fall back to `pane current` to resolve
# the source pane, then continue exactly as in case 1.
case_2() {
  setup_case
  unset HERDR_PANE_ID

  run_entrypoint
  assert_rc_zero "$RC"

  assert_log_exactly "$(expected_sequence_via_current "$CASE_DIR/bin/mcode")"
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
  export FAKE_HERDR_SPLIT_NO_PANE_ID=1

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

ALL_CASES=(case-1 case-2 case-3 case-4 case-5 case-6)

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
