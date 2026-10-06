#!/usr/bin/env bash
# flock-stop.sh — the member Stop hook for sparkfn/pc-tools#1699 item 1.
#
# A flock member must not end a turn silently. This hook asks
# `pc-tool flock hook stop` whether this turn may end, and turns its answer into
# the decision mcode reads off the hook's stdout.
#
# ── THE CONTRACT, AND WHERE EACH HALF COMES FROM ────────────────────────────
#
# mcode side, verified against the 0.6.2 bundle on this machine
# (releases/0.6.2/lib/node_modules/@minimax-ai/code), not from memory:
#
#   * The Stop payload on stdin carries `stop_hook_active` and
#     `last_assistant_message`; mcode's own payload validator requires both.
#   * The decision object accepts `decision` and `reason`
#     (plus `hookSpecificOutput` in CLAUDE/MINIMAX source format).
#   * A top-level `decision` must be the STRING "block" or absent — anything
#     else is discarded, so an envelope that happened to parse would silently
#     not block.
#
# pc-tool side, from sparkfn/pc-tools#1710 (head bcdf1d6b):
#
#   * `flock hook stop` is TWO WORDS.
#   * It reads the Stop payload from STDIN (`FLOCK_STOP_INPUT` is a test seam
#     that overrides it) and returns the block in the DECISION, never in the
#     exit code. It exits 0 either way.
#   * It answers `decision: "end"` when `stop_hook_active` is true, when the
#     flock is closed, when there is no mail, and when the session is not a
#     flock member at all.
#
# ── WHY THIS FAILS OPEN, ALWAYS ─────────────────────────────────────────────
#
# Every failure path below prints nothing and exits 0. A Stop hook that wedges
# an agent — refusing to end a turn because pc-tool is missing, or because its
# JSON changed shape — does not fail the member, it traps it. A missed nudge
# costs one round trip; a wedged agent costs the whole session. The member also
# has the tick and `flock metrics` behind this, so failing open degrades to the
# state we had before this hook existed, which is the correct direction.
#
# `set -uo pipefail`, not `-e`: an unset variable must not kill the hook before
# the fail-open path runs.

set -uo pipefail

log() { printf 'flock-stop: %s\n' "$*" >&2; }

# mcode hands a hook a JSON payload on stdin. Read it whole; the Stop payload is
# small, and a partial read would hand `hook stop` unparseable JSON.
payload="$(cat 2>/dev/null || true)"

if [ -z "$payload" ]; then
  # No payload means we cannot prove this is a Stop event at all. Standing the
  # hook down is the only safe reading: pc-tool treats unreadable input as
  # "stand down" too, and guessing otherwise could block on a malformed call.
  exit 0
fi

PC_TOOL="${PC_TOOL:-pc-tool}"
if ! command -v "$PC_TOOL" >/dev/null 2>&1; then
  log "pc-tool not on PATH; standing down"
  exit 0
fi

# `hook stop` never signals its answer by exit code, and a non-zero exit here is
# not ours to interpret — fail open rather than guess at a block.
if ! out="$(printf '%s' "$payload" | "$PC_TOOL" flock hook stop 2>/dev/null)"; then
  log "pc-tool flock hook stop exited non-zero; standing down"
  exit 0
fi

[ -n "$out" ] || exit 0

# Which shape is this? `.decision` being a string is the flat shape; an object is
# the envelope. Anything unparseable leaves both unset, which stands down.
shape=""
decision_a=""; reason_a=""; decision_b=""; reason_b=""
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
  decision_a="$(printf '%s' "$out" | jq -r 'if (.decision|type)=="string" then .decision else empty end' 2>/dev/null || true)"
  reason_a="$(printf '%s' "$out" | jq -r 'if (.decision|type)=="string" then (.reason // empty) else empty end' 2>/dev/null || true)"
  decision_b="$(printf '%s' "$out" | jq -r '.decision.decision // empty' 2>/dev/null || true)"
  reason_b="$(printf '%s' "$out" | jq -r '.decision.reason // empty' 2>/dev/null || true)"
  if [ -n "$decision_a" ]; then shape=flat
  elif [ -n "$decision_b" ]; then shape=envelope
  else
    log "pc-tool printed JSON in a shape this hook does not recognise; standing down"
  fi
fi

# pc-tool prints a JSON ENVELOPE whose `decision` is a nested object:
#   {"hook":"stop","blocked":true,"reason":"...","decision":{"decision":"block",...}}
# mcode requires `decision` to be the string "block", so the envelope has to be
# unwrapped. jq does this correctly; without jq we do NOT hand-roll a JSON parse
# in bash, because a subtly wrong parse here produces either a permanent block
# or a silently swallowed nudge, and neither is worth the bytes.
if ! command -v jq >/dev/null 2>&1; then
  log "jq not on PATH; cannot unwrap the decision safely, standing down"
  exit 0
fi

# BOTH shapes are accepted, deliberately.
#
#   flat     {"decision":"block","reason":"..."}          — sparkfn/pc-tools#1710
#                                                           after its flat-shape change
#   envelope {"hook":"stop","decision":{"decision":...}}  — #1710 today
#
# Accepting only the flat shape would make this hook a hard dependency on a
# merge: between #1710 changing and this hook shipping there is a window where
# machines run a hook that no longer understands its output and silently stop
# blocking, which is the exact failure this hook exists to prevent. Accepting
# both means it is correct on either side of that merge.
#
# Anything else — a shape neither side documents — STANDS THE HOOK DOWN. A
# future #1710 must not be able to wedge every member by changing its output.
decision=""
reason=""
case "$shape" in
  flat)     decision="$decision_a"; reason="$reason_a" ;;
  envelope) decision="$decision_b"; reason="$reason_b" ;;
esac
[ "$decision" = "block" ] || exit 0

# mcode discards a block with no reason (its validator requires one), so a
# reason-less block is not a block. Standing down is better than emitting a
# decision mcode will silently drop.
if [ -z "$reason" ]; then
  log "pc-tool asked to block without a reason; standing down rather than emitting an unusable decision"
  exit 0
fi

# jq builds and escapes this, so a reason containing quotes, newlines or a
# backslash cannot break the payload — and mcode parses the whole line as JSON,
# so anything appended after it would invalidate the decision and make the hook
# silently not block.
jq -nc --arg r "$reason" '{decision:"block", reason:$r}' 2>/dev/null || exit 0
exit 0