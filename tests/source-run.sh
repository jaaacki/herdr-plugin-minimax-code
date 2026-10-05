#!/usr/bin/env bash
# tests/source-run.sh — every reporter declares ONE --source namespace (issue #47).
#
# Plain bash, like the other suites. Discovered by the CI `tests/*run.sh` glob.
#
#   ./tests/source-run.sh          run every case
#   ./tests/source-run.sh --list   list case names
#
# ---- WHY THIS EXISTS ---------------------------------------------------------
# Three reporters register the same agent with herdr, and herdr uses --source to
# tell reporters apart. They once declared three different values:
#
#   bin/mcode-plugin.sh   herdr:minimax-code
#   bin/mcode-session.sh  jaaacki.minimax-code   (the plugin id)
#   bin/mcode-watch.sh    minimax-code           (bare)
#
# The convention is herdr's own `herdr:<agent>`; the Claude integration hook uses
# it, and on the development machine wZ:p3 reports source=herdr:claude.
#
# The architect's rule is that this is a SET: all three, or none. A set with no
# enforcement is a set that silently drifts back, and nobody notices until two
# agents appear for one pane. This suite is the enforcement. It reads the other
# members' files; it does not edit them.
#
# It is a RED-by-default design in one respect: if any reporter drifts, this
# suite goes red rather than warning. A green check that cannot fail is the exact
# failure mode this repo exists to end, so there is deliberately no "warn only"
# mode to fall back on.

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"

# The one namespace all three must declare.
EXPECTED_SOURCE="herdr:minimax-code"

# The reporters. A new reporter must be added here, or it escapes the
# check — which is the intended failure mode, since a silent fourth reporter is
# exactly the problem this suite exists to catch.
#
# mcode-plugin/hooks/herdr-bootstrap.sh joined this list in issue #118. It is a
# REPORTER in the full sense: it calls `pane report-agent` with this namespace,
# and it is the only path by which a hand-started mcode becomes visible at all.
# Leaving it out would have been the exact silent-fourth-reporter failure this
# suite was written to catch, committed by the person adding the fourth.
REPORTERS=(
  bin/mcode-plugin.sh
  bin/mcode-session.sh
  bin/mcode-watch.sh
  mcode-plugin/hooks/herdr-bootstrap.sh
)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcode-source-tests.XXXXXX")"
OUT="$WORK/out"
trap '/bin/rm -rf "$WORK"' EXIT

CASES_RUN=0
CASES_FAILED=0
CURRENT_CASE=""
broke=0
note() { broke=1; printf '        %s\n' "$*"; }

# --- extraction ---------------------------------------------------------------
# Print the agent-registration --source defaults a file declares, one per line.
#
# Deliberately narrow. It matches only the three DECLARATION forms, not every
# `--source` on every line, because two legitimate uses must not be mistaken for
# a drifting agent namespace:
#
#   * `pane read ... --source detection` in the watcher, which is a screen-read
#     source and a different concept entirely;
#   * `--source "$AGENT_SOURCE"`, which is indirection rather than a value.
#
#   1. AGENT_SOURCE="${VAR:-default}"   the overridable form (session)
#   2. AGENT_SOURCE="literal"            the non-overridable form (watch)
#   3. ...pane report-agent... --source literal   the inline form (plugin)
#
# Form 3 is anchored on the report-agent verb so `pane read` cannot match.
declared_sources() { # declared_sources <file>
  local file="$1"
  [ -f "$file" ] || return 0
  {
    grep -oE 'AGENT_SOURCE="\$\{[A-Z_]+:-[A-Za-z0-9:_.-]+\}"' "$file" 2>/dev/null \
      | grep -oE ':-[A-Za-z0-9:_.-]+\}' | sed 's/^:-//; s/}$//'
    grep -oE 'AGENT_SOURCE="[A-Za-z0-9:_.-]+"' "$file" 2>/dev/null \
      | sed 's/^AGENT_SOURCE="//; s/"$//'
    grep -oE 'pane report-agent[^|]*--source [A-Za-z0-9:_.-]+' "$file" 2>/dev/null \
      | grep -oE -- '--source [A-Za-z0-9:_.-]+' | sed 's/^--source //'
  } | sed '/^$/d' | sort -u
}

# --- cases -------------------------------------------------------------------
# 1. Each reporter declares the expected namespace. Reported per file, because
#    "something is wrong" is not actionable when three files are involved.
case_each_reporter_declares_the_expected_source() {
  local rel values count
  for rel in "${REPORTERS[@]}"; do
    if [ ! -f "$repo/$rel" ]; then
      note "reporter missing: $rel"
      continue
    fi
    values="$(declared_sources "$repo/$rel")"
    if [ -z "$values" ]; then
      # Not a pass. A file we cannot read a declaration from is a file whose
      # namespace is unverified, and treating that as green is the whole bug.
      note "$rel declares no agent-registration --source; the check cannot verify it"
      continue
    fi
    count="$(printf '%s\n' "$values" | wc -l | tr -d ' ')"
    if [ "$count" -ne 1 ]; then
      note "$rel declares $count different --source values; expected exactly one:"
      printf '%s\n' "$values" | sed 's/^/          /'
      continue
    fi
    if [ "$values" != "$EXPECTED_SOURCE" ]; then
      note "$rel declares --source '$values', expected '$EXPECTED_SOURCE'"
    fi
  done
}

# 2. The cross-check, independent of EXPECTED_SOURCE. This is the one that would
#    have caught the original defect even if the convention itself were
#    renegotiated: the three files must agree with EACH OTHER. Asserting only
#    against a hard-coded constant would let a change of convention silently
#    break every reporter at once.
case_all_reporters_agree_with_each_other() {
  local rel values first="" owner=""
  for rel in "${REPORTERS[@]}"; do
    [ -f "$repo/$rel" ] || continue
    values="$(declared_sources "$repo/$rel" | head -1)"
    [ -n "$values" ] || continue
    if [ -z "$first" ]; then
      first="$values"
      owner="$rel"
    elif [ "$values" != "$first" ]; then
      note "$rel declares --source '$values' but $owner declares '$first';"
      note "herdr is being told two reporter identities for one agent"
    fi
  done
  if [ -z "$first" ]; then
    note "no reporter declared a readable --source; nothing was actually checked"
  fi
}

# 3. The guard must not be a blunt "no other --source anywhere" rule. The
#    watcher's `pane read --source detection` is a screen-read source, not an
#    agent namespace, and is correct. If this case ever goes red, the guard has
#    become too strict and is about to reject valid code.
case_screen_read_source_is_not_an_agent_namespace() {
  local rel file
  for rel in "${REPORTERS[@]}"; do
    file="$repo/$rel"
    [ -f "$file" ] || continue
    # `pane read ... --source detection` must NOT be reported as a declared
    # agent namespace.
    if declared_sources "$file" | grep -qx 'detection'; then
      note "$rel: the guard is reading \`pane read --source detection\` as an agent namespace"
    fi
  done
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

CASES=(
  each-reporter-declares-the-expected-source:case_each_reporter_declares_the_expected_source
  all-reporters-agree-with-each-other:case_all_reporters_agree_with_each_other
  screen-read-source-is-not-an-agent-namespace:case_screen_read_source_is_not_an_agent_namespace
)

if [ "${1:-}" = "--list" ]; then
  for pair in "${CASES[@]}"; do printf '%s\n' "${pair%%:*}"; done
  exit 0
fi

for pair in "${CASES[@]}"; do run_case "${pair%%:*}" "${pair#*:}"; done

printf -- '---\n'
if [ "$CASES_FAILED" -eq 0 ]; then
  printf '%d case(s), all passed\n' "$CASES_RUN"
  exit 0
fi
printf '%d case(s), %d failed\n' "$CASES_RUN" "$CASES_FAILED"
exit 1
