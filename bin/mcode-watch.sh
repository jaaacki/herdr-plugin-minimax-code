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
# HOW IT IS RUN, and how it stops.
#
# An earlier version of this header described the watcher as a plain job of
# whichever pane ran it, ended by closing that pane or by Ctrl-C. That stopped
# being true in 0.4.1 and the wording was left behind as a lie. The launcher now
# starts one watcher per mcode pane with `nohup ... &` plus `disown`
# (watcher_autostart in bin/mcode-plugin.sh, issue #75), so a watcher outlives
# the shell that started it, and closing the pane you launched from does not end
# it. A hand-run in the foreground still works, which is what the usage line
# above describes and what the traps at the bottom of this file serve.
#
# SO NOTHING IS LEAKED, by a different mechanism than the one this file used to
# claim. There is still no pidfile and still no supervisor, and lifetime is tied
# to the thing being watched rather than to a process that could outlive it or
# die silently: the watcher polls `pane get` every cycle, and when the watched
# pane is gone it exits 0 - without reporting a state for a pane that no longer
# exists, and without releasing anything. See the pane-gone path in the main
# loop. That is why detaching it needed no PID bookkeeping, reaping or orphan
# sweep. `detached-doc-matches-launcher` in tests/watch-run.sh fails if this
# paragraph and the launcher disagree again.
#
# Deliberately NOT guessing: `blocked` is never reported. See BLOCKED below.
#
# bash 3.2 compatible: no [[ ]], no mapfile, no declare -A, no ${var^^}.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
# The agent label this watcher reports under. It MUST be the name the launcher
# actually gave the pane, not a guess: the launcher picks the first free name in
# its `mcode`, `mcode-2`, `mcode-3` sequence, so the first pane is `mcode` and
# every pane after it is not.
#
# This was hard-coded to `mcode`, which was invisible while the watcher was
# opt-in (an operator running it by hand was usually looking at pane one) and
# wrong from the moment the launcher started spawning watchers itself (issue #75)
# — pane two would have been reported under a name it does not have. MCODE_WATCH_AGENT
# is how the launcher passes the real name; MCODE_AGENT_LABEL is the same knob the
# other two reporters use, kept as the middle fallback so one variable can drive
# all three; and `mcode` remains the default so a hand-run still works.
AGENT_LABEL="${MCODE_WATCH_AGENT:-${MCODE_AGENT_LABEL:-mcode}}"
# --source namespace. Must match the other two reporters - bin/mcode-plugin.sh
# and bin/mcode-session.sh - and follows herdr's own `herdr:<agent>` convention,
# which is what the Claude integration hook uses. herdr uses this to tell
# reporters apart, so three different values for one agent defeats the point.
# It also has to match for release-agent to match, though this watcher no longer
# calls that.
AGENT_SOURCE="${MCODE_AGENT_SOURCE:-herdr:minimax-code}"

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

# THE RULES
# ---------
# A flat "state|marker" table, deliberately data rather than code. The manifest
# cannot load MiniMax Code today, so these rules live in bash; keeping them in one
# declarative table means they can be lifted verbatim into a herdr screen manifest
# later without the classification being rewritten.
#
# Every marker was checked against every captured snapshot in
# tests/fixtures/detection/, not just the one it was read from. Four candidates
# were REJECTED on that evidence:
#
#   tok/s   appears inside "Completed in 3s - 667 tok/s", a turn that has
#           already FINISHED. As a working marker it would report every
#           completed session as working.
#   Ask Mcode to do anything
#           the input placeholder; present in every snapshot, so it
#           discriminates nothing.
#   Esc     on its own. mcode's own changelog prose contains "pressing Esc on an
#           empty Composer", so a bare "Esc" matches a captured IDLE screen.
#           Markers must be phrases.
#   Ctrl+T expand
#           REMOVED, and this one was shipped as a working marker first. It is
#           part of mcode's task-list footer ("... +5 more - 7/8 done - 1
#           pending - Ctrl+T expand"), which is a RESTING shape: the footer
#           stays on screen after a turn finishes, so it sits inside the tail
#           on an idle prompt that still has a task list. Working rules are
#           tested before idle, so the footer won and an idle session was
#           reported working - a live watcher lying about a finished turn.
#           Every captured WORKING screen also carries "Esc stop" on the live
#           status line, so the footer added no coverage and its removal costs
#           nothing. Banked captures and provenance:
#           tests/fixtures/detection/README.md.
#
# Order matters: working is tested before idle. mcode has more than two resting
# shapes - a fresh session ("Start - @"), a finished turn ("Completed in"), an
# idle session still showing a task list, a drafted message, and mid-flight. A
# finished turn is idle and is the common case; a watcher keyed only on the
# fresh-session shape reports unknown for nearly every session.
#
# "More than two" is a floor, not a count. Each capture batch so far has added a
# resting shape the one before it did not have, so the table below should be read
# as covering the shapes that have been OBSERVED, not as an exhaustive list of
# the states mcode can be in. A shape with no marker here classifies `unknown`,
# which is the honest answer for an unread screen - see classify().
#
# These are never word-split on whitespace: each line is read whole and split on
# '|' only. That is what caused the "Esc" bug documented in classify().
RULES='working|Esc stop
working|Ctrl+O details
working|⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠭⠫
idle|Start · @
idle|● Ready
idle|Completed in
idle|Message · Enter send'

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
# The rule table is read one whole line at a time and split on '|' only. An
# earlier version looped over a whitespace-separated list, which split "Esc stop"
# into "Esc" and "stop" - and mcode's own changelog prose contains the word "Esc",
# so a captured IDLE screen was classified working. Not hypothetical: that is
# exactly what happened, and the idle case caught it.
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

  local line state marker
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    state="${line%%|*}"
    marker="${line#*|}"
    if has_marker "$snap" "$marker"; then
      printf '%s\n' "$state"
      return 0
    fi
  done <<EOF
$RULES
EOF

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

# Deliberately absent: release().
#
# An earlier version called `herdr pane release-agent` on every exit path, on the
# theory that it hands lifecycle authority back so herdr's own screen detection
# can resume. That is wrong, and it was measured rather than assumed:
# `release-agent` DELETES the agent entry. It does not revert to a screen-
# detected state, because there is no screen manifest for mcode to fall back to
# - that is the premise of this whole epic. So the old `release` meant that
# running the watcher once made the pane vanish from `herdr agent list`, taking
# with it the registration cmd_start had just made. Running the tool to get
# state reporting lost you the agent entry you already had.
#
# Registration is pane-scoped and dies with the pane, which is the whole reason
# nothing needs cleaning up. If herdr ever gains an mcode screen manifest,
# releasing becomes correct again - that is the Layer 1 work, not today's
# problem.
#
# The traps stay, because Ctrl-C should still end the watcher cleanly. It is
# only the release-agent call that had to go.

pane_alive() {
  "$HERDR" pane get "$PANE_ID" >/dev/null 2>&1
}

read_detection() {
  "$HERDR" pane read "$PANE_ID" --source detection --lines "$LINES" 2>/dev/null
}

# --- main loop ---------------------------------------------------------------

# Traps keep Ctrl-C and SIGTERM ending the watcher cleanly, and nothing else:
# see the note above on why there is no release().
trap 'exit 0' INT TERM

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
    # The watched pane is gone. Stop. Deliberately do NOT report a state for a
    # pane that no longer exists, and do NOT call release-agent: the
    # registration is pane-scoped and herdr drops it with the pane.
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
