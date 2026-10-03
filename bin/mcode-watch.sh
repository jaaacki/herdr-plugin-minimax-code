#!/usr/bin/env bash
# mcode-watch.sh - report a pane's mcode session state to herdr, on transitions only.
#
# Self-reported state goes stale: a session that reported `idle` stays `idle` in
# herdr while it is actually working, which is worse than not reporting at all.
# So this watcher reads the screen herdr's own detection would read, classifies
# it, and reports only when the classification changes.
#
# Usage:  mcode-watch.sh <PANE_ID> [--interval SECONDS] [--lines N] [--once]
#
# The watcher is a FOREGROUND process. That is the whole leak story: it is the
# foreground job of whichever pane ran it, so closing that pane or pressing
# Ctrl-C ends it. Nothing is detached, nothing is spawned per mcode pane, and
# there is no pidfile to go stale. See "Interface" in the PR body for why this
# was chosen over launching from cmd_start.
#
# Deliberately NOT guessing: `blocked` is never reported. See BLOCKED below.
#
# bash 3.2 compatible: no [[ ]], no mapfile, no declare -A, no ${var^^}.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
AGENT_LABEL="mcode"
AGENT_SOURCE="minimax-code"

INTERVAL=2
LINES=40
ONCE=0
MAX_POLLS=0

die() { printf 'mcode-watch: %s\n' "$*" >&2; exit 1; }

usage() {
  printf 'usage: %s <PANE_ID> [--interval SECONDS] [--lines N] [--max-polls N] [--once]\n' "${0##*/}" >&2
}

# --- arguments ---------------------------------------------------------------

PANE_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --interval) [ "$#" -ge 2 ] || die "--interval needs a value"; INTERVAL="$2"; shift 2 ;;
    --lines)    [ "$#" -ge 2 ] || die "--lines needs a value";    LINES="$2";    shift 2 ;;
    --max-polls) [ "$#" -ge 2 ] || die "--max-polls needs a value"; MAX_POLLS="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         usage; die "unknown option: $1" ;;
    *)          if [ -n "$PANE_ID" ]; then usage; die "unexpected argument: $1"; fi
                PANE_ID="$1"; shift ;;
  esac
done
[ -n "$PANE_ID" ] || { usage; die "a PANE_ID is required"; }
case "$INTERVAL" in
  ''|*[!0-9]*) die "--interval must be a whole number of seconds" ;;
esac
case "$LINES" in
  ''|*[!0-9]*) die "--lines must be a whole number" ;;
esac
case "$MAX_POLLS" in
  ''|*[!0-9]*) die "--max-polls must be a whole number (0 = no limit)" ;;
esac
[ "$INTERVAL" -ge 1 ] || die "--interval must be at least 1"

# --- classification ----------------------------------------------------------
#
# Every marker below was read out of a real captured snapshot; see
# tests/fixtures/detection/ and the provenance table in that directory's README.
# Markers are matched with a fixed-string grep, not a regex, because they
# contain characters that are regex metacharacters in some spellings.

# Markers that only appear while mcode is doing something. Any one is decisive.
#
# Each was checked against all three captured snapshots, not just the working one.
# Two candidates were REJECTED on that evidence:
#
#   "tok/s"  appears in the post-turn snapshot too, inside
#            "Completed in 3s - 667 tok/s" - a turn that has already finished.
#            Using it would report a finished session as working.
#   "Ask Mcode to do anything" is the input placeholder, present in every
#            snapshot including idle. Present everywhere means it discriminates
#            nothing.
#
# These are not iterated in a loop; see classify() for why that matters.
WORKING_MARKERS='Esc stop
Ctrl+O details
Ctrl+T expand'

# The braille spinner frames mcode cycles while busy.
SPINNER='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠭⠫'

# Markers that only appear while mcode is NOT working. There are two distinct
# resting shapes, and both are idle - a watcher that only knew the first would
# report `unknown` for every ordinary session that has completed a turn, which
# is most of the time:
#
#   fresh session  "Start - @ file or Plugin", "● Ready"
#   after a turn   "Completed in 3s", "Message - Enter send" (the composer)
IDLE_MARKERS='Start · @
● Ready
Completed in
Message · Enter send'

has_marker() { # has_marker <text> <marker>
  printf '%s\n' "$1" | grep -qF -- "$2"
}

# Only the tail of the snapshot is the live status area. The rest is scrollback,
# and a session that was working a moment ago has its spinner and `Esc stop` line
# still sitting in that scrollback. Matching the whole snapshot would therefore
# report `working` forever after the session finished. The status strip, the
# input box and the status line all sit within the last few lines.
TAIL_LINES=8
snapshot_tail() { # snapshot_tail <snapshot>
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n "$TAIL_LINES"
}

# classify SNAPSHOT -> working|idle|unknown
#
# Each check is written out longhand rather than looped over a newline-separated
# list. A loop would word-split on spaces and turn "Esc stop" into two markers,
# "Esc" and "stop" - and "Esc" occurs in mcode's own changelog prose, which would
# classify an idle session as working. That is not hypothetical: it is exactly
# what the first version of this function did, and what caught it.
classify() {
  local snap
  snap="$(snapshot_tail "$1")"

  # A pane that is still starting up yields an empty detection snapshot. That is
  # NOT an idle session, and reporting it as `idle` would be the exact stale-lie
  # this watcher exists to prevent. Report `unknown` until there is something to
  # read.
  if [ -z "$(printf '%s\n' "$snap" | tr -d '[:space:]')" ]; then
    printf 'unknown\n'
    return 0
  fi

  if has_marker "$snap" "Esc stop"        ||
     has_marker "$snap" "Ctrl+O details"  ||
     has_marker "$snap" "Ctrl+T expand"   ||
     has_marker "$snap" "$SPINNER"; then
    printf 'working\n'
    return 0
  fi

  if has_marker "$snap" "Start · @"           ||
     has_marker "$snap" "● Ready"             ||
     has_marker "$snap" "Completed in"        ||
     has_marker "$snap" "Message · Enter send"; then
    printf 'idle\n'
    return 0
  fi

  # Nothing matched. `blocked` is deliberately not guessed here - see BLOCKED.
  printf 'unknown\n'
}

# BLOCKED
# -------
# `blocked` means herdr recognised an approval or question UI. No such snapshot
# was ever captured: mcode 0.6.2 runs these sessions at `Full access`, where no
# permission prompt is raised, and the permission level is a session setting
# rather than a CLI flag, so no snapshot of that state exists to classify.
# A `blocked` rule that never fires would be a lie in the code, so this watcher
# never emits `blocked` and never claims to. Revisit when a real prompt can be
# produced and captured.

# --- herdr plumbing ----------------------------------------------------------

report_state() { # report_state <state>
  "$HERDR" pane report-agent "$PANE_ID" \
    --source "$AGENT_SOURCE" \
    --agent "$AGENT_LABEL" \
    --state "$1"
}

# Hand lifecycle authority back so herdr's own screen detection can resume.
release() {
  "$HERDR" pane release-agent "$PANE_ID" \
    --source "$AGENT_SOURCE" \
    --agent "$AGENT_LABEL" >/dev/null 2>&1 || true
}

pane_alive() {
  "$HERDR" pane get "$PANE_ID" >/dev/null 2>&1
}

read_detection() {
  "$HERDR" pane read "$PANE_ID" --source detection --lines "$LINES" 2>/dev/null
}

# --- main loop ---------------------------------------------------------------

trap 'release; exit 0' INT TERM
trap 'release' EXIT

# Baseline: classify once and report it, so herdr is never left at a stale state
# inherited from before the watcher started. Only then do we start watching for
# change.
if ! pane_alive; then
  die "pane $PANE_ID does not exist; nothing to watch"
fi

last=""
polls=0
while :; do
  polls=$(( polls + 1 ))

  if ! pane_alive; then
    # The watched pane is gone. Stop; do not report a state for a pane that no
    # longer exists.
    release
    exit 0
  fi

  snap="$(read_detection || true)"
  state="$(classify "$snap")"

  # Transition-only. An unchanged snapshot must produce no herdr call at all -
  # reporting on every poll is what makes a self-reported state worse than
  # nothing.
  if [ "$state" != "$last" ]; then
    if ! report_state "$state"; then
      printf 'mcode-watch: herdr refused the %s report for pane %s; continuing\n' \
        "$state" "$PANE_ID" >&2
    fi
    last="$state"
  fi

  if [ "$ONCE" -eq 1 ]; then
    break
  fi
  if [ "$MAX_POLLS" -gt 0 ] && [ "$polls" -ge "$MAX_POLLS" ]; then
    break
  fi

  sleep "$INTERVAL"
done
