#!/usr/bin/env bash
# MiniMax Code Herdr plugin entrypoint.
#
# Herdr injects the environment; do not assume these when run by hand.
#   HERDR_BIN_PATH             path to the running Herdr binary
#   HERDR_PLUGIN_ROOT          this plugin's checkout
#   HERDR_PLUGIN_ID            jaaacki.minimax-code
#   HERDR_PLUGIN_CONTEXT_JSON  invocation context
#   HERDR_WORKSPACE_ID / HERDR_TAB_ID / HERDR_PANE_ID
#
# "The entire Herdr CLI is the plugin API" - anything runnable as the Herdr
# CLI yourself, this script can run. Every invocation below goes through
# $HERDR rather than a hard-coded binary name, so the plugin always talks to
# the running instance.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"

# The launcher binary, resolved from PATH. `pane run` receives the absolute
# path so the launch does not silently depend on the target pane's PATH.
MCODE_BIN_NAME="mcode"

# The new pane's id in a `pane split` response.
#
# VERIFIED, not guessed. tests/fixtures/pane-split.json is a real captured
# response (Herdr 0.9.3, captured 2026-10-04) and:
#   jq -r '.result.pane.pane_id' tests/fixtures/pane-split.json   ->  wZ:p8
#
# Two traps this file must not walk into:
#   - The plausible-looking alternative `.result.pane_id` yields `null`. Had
#     that been used, every launch would trip the guard below and the plugin
#     would never work, with no error to explain why.
#   - `result.type` in the split response is `pane_info`, NOT `pane_split`
#     (the split response is shaped like `pane get`). Nothing here may branch
#     on `result.type`; the top-level `id` is the reliable discriminator.
NEW_PANE_ID_FIELD='.result.pane.pane_id'

log() { printf '%s\n' "$*" >&2; }
die() { log "minimax-code: $*"; exit 1; }

# json_field PATH - print PATH's value as a string, or nothing when the
# document is unparseable, the path is absent, or the value is not a string.
# Never fails the caller.
#
# PATH is a jq path expression including its leading dot, e.g.
# '.result.pane.pane_id'. These come from literal constants in this file,
# never from user input, so interpolating one into the filter is safe.
# Do not prepend another dot here: "..foo" is jq's recursive-descent operator,
# which matches nothing here and would make every lookup return empty.
#
# The `type` test matters: with `jq -r` alone, a number, an array or an object
# renders to a non-empty string and would sail past a later emptiness check.
json_field() {
  jq -r "if (${1}|type) == \"string\" then ${1} else empty end" 2>/dev/null || true
}

# next_agent_name - print the first free name in the sequence mcode, mcode-2,
# mcode-3, ... and ALWAYS print something: when the agent list cannot be read,
# or when all ten slots are taken, it falls back to the bare label and lets the
# rename fail with a truthful message. It never prints nothing and never fails.
#
# WHY A SEQUENCE, AND NOT THE PANE ID. The name is what a human types into
# `herdr agent prompt <name>`, so it has to be predictable and short. A pane id
# or a hex suffix is unique for free but tells the user nothing, and a name
# derived from the working directory collides the moment two workspaces share a
# basename. The bare label the user already knows — `mcode` — is the best first
# guess; the number exists only to disambiguate a second concurrent instance.
#
# The upper bound is a backstop, not a policy: ten concurrent mcode panes is far
# past any real use, and running out must still leave a usable name.
#
# Because this always prints, the caller's empty-name branch is defensive and is
# NOT reachable today — it is there so that changing this helper's contract to
# "may fail" cannot silently produce a rename with an empty argument. Do not
# read it as a tested path; there is no test for it because there is no way to
# reach it.
next_agent_name() {
  local taken candidate n
  taken="$("$HERDR" agent list 2>/dev/null | jq -r '.result.agents[]? | .name // empty' 2>/dev/null || true)"
  n=1
  while [ "$n" -le 10 ]; do
    if [ "$n" -eq 1 ]; then candidate="${MCODE_BIN_NAME}"; else candidate="${MCODE_BIN_NAME}-${n}"; fi
    if ! printf '%s\n' "$taken" | grep -qxF -- "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    n=$((n + 1))
  done
  printf '%s\n' "${MCODE_BIN_NAME}"
}

# resolve_mcode - print the absolute path to the launcher binary, or fail.
resolve_mcode() {
  command -v "$MCODE_BIN_NAME" 2>/dev/null
}

# resolve_source_pane - print the pane to split, or fail with a distinct code
# so the caller can report the real cause:
#   0  resolved
#   1  `pane current` itself failed
#   2  `pane current` succeeded but carried no pane id
#
# The action is registered for both the workspace and pane contexts, and only
# the pane context is guaranteed to set HERDR_PANE_ID, so both branches are
# live paths rather than defensive padding.
resolve_source_pane() {
  local pane="${HERDR_PANE_ID:-}"
  if [ -n "$pane" ]; then
    printf '%s\n' "$pane"
    return 0
  fi

  local out
  if ! out=$("$HERDR" pane current); then
    return 1
  fi

  # Deliberately a literal, NOT $NEW_PANE_ID_FIELD. That constant names the
  # NEW pane, and the source pane is a different concept that merely happens
  # to sit at the same path. Reusing the constant here would make its name a
  # lie, so the two stay separate on purpose - do not "deduplicate" them.
  pane=$(printf '%s' "$out" | json_field '.result.pane.pane_id')
  if [ -z "$pane" ]; then
    return 2
  fi
  printf '%s\n' "$pane"
}

# ---------------------------------------------------------------------------
# THE SINGLE WATCHER SPAWN PATH (issue #84).
#
# Everything that can start a watcher goes through `ensure_watcher`: the
# launcher's autostart AND the manifest's `pane.agent_status_changed` event
# hook. One function, one lock, one place that can fail. That is deliberate and
# it is the whole reason a pane cannot end up with two watchers: "exactly one"
# is a property of the code's shape, not of two independent call sites happening
# to agree. When the event hook landed, the launcher would otherwise have had
# its own spawn (step 10) racing a hook that had already started one for the
# very same pane.

# Per-pane log root, printed for the user. Under herdr's plugin state dir when
# there is one, which is where a plugin's own state belongs and where herdr
# expects to find it.
#
# Resolution order, and why each fallback exists:
#   1. MCODE_WATCH_LOG_DIR  an explicit override, so a test can point the logs
#                          somewhere disposable. Never consulted from the
#                          event path in normal use.
#   2. HERDR_PLUGIN_STATE_DIR   injected by herdr for actions AND for event
#                          handlers - measured, both. It resolves to
#                          ~/.local/state/herdr/plugins/<plugin-id>.
#   3. ${TMPDIR:-/tmp}/minimax-code-state   hand-run. Falling back to /dev/null
#                          is what issue #84 is about, and it is why a watcher
#                          that died left no trace.
watch_log_dir() {
  if [ -n "${MCODE_WATCH_LOG_DIR:-}" ]; then
    printf '%s\n' "$MCODE_WATCH_LOG_DIR"
    return 0
  fi
  if [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
    printf '%s/watch\n' "$HERDR_PLUGIN_STATE_DIR"
    return 0
  fi
  printf '%s/minimax-code-state/watch\n' "${TMPDIR:-/tmp}"
}

# Cap the per-pane log. A watcher that runs for a week at 2s intervals writing
# one line per transition is not large, but "not large" is a property of the
# traffic, not of the file, and the cost of being wrong is a silently
# unreadable multi-gigabyte file in the user's state dir. Truncate to the last
# 200 KiB once it passes 1 MiB. Best-effort throughout: a log that cannot be
# rotated is a nuisance, never a reason to skip starting the watcher.
trim_log() { # trim_log <path>
  local path="$1" size
  [ -f "$path" ] || return 0
  size="$(wc -c <"$path" 2>/dev/null || printf 0)"
  [ "${size:-0}" -gt 1048576 ] || return 0
  tail -c 204800 "$path" >"$path.trimmed" 2>/dev/null && mv -f "$path.trimmed" "$path" 2>/dev/null
  /bin/rm -f "$path.trimmed" 2>/dev/null || true
}

# A pane id arrives from a JSON payload, so it is validated rather than trusted,
# and it is about to be embedded in a regular expression. Same shape rule
# cmd_start applies to a split response, and for the same reason: these strings
# are data. `:` is legal in a POSIX filename; `/` is not, and that is the
# character that would actually hurt.
valid_pane_id() { # valid_pane_id <value>
  case "${1:-}" in
    ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
    *:*)                   return 0 ;;
    *)                     return 1 ;;
  esac
}

# Escape a string for use as a LITERAL inside an ERE.
#
# A pane id may legally contain `.`, which in a regular expression means "any
# character". That is a small hole, but this is a value from an untrusted
# payload on its way to a process-matching pattern, so the whole metacharacter
# set is escaped rather than the one character that happens to be reachable
# today. Cheap, and it does not need a second argument whenever the allowed
# character set widens.
ere_escape() { # ere_escape <string>
  printf '%s' "$1" | sed 's/[][\\.*^$(){}|+?\/]/\\&/g'
}

# pane_is_watched <pane-id> - is a state watcher already running for this pane?
#
# WHY A PROCESS CHECK AND NOT A LOCK FILE. There was one, and it was wrong in a
# way only real machines reveal. A lock file records the watchers THIS code
# started, so it is blind to every watcher it did not:
#
#   * every watcher started by a 0.4.1 launcher - which is to say, all of them
#     at the moment a user upgrades, and
#   * the hand-run `bin/mcode-watch.sh <PANE_ID>` that the README tells people
#     to run as the fix for a frozen state.
#
# Both are live processes holding a pane, and on the next status change the
# lock would read "not watched", start a second watcher, and two watchers would
# report the same pane for the rest of its life. The lock was tracking the
# wrong thing: not "is this pane watched", but "did I start it".
#
# The process table is the single source of truth for that question, and it is
# the only one that already contains the 0.4.1 and hand-run cases for free.
#
# THE PATTERN, and both ends of it are load-bearing:
#
#   (^|[[:space:]/])mcode-watch\.sh[[:space:]]+PANE([[:space:]]|$)
#
#   * The left anchor stops a file merely NAMED `notmcode-watch.sh` from being
#     taken for the real watcher. Measured: it is.
#   * The right side must accept WHITESPACE as well as end-of-string. An
#     end-anchor alone looks right and is not: a watcher started as
#     `mcode-watch.sh wZ:p8 --interval 1` has a command line that continues
#     after the pane id, so `mcode-watch.sh wZ:p8$` does NOT match it. That is
#     the exact shape the README's hand-run fix takes, so an end-anchored
#     pattern fails to see precisely the watchers it exists to find. Measured
#     with the process table verified clean, one watcher at a time:
#         mcode-watch.sh wZ:p8                        end-anchored: MATCH
#         mcode-watch.sh wZ:p8 --interval 1           end-anchored: MISS
#         mcode-watch.sh wZ:p8 --interval 1  refined: MATCH
#   * Requiring the separator to be whitespace or `/` also stops a watcher on
#     `wZ:p80` from being counted as a watcher on `wZ:p8`.
#
# Two calls in the same instant both pass this check. The launch path and the
# event hook, or two hooks, can each observe "no watcher" and each spawn.
# Measured on this function as it stood: forty paired ensure-watcher calls on
# one pane started two watchers forty times (issue #120). pgrep stays the
# source of truth for a watcher that is already running, including one started
# by hand. The spawn itself is closed by acquire_watcher_claim below.
pane_is_watched() { # pane_is_watched <pane-id>
  local pane pattern
  pane="$(ere_escape "$1")"
  # The escaping here is the whole function, and it is easy to get wrong by one
  # backslash in either direction. What bash must hand pgrep is:
  #     (^|[[:space:]/])mcode-watch\.sh[[:space:]]+PANE([[:space:]]|$)
  # so the source needs `\\.` to emit `\.` and `\$` to emit a bare `$`. Writing
  # `\\\\.` instead emits `\\.` — a LITERAL BACKSLASH followed by any character,
  # which matches nothing at all — and `\\$` emits `\$`, a literal dollar sign
  # rather than the end anchor. Both fail silently and in the same direction:
  # the check never matches, every pane looks unwatched, and the hook starts a
  # watcher on every single transition. The tests caught that, which is the only
  # reason it is worth spelling out.
  pattern="(^|[[:space:]/])mcode-watch\\.sh[[:space:]]+${pane}([[:space:]]|\$)"
  pgrep -f "$pattern" >/dev/null 2>&1
}

# A spawn-window claim. mkdir is the atomic primitive: two callers cannot both
# create the same directory. The directory holds this process's pid and nothing
# else, and it is removed once the child is visible to pgrep or has already
# exited. It is not a lifetime lock.
#
# A lifetime lock was tried and removed. It recorded only the watchers this
# code started, so it was blind to a 0.4.1 watcher and to the hand-run
# `mcode-watch.sh <pane> --interval 1` the README tells a user to start, and a
# stale pid froze the pane after the watcher died. pgrep still answers "is a
# watcher running". This directory answers only "is someone in the middle of
# starting one", which is the gap pgrep cannot see.
#
# The pid is written so a claimer that died between mkdir and release can be
# told from one that is still spawning. A live pid is left alone. A dead pid is
# reclaimed by renaming the directory aside — mv of one directory on one
# filesystem is atomic — and mkdir'ing it again. The winner re-reads the pid
# and spawns only if it still says this process, so two reclaimers cannot both
# spawn.

claim_pid_alive() { # claim_pid_alive <pid>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null || return 1
  return 0
}

watcher_claim_owned() { # watcher_claim_owned <dir>
  local owner
  owner="$(cat "$1/pid" 2>/dev/null || true)"
  owner="${owner%%$'\n'*}"
  if [ "$owner" = "$$" ]; then
    return 0
  fi
  return 1
}

release_watcher_claim() { # release_watcher_claim <dir>
  local dir="${1:-}"
  [ -n "$dir" ] || return 0
  [ -d "$dir" ] || return 0
  # Only the pid file this code wrote. rmdir then refuses a directory that
  # holds anything else, which is the behaviour we want.
  /bin/rm -f -- "$dir/pid" 2>/dev/null || true
  rmdir -- "$dir" 2>/dev/null || true
}

acquire_watcher_claim() { # acquire_watcher_claim <dir> — 0 when this process owns it
  local dir="$1" i=0 owner="" stale=""
  if mkdir -- "$dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$dir/pid" 2>/dev/null || true
    if watcher_claim_owned "$dir"; then
      return 0
    fi
  fi
  # The winner writes its pid immediately. An empty claim is either that write
  # still in flight, or a claimer that died before it. Wait before stealing.
  #
  # If the directory disappears during the wait, the winner finished and
  # released the claim. Taking it now and spawning is how the second caller
  # starts a second watcher: it lost the mkdir, then the winner's child became
  # visible and the claim was removed before this loop read the pid. A missing
  # claim is not a stale one. Leave it, and let pgrep answer the next event.
  i=0
  while [ "$i" -lt 20 ]; do
    if [ ! -d "$dir" ]; then
      return 1
    fi
    owner="$(cat "$dir/pid" 2>/dev/null || true)"
    owner="${owner%%$'\n'*}"
    if [ -n "$owner" ]; then
      break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  if [ ! -d "$dir" ]; then
    return 1
  fi
  if [ "$owner" = "$$" ]; then
    return 0
  fi
  if claim_pid_alive "$owner"; then
    return 1
  fi
  stale="${dir}.stale.$$"
  if ! mv -- "$dir" "$stale" 2>/dev/null; then
    return 1
  fi
  /bin/rm -f -- "$stale/pid" 2>/dev/null || true
  rmdir -- "$stale" 2>/dev/null || true
  if mkdir -- "$dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$dir/pid" 2>/dev/null || true
    if watcher_claim_owned "$dir"; then
      return 0
    fi
  fi
  return 1
}

# ensure_watcher - THE spawn path. Starts bin/mcode-watch.sh for a pane, at
# most one watcher per pane, logging to a per-pane file.
#
#   ensure_watcher <pane-id> <agent-name> [log-line]
#
# The optional third argument is the one line the LAUNCH path prints to the
# user's terminal. The event path passes none: it runs detached inside the herdr
# server with nobody reading its stderr, so anything it printed there would be
# lost - which is the same reason the watcher itself now writes to a file.
#
# Both names are passed for the reason documented at the old autostart call
# site: MCODE_AGENT_LABEL is the knob the other two reporters read, and
# MCODE_WATCH_AGENT is the watcher's own override. Passing only one of them is
# a real defect, and only the SECOND pane reveals it - on pane one the chosen
# name is the literal `mcode` and both spellings produce the same string.
ensure_watcher() { # ensure_watcher <pane-id> <agent-name> [launch-log-line]
  local pane="$1" agent_name="$2" launch_line="${3:-}"
  local dir watcher logdir log claim="" claim_root="" child="" i=0

  if ! valid_pane_id "$pane"; then
    [ -n "$launch_line" ] && log "minimax-code: refused to start a watcher for $(printf '%q' "$pane"): not a pane id."
    return 0
  fi

  # Resolved from this script's own directory, NOT $HERDR_PLUGIN_ROOT: the env
  # var is only injected when herdr runs an ACTION, so a hand-run of the
  # entrypoint would resolve an empty string. The event hook does get it, but
  # relying on that would make the two entry paths disagree for no reason.
  #
  # `..` because this file IS bin/mcode-plugin.sh, so its own directory is
  # `bin/` and the watcher sits one level up. Getting this wrong yields
  # <root>/bin/bin/mcode-watch.sh - short enough to look right and `-x`-false.
  # `pwd -P` collapses the `..` and resolves symlinks.
  #
  # `|| true` matters under `set -e`: a failing `cd` in this substitution would
  # abort the caller.
  dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P || true)"
  watcher="${dir}/bin/mcode-watch.sh"

  if [ -z "$dir" ]; then
    [ -n "$launch_line" ] && log "minimax-code: could not resolve this plugin's own directory, so the state watcher was not started and pane ${pane} will stay 'unknown' in \`herdr agent list\`. The launch itself succeeded."
    return 0
  fi
  if [ ! -x "$watcher" ]; then
    [ -n "$launch_line" ] && log "minimax-code: could not start the state watcher - ${watcher} is missing or not executable - so pane ${pane} will stay 'unknown' in \`herdr agent list\`. The launch itself succeeded."
    return 0
  fi
  # Checked rather than assumed: this is a POSIX tool, but a stripped-down
  # install may not carry it, and a missing nohup would produce a watcher that
  # dies the moment this script exits - the worst failure mode, because it
  # looks started.
  if ! command -v nohup >/dev/null 2>&1; then
    [ -n "$launch_line" ] && log "minimax-code: \`nohup\` is not on PATH, so the state watcher was not started and pane ${pane} will stay 'unknown'. Start it in another terminal to get real states: ${watcher} ${pane}. The launch itself succeeded."
    return 0
  fi

  logdir="$(watch_log_dir)"
  if ! mkdir -p "$logdir" 2>/dev/null; then
    [ -n "$launch_line" ] && log "minimax-code: could not create ${logdir} for the state watcher's log, so pane ${pane}'s watcher output will be discarded. The watcher will still start. The launch itself succeeded."
    logdir=""
  fi
  # /dev/null as the WHOLE path, not as a directory to append a filename to.
  # "${logdir:-/dev/null}/${pane}.log" would expand to /dev/null/wZ:p1.log, whose
  # redirect fails with ENOTDIR - so the watcher would never start at all, and
  # the `2>/dev/null` on the append would hide the reason. A silent dead watcher
  # is precisely the defect #84 is filed about.
  if [ -n "$logdir" ]; then
    log="${logdir}/${pane}.log"
  else
    log="/dev/null"
  fi

  # Is this pane ALREADY watched? Checked before anything is spawned, and it is
  # the half of #84 the event hook makes necessary: the hook fires on the
  # watcher's own first report, so without this every state transition would
  # double the watcher.
  #
  # `pgrep` is checked for first, not assumed. Without it the question is
  # unanswerable, and the two available answers are both wrong: spawning risks
  # the duplicate this check exists to prevent, and refusing would leave panes
  # unwatched - the defect #84 is filed about. So a missing pgrep spawns, says
  # so on the launch path, and the log records that the guarantee was degraded.
  if ! command -v pgrep >/dev/null 2>&1; then
    [ -n "$launch_line" ] && log "minimax-code: \`pgrep\` is not on PATH, so this plugin cannot tell whether pane ${pane} is already watched and has started a watcher anyway. If a watcher was already running - one started before an upgrade, or one you started by hand - there are now two reporting the same pane. Everything else about the pane is unaffected; only the duplicate is."
  elif pane_is_watched "$pane"; then
    [ -n "$launch_line" ] && log "minimax-code: pane ${pane} already has a state watcher, so none was started."
    return 0
  fi

  # Close the gap between the check above and the spawn. A second caller that
  # also saw "not watched" loses the mkdir and returns. The claim is dropped
  # once pgrep can see the child, or once the child has already exited, so a
  # later event can replace a dead watcher.
  claim_root="$logdir"
  if [ -z "$claim_root" ]; then
    claim_root="${TMPDIR:-/tmp}/minimax-code-state/watch"
    if ! mkdir -p "$claim_root" 2>/dev/null; then
      claim_root=""
    fi
  fi
  if [ -n "$claim_root" ]; then
    claim="${claim_root}/claim-${pane}"
    if ! acquire_watcher_claim "$claim"; then
      [ -n "$launch_line" ] && log "minimax-code: pane ${pane} already has a state watcher starting, so none was started."
      return 0
    fi
    # A hand-started watcher can appear between the first pgrep and the claim.
    # Drop the claim and leave that process alone.
    if command -v pgrep >/dev/null 2>&1 && pane_is_watched "$pane"; then
      release_watcher_claim "$claim"
      [ -n "$launch_line" ] && log "minimax-code: pane ${pane} already has a state watcher, so none was started."
      return 0
    fi
    if ! watcher_claim_owned "$claim"; then
      return 0
    fi
  fi

  if [ -n "$logdir" ]; then
    trim_log "$log"
    printf -- '--- %s watching pane %s as agent %s (source %s) ---\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf 'unknown-time')" \
      "$pane" "${agent_name:-mcode}" "${MCODE_AGENT_SOURCE:-herdr:minimax-code}" \
      >>"$log" 2>/dev/null || true
  fi

  # WHY NOT /dev/null ANY MORE (issue #84). It was defended here on the grounds
  # that herdr already records every transition, so a detached writer is
  # "writing to a void". That was true about herdr's record and wrong about the
  # failure this hid: with output discarded, a watcher that failed to start,
  # died on its first poll, or was refused a report by herdr left NO trace at
  # all, and the symptom the user sees is a frozen state with no way to tell a
  # dead watcher from an idle pane. One file per pane, capped, named after the
  # pane, is a diagnosable amount of state.
  #
  # `disown` detaches it from this shell's job table so the caller's own exit
  # does not signal it. Harmless if it fails: nohup already ignores SIGHUP.
  MCODE_AGENT_LABEL="$agent_name" MCODE_WATCH_AGENT="$agent_name" \
    nohup "$watcher" "$pane" >>"$log" 2>&1 &
  child=$!
  disown 2>/dev/null || true

  # The claim pid is not a record of the watcher. It exists only so a dead
  # claimer can be told from one that is still inside this function. Once the
  # child is visible, pgrep is the record again, which is what lets a watcher
  # started by hand or by a 0.4.1 launcher count. Releasing here is also what
  # lets the next event replace a watcher that has already exited.
  if [ -n "$claim" ]; then
    if command -v pgrep >/dev/null 2>&1; then
      i=0
      while [ "$i" -lt 40 ]; do
        if pane_is_watched "$pane"; then
          break
        fi
        kill -0 "$child" 2>/dev/null || break
        sleep 0.05
        i=$((i + 1))
      done
      # Release as soon as pgrep can see the child. A peer that is still between
      # its own pgrep miss and its mkdir either loses the claim, or wins it and
      # then hits the pgrep re-check above and spawns nothing. Holding the claim
      # longer keeps this hook alive after the child exists; measured, that is
      # when the child then exits and the pane is left with no watcher.
    fi
    release_watcher_claim "$claim"
  fi

  if [ -n "$launch_line" ]; then
    log "minimax-code: started the state watcher for pane ${pane}, so idle/working will follow the pane. Its log is ${log}. It stops by itself when the pane closes. Set MCODE_WATCH_AUTOSTART=0 to skip this next time; \`blocked\` is never reported - MiniMax Code 0.6.2 exposes no hook a plugin can read, so idle/working/unknown is the whole range."
  fi
  return 0
}

# WHY THE WATCHER IS STARTED AT ALL NOW RATHER THAN ONLY SUGGESTED (issue #75).
#
# It was opt-in for a long time, and the opt-in nobody takes is the same as no
# state tracking at all. Measured on this machine, 2026-10-04: `ps` found ZERO
# mcode-watch.sh processes, so every state herdr displayed came from a one-time
# adopt-time measurement and never moved again. That is the owner's report, and
# it is the reason `working` stuck after a turn finished - the orange dot.
#
# The original blocker is GONE. #47 refused to auto-start the watcher because it
# called `pane release-agent` on every exit path, and that call DELETES the agent
# entry - measured, reproduced live. #54 removed it: the watcher now holds the
# registration, reports transitions, and leaves no entry to release. Registration
# is pane-scoped, so herdr drops it when the pane closes anyway.
#
# WHY `nohup ... &` IS THE SMALLEST HONEST THING, and not a supervisor:
#
#   * foreground-in-the-target-pane is impossible - that pane is running mcode.
#   * detached-with-a-supervisor means PID bookkeeping, reaping and an orphan
#     sweep, to answer a question the watcher can answer for free: it already
#     polls `pane get`, and when the pane is gone it exits 0 without reporting a
#     state and without releasing anything. Verified in bin/mcode-watch.sh.
#   * and after #84 there is a THIRD option that is better than both: herdr
#     itself tells us when a pane has a minimax-code agent (see the
#     [[events]] block in herdr-plugin.toml), so no polling loop has to guess.
#
# So lifetime is tied to the thing being watched rather than to a supervisor that
# could itself outlive it or die silently.
#
# FAILURE POLICY, same asymmetry as every other step after the split: the launch
# already worked and the user can see mcode running. Failing now would report a
# success as a failure and could make a caller retry, spawning a second pane. So
# every failure below is a warning and exit 0 - and the warning says what is
# lost, because "state is not tracked" with no remedy is how this gets
# misdiagnosed.
watcher_autostart() { # watcher_autostart <pane-id> <agent-name>
  local pane="$1" agent_name="$2"

  # Opt-out, checked BEFORE anything else so it costs nothing and starts nothing.
  # Compared as the exact string "0" rather than "any non-empty value", so
  # MCODE_WATCH_AUTOSTART= (set but empty) keeps the default on - an empty value
  # reads as "not configured", and treating it as "off" would silently disable a
  # default the user never turned off.
  #
  # The event hook honours the same variable, with the honest caveat that the
  # hook runs inside the herdr SERVER, so the value has to have been exported
  # into the environment herdr was started from to reach it. A per-launch
  # export will not. That is a property of the mechanism, not a bug to work
  # around, and it is why this is an opt-out and not the default.
  if [ "${MCODE_WATCH_AUTOSTART:-1}" = "0" ]; then
    local dir watcher
    dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P || true)"
    watcher="${dir}/bin/mcode-watch.sh"
    log "minimax-code: state for pane ${pane} will NOT be tracked, because MCODE_WATCH_AUTOSTART=0. Until you start a watcher, \`herdr agent list\` will keep showing whatever state it last saw - which goes stale in BOTH directions when a turn starts or finishes. To start it by hand: ${watcher} ${pane}"
    return 0
  fi

  # The third argument is the only difference between the launch path and the
  # event path, and it is a message rather than behaviour. See ensure_watcher.
  ensure_watcher "$pane" "$agent_name" \
    "launch"
}

# Register the pane's session identity and resume command (issue #79).
#
# THE CALL, NOT A FORK. `bin/mcode-session.sh report` already does this correctly
# and already knows the awkward parts: it re-asserts the pane's existing agent
# state instead of imposing a placeholder, it refuses to invent a session id, and
# since #71 it reads the report back and says whether herdr actually kept it.
# Duplicating that logic here would be a second copy of the ordering law, the
# no-invented-id rule and the read-back - three things that must not drift.
#
# ORDER IS NOT OPTIONAL. `pane report-agent-session` is only accepted from a
# reporter that already holds the pane, and the sibling's own first call is
# `pane report-agent` for that reason (measured on herdr 0.9.3; the refusal is
# `resume_not_accepted`). This function therefore runs strictly AFTER the
# registration block above. Do not move it up, and do not "optimise" it into a
# direct `report-agent-session` call here: the sibling sequences the two calls
# itself, and a caller that skips its first call breaks the contract.
#
# WHAT THIS BUYS, stated honestly because it is easy to overclaim: on herdr 0.9.3
# the session write is DISCARDED for agent kinds herdr does not enumerate, and
# `minimax-code` is not one of them (issue #71, proven, independently confirmed in
# sparkfn/pc-client#2251). Wiring this does NOT make `agent_session` appear. What
# it buys is (1) the report is attempted on the real launch path, so the #71
# read-back runs where a user will actually see it, instead of only when someone
# runs the sibling by hand; (2) `MCODE_RESUME_CMD` and the session-id resolution
# execute where they were designed to; (3) the day herdr gains `--kind
# minimax-code`, the launch path already reports identity and resume works with
# no further change here.
session_report() { # session_report <pane-id> <agent-name>
  local pane="$1" agent_name="$2"
  local dir sibling

  dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P || true)"
  sibling="${dir}/bin/mcode-session.sh"

  if [ -z "$dir" ] || [ ! -x "$sibling" ]; then
    log "minimax-code: could not run the session reporter - ${sibling} is missing or not executable - so no session id and no resume command were recorded for pane ${pane}. The pane IS registered and named, and state tracking is unaffected; only resume is unavailable. The launch itself succeeded."
    return 0
  fi

  # `attach`, NOT `report` (issue #79, architect ruling). `report` re-asserts the
  # pane's agent state and so issues its OWN `pane report-agent` — calling it
  # from here put two claims on one pane in one launch, which is the duplication
  # the three-reporter split exists to avoid. `attach` issues
  # report-agent-session only, and this function runs after step 7's report-agent,
  # so the "reporter must already hold the pane" law is satisfied by the launcher.
  #
  # MCODE_AGENT_LABEL is the name step 8 actually chose. Without it the sibling
  # would fall back to its own default and report under a label this pane does not
  # have — the same second-pane mismatch the watcher had, one file over.
  #
  # stderr is INHERITED, not captured. The sibling's read-back line — "herdr 0.9.3
  # did not persist it" — is the only thing telling the operator their session was
  # discarded, and it is the path this actually takes on 0.9.3. Capturing stderr to
  # print only on failure would swallow it. The verb is otherwise quiet by design.
  #
  # HERDR_BIN_PATH is passed with the value THIS script resolved so the sibling
  # talks to the same multiplexer. Set per-invocation, never exported: this
  # process's own HERDR_PANE_ID is the SOURCE pane and must not leak into a
  # reporter that would then report the wrong pane.
  if HERDR_PANE_ID="$pane" HERDR_BIN_PATH="$HERDR" MCODE_AGENT_LABEL="$agent_name" \
       "$sibling" attach; then
    return 0
  fi
  # The sibling's own stderr has already said why. This line adds the one thing it
  # cannot know - which pane the launch was for - so a failure is attributable.
  log "minimax-code: the session report for pane ${pane} failed (the sibling's own diagnostics are above). The pane is still registered and named, and this launch succeeded; what was NOT recorded is the session id and the resume command, so resume will be unavailable for this pane. Nothing was rolled back."
  return 0
}

cmd_start() {
  # 1. Preflight. jq parses the CLI's JSON output; without it a missing parser
  #    would surface as a confusing parse error instead of a real diagnostic.
  if ! command -v jq >/dev/null 2>&1; then
    die "\`jq\` is required to read Herdr's JSON output but was not found on PATH. Install it (macOS: \`brew install jq\`; Debian/Ubuntu: \`apt-get install jq\`; Fedora: \`dnf install jq\`) and retry. No pane was created."
  fi

  # Resolved before the split so a missing binary cannot orphan a fresh pane.
  local mcode_bin
  if ! mcode_bin=$(resolve_mcode); then
    die "\`${MCODE_BIN_NAME}\` is not on PATH, so there is nothing to launch. Install MiniMax Code, or add it to PATH, then retry. No pane was created."
  fi
  if [ -z "$mcode_bin" ]; then
    die "\`${MCODE_BIN_NAME}\` did not resolve to a path, so there is nothing to launch. No pane was created."
  fi
  # `command -v` returns whatever PATH entry matched, so a relative entry in
  # PATH (including a bare `.`) yields a relative path. `pane run` hands that
  # string to the TARGET pane, which resolves it against the target's own cwd -
  # the split's --cwd, not ours - so it would not be found. Refuse rather than
  # report success on a path the target cannot resolve.
  case "$mcode_bin" in
    /*) ;;
    *) die "\`${MCODE_BIN_NAME}\` resolved to the relative path $(printf '%q' "$mcode_bin"), usually because PATH contains a relative entry. \`pane run\` would resolve it against the new pane's own directory, where it does not exist. Use an absolute PATH entry and retry. No pane was created." ;;
  esac

  # 2. Resolve the source pane. The two failure modes get distinct wording:
  #    a failed call and a successful call that carried no id are different
  #    problems, and reporting both as "no pane id" hides which one happened.
  local source_pane
  local src_rc=0
  source_pane=$(resolve_source_pane) || src_rc=$?
  if [ "$src_rc" -ne 0 ]; then
    if [ "$src_rc" -eq 1 ]; then
      die "\`${HERDR} pane current\` exited non-zero and HERDR_PANE_ID is unset, so no source pane could be determined. No pane was created."
    fi
    die "\`${HERDR} pane current\` succeeded but its response carried no \`.result.pane.pane_id\`, and HERDR_PANE_ID is unset. No pane was created."
  fi

  # 3. Resolve cwd. A missing or empty cwd degrades to the CLI's own default
  #    placement rather than failing the whole launch. A failed `pane get` is
  #    reported as a failed read, not as "no cwd", so the cause is not hidden.
  #
  #    stderr goes to a temp file rather than being dropped or merged into
  #    stdout. Merging is wrong: the CLI may write a notice to stderr on
  #    success, and a non-JSON line ahead of the document makes jq fail, which
  #    would silently discard a perfectly good cwd. This repo's own fake-herdr
  #    does exactly that, and doing it here broke tests/run.sh before this
  #    comment existed. mktemp is coreutils and already used by the test suite.
  local cwd=""
  local get_out=""
  local get_err=""
  local get_err_file=""
  if get_err_file="$(mktemp "${TMPDIR:-/tmp}/mcode-plugin-pane-get.XXXXXX" 2>/dev/null)"; then
    if ! get_out=$("$HERDR" pane get "$source_pane" 2>"$get_err_file"); then
      get_err="$(<"$get_err_file")"
    fi
    /bin/rm -f "$get_err_file"
  else
    # No temp file available. Degrade rather than fail: we just lose the reason.
    get_out=$("$HERDR" pane get "$source_pane" 2>/dev/null) || get_out=""
  fi

  if [ -n "$get_out" ]; then
    cwd=$(printf '%s' "$get_out" | json_field '.result.pane.cwd')
  fi

  local cwd_args=()
  if [ -n "$cwd" ]; then
    cwd_args=(--cwd "$cwd")
  elif [ -n "$get_err" ]; then
    log "minimax-code: \`${HERDR} pane get ${source_pane}\` failed, so its cwd is unknown; splitting without --cwd and letting the CLI place the pane. Herdr said: ${get_err:0:300}"
  else
    log "minimax-code: pane ${source_pane} reported no cwd; splitting without --cwd and letting the CLI place the pane."
  fi

  # 4. Split. Direction is fixed to right for this epic; making it
  #    configurable is a follow-up, not a nit to fix here.
  #
  #    --no-focus is deliberate, not inherited from a fixture note. The
  #    action is registered for the `pane` context, so it can be fired from
  #    the pane the user is actively typing in. If the split took focus,
  #    their in-flight keystrokes would land in the brand-new pane in the
  #    window between the split and mcode starting there. It also keeps the
  #    invocation deterministic in the `workspace` context, where the source
  #    pane comes from `pane current` and need not be the focused pane at
  #    all. The trade-off: the user does not get focus stolen, but the new
  #    pane still appears beside theirs with the agent visibly starting.
  local split_out=""
  if ! split_out=$("$HERDR" pane split "$source_pane" --direction right --no-focus ${cwd_args[@]+"${cwd_args[@]}"}); then
    die "\`${HERDR} pane split ${source_pane} --direction right --no-focus\` failed, so no new pane was created and nothing was launched."
  fi

  # 5. Extract the new pane id.
  #
  #    SAFETY GATE. Both guards below call die, which exits non-zero, so
  #    `pane run` at step 6 is UNREACHABLE whenever the new pane cannot be
  #    identified. `pane run` types text into a pane id; a wrong or empty id
  #    means typing a command into the wrong window, or into no window at all.
  #    Never reorder or weaken these two conditions to "log and continue".
  local new_pane
  new_pane=$(printf '%s' "$split_out" | json_field "$NEW_PANE_ID_FIELD")

  # Validate the SHAPE of the id, not a list of bad values. A herdr pane id is
  # a short opaque token - `wZ:p8` shaped, a workspace part, a separator, a pane
  # part - built only from characters herdr uses in layout ids. Anything else
  # is not a pane id, whatever produced it: whitespace, an embedded newline
  # (including a value assembled from more than one JSON document), a bare word
  # with no separator, or a rendering of a non-string JSON value that survived
  # json_field. Bash pattern matching tests the WHOLE value, so an embedded
  # newline is rejected here - a per-line grep would not catch it.
  #
  # Rejecting a legitimate id is the safe direction: the launch fails loudly
  # with a diagnostic naming the value, rather than typing into a pane the
  # response did not actually identify.
  local pane_id_shape_ok=0
  case "$new_pane" in
    *[!A-Za-z0-9_.:-]*) pane_id_shape_ok=0 ;;   # character herdr never uses
    *:*)                pane_id_shape_ok=1 ;;   # has the workspace:part separator
    *)                  pane_id_shape_ok=0 ;;   # no separator, so not a pane id
  esac

  if [ "$pane_id_shape_ok" -ne 1 ]; then
    die "the split of pane ${source_pane} succeeded but '${NEW_PANE_ID_FIELD}' did not yield a usable pane id in its response: rejected value $(printf '%q' "$new_pane"). A pane id must be a non-empty token containing ':' and no characters outside [A-Za-z0-9_.:-]. Refusing to run \`${MCODE_BIN_NAME}\` in an unidentified pane. A new pane may exist: check the layout and close it by hand if it is empty."
  fi

  # A split always produces a *different* pane, so a response naming the
  # source pane means the field layout changed and we misread it. Typing
  # there would hijack the pane the user is working in.
  if [ "$new_pane" = "$source_pane" ]; then
    die "the split of pane ${source_pane} reported that same pane as the new one, so its response was not understood. Refusing to run \`${MCODE_BIN_NAME}\` into the source pane. Check the layout; a new pane may exist."
  fi

  # 6. Run the launcher in the new pane.
  if ! "$HERDR" pane run "$new_pane" "$mcode_bin"; then
    die "\`${HERDR} pane run ${new_pane} ${mcode_bin}\` failed, so MiniMax Code was not started. Pane ${new_pane} exists but is empty; close it by hand with \`${HERDR} pane close ${new_pane}\`."
  fi

  log "minimax-code: started ${mcode_bin} in pane ${new_pane}"

  # 7. Register the new pane with Herdr's agent surface, best-effort.
  #
  #    Until this, the pane is anonymous to Herdr: it shows in `pane list` with
  #    agent_status "unknown" and never appears in `herdr agent list`. After
  #    this, `herdr agent get <PANE_ID>` and `herdr agent read <PANE_ID>
  #    --source detection` resolve against it.
  #
  #    FAILURE POLICY - deliberately the opposite of the split guard above, and
  #    the asymmetry is intentional. There, an unidentifiable pane means we
  #    might type into the wrong window, so failing loudly is the safe move.
  #    Here the launch is already done and the user can see mcode running: the
  #    thing they asked for succeeded. Exiting non-zero now would report a
  #    success as a failure and could make a caller retry, spawning a second
  #    pane. So a failed registration is a warning on stderr and exit 0.
  #
  #    DO NOT add a `pane release-agent` call here. Measured on Herdr 0.9.3:
  #    report-agent makes the entry appear, and release-agent makes it vanish
  #    again on the next `agent list`. The intent of releasing is to hand
  #    authority back so screen detection can resume - but Herdr has no screen
  #    manifest for MiniMax Code, so there is nothing to hand back to, and
  #    releasing would simply delete the registration this step exists to
  #    create. The entry is scoped to the pane: it disappears when the pane
  #    closes, so holding authority leaks nothing. A future state watcher
  #    (bin/mcode-watch.sh) should keep reporting on this same registration
  #    rather than re-reporting per state, and should not release either.
  #
  #    --source namespace. Must match the other two reporters, and follows herdr's
  #    own `herdr:<agent>` convention (see the Claude integration hook). herdr uses
  #    this to tell reporters apart; three different values for one agent defeats
  #    it. The siblings are bin/mcode-session.sh and bin/mcode-watch.sh; the three
  #    are one change and must land together.
  #
  #    --state is `unknown`, and that is the point of the change. An earlier
  #    revision claimed `idle` here, on the reasoning that the pane was just
  #    created and mcode was still starting. Measured on 0.9.3, that claim does
  #    not age well: a pane registered `idle` here still read `idle`
  #    twenty-five seconds later with the MiniMax Code TUI up and visibly
  #    working, and `herdr agent list` would have shown the lie for as long as
  #    the pane lived.
  #
  #    What makes `unknown` the right claim is NOT that nothing ever updates it.
  #    It is that the watcher now does, within seconds: step 10 below
  #    (watcher_autostart) starts one for every pane we launch, and its first
  #    act is to classify the screen and report. So this value is a placeholder
  #    that is corrected almost immediately - and `unknown` is the only claim
  #    that is true for the short window this process actually owns, where
  #    `idle` would be a specific, unearned assertion. It is also what Herdr
  #    shows for a pane nobody has registered.
  #
  #    So `unknown` here followed by an accurate state moments later is the
  #    INTENDED sequence, not an unfinished one. If you ever read a stale state
  #    on a launched pane, suspect the watcher before the claim: a dead watcher
  #    freezes whatever was last reported, with no supervisor to notice. Check
  #    `pgrep -f "mcode-watch.sh <PANE_ID>"`, and re-sync with
  #    `bin/mcode-watch.sh <PANE_ID>`.
  #
  #    The fix is deliberately NOT "start the watcher so that `idle` becomes
  #    true" (issue #47). bin/mcode-watch.sh called `pane release-agent` from its
  #    INT/TERM/EXIT traps and when the watched pane died, and `release-agent`
  #    DELETES the agent entry - measured, reproduced live. Auto-starting the
  #    watcher would therefore have unregistered every pane it watched, trading a
  #    stale state for no state at all, and that defect was not in this file.
  #
  #    THAT DEFECT IS GONE (#54), so the reasoning above no longer holds and the
  #    watcher IS auto-started now - see watcher_autostart. The refusal recorded
  #    here is history, not policy: it explains why this used to be a printed
  #    hint, and why re-introducing auto-start looked wrong to everyone who read
  #    it. Read watcher_autostart before "simplifying" this back to a hint.
  #
  #    --seq is omitted on purpose. Herdr assigns state_change_seq itself (it
  #    did, 122, on a first report in a live check), so inventing our own
  #    counter would add a second, competing ordering scheme.
  #
  #    --agent-session-id is omitted: mcode does not hand us one at launch, and
  #    inventing a session id would be worse than reporting none.
  # 8. Name the agent, so it can be addressed by something a human would type.
  #
  #    `report-agent` alone gets the pane into `agent list` and no further: with
  #    no active name, `herdr agent get`/`read`/`wait` will not resolve it by
  #    name. `agent rename` is what installs the name, and it only works on an
  #    already registered agent — which is why this is nested inside the success
  #    branch of step 7. Renaming a pane that was never registered cannot
  #    succeed, and trying would turn one root cause into two warnings.
  #
  #    WHAT NAMING BUYS, AND WHAT IT DOES NOT — measured on 0.9.3, do not
  #    "simplify" the messages below into a promise it cannot keep. After a
  #    successful rename, `agent get`, `agent read` and `agent wait` all resolve
  #    by name. `agent prompt` and `agent send-keys` still fail with
  #    `agent_not_ready: not an active named agent`, and no amount of renaming
  #    changes that: only `herdr agent start --kind` mints an *active* agent, and
  #    that closed 22-value enum has no `minimax-code` member. So a self-reported
  #    agent is named but never active. That is an upstream ceiling, tracked in
  #    issue #37, not a step we are one rename away from. The warning text says
  #    so explicitly, because a user told only "it is unnamed" will spend an
  #    afternoon renaming it and get nowhere.
  #
  #    Same best-effort policy as step 7, for the same reason: the launch is
  #    already done. A pane that is registered but unnamed is still better than
  #    one that is invisible, so a failure here is a warning and exit 0 — and the
  #    warning says exactly which commands are lost, because "it half worked"
  #    with no consequence spelled out is how this gets misdiagnosed later.
  # The name this pane ACTUALLY gets, hoisted so the two reporters spawned below can
  # be told it rather than each guessing. `next_agent_name` is a pure function of
  # the agent list, so calling it twice could return the same free slot twice; one
  # call, one variable, and every reporter downstream uses that same string.
  local agent_name=""
  if "$HERDR" pane report-agent "$new_pane" --source herdr:minimax-code --agent "$MCODE_BIN_NAME" --state unknown; then
    agent_name=$(next_agent_name)
    if [ -z "$agent_name" ]; then
      log "minimax-code: could not work out a free name for pane ${new_pane}, so it stays registered but unnamed. \`herdr agent get\`, \`read\` and \`wait\` will need the pane id ${new_pane} instead, and \`herdr agent prompt\`/\`send-keys\` will not work for it either way on Herdr 0.9.3 (agent_not_ready) — those need an agent Herdr itself started. Naming it later would not change that."
    elif ! "$HERDR" agent rename "$new_pane" "$agent_name"; then
      log "minimax-code: pane ${new_pane} is registered but could not be renamed, so it has no active name. \`herdr agent get\`, \`read\` and \`wait\` will need the pane id ${new_pane} instead, and \`herdr agent prompt\`/\`send-keys\` will not work for it either way on Herdr 0.9.3 (agent_not_ready) — those need an agent Herdr itself started. Renaming it later would not change that. The launch itself succeeded."
    fi
  else
    log "minimax-code: could not register pane ${new_pane} with Herdr's agent surface, so it will not appear in \`herdr agent list\`, could not be named, and \`herdr agent prompt\`/\`send-keys\` will not work for it. The launch itself succeeded; nothing was rolled back. \`herdr agent list\` will show it once Herdr detects it, if it ever does."
  fi

  # 9. Register session identity and resume (issue #79).
  #
  #    HERE, and not earlier, because of the ordering law: the sibling reports
  #    `pane report-agent` itself and only then `pane report-agent-session`,
  #    because herdr refuses a session report from a reporter that does not
  #    already hold the pane. Step 7 above is what establishes that, so this
  #    call has to come after it. Moving it earlier is not a cleanup, it is the
  #    `resume_not_accepted` refusal.
  #
  #    Unconditional for the same reason the watcher start is: a failed
  #    registration does not make a session report more likely to succeed, but
  #    the sibling re-asserts the agent state as its first act, so running it
  #    after a failed step 7 is a second chance at the registration rather than a
  #    wasted call. Best-effort inside: it warns and returns 0.
  session_report "$new_pane" "$agent_name"

  # 10. Start the state watcher (issue #75), detached.
  #
  #     Unconditional, and deliberately so: it is most useful when registration
  #     FAILED, because the watcher's first act is to re-report the pane, which
  #     recreates the entry. Suppressing it on the error path would hide the one
  #     situation where it is worth most - and it is exactly the situation that
  #     produced the stale states this step was written to fix.
  #
  #     After session_report, and the order between the two is not load-bearing:
  #     neither depends on the other. It is last simply because state is the
  #     outermost concern of the three - the pane exists, then it is registered,
  #     then it has identity, then its state is live.
  watcher_autostart "$new_pane" "$agent_name"
}

# ---------------------------------------------------------------------------
# THE EVENT PATH (issue #84): `pane.agent_status_changed` -> ensure a watcher.
#
# This is what fixes the defect. Before it, the only way a pane got a watcher was
# step 10 of a launch THIS plugin performed, so a pane started by flock's
# `adopt --agent minimax-code`, or by a human typing `mcode` into a pane, or
# left over from before 0.4.1, kept whatever state herdr last saw - frozen, and
# frozen in both directions, which is worse than no state at all because it looks
# live.
#
# WHY THE EVENT REACHES THOSE PANES AT ALL. herdr fires this event whenever
# `pane report-agent` is called by anyone, and it was MEASURED that it fires for
# a registration this plugin did not make - including flock's, which is the
# exact case #84 is about. See the [[events]] block in herdr-plugin.toml for the
# captured payloads. The block comment that used to sit there argued this event
# could only ever echo the plugin's own reporting back to it; that was true when
# it was written and #84 is what made it false.

# Is this event about a pane of ours?
#
# The event payload carries `agent` but NOT `--source`, so a handler cannot ask
# "did I report this?". It can ask "is the label mine?", and for a LIFECYCLE
# decision that is enough: the only thing done with the answer is "start a
# watcher for this pane", and a pane labelled `claude` is not a pane this plugin
# should be polling.
#
# Both spellings are accepted because both exist in the wild, and neither is a
# typo: the launcher registers `--agent mcode`, and flock adopts with
# `--agent minimax-code`. Matching only one of them would leave exactly the
# panes #84 is filed about unwatched.
#
# `mcode-N` is a NAME rather than a label, and the launch path never produces
# one here — the event carries the label, which the launcher sets to the literal
# `mcode` on every pane it starts. So that branch only fires for a pane somebody
# renamed by hand. It is kept as defensive code, and a reviewer should not go
# looking for a caller that reaches it.
#
# The digits-only test is a loop rather than a glob on purpose: `mcode-[0-9]*`
# is ONE digit followed by anything, so it also matches `mcode-2foo`. Harmless —
# such a name is obviously somebody's mcode — but it is not what the pattern
# reads like, and a case that asserts `mcode-2` is ours should not silently also
# bless `mcode-2foo`.
is_our_agent_label() { # is_our_agent_label <label>
  local rest
  case "${1:-}" in
    minimax-code) return 0 ;;
    mcode)        return 0 ;;
    mcode-[0-9]*)
      rest="${1#mcode-}"
      # All digits, and at least one.
      case "$rest" in
        ''|*[!0-9]*) return 1 ;;
      esac
      return 0
      ;;
    *) return 1 ;;
  esac
}

# The agent's NAME - what `herdr agent get <name>` resolves - read back from
# herdr rather than guessed, when herdr has one to give.
#
# THIS IS NOT AVAILABLE FOR EVERY PANE, and the difference is worth stating
# precisely, because a review of this function (m4, on #93) measured one pane,
# found no `name`, and concluded the field does not exist. Measured here on
# 0.9.3, in an isolated instance, register-then-rename:
#
#   agent get <pane>  BEFORE any rename   -> no `name` key at all
#   agent rename <pane> mcode-3           -> {"name":"mcode-3", ...}
#   agent get <pane>  AFTER the rename    -> {"name":"mcode-3", ...}
#   agent list                             -> `.name` for renamed agents, absent
#                                            for panes that were never renamed
#
# So both shapes are real, and which one a pane has is the whole question:
#
#   * a pane the LAUNCHER started was renamed by `agent rename`, so it HAS a
#     name, and this read is what keeps the watcher from being handed the bare
#     label `mcode` for what is actually `mcode-3` — the second-pane divergence
#     CLAUDE.md records, and the reason this read exists.
#   * a pane some other source registered may never have been renamed, so there
#     is no name to read, and the event's own label is the honest thing to
#     report. That is not a degraded guess; the label is what `report-agent`
#     takes, and herdr keeps the name it was given regardless: measured, a pane
#     renamed to `mcode-3` still resolved by that name after two further
#     `report-agent` calls carrying `--agent minimax-code`.
#
# WHY `agent get <pane>` AND NOT A SCAN OF `agent list`. Both carry the name for
# a renamed agent, so this is about addressing rather than availability: the event
# names a PANE, and `agent get <pane>` answers for exactly that pane, whereas
# reading a list means matching the right row out of every agent in the session
# and being certain the match was the intended one. A per-pane key cannot be
# confused with a neighbour's.
resolve_agent_name() { # resolve_agent_name <pane-id> <fallback-label>
  local pane="$1" fallback="$2" name=""
  name="$("$HERDR" agent get "$pane" 2>/dev/null | json_field '.result.agent.name' || true)"
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  printf '%s\n' "$fallback"
}

cmd_ensure_watcher() {
  local event_json="${HERDR_PLUGIN_EVENT_JSON:-}"
  local pane agent

  if [ -z "$event_json" ]; then
    # Reachable by hand, and the diagnostic has to name the cause: this command
    # is meaningless outside an event, and an empty pane id would otherwise
    # silently do nothing at all.
    die "\`ensure-watcher\` is the manifest's \`pane.agent_status_changed\` handler and needs HERDR_PLUGIN_EVENT_JSON. Run it through \`${HERDR} plugin action invoke\` or by hand with that variable set; there is nothing to do otherwise."
  fi

  pane="$(printf '%s' "$event_json" | json_field '.data.pane_id')"
  if ! valid_pane_id "$pane"; then
    # A pane id from a JSON payload is data, and this value is about to be used
    # to build a path and to name a process. Refuse rather than coerce.
    die "\`ensure-watcher\` got no usable pane id from the event payload: $(printf '%q' "$pane"). Refusing to start a watcher for an unidentified pane. No watcher was started."
  fi

  # The scoping gate. Not an optimisation - see is_our_agent_label.
  agent="$(printf '%s' "$event_json" | json_field '.data.agent')"
  if ! is_our_agent_label "$agent"; then
    # Silent by design. This event fires for every agent in the session,
    # including agents this plugin has never heard of, and an event handler that
    # announced itself on every one of them would be a second source of noise in
    # a system that already has one. There is nothing to report here: not acting
    # on someone else's pane is the correct outcome, not a problem.
    return 0
  fi

  # Same opt-out as the launch path. See watcher_autostart for the caveat that
  # this only sees the value if it was exported into the environment herdr
  # itself was started from.
  if [ "${MCODE_WATCH_AUTOSTART:-1}" = "0" ]; then
    return 0
  fi

  # No third argument: this runs detached inside the herdr server, so a line on
  # stderr has no reader. The watcher's own log is the place for this story.
  ensure_watcher "$pane" "$(resolve_agent_name "$pane" "$agent")"
}

main() {
  case "${1:-}" in
    start)
      cmd_start
      ;;
    ensure-watcher)
      cmd_ensure_watcher
      ;;
    *)
      log "usage: mcode-plugin.sh start | ensure-watcher"
      exit 2
      ;;
  esac
}

main "$@"
