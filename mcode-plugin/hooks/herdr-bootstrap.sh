#!/usr/bin/env bash
# mcode SessionStart hook — bootstrap ONE herdr registration, then get out of the way.
#
# ---- WHAT THIS DOES, AND WHAT IT DELIBERATELY DOES NOT ------------------------
# It reports agent state exactly ONCE, on SessionStart, and never again. The
# registration that single call creates is what starts the state reporter: herdr
# fires `pane.agent_status_changed`, and this plugin's existing `ensure-watcher`
# action starts `bin/mcode-watch.sh` for the pane. The watcher owns working/idle
# from that point on.
#
# ONE REPORTER PER PANE IS THE WHOLE POINT. This hook and the watcher both declare
# `--source herdr:minimax-code`, so if both reported they would be two writers of
# one field on one pane and would fight: the hook would say `working` from
# UserPromptSubmit while the watcher's screen rules said `idle`, and herdr's state
# would flip on whichever landed last. That is why this file declares no Stop,
# PreToolUse or UserPromptSubmit handler, and why it has no release path at all.
# The absence is the design, not an omission.
#
# In particular there is NO `release-agent` call anywhere, including at Stop.
# `release-agent` DELETES a registration rather than handing authority back
# (measured on 0.9.3, recorded in bin/mcode-watch.sh), and Stop is a TURN
# boundary, not a session end — releasing there would delete the registration out
# from under a live session. Deregistration is left entirely to herdr's pane scope.
#
# ---- WHY THE PANE IS FOUND BY PROCESS ANCESTRY --------------------------------
# Measured on mcode 0.6.2, herdr 0.9.3, darwin arm64 (full writeup in CLAUDE.md):
# a plugin hook CANNOT learn its pane from the environment.
#
#   * mcode hands hooks a SANITIZED environment — 57 variables, zero of them
#     `HERDR_*`, even when the shell that launched mcode had `HERDR_PANE_ID` set.
#     An exported variable of your own does not reach the hook either, which is
#     how a probe can log to /dev/null and look exactly like "plugin enabled but
#     no events fire".
#   * `${HERDR_PANE_ID}` in a hook `command` expands from that same sanitized map,
#     so it becomes the empty string with no error.
#   * The stdin JSON payload carries `session_id`, `prompt_id`, `transcript_path`,
#     `cwd` and `model`. No pane id, no herdr field.
#   * The hook has NO controlling terminal: tty_stdin, tty_stdout and tty_stderr
#     are all false, in `mcode exec` AND in the interactive TUI. The terminal
#     device cannot identify the pane either.
#
# Process ancestry is the one channel left, and it works because mcode is a child
# of the pane's shell. Measured in an isolated session: pane `w1:p1` reported
# `shell_pid 90385`, and a hook fired from the TUI in it walked
# `4563 (hook) -> 93121 (minimax-code) -> 90385 (pane shell) -> 90320 (server)`.
# The pane's `shell_pid` sits at index 2. This is the nearest-first walk of
# pc-tools `fleet/flock/identity.ts` `discoverPane` / `paneAnchorPids`, binding by
# the PROCESS TREE rather than by a claimable environment variable. `cwd` is never
# used to identify a pane: two mcode panes in one cwd is a documented collision in
# this repo, and a cwd-keyed guess would inherit it.
#
# ---- WHY THIS TARGETS A SOCKET AND NEVER A SESSION NAME -----------------------
# `HERDR_SOCKET_PATH` is stripped from the hook environment along with everything
# else, so a bare `herdr` call resolves to the DEFAULT session's socket — measured:
# from a stripped environment, bare `herdr pane list` reaches the default socket
# and nothing else. If this pane lives in any other session, a bare call reports to
# the wrong server.
#
# `--session <name>` is not used either. It cannot be trusted as a selector: the
# name is resolved against a config root the hook cannot see, so the same name can
# denote a different server — or none. (For the record, `--session` against a
# session with no running server does NOT silently spawn one: it answers
# `server_not_running` and names the socket it looked for. The "or create" wording
# in `herdr --session --help` describes `session attach`/`server`, not a plain
# subcommand. Name-based targeting is still rejected here because a name is not a
# proof, and the socket is.)
#
# So every call below sets `HERDR_SOCKET_PATH` for the herdr process IT spawns.
# The stripping applies to the hook's inherited environment, not to the environment
# of a child the hook chooses to launch. Measured: `HERDR_SOCKET_PATH=<socket>
# herdr pane list` reaches exactly that session, and a wrong socket fails loudly
# with `server_not_running` naming that path — it does NOT silently fall back.
#
# If no pane can be proven, this refuses and writes nothing. There is no fallback.

set -uo pipefail

# TEST-ONLY KNOBS. All three are unreachable from a real hook: mcode strips every
# variable the user exported, so in production these are ALWAYS the defaults. They
# exist so the suite can drive this script directly, and they are named as test
# affordances on purpose. `MCODE_AGENT_SOURCE` is the dangerous one — a test could
# set a wrong `--source` and the suite would pass on a string the shipped hook can
# never produce. Do not add a knob here that reads as a production setting.
AGENT_LABEL="${MCODE_AGENT_LABEL:-mcode}"
AGENT_SOURCE="${MCODE_AGENT_SOURCE:-herdr:minimax-code}"

# herdr is resolved from PATH, because HERDR_BIN_PATH is one of the variables
# mcode strips. It is still honoured when present, so this script stays drivable
# from a test that runs it directly.
HERDR="${HERDR_BIN_PATH:-}"
if [ -z "$HERDR" ]; then
  HERDR="$(command -v herdr 2>/dev/null || true)"
fi

# ---- logging ------------------------------------------------------------------
# Never inside the plugin directory. mcode copies a plugin into a
# content-addressed, read-only snapshot before running its hooks
# (`PLUGIN_ROOT=~/.minimax/v2/plugin-hook-cache/sha256-tree-v1-<digest>`), so a
# write next to this script either fails or lands in a throwaway copy. stderr is
# always written, because that is what mcode keeps in its hook diagnostics.
log() {
  printf 'herdr-bootstrap: %s\n' "$*" >&2
}

# ---- the ancestry chain -------------------------------------------------------
# Walk order, index 0 = this process, NEAREST first. Nearest wins, so a nested
# mcode binds to the inner pane rather than the outer one.
chain_walk() {
  local cur=$$ out="" ppid n=0
  while [ "$n" -lt 24 ]; do
    out="$out $cur"
    ppid="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')"
    case "$ppid" in
      '' | 0) break ;;
    esac
    [ "$ppid" = "$cur" ] && break
    cur="$ppid"
    n=$((n + 1))
  done
  printf '%s' "${out# }"
}

# Call herdr against ONE specific session, by socket, never by name and never
# without qualification. `h_ <socket> <args...>`.
#
# herdr's stderr is folded into our log rather than discarded. This is the one place
# the hook used to be un-diagnosable exactly when it mattered: when herdr REFUSES a
# report-agent it says why on stderr, and throwing that away left a log line reading
# "herdr REFUSED the registration" with no reason attached. The whole `--source`
# story in this repo lives in errors herdr declines to print. A caller that sets
# `H_ERR` gets the text instead, so the discovery loop stays quiet.
h_() {
  local sock="$1"
  shift
  if [ -n "${H_ERR:-}" ]; then
    HERDR_SOCKET_PATH="$sock" "$HERDR" "$@" 2>>"$H_ERR"
  else
    HERDR_SOCKET_PATH="$sock" "$HERDR" "$@" 2>/dev/null
  fi
}

# ---- pane discovery -----------------------------------------------------------
# Prints "<socket>\t<pane>\t<rank>" for the NEAREST pane whose anchors appear in
# the chain, across every RUNNING session, or nothing when no pane is proven.
#
# Time-bounded on purpose. The hook budget is 5s and mcode kills an overrun by
# process group, so a slow walk is indistinguishable from a hook that never ran.
DEADLINE_SECONDS="${MCODE_HOOK_BUDGET_SECONDS:-3}"

now_ms() {
  local s
  s="$(date -u '+%s' 2>/dev/null || echo 0)"
  printf '%s' "$((s * 1000))"
}

budget_left() { # budget_left <start_ms>
  # Both operands are read into variables first. A command substitution nested
  # inside `$(( ))` is not worth the portability question at all, and the deadline
  # is the one thing that must not be the reason a hook is killed.
  local start="$1" now
  now="$(now_ms)"
  [ $(( (now - start) / 1000 )) -lt "$DEADLINE_SECONDS" ]
}

discover_pane() { # discover_pane <chain>
  local chain="$1" start_ms best_sock="" best_pane="" best_rank=999999
  local sock running pane_id procs anchors rank pid idx
  # `definitive` = a match nothing can beat, so the scan may stop. `truncated` =
  # the budget cut the scan short, which must never look like a clean sweep.
  local definitive=0 truncated=0

  start_ms="$(now_ms)"

  local sessions_json
  if ! sessions_json="$("$HERDR" session list --json 2>/dev/null)"; then
    log "herdr 'session list --json' failed; refusing to register."
    return 1
  fi
  if ! printf '%s' "$sessions_json" | jq -e '.sessions' >/dev/null 2>&1; then
    log "herdr 'session list --json' returned no .sessions array; refusing to register."
    return 1
  fi

  # Only RUNNING sessions are probed, and each is addressed by the socket_path the
  # enumeration itself returned — so the socket and the panes come from the same
  # answer, and a session can never be selected by a name this script guessed.
  #
  # The gate is `running`, not "is this path a socket". `running` is herdr's own
  # answer about a live server; a `-S` test would only re-ask the filesystem a
  # question herdr has already answered, would reject a perfectly good socket on
  # any platform that models one differently, and buys nothing: a socket with no
  # server behind it answers `server_not_running` in about a millisecond, and the
  # deadline below bounds the loop either way.
  while IFS=$'\t' read -r sock running; do
    [ -n "$sock" ] || continue
    case "$sock" in
      /*) : ;;
      *) continue ;;
    esac
    [ "$running" = "true" ] || continue
    budget_left "$start_ms" || { truncated=1; break; }

    local panes_json
    panes_json="$(h_ "$sock" pane list)" || continue
    printf '%s' "$panes_json" | jq -e '.result.panes' >/dev/null 2>&1 || continue

    while IFS= read -r pane_id; do
      [ -n "$pane_id" ] || continue
      budget_left "$start_ms" || { truncated=1; break; }
      # `pane process-info` takes --pane on 0.9.3, not a positional argument.
      procs="$(h_ "$sock" pane process-info --pane "$pane_id")" || continue

      # ONE jq, not three. The three values used to be extracted by three separate
      # forks of jq, and forks — not herdr — dominated the per-pane cost. They now
      # arrive as one TSV line. Measured on a 32-pane machine: 2 herdr + 3 jq per
      # pane was ~24 ms, and the whole scan had to fit a 3 s budget.
      anchors="$(printf '%s' "$procs" | jq -r '
        [ (.result.process_info.shell_pid // empty),
          (.result.process_info.foreground_process_group_id // empty),
          ((.result.process_info.foreground_processes // [])[].pid) ]
        | map(select(. != null and . != ""))
        | join(" ")' 2>/dev/null)" || continue
      [ -n "$anchors" ] || continue

      # Anchors, shell_pid first: the foreground group moves per job, so the shell
      # is the stable one, and the foreground pids are what let a pane running
      # mcode match on the mcode process itself.
      rank=999999
      for pid in $anchors; do
        case "$pid" in
          '' | *[!0-9]*) continue ;;
        esac
        idx="$(printf '%s\n' $chain | grep -n "^$pid$" | head -1 | cut -d: -f1)"
        [ -n "$idx" ] || continue
        idx=$((idx - 1))
        [ "$idx" -lt "$rank" ] && rank="$idx"
      done
      [ "$rank" -lt 999999 ] || continue

      if [ "$rank" -lt "$best_rank" ]; then
        best_rank="$rank"
        best_sock="$sock"
        best_pane="$pane_id"
      fi

      # EARLY EXIT, and this is the fix that makes the scan affordable.
      #
      # A match at rank 0 is this very process and rank 1 is its `mcode` parent.
      # Either one is definitive: no other pane can be nearer, because the chain
      # only gets further away as the index grows. So once one is found, the
      # remaining panes of this session and every later session cannot improve on
      # it, and continuing to ask herdr about them is pure cost.
      #
      # Without this the loop kept going after it had already proved its pane, and
      # the cost was O(all panes x all sessions) on EVERY session start. Measured
      # by m3 with a 3-session x 100-pane fixture and the match at session 2: the
      # pane was proved on about call 2 and the hook still spent 305. Against real
      # herdr that is ~24 ms per pane, so a machine with ~85 panes exhausted the
      # 3 s budget and the hook refused — the worst kind of failure, because the
      # pane silently never registers, and it fails on exactly the busy machines
      # where registration matters most.
      if [ "$best_rank" -le 1 ]; then
        definitive=1
        break
      fi
    done < <(printf '%s' "$panes_json" | jq -r '.result.panes[].pane_id' 2>/dev/null)
    [ "$definitive" -eq 1 ] && break
  done < <(printf '%s' "$sessions_json" \
    | jq -r '.sessions[] | select(.running == true) | [.socket_path, "true"] | @tsv' 2>/dev/null)

  # A TRUNCATED SCAN MUST SAY SO. If the budget cut the search short, the match we
  # hold may not be the nearest one, and a caller reading only "proved pane X" would
  # take that as a complete search. This is the same failure class as the one this
  # issue already fought — a silent "enabled, nothing happened" — re-entering
  # through a performance ceiling, so it is stated in the log rather than inferred.
  if [ "$truncated" -eq 1 ]; then
    log "WARNING: the ${DEADLINE_SECONDS}s search budget expired mid-scan."
    if [ -n "$best_pane" ]; then
      log "WARNING: using pane $best_pane at rank $best_rank anyway, but it may NOT be the nearest pane; some were never examined."
    else
      log "WARNING: no pane was examined before the budget expired."
    fi
  fi

  [ -n "$best_pane" ] || return 1
  printf '%s\t%s\t%s\n' "$best_sock" "$best_pane" "$best_rank"
}

main() {
  local event="${1:-unknown}"
  log "hook fired: event=$event pid=$$"

  if [ -z "$HERDR" ]; then
    log "herdr binary not found on PATH; refusing to register."
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log "jq not found; cannot read herdr JSON; refusing to register."
    return 0
  fi

  local chain found sock pane_id rank
  chain="$(chain_walk)"
  log "ancestry chain: $chain"

  if ! found="$(discover_pane "$chain")"; then
    log "no herdr pane is proven by this process ancestry; refusing to register."
    log "NOT falling back to any session: an unproven pane must never be reported."
    return 0
  fi

  sock="$(printf '%s' "$found" | cut -f1)"
  pane_id="$(printf '%s' "$found" | cut -f2)"
  rank="$(printf '%s' "$found" | cut -f3)"
  log "proved pane $pane_id in session socket $sock at chain rank $rank"

  # The single report, to the socket the ancestry proved. State is `idle`: the
  # session has just started and no turn is running. From here the watcher owns
  # state, and this hook never reports again.
  if h_ "$sock" pane report-agent "$pane_id" \
    --source "$AGENT_SOURCE" \
    --agent "$AGENT_LABEL" \
    --state idle; then
    log "registered pane $pane_id (source=$AGENT_SOURCE agent=$AGENT_LABEL state=idle); the watcher owns state from here."
  else
    # Not fatal: herdr refused, and no registration is better than a wrong one.
    log "herdr REFUSED the registration for pane $pane_id; nothing was registered."
  fi
  return 0
}

main "$@"
exit 0
