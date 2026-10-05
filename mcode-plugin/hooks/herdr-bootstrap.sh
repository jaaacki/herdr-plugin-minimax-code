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
  # Every line that reaches stderr is also made durable. Routing it here rather than
  # adding a dlog call at each step means a new log line cannot be added later that
  # quietly skips the durable record — the two can no longer drift apart.
  dlog "$*"
}

# ---- DURABLE LOG -------------------------------------------------------------
# WHY THIS EXISTS. The one real-machine run of this hook, on 2026-10-05, registered
# nothing and left no evidence at all: the command was malformed, mcode's TUI
# consumed the hook's stderr, and every observable — pane status, watcher processes,
# herdr's own request log — was equally consistent with "the hook never ran" and
# "the hook ran and failed". stderr is not a diagnostic, it is a stream something
# else decides whether to show you. This file is the diagnostic.
#
# WHERE. Under the plugin's own state directory, never beside the script: mcode runs
# hooks from a content-addressed, read-only snapshot, so a write next to this file
# either fails or lands in a throwaway copy that is deleted with the snapshot.
# HOME is one of the few variables m3 measured as reaching a live hook, so this path
# resolves from inside the stripped environment.
#
# BOUNDED. One line per step, and the file is trimmed to its tail once it passes
# DLOG_MAX_BYTES. A diagnostic that can grow without limit on someone's machine is
# not a diagnostic, it is a leak. Trimming keeps the last 200 lines, which spans
# several sessions and still shows whether the current one started at all.
#
# NEVER FAILS THE HOOK. Every write is `|| true` and the mkdir is guarded. A
# registration must never be lost because a log line could not be written; if this
# file cannot be written, the hook's actual job still runs and still decides for
# itself. The log is an observer here, not a participant.
DLOG_DIR="${MINIMAX_DATA_DIR:-$HOME/.minimax}/state/herdr-bootstrap"
DLOG_FILE="$DLOG_DIR/hook.log"
DLOG_MAX_BYTES=65536
DLOG_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

dlog() {
  local sz
  mkdir -p "$DLOG_DIR" 2>/dev/null || return 0
  if [ -f "$DLOG_FILE" ]; then
    sz="$(wc -c < "$DLOG_FILE" 2>/dev/null || echo 0)"
    case "$sz" in '' | *[!0-9]*) sz=0 ;; esac
    if [ "$sz" -gt "$DLOG_MAX_BYTES" ]; then
      tail -n 200 "$DLOG_FILE" > "$DLOG_FILE.tmp" 2>/dev/null &&
        mv "$DLOG_FILE.tmp" "$DLOG_FILE" 2>/dev/null
    fi
  fi
  printf 'herdr-bootstrap %s pid=%s %s\n' "$DLOG_TS" "$$" "$*" >> "$DLOG_FILE" 2>/dev/null || true
  return 0
}

# Chained onto the existing cleanup trap, not replacing it: the probe directory must
# still be removed on the way out, and the exit code is the single most useful line
# in the file when a run registers nothing.
dlog_exit() {
  dlog "exit=$?"
  cleanup_probe_dir
  return 0
}

# ---- the once-guard ----------------------------------------------------------
# ONE REPORT PER SESSION, claimed by a directory, because mkdir is atomic.
#
# WHY THIS EXISTS, AGAINST THE HEADER'S OWN CLAIM. The top of this file says it
# reports agent state exactly ONCE, on SessionStart, and never again. Measured on
# the authorised run, it did not: pane wT:p8J was registered at 16:30:52 by hook pid
# 18615 and again at 16:36:17 by hook pid 84070, and both hook processes were
# parented by the SAME mcode process — both chains end "... 27434 14173 710". One
# session, one mcode process, two SessionStart events, two registrations of one
# pane. That is precisely the two-writers-on-one-field fight that the absence of a
# Stop handler exists to prevent, and it happened anyway.
#
# WHY A DIRECTORY AND NOT A FILE. mkdir is the claim that is atomic between two
# processes on every filesystem this runs on, and it is already the mechanism this
# repo uses for the watcher's spawn race (#120, #121). A `>` redirect is
# check-then-act, which is the bug that fix was written against.
#
# WHY IT FAILS OPEN, EVERY TIME, AND THE ASYMMETRY IS THE POINT. Three ways this can
# go wrong, and all three report:
#   * no session_id in the payload -> nothing to key on, so no guard
#   * the marker dir is unwritable -> nothing to record in, so no guard
#   * the report itself failed   -> the claim is RELEASED below, so a later fire of
#                                   the same session can retry
# Reporting twice is the behaviour that exists today and is recoverable. Silently
# not reporting leaves a pane unregistered with nothing in any log to explain it. A
# guard that can swallow a registration is worse than the double registration it
# prevents, so every uncertain path here reports.
#
# WHY IT IS KEYED ON THE SESSION AND NOT THE PANE. The harm is two writers on one
# pane's field, but "already done" is a fact about the SESSION. Keying on the pane
# would suppress a genuinely different session that happened to land in the same
# pane, and that pane would then carry no registration at all. The suite proves both
# directions: two fires of one session report once, two sessions in one pane report
# twice.
#
# BOUNDED. One empty directory per session, pruned past GUARD_TTL_MIN. A re-fire is
# minutes apart; a marker that outlives a day is only costing disk, and this runs on
# every session a user starts.
GUARD_TTL_MIN=1440
REPORTED_DIR=""
GUARD_MARKER=""

prune_reported() {
  if [ -n "$REPORTED_DIR" ] && [ -d "$REPORTED_DIR" ]; then
    find "$REPORTED_DIR" -mindepth 1 -maxdepth 1 -type d -mmin "+$GUARD_TTL_MIN" \
      -exec rmdir {} + 2>/dev/null || true
  fi
  return 0
}

# claim_report <session-id>
#   0 claimed (caller owns it, and MUST release it if the report fails)
#   1 already reported by an earlier fire of this session
#   2 no guard possible — the caller reports unguarded
claim_report() {
  local sid="$1" key
  [ -n "$sid" ] || return 2
  # The id becomes a FILENAME, so it is sanitised rather than trusted. The `sid-`
  # prefix means the name can never be "." or ".." whatever the payload said. A
  # session id is not attacker-controlled today, but a hook that builds a path out
  # of stdin does not get to assume that.
  key="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_' 2>/dev/null || true)"
  [ -n "$key" ] || return 2
  REPORTED_DIR="$DLOG_DIR/reported"
  mkdir -p "$REPORTED_DIR" 2>/dev/null || return 2
  GUARD_MARKER="$REPORTED_DIR/sid-$key"
  [ -d "$GUARD_MARKER" ] && return 1
  mkdir "$GUARD_MARKER" 2>/dev/null || return 2
  prune_reported
  return 0
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
# The bound is a BACKSTOP, not the defence: correctness comes from examining every
# pane, and the design below is what makes examining every pane cheap enough to do.
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

# ---- why the scan is exhaustive, and why that is now affordable ------------------
# The outcome must not depend on which session or pane happens to be scanned first.
# Nothing is preselected and nothing is scored on arrival: the only way to know
# which match is NEAREST is to look at every pane, and the only way to be sure the
# answer is not "we ran out of time" is to finish.
#
# Session preselection — scan only the session whose SERVER pid is in the hook's
# ancestry — is NOT possible on herdr 0.9.3. Measured, not assumed:
#
#   * `herdr session list --json` answers with `default`, `name`, `running`,
#     `session_dir` and `socket_path`. No pid. `herdr status server` carries none
#     either; it reports status, version, protocol and socket.
#   * The bundled schema (`herdr api schema --json`, 272 KB on 0.9.3) holds exactly
#     two pid fields in the entire document, and both are PER PANE:
#     `PaneProcessInfo.shell_pid` and `PaneProcessInfoProcess.pid`. `pane list`
#     itself carries no pid at all — its keys are agent_session, agent_status,
#     cwd, focused, foreground_cwd, pane_id, revision, scroll, tab_id, terminal_id,
#     terminal_title, terminal_title_stripped, workspace_id — and there is no bulk
#     process-info request, so even a session's worth of anchors costs one call per
#     pane by design.
#   * The process table cannot supply the missing link. Every server on the machine
#     runs the identical argv `herdr server`, with no session dir and no socket
#     argument (measured: pid 710 under the default-root session). A server pid in
#     the ancestry — and the server IS in the chain, `hook -> mcode -> pane shell
#     -> server` — proves THAT a herdr server is an ancestor and never WHICH
#     session it is.
#
# So the scan is bounded by COST, not by selection, and this block spends its
# effort on cost. Per pane the work is one `pane process-info` call (measured
# ~10 ms against real herdr) plus one jq. Run sequentially, 300 panes is ~3 s
# against a 3 s budget, so a pane in the LAST of three 100-pane sessions would be
# lost to the clock — an answer that depends on scan order, which is the defect
# this exists to remove. Two things fix that, and both are here:
#
#   1. Probing PROBE_LANES panes at a time. Rounded, 300 panes is ~0.5 s.
#   2. ONE jq per pane that extracts the anchors AND computes the rank. The rank
#      used to be computed in the shell — `grep -n`, `head`, `cut` per anchor pid
#      — which was four forks per anchor on top of the herdr call, and forks
#      dominated the scan. Ranking inside the jq that already had to parse the
#      response removed them.

# Pane probes run this many at a time. Eight is where a 300-pane scan lands near
# half a second while leaving ample room inside mcode's 5 s ceiling. Deliberately
# NOT a knob: m3's standing note is that test-only knobs which read as production
# settings are a liability, and nothing here needs to vary it.
PROBE_LANES=8

# Scratch space for the scan: one file per probe verdict. Per-pane files rather
# than one shared file so two probes can never interleave into one another, which
# means no assumption about atomic appends is needed anywhere in this file.
#
# Created by main(), not by discover_pane(), and that detail is load-bearing:
# discover_pane is called in a COMMAND SUBSTITUTION, so anything it creates lives
# in a subshell that exits before main does, and the cleanup trap installed in the
# parent would never see the path. Created in the parent, it is always removed.
PROBE_DIR=""

# /bin/rm, never a bare `rm` and never a trash can: issue #109 forbids both. The
# path is mktemp's own, and the guard refuses to act on anything not under TMPDIR.
cleanup_probe_dir() {
  [ -n "$PROBE_DIR" ] || return 0
  case "$PROBE_DIR" in
    "${TMPDIR:-/tmp}"/*) /bin/rm -rf "$PROBE_DIR" 2>/dev/null ;;
    *) : ;;
  esac
  PROBE_DIR=""
  return 0
}
trap dlog_exit EXIT

# rank_for_pane <socket> <pane_id> <chain>
#
# Prints the chain rank of the NEAREST anchor this pane owns, or nothing when the
# pane owns none of them. Anchors, shell_pid first: the foreground group moves per
# job, so the shell is the stable one, and the foreground pids are what let a pane
# running mcode match on the mcode process itself.
#
# The rank is computed inside the jq that already has to read the response. It used
# to be a shell loop over `grep -n | head | cut`, one pipeline per anchor pid.
rank_for_pane() {
  local sock="$1" pane_id="$2" chain="$3" procs

  # `pane process-info` takes --pane on 0.9.3, not a positional argument.
  procs="$(h_ "$sock" pane process-info --pane "$pane_id")" || return 0

  printf '%s' "$procs" | jq -r --arg chain "$chain" '
    # chain position -> index, so a pid can be looked up without a shell loop
    ($chain | split(" ") | to_entries | map({key: .value, value: .key}) | from_entries) as $at
    | [ (.result.process_info.shell_pid // empty),
        (.result.process_info.foreground_process_group_id // empty),
        ((.result.process_info.foreground_processes // [])[].pid) ]
    | map(tostring)
    | map(select(test("^[0-9]+$")))
    | map($at[.] // empty)
    | min // empty' 2>/dev/null
}

# probe_pane_to <socket> <pane_id> <outfile> — probe one pane, record the verdict.
# Runs in the background, so it touches nothing but its own result file. The chain
# is inherited from the caller's scope, which a background subshell does inherit.
probe_pane_to() {
  local sock="$1" pane_id="$2" out="$3" rank
  rank="$(rank_for_pane "$sock" "$pane_id" "$chain")"
  printf '%s\t%s\t%s\n' "${rank:-}" "$pane_id" "$sock" >"$out" 2>/dev/null
  return 0
}

# probe_pass <candidates_only: 1|0>
#
# Walks the indexed panes and leaves the nearest match in the CALLER's best_pane /
# best_rank / best_sock. bash scoping is dynamic, so assigning them here without
# declaring them local writes the caller's variables rather than a copy — that is
# deliberate, and it is why this takes no output argument and returns no verdict.
#
# Batching: probes run a batch at a time and the batch is evaluated before the next
# one starts. The first batch is ONE pane and the width then doubles to
# PROBE_LANES. A fixed width would make the common case pay for parallelism it does
# not need — with the matching pane first, eight probes would be launched before any
# of them was read, and every session start would cost eight herdr round trips
# where one would do. The ramp changes only HOW MANY probes are in flight, never
# which panes are eligible, so it cannot change the answer, only how long it takes.
probe_pass() {
  local only_candidates="$1"
  local n=0 launched lanes=1 i rank pane cand_sock total=${#A_SOCK[@]}

  while [ "$n" -lt "$total" ]; do
    [ "$definitive" -eq 1 ] && break
    budget_left "$start_ms" || { truncated=1; break; }

    launched=0
    while [ "$n" -lt "$total" ] && [ "$launched" -lt "$lanes" ]; do
      if [ "$only_candidates" != "1" ] || [ "${A_CAND[$n]:-0}" = "1" ]; then
        # stdin comes from /dev/null: these run while the parent is mid-loop, and
        # an inherited stdin would let a probe swallow the parent's input.
        probe_pane_to "${A_SOCK[$n]}" "${A_PANE[$n]}" "$PROBE_DIR/result.$n" </dev/null &
        launched=$((launched + 1))
      fi
      n=$((n + 1))
    done
    wait 2>/dev/null

    i=$((n - launched))
    while [ "$i" -lt "$n" ]; do
      rank=""
      pane=""
      cand_sock=""
      if [ -f "$PROBE_DIR/result.$i" ]; then
        IFS=$'\t' read -r rank pane cand_sock <"$PROBE_DIR/result.$i" || true
      fi
      case "$rank" in
        '' | *[!0-9]*) : ;;
        *)
          if [ "$rank" -lt "$best_rank" ]; then
            best_rank="$rank"
            best_pane="$pane"
            best_sock="$cand_sock"
          fi
          # EARLY EXIT, and this is what keeps the common case cheap.
          #
          # A match at rank 0 is this very process and rank 1 is its `mcode`
          # parent. Either one is definitive: the chain only gets further away as
          # the index grows, so no unexamined pane can beat it.
          #
          # Note what this does NOT do: it is not what makes the answer
          # order-independent. The pass finishes in full unless it finds a match
          # that cannot be beaten, and when the prefilter misses the full scan runs
          # anyway, so the answer is the same whatever order sessions and panes came
          # back in. This only avoids paying for panes that cannot change it.
          if [ "$best_rank" -le 1 ]; then
            definitive=1
            break
          fi
          ;;
      esac
      i=$((i + 1))
    done

    [ "$lanes" -lt "$PROBE_LANES" ] && lanes=$((lanes * 2))
    [ "$lanes" -gt "$PROBE_LANES" ] && lanes="$PROBE_LANES"
  done
}

discover_pane() { # discover_pane <chain> <hook_cwd>
  local chain="$1" hook_cwd="$2"
  local start_ms best_sock="" best_pane="" best_rank=999999
  local sock running pane_id panes_json is_cand
  # `definitive` = a match nothing can beat, so the scan may stop. `truncated` =
  # the budget cut the search short, which must never look like a clean sweep.
  local definitive=0 truncated=0 fell_back=0

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

  # ---- pass one: one `pane list` per session, and mark the candidates -----------
  #
  # Every running session is asked for its panes exactly once. From that single
  # answer each pane is recorded twice over: it is always a candidate for the
  # fallback, and it is a CANDIDATE for the cheap pass when its `cwd` or
  # `foreground_cwd` equals the hook's cwd.
  #
  # cwd is a PREFILTER AND NOTHING MORE. Two panes in one directory is a documented
  # collision in this repo, which is exactly why cwd is never allowed to identify a
  # pane — so a cwd match here buys one `process-info` call and decides nothing. The
  # shell_pid / foreground-pid ancestry match is still the only thing that can
  # register a pane, and if the ancestry match fails the pane is discarded exactly
  # as if its cwd had never been looked at. The win is arithmetic: the expensive
  # per-pane call is spent on a handful of candidates instead of on all of them.
  local -a A_SOCK=() A_PANE=() A_CAND=()
  while IFS=$'\t' read -r sock running; do
    [ -n "$sock" ] || continue
    case "$sock" in
      /*) : ;;
      *) continue ;;
    esac
    [ "$running" = "true" ] || continue
    budget_left "$start_ms" || { truncated=1; break; }

    panes_json="$(h_ "$sock" pane list)" || continue
    printf '%s' "$panes_json" | jq -e '.result.panes' >/dev/null 2>&1 || continue

    while IFS=$'\t' read -r pane_id is_cand; do
      [ -n "$pane_id" ] || continue
      A_SOCK+=("$sock")
      A_PANE+=("$pane_id")
      A_CAND+=("${is_cand:-0}")
    done < <(printf '%s' "$panes_json" | jq -r --arg c "$hook_cwd" '
      .result.panes[]
      | [ .pane_id,
          (if (.cwd == $c or .foreground_cwd == $c) then "1" else "0" end) ]
      | @tsv' 2>/dev/null)
  done < <(printf '%s' "$sessions_json" \
    | jq -r '.sessions[] | select(.running == true) | [.socket_path, "true"] | @tsv' 2>/dev/null)

  # Only RUNNING sessions are indexed, and each is addressed by the socket_path the
  # enumeration itself returned — so the socket and the panes come from the same
  # answer, and a session can never be selected by a name this script guessed.
  #
  # The gate is `running`, not "is this path a socket". `running` is herdr's own
  # answer about a live server; a `-S` test would only re-ask the filesystem a
  # question herdr has already answered, would reject a perfectly good socket on
  # any platform that models one differently, and buys nothing: a socket with no
  # server behind it answers `server_not_running` in about a millisecond, and the
  # deadline bounds the loop either way.

  probe_pass 1

  if [ -z "$best_pane" ] && [ "$definitive" -eq 0 ] && [ "$truncated" -eq 0 ]; then
    # ---- pass two: the fallback, and it is never silent ------------------------
    # The prefilter found nothing that the ancestry would accept. That is an
    # ordinary outcome — a pane's `cwd` can differ from the project directory, and
    # a `cd` between launch and SessionStart moves it — so the full budgeted scan
    # runs and the answer is still the ancestry's to give. What is NOT ordinary is
    # doing that quietly: a user whose pane never registers needs to be able to
    # tell "no pane matched" from "the cheap path missed and we paid for the
    # thorough one", so it is said out loud, with the cost it just incurred.
    fell_back=1
    log "no pane whose cwd matched was PROVEN by ancestry; running the full scan over every pane."
    probe_pass 0
  fi

  # A TRUNCATED SCAN MUST SAY SO. If the budget cut the search short, the match we
  # hold may not be the nearest one, and a caller reading only "proved pane X" would
  # take that as a complete search. This is the same failure class as the one this
  # issue already fought — a silent "enabled, nothing happened" — re-entering
  # through a performance ceiling, so it is stated in the log rather than inferred.
  #
  # It costs SPEED, never the registration: best_pane is deliberately kept, so a
  # trip still registers the pane it found and says the answer may not be nearest.
  # An earlier revision of this file claimed the opposite — that a machine with
  # ~85 panes "exhausted the budget and the hook refused", leaving the pane never
  # registered. That was m3's reading of an earlier revision; it was retracted, and
  # this hook has never done it.
  if [ "$fell_back" -eq 1 ]; then
    if [ -n "$best_pane" ]; then
      log "the full scan proved pane $best_pane at rank $best_rank."
    else
      log "the full scan proved no pane either."
    fi
  fi
  if [ "$truncated" -eq 1 ]; then
    log "WARNING: the ${DEADLINE_SECONDS}s search budget expired mid-scan."
    if [ -n "$best_pane" ]; then
      log "WARNING: using pane $best_pane at rank $best_rank anyway, but it may NOT be the nearest pane; some were never examined."
    else
      log "WARNING: no pane was examined before the budget expired."
    fi
  elif [ "$fell_back" -eq 0 ] && [ -n "$best_pane" ]; then
    log "prefilter matched; cost was ${#A_SOCK[@]} pane(s) listed and fewer probed than a full scan would need."
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

  local chain found sock pane_id rank hook_cwd hook_sid guard_claimed=0
  chain="$(chain_walk)"
  log "ancestry chain: $chain"

  # The SessionStart payload, read once and BOUNDED — but only briefly.
  #
  # mcode writes a JSON object on the hook's stdin carrying session_id, prompt_id,
  # transcript_path, cwd and model (measured on mcode 0.6.2), one line, and it does
  # so BEFORE spawning the hook, so the bytes are already in the pipe when this
  # process starts. Half a second is therefore not a race: it is slack.
  #
  # The obvious `payload="$(cat)"` is a hang — any caller that invokes the hook
  # with an open pipe and no payload leaves `cat` waiting for an EOF that never
  # comes. The e2e harness does exactly that, and the hang was real. `read -t` is a
  # builtin, so it costs no fork, and it gives up.
  #
  # WHY THE WINDOW IS 0.5s AND NOT 2s. The first version used 2s and it was my own
  # regression: the e2e stand-in runs the hook with no payload, so every such run
  # paid a flat 2 seconds before doing any work, against a 10s window, and the
  # hook case went flaky on a loaded machine. A missed payload costs NOTHING here,
  # because the two fallbacks below resolve to the same directory that mcode
  # reports — so paying real time for a nicety is the wrong trade.
  # WHY THE WINDOW IS AN INTEGER. A fractional `read -t 0.5` is rejected outright by
  # bash 3.2 — "invalid timeout specification", non-zero, variable left empty — and
  # bash 3.2 is /bin/bash on macOS, which is the platform this plugin targets. The
  # failure is silent by construction: the payload simply comes back empty and the
  # hook falls back to its own directory, so the prefilter quietly stops working on
  # exactly the platform where the rest of it was measured. Integer timeouts work on
  # both 3.2 and 5.x.
  local payload=""
  if [ ! -t 0 ]; then
    IFS= read -r -t 1 payload 2>/dev/null || true
  fi
  hook_sid="$(printf '%s' "$payload" | jq -r 'if type == "object" then (.session_id // empty) else empty end' 2>/dev/null || true)"
  # Logged on EVERY fire, including fires that end up reporting nothing. Issue #126
  # is a question about which sessions fired at all, and the durable log could not
  # answer it because it never recorded the one identifier that distinguishes one
  # session from the next. A future occurrence should be diagnosable from the file
  # rather than reconstructed from a pane list weeks later.
  log "session id: ${hook_sid:-<none: the payload carried no session_id>}"
  hook_cwd="$(printf '%s' "$payload" | jq -r 'if type == "object" then (.cwd // empty) else empty end' 2>/dev/null || true)"
  if [ -n "$hook_cwd" ]; then
    log "prefilter cwd (from the SessionStart payload): $hook_cwd"
  elif [ -n "${MINIMAX_PROJECT_DIR:-}" ]; then
    # mcode's own project-directory variable, measured present in a live hook's
    # environment. Free, and identical to what the payload would have said.
    hook_cwd="$MINIMAX_PROJECT_DIR"
    log "prefilter cwd (from MINIMAX_PROJECT_DIR, the payload was unavailable): $hook_cwd"
  else
    hook_cwd="$(pwd 2>/dev/null || true)"
    log "prefilter cwd (no payload and no MINIMAX_PROJECT_DIR; using the hook's own cwd): $hook_cwd"
  fi

  # Created HERE, in the parent, and not inside discover_pane: discover_pane runs in
  # a command substitution, so a directory it made would belong to a subshell that
  # is gone before this line returns, and the EXIT trap would have nothing to clean.  # Fail closed if it cannot be made — a scan with nowhere to put its verdicts has
  # proved nothing, and an unproved pane must never be reported.
  if ! PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcode-herdr-probe.XXXXXX" 2>/dev/null)"; then
    log "cannot create a scratch directory for the pane scan; refusing to register."
    PROBE_DIR=""
    return 0
  fi

  if ! found="$(discover_pane "$chain" "$hook_cwd")"; then
    log "no herdr pane is proven by this process ancestry; refusing to register."
    log "NOT falling back to any session: an unproven pane must never be reported."
    return 0
  fi

  sock="$(printf '%s' "$found" | cut -f1)"
  pane_id="$(printf '%s' "$found" | cut -f2)"
  rank="$(printf '%s' "$found" | cut -f3)"
  log "proved pane $pane_id in session socket $sock at chain rank $rank"

  # THE ONCE-GUARD, AND IT SITS HERE ON PURPOSE — after the ancestry walk and the
  # proof, not at the top of the file. A suppressed re-fire must still leave its
  # chain, its cwd and its proved pane in the durable log. Short-circuiting early
  # would make "fired and was suppressed" indistinguishable from "never fired",
  # which is exactly the ambiguity that made issue #126 expensive to reason about.
  local guard_rc=2
  claim_report "${hook_sid:-}" && guard_rc=0
  [ "$guard_rc" = "0" ] || [ ! -d "${GUARD_MARKER:-/nonexistent}" ] || guard_rc=1
  case "$guard_rc" in
    1)
      log "session ${hook_sid:-} was ALREADY reported once; not reporting again."
      log "the watcher owns this pane from here; a second writer is the fight this file exists to prevent."
      return 0
      ;;
    2)
      log "no once-guard available for session ${hook_sid:-<none>}; reporting unguarded."
      ;;
  esac

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
    # THE CLAIM IS RELEASED. A session whose first attempt was refused must not be
    # permanently suppressed by its own failed attempt — that would turn a
    # transient herdr refusal into a session that never appears, with nothing in
    # the log to say why. Claimed-but-failed and never-claimed are the same state.
    if [ -n "${GUARD_MARKER:-}" ]; then
      rmdir "$GUARD_MARKER" 2>/dev/null || true
      log "released the once-guard claim, so a later fire of this session can retry."
    fi
  fi
  return 0
}

main "$@"
exit 0
