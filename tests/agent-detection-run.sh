#!/usr/bin/env bash
# tests/agent-detection-run.sh — the shipped mcode detection manifest, checked.
#
# Plain bash wrapper around python3/tomllib, like the other suites. Discovered by
# the CI `tests/*run.sh` glob, so it runs on every push.
#
# Three things are checked, and each has bitten this repo before:
#
#   1. The manifest parses as TOML and uses the SAME schema shape as the manifests
#      that herdr actually ships. A file that parses but invents a key is not
#      "ready for upstream", it is broken.
#   2. Every rule that claims a state matches the capture that demonstrates it.
#      A rule with no evidence is the class of lie issue #7 refused to write.
#   3. Every rule does NOT fire on the captures that show the other states. A
#      working rule that also matches a finished turn reports "working" forever,
#      which is worse than reporting nothing.

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"
MANIFEST="$repo/agent-detection/minimax-code.toml"
FIX="$here/fixtures/agent-detection"

CASES_RUN=0
CASES_FAILED=0
CURRENT_CASE=""
broke=0
note() { broke=1; printf '        %s\n' "$*"; }
ok() { printf 'ok    %s\n' "$CURRENT_CASE"; CASES_RUN=$((CASES_RUN+1)); }
bad() { printf 'FAIL  %s\n' "$CURRENT_CASE"; printf '        %s\n' "$*"; CASES_RUN=$((CASES_RUN+1)); CASES_FAILED=$((CASES_FAILED+1)); }
run_case() { CURRENT_CASE="$1"; }

if ! command -v python3 >/dev/null 2>&1; then
  printf 'FAIL  preflight: python3 is required to parse TOML and is not on PATH\n' >&2
  exit 2
fi
if [ ! -f "$MANIFEST" ]; then
  printf 'FAIL  preflight: %s is missing\n' "$MANIFEST" >&2
  exit 2
fi
for f in working.txt idle.txt idle-after-working.txt; do
  [ -f "$FIX/$f" ] || { printf 'FAIL  preflight: evidence %s is missing; a rule with no capture is not shippable\n' "$f" >&2; exit 2; }
done

# The checker's exit status is the suite's verdict. Ignoring it is how this file
# first shipped a "3 case(s), all passed" on top of a python traceback - a green
# that had never seen red, produced by the very harness meant to prevent it.
# A crash in the checker must fail the suite, loudly.
if ! python3 "$here/agent-detection-check.py" "$MANIFEST" "$FIX"; then
  note "agent-detection-check.py reported a failure (or crashed) - see above"
  CASES_FAILED=$((CASES_FAILED + 1))
fi
CASES_RUN=$((CASES_RUN + 3))

printf -- '---\n'
if [ "$CASES_FAILED" -eq 0 ]; then
  printf '%d case(s), all passed\n' "$CASES_RUN"
  exit 0
fi
printf '%d case(s), %d failed\n' "$CASES_RUN" "$CASES_FAILED"
exit 1
