#!/usr/bin/env bash
# tests/e2e/run.sh — end-to-end check against a REAL herdr.
#
# WHY THIS EXISTS. Every other suite in this repo stubs herdr out via
# tests/fake-herdr. That is the right design for CI and it has one exact blind
# spot: nothing ever checks the plugin against a real multiplexer. Two things
# shipped broken in v0.2.0 for that reason — ${HERDR_PLUGIN_ROOT} reached a
# manifest herdr had never loaded, and agent registration was simply absent.
# Both were verified only against a stub.
#
# THIS SUITE IS NOT A UNIT TEST. It installs herdr, starts a real server, links
# the plugin, invokes the real action, and asserts against real panes.
#
# Run it:            ./tests/e2e/run.sh
#
# It EXITS NON-ZERO WHEN HERDR IS ABSENT. It does not skip. A test that skips
# itself converts an honest gap into a false assurance, which is worse than no
# test at all — see the CI wiring note at the bottom of this file.
#
# ── A NOTE ON CI DISCOVERY, READ BEFORE TRUSTING THIS ──────────────────────────
# .github/workflows/ci.yml discovers suites with the glob `tests/*run.sh`. Bash's
# `*` does not cross `/`, so this file at tests/e2e/run.sh is NOT matched by that
# glob and will not run in CI as things stand. That is deliberate silence on my
# part rather than an oversight: the alternative — renaming this file to
# tests/e2e-run.sh — would place it outside the tests/e2e/ directory that issue
# #42 assigns me, and I do not edit files I do not own.
#
# Making it run in CI needs two changes in .github/workflows/ci.yml, which is
# not mine to edit. The patch, ready to apply:
#
#   - name: Install herdr
#     shell: bash
#     run: curl -fsSL https://herdr.dev/install.sh | sh
#
#   # in the existing "Run every test suite" step, widen the glob so a suite in
#   # a subdirectory is not invisible. globstar is off by default, so `*` does
#   # not cross `/` and `tests/e2e/run.sh` is NOT matched by `tests/*run.sh`.
#   shopt -s nullglob globstar
#   suites=(tests/**/run.sh)
#
# The herdr install is not a convenience: this suite exits 2 with a FATAL message
# when herdr is missing, so without that step CI goes red loudly rather than
# silently skipping. That is the intended behaviour, not a misconfiguration.

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../.." && pwd)"

PLUGIN_ID="jaaacki.minimax-code"
ACTION_ID="$PLUGIN_ID.minimax-code-start"
AGENT_LABEL="mcode"
# The plugin action's own log, captured from the FIRST server while it still has
# it in memory. Declared here, not inside the case, because a case that fails
# before it gets that far must still be able to quote it — and under `set -u`
# referencing it unassigned kills the case with "unbound variable", which is a
# worse failure than the one being reported.
ACTION_LOG=""

CASES_RUN=0
CASES_FAILED=0
ANY_FAILED=0
SESSION=""
SERVER_PID=""
WORKDIR=""
PRIOR_LINK=""
LINKED_BY_US=""
THROWAWAY_PANE=""
FOREIGN_PANE=""
# Every pane this suite creates, so cleanup can tear down all of them. The launch
# action auto-starts a DETACHED watcher per pane (MCODE_WATCH_AUTOSTART), and a
# watcher outlives the pane only if nothing stops it — it polls herdr forever. A
# watcher left running from a test run is a real process doing real work against
# whichever server it inherited, and tests/run.sh case-22 has a probe whose entire
# job is to catch exactly that. It caught one of mine.
#
# Recording panes in one list rather than one variable per case is what makes it
# exhaustive: the first version cleaned up only the two #84 cases' panes, and the
# launch pane's watcher was left to luck.
CREATED_PANES=""

note_created_pane() { # note_created_pane <pane-id>
  local p="$1"
  [ -n "$p" ] || return 0
  case "
$CREATED_PANES
" in
    *"
$p
"*) : ;;
    *) CREATED_PANES="${CREATED_PANES}${CREATED_PANES:+
}$p" ;;
  esac
}

# ── reporting ────────────────────────────────────────────────────────────────
pass() { CASES_RUN=$((CASES_RUN + 1)); printf 'ok    %s\n' "$1"; }
fail() {
  CASES_RUN=$((CASES_RUN + 1))
  CASES_FAILED=$((CASES_FAILED + 1))
  ANY_FAILED=1
  printf 'FAIL  %s\n' "$1"
  shift
  while [ $# -gt 0 ]; do printf '        %s\n' "$1"; shift; done
}

# A case that is deliberately not run, and says so.
#
# This suite's founding rule is that a skipped e2e is a false assurance - which is
# why it refuses to skip when herdr is missing. The one exception is the resume
# case, gated behind MCODE_E2E_RESUME=1 by architect decision (issue #85): it is
# red roughly a third of the time for a reason that is upstream of this plugin,
# and a permanently-red case trains everyone to ignore the whole suite.
#
# So it skips BY DEFAULT, and a skip that could be mistaken for a pass is exactly
# what must not happen here. Three things make it unmissable: the word `skip`
# rather than `ok`, the reason on the next line, and 99 - a number that cannot be
# read as a case count, so someone skimming a green run still sees that something
# did not run. It is never counted as passed.
CASES_SKIPPED=0
skip() { # skip <name> <reason>
  CASES_RUN=$((CASES_RUN + 1))
  CASES_SKIPPED=$((CASES_SKIPPED + 1))
  printf 'skip  %s\n' "$1"
  printf '        99: %s\n' "$2"
}

# Kill every watcher THIS CHECKOUT started, and only those.
#
# The discriminator is this worktree's absolute script path, and it has to be. The
# pane-id match cleanup already used can only catch a watcher whose pane was
# recorded in CREATED_PANES, and two watchers outlived a run and made the NEXT
# run's event-hook case count two watchers on one pane - a run measuring the
# debris of an earlier one. A blanket `pkill -f mcode-watch.sh` would fix that and
# break something much worse: the developer's real panes run their INSTALLED copy,
# so their watchers' argv does not contain this worktree's path, while every
# blanket match takes them out too. This suite has already damaged this machine
# once by being careless about exactly that boundary.
#
# `kill` is a request, not a receipt, so there is a bounded wait and a SIGKILL
# behind it - the same reasoning as the per-pane teardown above.
kill_own_watchers() { # kill_own_watchers <when>
  local wp n=0 waited=0
  for wp in $(pgrep -f -- "$repo/bin/mcode-watch.sh" 2>/dev/null); do
    kill "$wp" 2>/dev/null && n=$((n + 1))
  done
  while [ "$waited" -lt 2000 ]; do
    pgrep -f -- "$repo/bin/mcode-watch.sh" >/dev/null 2>&1 || break
    sleep 0.1 2>/dev/null || sleep 1
    waited=$((waited + 100))
  done
  for wp in $(pgrep -f -- "$repo/bin/mcode-watch.sh" 2>/dev/null); do
    kill -9 "$wp" 2>/dev/null
  done
  if [ "$n" -gt 0 ]; then
    printf 'e2e: %s: stopped %s watcher(s) belonging to this checkout\n' "$1" "$n" >&2
  fi
  return 0
}

# ── cleanup: runs whatever happens, and leaves nothing behind ────────────────
# The brief's criterion 6 is "leave no panes, no sessions, no registry changes",
# so cleanup is not best-effort: a failure below is reported, never swallowed.
#
# KEEP_E2E=1 keeps the workdir AND the named session's directory, and prints both.
# Same escape hatch tests/session-run.sh offers as KEEP_TMP, and it earns its keep
# here for a specific reason: this suite deletes the session directory, which is
# also where herdr-server.log and the plugin's own command log live. Those two
# files are the only way to tell "the action never reported a resume" apart from
# "it reported one and herdr dropped it", and guessing between them from a red
# result alone is how a race gets misdiagnosed as a missing feature.
cleanup() {
  local rc=$?
  set +e

  # On a FAILING run, the evidence is copied out BEFORE anything is torn down —
  # and specifically before the server is killed, because the plugin's command log
  # lives in the server's memory and dies with it.
  #
  # This is not belt-and-braces. The resume case has failed twice for two
  # different reasons, and the first time it failed the diagnosis was guessed
  # from an action log and a snapshot that cleanup had already deleted, which is
  # how a real refusal got reported as a lost record. Whatever comes next is
  # upstream of this plugin, and "report back with the herdr log around the
  # clear" is unanswerable unless the log survives the run that produced it.
  #
  # Kept OUTSIDE the isolated root on purpose: that root is deleted below, and an
  # evidence directory inside it would be deleted a few lines later.
  if [ "$ANY_FAILED" = "1" ] && [ -n "$SESSION" ]; then
    local ev="/tmp/mcode-e2e-evid-$SESSION"
    mkdir -p "$ev" 2>/dev/null
    for f in "$HERDR_CONFIG_DIR/sessions/$SESSION/herdr-server.log" \
             "$HERDR_CONFIG_DIR/sessions/$SESSION/session.json" \
             "$WORKDIR/server.log" "$WORKDIR/server-restart.log" "$WORKDIR/attach.log"
    do
      [ -f "$f" ] && cp "$f" "$ev/" 2>/dev/null
    done
    "$HERDR" --session "$SESSION" plugin log list --plugin "$PLUGIN_ID" \
      >"$ev/plugin-log.json" 2>/dev/null
    printf 'e2e: FAILING RUN — evidence kept at %s\n' "$ev" >&2
    printf 'e2e:   server log: %s/herdr-server.log\n' "$ev" >&2
  fi

  # Every pane this suite created, and the detached watcher each one started.
  #
  # Scoped to THOSE pane ids on purpose, and the scoping is the whole point: a
  # blanket `pkill -f mcode-watch.sh` also kills the watchers belonging to the
  # developer's real minimax-code panes, which is damage this suite must not do to
  # the machine it verifies. Matching on "<script> <pane-id>" is also what keeps
  # an unrelated watcher from being mistaken for ours.
  local tp
  while IFS= read -r tp; do
    [ -n "$tp" ] || continue
    [ -n "$SESSION" ] && "$HERDR" --session "$SESSION" pane close "$tp" >/dev/null 2>&1
    for wp in $(pgrep -f "mcode-watch.sh $tp" 2>/dev/null); do
      kill "$wp" 2>/dev/null
    done
    # WAIT for the watchers to actually be gone before this function returns.
    #
    # `kill` is a request, not a receipt, and a watcher being asked to exit is
    # still visible to pgrep for a moment. tests/run.sh has two leak probes
    # (cases 22 and 23) whose whole purpose is to see any watcher left running
    # from this checkout — and running that suite immediately after this one made
    # them fire on a watcher that was on its way out. A test that fails on a
    # process which has already been asked to stop is a test teaching the reader
    # to ignore it, so the wait is part of the cleanup rather than a nicety.
    #
    # Bounded, because a watcher that ignores SIGTERM must not hang the suite.
    # KILL after the bound, so the guarantee holds either way.
    local waited=0
    while [ "$waited" -lt 2000 ]; do
      pgrep -f "mcode-watch.sh $tp" >/dev/null 2>&1 || break
      sleep 0.1 2>/dev/null || sleep 1
      waited=$((waited + 100))
    done
    for wp in $(pgrep -f "mcode-watch.sh $tp" 2>/dev/null); do
      kill -9 "$wp" 2>/dev/null
    done
  done <<EOF
$CREATED_PANES
EOF

  # Then the belt to that loop's braces: kill every watcher THIS checkout started,
  # whatever pane it was watching. The loop above can only kill a watcher whose
  # pane was recorded, and two outlived a run and made the NEXT run's event-hook
  # case count two watchers on one pane - so a later run was measuring the debris
  # of an earlier one.
  kill_own_watchers "teardown"

  # BEFORE the server is killed, and that ordering is the whole point of the
  # escape hatch: the plugin's command log lives in the server's memory, so a
  # kept-but-stopped session has thrown away the one artifact that says whether
  # the action reported a resume at all.
  if [ "${KEEP_E2E:-0}" = "1" ] && [ -n "$SESSION" ]; then
    printf 'e2e: KEEP_E2E=1, session %s left RUNNING at %s\n' \
      "$SESSION" "$HERDR_CONFIG_DIR/sessions/$SESSION" >&2
    printf 'e2e:   plugin log:  herdr --session %s plugin log list --plugin %s\n' \
      "$SESSION" "$PLUGIN_ID" >&2
    printf 'e2e:   server log:  %s\n' "$HERDR_CONFIG_DIR/sessions/$SESSION/herdr-server.log" >&2
    printf 'e2e:   workdir:     %s\n' "$WORKDIR" >&2
    printf 'e2e:   config root: %s  (isolated; delete it too)\n' "$E2E_XDG_ROOT" >&2
    printf 'e2e:   stop it:     herdr --session %s server stop; herdr session delete %s\n' \
      "$SESSION" "$SESSION" >&2
    return $rc
  fi

  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  if [ -n "$SESSION" ]; then
    "$HERDR" --session "$SESSION" server stop >/dev/null 2>&1
    # The session directory is created on first use and is NOT removed by
    # `server stop`. Leaving it behind would grow the runner's state dir on
    # every run, so it goes explicitly.
    if [ -n "$HERDR_CONFIG_DIR" ] && [ -d "$HERDR_CONFIG_DIR/sessions/$SESSION" ]; then
      rmdir "$HERDR_CONFIG_DIR/sessions/$SESSION" 2>/dev/null \
        || /bin/rm -rf "$HERDR_CONFIG_DIR/sessions/$SESSION" 2>/dev/null
    fi
  fi

  # Restore the plugin registry to exactly what it was.
  #
  # Now BELT AND BRACES rather than a repair. The registry is config_dir()/
  # plugins.json, so with the isolation above it is a file this run created, and
  # the whole block is about a throwaway directory. It is kept anyway: the day
  # someone runs this suite with the isolation bypassed, this is the line that
  # stops it taking the developer's installed plugin with it — and unlike the
  # refusal guard, which has its own tests, this has none.
  #
  # Guarded on LINKED_BY_US. Unconditionally unlinking here would delete a real
  # registration if the suite ever ran against a real registry and died between
  # installing this trap and taking the snapshot below. Only undo what was done.
  if [ -n "$LINKED_BY_US" ]; then
    "$HERDR" plugin unlink "$PLUGIN_ID" >/dev/null 2>&1
    if [ -n "$PRIOR_LINK" ]; then
      "$HERDR" plugin link "$PRIOR_LINK" >/dev/null 2>&1
    fi
  fi

  # Both temp roots go LAST, after the server has stopped. Removing the config root
  # first — which is what the first draft of the isolation block did — leaves an
  # empty directory behind, because the running server still holds and recreates
  # files under it. A suite whose whole selling point is "does not touch your
  # machine" must not leave anything in /tmp either.
  [ -n "$E2E_XDG_ROOT" ] && [ -d "$E2E_XDG_ROOT" ] && /bin/rm -rf "$E2E_XDG_ROOT" 2>/dev/null
  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && /bin/rm -rf "$WORKDIR" 2>/dev/null
  return $rc
}

# ── prerequisites. Absence is a FAILURE, never a skip. ───────────────────────
HERDR="${HERDR_BIN_PATH:-}"
if [ -z "$HERDR" ]; then
  if command -v herdr >/dev/null 2>&1; then
    HERDR="$(command -v herdr)"
  else
    printf 'FATAL: herdr is not installed and HERDR_BIN_PATH is unset.\n' >&2
    printf 'This suite is an END-TO-END check against a real multiplexer. It cannot\n' >&2
    printf 'be satisfied by a stub, and it will not skip itself: a skipped e2e is a\n' >&2
    printf 'false assurance, which is the exact failure mode this suite exists to\n' >&2
    printf 'remove. Install herdr and re-run:\n' >&2
    printf '    curl -fsSL https://herdr.dev/install.sh | sh\n' >&2
    printf 'or point HERDR_BIN_PATH at an existing binary.\n' >&2
    exit 2
  fi
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'FATAL: jq is required to read herdr JSON. Install jq and re-run.\n' >&2
  exit 2
fi
if [ ! -f "$repo/herdr-plugin.toml" ]; then
  printf 'FATAL: no manifest at %s/herdr-plugin.toml — wrong checkout?\n' "$repo" >&2
  exit 2
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mcode-e2e.XXXXXX")"
trap cleanup EXIT INT TERM

# ── ISOLATION: the whole point of the block below ────────────────────────────
# This suite runs a REAL herdr and it LINKS A PLUGIN. The plugin registry is not
# per-session: it is one file at config_dir()/plugins.json
# (src/persist/plugin_registry.rs:11), shared by every session on the machine.
# So running this suite against the developer's own herdr REPLACES whatever they
# had installed, and the unlink in cleanup then leaves them with nothing.
#
# That is not hypothetical. It is what happened on 2026-10-05: running this file
# locally replaced the owner's GitHub-installed jaaacki.minimax-code 0.4.1 with a
# link to a throwaway worktree, and the restore left the registry empty.
#
# The fix is XDG_CONFIG_HOME, which herdr honours for config_dir()
# (src/config/io.rs:31) and therefore for the socket, the state dir, the session
# directories AND the plugin registry. Pointing it at a directory inside this run's
# own workdir isolates all of them, and costs nothing: a fresh config dir simply
# means no user config.toml, so herdr's defaults apply, which is what a CI runner
# has anyway.
#
# Note this also fixes a quieter version of the same problem that predated it:
# HERDR_SOCKET_PATH is inherited from the developer's own pane when the suite is
# run from inside herdr, and every `$HERDR` call in here would then have talked to
# the developer's LIVE server rather than this run's.
# A SEPARATE, SHORT root, and the shortness is not cosmetic. herdr's socket lives at
# <config_dir>/sessions/<name>/herdr.sock, and a unix socket path is capped at
# sun_path — 104 bytes on macOS. Nesting that under the long per-user TMPDIR the
# workdir comes from overruns it, and every herdr call then fails with "local
# socket name length exceeds capacity of sun_path of sockaddr_un". Which is what
# happened when this was first written with the root inside WORKDIR: the whole
# suite failed, and the isolation fix was blamed for a path-length bug.
#
# So: /tmp explicitly, a short template, and a session name short enough to leave
# room. Everything else — logs, the stub launcher, the sandbox — stays in the long
# workdir, where length does not matter.
E2E_XDG_ROOT="$(mktemp -d "/tmp/mcode-e2e-cfg.XXXXXX")"
# What the DEVELOPER's config dir is, before this suite replaces the variable.
# The refusal guard needs it to name the place it is protecting; nothing else
# reads it.
XDG_CONFIG_HOME_BEFORE_ISOLATION="${XDG_CONFIG_HOME:-}"
export XDG_CONFIG_HOME_BEFORE_ISOLATION
export XDG_CONFIG_HOME="$E2E_XDG_ROOT"
# The socket the developer is sitting in must not leak in either. Cleared rather
# than trusted, because inheriting it is exactly the bug.
unset HERDR_SOCKET_PATH
# ...and HERDR_SESSION, for the same reason: it would silently retarget every
# `herdr --session` call at a different server than the one this suite starts.
unset HERDR_SESSION
HERDR_CONFIG_DIR="$E2E_XDG_ROOT/herdr"
# XDG_CONFIG_HOME does not move herdr's plugin state dir, which stays under the
# developer's real ~/.local/state, so watcher logs from this run landed there
# (#108). The server and every plugin command it spawns inherit this.
export MCODE_WATCH_LOG_DIR="$E2E_XDG_ROOT/watch"

# ── case 1: a real server starts and a real session bootstraps ───────────────
# A fresh session has zero panes, and a bare `pane split` answers
# pane_not_found. `workspace create` is what mints the first pane. Without this
# the action under test has nothing to split from and every later case is noise.
run_case_bootstrap() {
  local name="bootstrap: headless session starts and mints a pane"
  SESSION="e2e-$$-$(date +%s)"
  SERVER_LOG="$WORKDIR/server.log"

  "$HERDR" --session "$SESSION" server </dev/null >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!

  local i ready=""
  for i in $(seq 1 40); do
    ready="$("$HERDR" --session "$SESSION" status server 2>/dev/null | sed -n 's/^status: //p')"
    [ "$ready" = "running" ] && break
    sleep 0.25
  done
  if [ "$ready" != "running" ]; then
    fail "$name" "server did not reach 'running' within 10s" \
      "log: $(head -3 "$SERVER_LOG" 2>/dev/null | tr '\n' ' ')"
    return
  fi

  if ! "$HERDR" --session "$SESSION" workspace create --cwd "$WORKDIR" >/dev/null 2>&1; then
    fail "$name" "workspace create failed — the session has no pane to split from"
    return
  fi
  if [ -z "$(pane_ids)" ]; then
    fail "$name" "workspace create reported success but no pane exists"
    return
  fi
  pass "$name"
}

# ── the stub launcher ───────────────────────────────────────────────────────
# A stub `mcode`. The action resolves the launcher with `command -v` and types
# its absolute path into the new pane, so a stub on PATH is enough to exercise
# the plugin's plumbing. What is under test is whether a plugin-launched pane
# becomes a registered agent — not whether mcode's TUI works.
#
# THE PATH EXPORT MUST HAPPEN BEFORE THE SERVER STARTS, and that ordering is the
# whole reason this function exists separately. The action is spawned by the
# herdr SERVER, which inherits the environment it was started with — not the one
# the suite has at the moment it invokes the action. Exporting the stub after
# the server is already running leaves the action without it, and the action
# then dies at `command -v mcode`.
#
# This is not hypothetical: it is exactly how this suite failed on its first CI
# run, on both legs, while passing on a developer machine. The developer machine
# had a REAL mcode on the ambient PATH, so the missing stub was invisible; the
# runner had no mcode at all, so the omission became the whole failure. Only a
# real CI run against a real herdr could surface it — which is the argument for
# this job existing.
prepare_stub_mcode() {
  mkdir -p "$WORKDIR/bin"
  cat > "$WORKDIR/bin/$AGENT_LABEL" <<STUB
#!/bin/sh
# Stand-in for the real launcher, and it must be a LONG-LIVED process for the whole
# time the test needs it.
#
# Not a nicety. A self-report on a pane whose foreground process is transient is
# volatile: reported_resume follows the registration, and a registration that
# wobbles takes the resume with it. m2 and m1 both measured that on a shell-only
# pane. This case failed once in a full-suite run with the resume accepted by
# herdr and then absent from the snapshot, which is the shape that produces.
#
# The pane gets the stub's path typed in, so for a moment its foreground process is
# still the shell. The marker file is how the test knows the long-lived process is
# actually in place, so the wait can be placed where it matters rather than assumed.
printf 'mcode (e2e stub) %s\n' "\$*"
: > "\$MCODE_STUB_MARKER"
exec sleep 600
STUB
  chmod +x "$WORKDIR/bin/$AGENT_LABEL"
  PATH="$WORKDIR/bin:$PATH"
  export PATH
  MCODE_STUB_MARKER="$WORKDIR/stub-running"
  export MCODE_STUB_MARKER

  # Make the session reporter print which socket and which herdr binary it is
  # about to use, into the plugin log this suite already captures. Diagnostic
  # only, and the reporter is silent unless this is set — see log_report_env in
  # bin/mcode-session.sh. Exported for the same reason as the stub above: the
  # action is spawned by the server, so it must be in the server's environment
  # before it starts.
  MCODE_LOG_REPORT_ENV=1
  export MCODE_LOG_REPORT_ENV

  # The resume command the plugin will record, overridden for the same PATH
  # reason and at the same moment as the stub: the action is spawned by the
  # server, so anything the action must see has to be in the server's environment
  # before it starts. See run_case_resume_restored for why this is not the
  # plugin's real default.
  MCODE_RESUME_CMD="echo $RESUME_PROOF"
  export MCODE_RESUME_CMD
}
pane_ids() {
  "$HERDR" --session "$SESSION" pane list 2>/dev/null \
    | jq -r '.result.panes[]?.pane_id' 2>/dev/null
}

agent_row() { # $1 = pane id
  "$HERDR" --session "$SESSION" agent list 2>/dev/null \
    | jq -c --arg p "$1" '.result.agents[]? | select(.pane_id == $p)' 2>/dev/null
}

# The most recent plugin command record, reduced to the fields that explain a
# failure: status, exit code, and whatever the command wrote to stderr.
#
# Two shapes that are easy to get wrong, and were: `plugin log list` takes NO
# --json flag (it is rejected; the command already answers JSON), and each
# record's `action_id` is the BARE id — `minimax-code-start`, not the fully
# qualified `jaaacki.minimax-code.minimax-code-start` used to invoke it. Filtering
# on the qualified name matches nothing and yields an empty report, which reads
# as "no log record" and hides the very failure it was added to explain.
action_log_tail() {
  local out
  out="$("$HERDR" --session "$SESSION" plugin log list --plugin "$PLUGIN_ID" 2>/dev/null)"
  printf '%s' "$out" | jq -r \
    '[.result.logs[]? | select(.action_id == "minimax-code-start")] | last
     | if . == null then "no log record for the action"
       else "status=\(.status) exit=\(.exit_code // "-") stderr=\((.stderr // "") | gsub("\\s+"; " ") | .[0:200])"
       end' 2>/dev/null || echo "log unavailable or unparseable"
}

# The action is ASYNCHRONOUS, and its log record says so: `status` is "running" and
# `exit_code` and `stderr` are null until the process finishes. Reading it early is
# how a read-back assertion ends up asserting on an empty string and failing for
# the wrong reason — the resume case did exactly that.
#
# "Finished" is taken as exit_code being non-null. Waiting for a NON-EMPTY stderr
# instead would be wrong on its own: a successful launch of this plugin has stderr
# (the launcher narrates and the read-back reports), but a plugin with nothing to
# say would look like it never finished, and the wait would time out on correct
# behaviour.
await_action_log() { # await_action_log <seconds>
  local deadline=$(( $(date +%s) + $1 ))
  while :; do
    if "$HERDR" --session "$SESSION" plugin log list --plugin "$PLUGIN_ID" 2>/dev/null \
        | jq -e '[.result.logs[]? | select(.action_id == "minimax-code-start")]
                  | last | (.exit_code != null)' >/dev/null 2>&1; then
      return 0
    fi
    [ "$(date +%s)" -le "$deadline" ] || return 1
    sleep 1
  done
}

# ── case 2: the real action launches a real pane ─────────────────────────────
# The action is ASYNCHRONOUS. `plugin action invoke` returns a log record with
# status "running" and no pane. Asserting immediately reads a false negative —
# I hit this while writing the suite, so the wait is not optional.
run_case_launch() {
  local name="launch: the real action creates a pane"

  BEFORE="$(pane_ids | wc -l | tr -d ' ')"
  pane_ids | sort > "$WORKDIR/panes.before"

  if ! "$HERDR" --session "$SESSION" plugin action invoke "$ACTION_ID" >"$WORKDIR/invoke.json" 2>&1; then
    fail "$name" "plugin action invoke returned non-zero" \
      "output: $(head -3 "$WORKDIR/invoke.json" | tr '\n' ' ')"
    return
  fi

  local i after=0
  for i in $(seq 1 60); do
    after="$(pane_ids | wc -l | tr -d ' ')"
    [ "$after" -gt "$BEFORE" ] && break
    sleep 0.5
  done
  if [ "$after" -le "$BEFORE" ]; then
    # "No pane appeared" names a symptom, not a cause. The action runs
    # asynchronously, so a failure inside it is invisible from here unless the
    # plugin's own command log is read. Without this, a launcher that died with
    # "mcode not found" and a multiplexer that refused to split look identical
    # — and the first CI run proved that guess costs a whole debugging round
    # trip.
    fail "$name" "no pane appeared within 30s of invoking the action" \
      "the action is asynchronous; see the comment above" \
      "action log: $(action_log_tail)"
    return
  fi

  # The new pane is the SET DIFFERENCE, not the last line of the listing.
  # `tail -1` assumed the freshly split pane sorts last; if that ever stops
  # holding, the remaining cases would assert against a pre-existing pane and
  # could report a confident pass about the wrong agent. Taking the difference
  # makes the test assert about the pane it actually created.
  pane_ids | sort > "$WORKDIR/panes.after"
  NEW_PANE="$(comm -13 "$WORKDIR/panes.before" "$WORKDIR/panes.after" | head -1)"
  note_created_pane "$NEW_PANE"
  if [ -z "$NEW_PANE" ]; then
    fail "$name" "pane count grew but no new pane id could be identified" \
      "before: $(tr '\n' ' ' < "$WORKDIR/panes.before")" \
      "after:  $(tr '\n' ' ' < "$WORKDIR/panes.after")"
    return
  fi
  pass "$name"
}

# ── case 3: the launched pane is a REGISTERED agent ──────────────────────────
# This is the assertion the whole stub-driven suite could never make. Before
# #34, agent list was empty and agent get answered agent_not_found — measured on
# a real herdr, not inferred. That pre-merge state is this case's RED.
run_case_registered() {
  local name="registration: the launched pane appears in agent list"

  if [ -z "${NEW_PANE:-}" ]; then
    fail "$name" "no new pane recorded by the launch case"
    return
  fi
  local row
  row="$(agent_row "$NEW_PANE")"
  if [ -z "$row" ]; then
    fail "$name" "pane $NEW_PANE is not in agent list" \
      "if #34's registration is missing, this is the expected red"
    return
  fi
  local label status
  label="$(printf '%s' "$row" | jq -r '.agent // empty')"
  status="$(printf '%s' "$row" | jq -r '.agent_status // empty')"
  if [ "$label" != "$AGENT_LABEL" ]; then
    fail "$name" "pane $NEW_PANE reports agent '$label', expected '$AGENT_LABEL'"
    return
  fi
  pass "$name"
}

# ── case 4: agent get and agent read resolve against that pane ───────────────
# `agent get` answers a JSON envelope; `agent read` prints the pane's text
# directly and is NOT wrapped. Asserting a JSON shape on the read is wrong — I
# wrote that first and it failed against a perfectly healthy agent. The read is
# asserted by exit status plus non-empty, non-error output instead.
run_case_readable() {
  local name="readability: agent get and agent read resolve against the pane"

  if [ -z "${NEW_PANE:-}" ]; then
    fail "$name" "no new pane recorded by the launch case"
    return
  fi
  if ! "$HERDR" --session "$SESSION" agent get "$NEW_PANE" 2>/dev/null \
      | jq -e '.result.agent' >/dev/null 2>&1; then
    fail "$name" "herdr agent get $NEW_PANE did not resolve"
    return
  fi

  local out
  out="$("$HERDR" --session "$SESSION" agent read "$NEW_PANE" --source detection 2>&1)"
  if [ $? -ne 0 ]; then
    fail "$name" "herdr agent read $NEW_PANE exited non-zero" \
      "output: $(printf '%s' "$out" | head -c 200)"
    return
  fi
  if printf '%s' "$out" | grep -q '"error"'; then
    fail "$name" "herdr agent read $NEW_PANE returned an error envelope" \
      "output: $(printf '%s' "$out" | head -c 200)"
    return
  fi
  if [ -z "$out" ]; then
    fail "$name" "herdr agent read $NEW_PANE produced no output — did it resolve?"
    return
  fi
  pass "$name"
}

# ── case 5: the launch is NAME-ADDRESSABLE ───────────────────────────────────
# The point of #34's rename: the user types `herdr agent get mcode`, not a pane
# id. Asserted because a pane-id-only registration is a real regression that
# every other case would pass.
run_case_name_addressable() {
  local name="addressability: the launch is reachable by the name 'mcode'"

  if ! "$HERDR" --session "$SESSION" agent get "$AGENT_LABEL" 2>/dev/null \
      | jq -e '.result.agent' >/dev/null 2>&1; then
    fail "$name" "herdr agent get $AGENT_LABEL did not resolve — the rename is missing or was taken"
    return
  fi
  pass "$name"
}

# ── case 6: TRIPWIRE — prompt/send-keys are still refused on 0.9.3 ───────────
# Issue #42 originally asked this suite to assert that `agent prompt` and
# `agent send-keys` do NOT fail with agent_not_ready. They do. Measured twice,
# independently: after a SUCCESSFUL `agent rename`, `agent list` shows
# name:"mcode" and both commands still answer
#   agent_not_ready: agent mcode is not an active named agent
# Rename sets a display label; it does not promote the agent to an "active named
# agent". A session id and `working` state do not change it.
#
# So this case asserts TODAY'S REFUSAL. That is a deliberate inversion: it turns
# a known limitation into a tripwire. If a future herdr release makes these
# commands work, this case goes RED on purpose and says what that means, instead
# of the plugin quietly keeping a ceiling in a comment that nothing re-checks.
run_case_tripwire() {
  local name="tripwire: prompt/send-keys still refuse on herdr $(herdr_version)"

  # Distinguish three outcomes, because collapsing them would make this red lie
  # about its own cause. I got that wrong first: with registration removed the
  # agent does not exist at all, the call answers agent_not_found, and a naive
  # "expected agent_not_ready" check printed "herdr now supports prompt" — the
  # exact opposite of the truth. A test that misreports why it failed is worse
  # than one that fails, so agent_not_found is reported as what it is.
  #
  #   agent_not_found  -> the launch is not registered. NOT a herdr improvement.
  #   agent_not_ready  -> today's ceiling. This is the case that must hold.
  #   anything else    -> herdr changed. That is the good news this watches for.
  local out code
  out="$("$HERDR" --session "$SESSION" agent prompt "$AGENT_LABEL" "hello" 2>&1)"
  code="$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)"

  if [ "$code" = "agent_not_found" ]; then
    fail "$name" \
      "the agent '$AGENT_LABEL' is not registered, so prompt cannot be exercised." \
      "This is NOT evidence that herdr gained the capability — it means the" \
      "registration is missing. The registration cases above report the real cause."
    return
  fi
  if [ "$code" != "agent_not_ready" ]; then
    fail "$name" \
      "EXPECTED FAILURE: herdr now supports prompt/send-keys on self-reported agents." \
      "This is good news. Update the ceiling in bin/mcode-plugin.sh, the README and epic #40," \
      "and widen this assertion." \
      "observed: code='${code:-<none>}' output: $(printf '%s' "$out" | head -c 200)"
    return
  fi

  out="$("$HERDR" --session "$SESSION" agent send-keys "$AGENT_LABEL" Enter 2>&1)"
  code="$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)"
  if [ "$code" = "agent_not_found" ]; then
    fail "$name" \
      "the agent '$AGENT_LABEL' vanished between the prompt and send-keys calls." \
      "That is a registration lifetime problem, not a herdr capability change."
    return
  fi
  if [ "$code" != "agent_not_ready" ]; then
    fail "$name" \
      "EXPECTED FAILURE: herdr now supports prompt/send-keys on self-reported agents." \
      "This is good news. Update the ceiling in bin/mcode-plugin.sh, the README and epic #40," \
      "and widen this assertion." \
      "observed: code='${code:-<none>}' output: $(printf '%s' "$out" | head -c 200)"
    return
  fi
  pass "$name"
}

# ── case 7: the event hook starts a watcher for a pane WE DID NOT LAUNCH ─────
# Issue #84. Every case above watches a pane this suite launched through the
# action, which is the one path that already worked. The defect was the other
# panes: a flock-adopted minimax-code pane, a hand-run `mcode`, a pane from
# before 0.4.1. Nothing in the plugin ever saw those, so nothing started a
# watcher for them and their state froze.
#
# So this case does what the stub suite cannot: it registers a pane the way a
# THIRD PARTY does, with a source this plugin does not own, and asserts a
# watcher appears for it with no action invoked at all. That is the whole claim
# of #84, and it is only true against a real herdr — a manifest entry that
# parses is not a working hook.
#
# The pane is a throwaway this suite splits itself, on the e2e session, and it
# is closed at the end. The source used is `flock:adopt` to model the real
# route; note that this suite only ever REPORTS with that source, which is what
# a third party does. It never reports state AS flock:adopt, which freezes the
# reporter's own state (flock#2311) and is forbidden by the brief.
run_case_event_watcher() {
  local name="event hook: a pane registered by another source gets a watcher"

  if [ -z "${NEW_PANE:-}" ]; then
    fail "$name" "no new pane recorded by the launch case"
    return
  fi
  if ! command -v pgrep >/dev/null 2>&1; then
    fail "$name" "pgrep is required to assert a watcher process exists"
    return
  fi

  # A pane of our own, but a FRESH one this case splits, so the assertion is
  # about the hook and not about a watcher the launch path already started.
  local src pane
  src="$(pane_ids | head -1)"
  if [ -z "$src" ]; then
    fail "$name" "no source pane to split from"
    return
  fi
  pane="$("$HERDR" --session "$SESSION" pane split "$src" --direction right --no-focus 2>/dev/null \
    | jq -r '.result.pane.pane_id' 2>/dev/null)"
  if [ -z "$pane" ]; then
    fail "$name" "could not split a throwaway pane"
    return
  fi
  THROWAWAY_PANE="$pane"
  note_created_pane "$pane"
  # A live process, or herdr's detection pass re-reads the pane and resets the
  # self-reported state to `unknown` — measured on 0.9.3 — and the pane never
  # reaches agent list at all, which would make the case fail for a reason that
  # has nothing to do with the hook.
  "$HERDR" --session "$SESSION" pane run "$pane" "exec sleep 300" >/dev/null 2>&1
  sleep 1

  # Registered by someone else, under an agent label this plugin recognises.
  "$HERDR" --session "$SESSION" pane report-agent "$pane" \
    --source flock:adopt --agent minimax-code --state working >/dev/null 2>&1

  # The action is NOT invoked anywhere in this case. If a watcher appears, it is
  # because herdr fired pane.agent_status_changed and the manifest's hook ran.
  local i found=0
  for i in $(seq 1 40); do
    if pgrep -f "mcode-watch.sh $pane" >/dev/null 2>&1; then
      found=1
      break
    fi
    sleep 0.25
  done
  if [ "$found" -ne 1 ]; then
    fail "$name" "no watcher was started for $pane within 10s of another source registering it" \
      "this is issue #84: without the event hook, such a pane keeps whatever" \
      "state herdr last saw and never moves again" \
      "pane state: $("$HERDR" --session "$SESSION" agent get "$pane" 2>/dev/null | jq -c '.result.agent // .error' 2>/dev/null)"
    return
  fi

  # Exactly one. Two would be the spawn loop the lock exists to prevent, and it
  # is the failure that would not show up in any other assertion here.
  local n
  n="$(pgrep -f "mcode-watch.sh $pane" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -ne 1 ]; then
    fail "$name" "$n watchers were started for one pane; it must be exactly 1"
    return
  fi

  # A second status change must not start a second one. The hook fires on
  # transitions, and the watcher's own first report is one, so this is the real
  # spawn loop and not a hypothetical.
  "$HERDR" --session "$SESSION" pane report-agent "$pane" \
    --source flock:adopt --agent minimax-code --state idle >/dev/null 2>&1
  sleep 3
  n="$(pgrep -f "mcode-watch.sh $pane" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -ne 1 ]; then
    fail "$name" "$n watchers after a second status change; the hook must be idempotent"
    return
  fi

  # And the per-pane log, since the other half of #84 is that a watcher which
  # dies must leave a trace. It must land in this run's disposable root, not
  # the developer's real state dir (#108).
  if [ ! -s "$MCODE_WATCH_LOG_DIR/$pane.log" ]; then
    fail "$name" "no watcher log at $MCODE_WATCH_LOG_DIR/$pane.log; it went somewhere outside this run's temp root"
    return
  fi
  pass "$name"
}

# ── case 8: a pane that is NOT ours is left alone ───────────────────────────
# The hook is session-wide: measured on 0.9.3, it fires for agents this plugin
# never launched. So "do not act on someone else's pane" has to be enforced, and
# a plugin that started a watcher for every `claude` pane in the session would
# be a real regression that no other case here would catch.
run_case_foreign_pane_untouched() {
  local name="scoping: a pane registered as another agent gets no watcher"

  # SELF-CONTAINED, deliberately. This case used to depend on THROWAWAY_PANE
  # from the case above it, so when that case failed early this one failed too
  # and a scoping regression looked like two separate failures. It splits its
  # own pane now, and the two cases can be read and run independently.
  local src pane
  src="$(pane_ids | head -1)"
  if [ -z "$src" ]; then
    fail "$name" "no source pane to split from"
    return
  fi
  pane="$("$HERDR" --session "$SESSION" pane split "$src" --direction right --no-focus 2>/dev/null \
    | jq -r '.result.pane.pane_id' 2>/dev/null)"
  if [ -z "$pane" ]; then
    fail "$name" "could not split a throwaway pane"
    return
  fi
  FOREIGN_PANE="$pane"
  note_created_pane "$pane"
  "$HERDR" --session "$SESSION" pane run "$pane" "exec sleep 300" >/dev/null 2>&1
  sleep 1
  "$HERDR" --session "$SESSION" pane report-agent "$pane" \
    --source some:other --agent claude --state working >/dev/null 2>&1
  sleep 3

  if pgrep -f "mcode-watch.sh $pane" >/dev/null 2>&1; then
    fail "$name" "a watcher was started for a claude pane; the event is session-wide" \
      "and acting on it makes this plugin poll panes it does not own"
    return
  fi
  pass "$name"
}

herdr_version() { "$HERDR" --version 2>/dev/null | head -1 | awk '{print $2}'; }

# ── the resume restart, and the only assertion that can prove it ─────────────
# Everything above this line is checked against a running server. This case stops
# the server and starts it again, which is the only way to observe the thing issue
# #85 is about: herdr re-creates a pane from the snapshot and re-runs the resume
# command the plugin recorded on it.
#
# SAFE FOR THE DEVELOPER'S MACHINE, and that is not an accident of the harness —
# it is the named session. `herdr --session <name>` keeps its socket, its state
# and its session.json in <config_dir>/sessions/<name>/ (src/session.rs:163,
# data_dir_for), and `server stop` there stops that server and no other. The
# default session is never stopped, reconfigured or even contacted: every call in
# this case carries --session, and the plugin registry is the one shared global
# this suite already snapshots and restores.
#
# WHY THE RESUME COMMAND IS OVERRIDDEN. The plugin's real default is
# `mcode --continue`, and a CI runner has no mcode, so the restore would type a
# command that fails and the case would be asserting on a failure. The override is
# `echo <token>`, chosen because `echo` is a shell builtin in every login shell —
# PATH-independent, which matters because a RESTORED pane resolves commands from
# its own login environment and not from the server's (measured: a stub placed on
# the server's PATH was not found by the restored pane). The token is the argv, so
# finding it in the pane proves herdr restored OUR argument rather than merely
# starting a shell. The plugin's real default is asserted separately, as a literal,
# in tests/session-run.sh.
#
# A CLIENT MUST ATTACH. See tests/e2e/attach-pty.py. Without one, herdr's pending
# resume has a 0x0 terminal area to work with and quietly does nothing.
RESUME_PROOF="MCODE_RESUME_PROOF_$$"

session_snapshot() { printf '%s' "$HERDR_CONFIG_DIR/sessions/$SESSION/session.json"; }

# herdr debounces session saves by five seconds, so a snapshot read immediately
# after the launch is a snapshot from before it. Polling is the honest way to
# wait for the write instead of sleeping a guessed interval.
#
# THE SUCCESS TEST IS DELIBERATELY STRICT, and the first draft of it was not —
# which cost a full debugging round trip and is worth writing down. It read
#
#     if [ "$(jq -c '…' "$snap")" != "0" ]; then return 0; fi
#
# and `session.json` does not exist for the first ~8 seconds of a session, so jq
# failed, wrote NOTHING to stdout, and the empty string compared unequal to "0".
# The function reported success on its first iteration, ~8 seconds before the
# snapshot existed, and the case went on to assert a restore of a resume that had
# not been written yet. It failed, and it failed for a reason that had nothing to
# do with the thing under test.
#
# So: jq must SUCCEED, and its output must be a number, and that number must be
# above zero. A missing file, an unreadable file and malformed JSON are all
# "not yet", never "found".
await_resume_in_snapshot() { # await_resume_in_snapshot <seconds>
  local deadline=$(( $(date +%s) + $1 )) n
  while [ "$(date +%s)" -le "$deadline" ]; do
    if n=$(jq -e --arg src "herdr:minimax-code" --arg agent "$AGENT_LABEL" \
            --arg proof "$RESUME_PROOF" \
            '[.workspaces[]? | .tabs[]? | .panes | to_entries[]?
              | select(.value.agent_resume != null)
              | select(.value.agent_resume.source == $src)
              | select(.value.agent_resume.agent == $agent)
              | select(.value.agent_resume.argv == ["echo", $proof])] | length' \
            "$(session_snapshot)" 2>/dev/null); then
      case "$n" in
        ''|*[!0-9]*) : ;;
        0) : ;;
        *) return 0 ;;
      esac
    fi
    sleep 1
  done
  return 1
}

# ── triage for "the resume token never appeared" ────────────────────────────
# The three facts below are read separately from the case so the DECISION about
# what they mean can be tested without a race. See resume_failure_mode.

# 1 if the plugin's own log says herdr REFUSED the resume report.
#
# Read from the FULL record rather than from the 200-char tail action_log_tail
# prints. The refusal line is the plugin's narration, and it sits behind whatever
# the launcher printed before it, so a truncated field can push it out of view —
# which would make this guard quietly miss the exact failure it exists to name.
action_refused_resume() {
  "$HERDR" --session "$SESSION" plugin log list --plugin "$PLUGIN_ID" 2>/dev/null \
    | jq -r '[.result.logs[]? | select(.action_id == "minimax-code-start")] | last
             | ((.stdout // "") + "\n" + (.stderr // ""))' 2>/dev/null \
    | grep -qF 'resume REFUSED by herdr'
}

# 1 if the snapshot holds any agent_resume at all. Deliberately "any", not "for
# this pane": a resume restored from ANOTHER pane still proves the mechanism, and
# the only case that can produce one is the dedupe collision documented in the
# plugin header. Treating that as a pass would be wrong, so this feeds a
# diagnosis and never a verdict.
snapshot_has_resume() {
  [ "$(jq -e '[.workspaces[]?.tabs[]?.panes[]? | select(.agent_resume)] | length > 0' \
        "$(session_snapshot)" 2>/dev/null)" = "true" ]
}

# 1 if herdr ever saw a client connect. herdr skips deferred agent resumes while
# the terminal area is 0x0, which is the state of a headless server with no
# client attached (src/app/agent_resume.rs:99).
client_ever_connected() {
  grep -q "client connected" "$HERDR_CONFIG_DIR/sessions/$SESSION/herdr-server.log" 2>/dev/null
}

# The server's own lines for the refusal. This is the evidence the next reader
# needs and the thing that was missing when a refusal first showed up: the
# action log says herdr said no, and only the server log says why.
resume_refusal_evidence() {
  grep -hF 'resume_not_accepted' \
    "$HERDR_CONFIG_DIR/sessions/$SESSION/herdr-server.log" \
    "$WORKDIR/server.log" 2>/dev/null | tail -3 | cut -c1-190 | tr '\n' ' '
}

# WHICH of the several real causes explains a missing resume token.
#
#   $1 1 if herdr refused the report
#   $2 1 if the snapshot holds an agent_resume
#   $3 1 if a client ever connected
#
# Pure — three facts in, one mode out, no herdr and no sleeping — and that is the
# point. A triage that can only run once a race has already bitten gets its
# wording wrong the first time it matters, and it did: this function did not
# exist until a refusal was observed, and the inline `if`s it replaced reported
# that refusal as "the resume was reported and herdr ACCEPTED it, but the
# snapshot never gained it". That is a false claim about herdr — it refused, on
# purpose, having stored nothing to lose — and it points the next reader at a
# dropped-record bug that does not exist.
#
# `refused` is tested first and wins outright for the same reason: when herdr
# refuses, every record-based verdict below it is answering a different question.
resume_failure_mode() {
  if [ "$1" -eq 1 ]; then printf 'refused\n'; return 0; fi
  if [ "$2" -eq 1 ]; then
    if [ "$3" -eq 1 ]; then printf 'stored-but-no-token\n'; else printf 'no-client\n'; fi
    return 0
  fi
  printf 'lost\n'
}

run_case_resume_restored() {
  local name="resume: a restart re-runs the recorded resume command in the recreated pane"

  # GATED, off by default (architect decision, issue #85). The reasoning and the
  # evidence are in .git/flock-review/self-85-rev4-evidence.md; the short version
  # is that this case fails roughly one run in three for a cause that is upstream
  # of this plugin, and an always-red case is how suites get ignored wholesale.
  #
  # The failure is understood, not ignored. It is NOT the shell-only-pane case the
  # stub fix addressed: the plugin's own log shows herdr accepting the resume
  # (exit 0) from the CORRECT session socket, and that same session's server log
  # recording no report request at all. That is issue #99, and it stays tracked
  # there rather than as a permanently-red case here.
  #
  # When this is switched on, run it where the failure is visible and the machine
  # is otherwise quiet - it is the only case here that stops and restarts the
  # server, so it is also the only one that leaves debris if it dies.
  if [ "${MCODE_E2E_RESUME:-0}" != "1" ]; then
    skip "$name" \
      "gated behind MCODE_E2E_RESUME=1. Known-flaky for a cause upstream of this plugin (issue #99): herdr returns 0 for a resume report while its own session log records no report. Run: MCODE_E2E_RESUME=1 ./tests/e2e/run.sh"
    return
  fi

  # PREFLIGHT: no other e2e server may be alive. Every run mints the same pane id
  # w1:p2, so a leaked server from an earlier run owns a pane with that exact
  # name — and a report naming w1:p2 then SUCCEEDS against the wrong server
  # instead of failing, which is the least detectable way to be wrong. That is not
  # a hypothesis about the flake: it is why a stale server has to be impossible
  # before any result below this line means anything.
  #
  # Scoped to this suite's own session-name prefix on purpose. A blanket kill on
  # "herdr" would take the developer's own session down, and this suite has
  # already damaged this machine once by being careless about that boundary.
  local swept=0 stray
  for stray in $(pgrep -f "herdr --session e2e-" 2>/dev/null); do
    # Skip our own server: the current run is legitimately alive right now.
    grep -q -- "--session $SESSION " <<<"$(ps -o args= -p "$stray" 2>/dev/null)" && continue
    kill "$stray" 2>/dev/null && swept=$((swept + 1))
  done
  if [ "$swept" -gt 0 ]; then
    printf 'e2e: swept %s leaked e2e server(s) from an earlier run before the resume case\n' \
      "$swept" >&2
  fi
  # A swept process may still be visible for a moment, and the assertion below is
  # about what is alive NOW, so give the signal the same bounded wait the watcher
  # teardown in cleanup uses. Bounded, because a server ignoring SIGTERM must not
  # hang the suite.
  local swept_wait=0
  while [ "$swept_wait" -lt 2000 ] && pgrep -f "herdr --session e2e-" >/dev/null 2>&1 \
        && ! pgrep -f "herdr --session $SESSION " >/dev/null 2>&1; do
    sleep 0.1 2>/dev/null || sleep 1
    swept_wait=$((swept_wait + 100))
  done
  if pgrep -f "herdr --session e2e-" >/dev/null 2>&1 \
     && ! pgrep -f "herdr --session $SESSION " >/dev/null 2>&1; then
    fail "$name" "another e2e server from an earlier run is still alive" \
      "live: $(pgrep -fl 'herdr --session e2e-' 2>/dev/null | cut -c1-160 | tr '\n' ' ')" \
      "every run mints the same pane id w1:p2, so a report naming w1:p2 would" \
      "SUCCEED against that stale server and this case would measure the wrong" \
      "machine. Stopping here rather than reporting a result I cannot trust."
    return
  fi

  if [ -z "${NEW_PANE:-}" ]; then
    fail "$name" "no new pane recorded by the launch case"
    return
  fi

  # The action is asynchronous, so its log has to be WAITED for rather than read:
  # a record for a still-running action carries a null exit code and an empty
  # stderr, and every failure message below quotes it. Reading it early is how a
  # real failure gets reported as "action log: status=running exit=- stderr=",
  # which says nothing. Cheap either way — the action is long done by now.
  await_action_log 25
  ACTION_LOG="$(action_log_tail)"

  # The stub must be the pane's foreground process before the resume is read back
  # from the snapshot. The action types the stub's path and then reports the agent,
  # so for a moment the pane is still running its shell, and a registration that
  # wobbles takes reported_resume with it. Waiting for the stub's marker is what
  # makes "a long-lived process is in place" a checked fact instead of an
  # assumption — the alternative is a test that is green or red depending on how
  # fast the machine was.
  #
  # Bounded, and its own failure: if the marker never appears the stub never ran,
  # and every assertion below would be about a pane that was never really launched.
  local marker_waited=0
  while [ ! -f "$MCODE_STUB_MARKER" ] && [ "$marker_waited" -lt 10000 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    marker_waited=$((marker_waited + 100))
  done
  if [ ! -f "$MCODE_STUB_MARKER" ]; then
    fail "$name" "the stub launcher never started in pane $NEW_PANE, so there is no long-lived process behind the registration" \
      "expected marker: $MCODE_STUB_MARKER" \
      "action log: ${ACTION_LOG}" \
      "everything below this point would be measuring a pane that was never really" \
      "launched, so this case stops here rather than reporting a false result."
    return
  fi

  # 1. STORED. The plugin reported the resume, and herdr kept it — in
  #    `agent_resume` in the session snapshot, which is the field the old
  #    read-back never looked at.
  if ! await_resume_in_snapshot 25; then
    fail "$name" "herdr's session snapshot never gained an agent_resume for this pane" \
      "snapshot: $(session_snapshot)" \
      "agent_resume entries: $(jq -c '[.workspaces[]?.tabs[]?.panes[]? | select(.agent_resume) | .agent_resume]' \
                    "$(session_snapshot)" 2>/dev/null)" \
      "action log: ${ACTION_LOG}" \
      "the action log is what separates 'the plugin never reported a resume' from" \
      "'the plugin reported one and herdr dropped it'. Those are different bugs."
    return
  fi

  # 2. STOPPED. Only this session's server; the default session is not touched.
  if ! "$HERDR" --session "$SESSION" server stop >/dev/null 2>&1; then
    fail "$name" "\`herdr --session $SESSION server stop\` failed, so nothing was restarted" \
      "note: this stops the NAMED session only; the default session is a different server"
    return
  fi
  sleep 2

  # 3. RESTARTED.
  "$HERDR" --session "$SESSION" server </dev/null >"$WORKDIR/server-restart.log" 2>&1 &
  SERVER_PID=$!
  local i ready=""
  for i in $(seq 1 40); do
    ready="$("$HERDR" --session "$SESSION" status server 2>/dev/null | sed -n 's/^status: //p')"
    [ "$ready" = "running" ] && break
    sleep 0.25
  done
  if [ "$ready" != "running" ]; then
    fail "$name" "the session did not come back up after the restart" \
      "log: $(head -3 "$WORKDIR/server-restart.log" 2>/dev/null | tr '\n' ' ')"
    return
  fi

  # 4. A CLIENT ATTACHES, which is what gives the server a terminal area big
  #    enough to act on a pending resume.
  if ! python3 "$here/attach-pty.py" 50 160 12 \
        "$HERDR" session attach "$SESSION" >"$WORKDIR/attach.log" 2>&1; then
    fail "$name" "the pty helper could not attach a client" \
      "output: $(head -3 "$WORKDIR/attach.log" 2>/dev/null | tr '\n' ' ')"
    return
  fi

  # 5. THE ASSERTION. The token only appears in the pane if herdr restored the
  #    resume command we recorded and typed it into the recreated pane.
  local content
  content="$("$HERDR" --session "$SESSION" pane read "$NEW_PANE" 2>/dev/null)"
  if printf '%s' "$content" | grep -qF "$RESUME_PROOF"; then
    pass "$name"
    return
  fi

  # A failure here has four quite different causes and they must not be
  # collapsed, because the fix for each is different. So say which one it looks
  # like instead of printing "resume did not happen" and leaving it there.
  # resume_failure_mode holds the decision and is tested without a race.
  local mode
  mode="$(resume_failure_mode \
            "$(action_refused_resume && printf 1 || printf 0)" \
            "$(snapshot_has_resume && printf 1 || printf 0)" \
            "$(client_ever_connected && printf 1 || printf 0)")"
  case "$mode" in
    refused)
      fail "$name" "herdr REFUSED the resume report, so it stored nothing and there is no record to lose" \
        "action log: ${ACTION_LOG}" \
        "herdr says: $(resume_refusal_evidence)" \
        "this is NOT the accepted-then-lost case and NOT a missing feature: herdr" \
        "rejects a resume_argv whose reporter does not hold the pane, and the" \
        "reporter is whatever holds the pane at the moment of the report. Whether" \
        "the pane was still ours at that instant is the open question, and the" \
        "server log above is the evidence for it. Do NOT add a retry."
      ;;
    no-client)
      fail "$name" "no client ever connected, so herdr's pending resume had a 0x0 terminal area" \
        "herdr skips deferred agent resumes when no client is attached" \
        "see tests/e2e/attach-pty.py"
      ;;
    stored-but-no-token)
      fail "$name" "the resume was stored and a client connected, but the token never appeared" \
        "expected token: $RESUME_PROOF" \
        "action log: ${ACTION_LOG}" \
        "pane tail: $(printf '%s' "$content" | tail -c 200 | tr -d '\000')"
      ;;
    *)
      fail "$name" "the resume was reported and herdr ACCEPTED it, but the snapshot never gained it" \
        "action log: ${ACTION_LOG}" \
        "the stub was confirmed running before this poll, so a long-lived process was" \
        "in place and this is not the known shell-only-pane case. The herdr server log" \
        "around this pane is the next thing to read; do NOT add a retry, because a" \
        "retry would hide a real regression as thoroughly as it would hide a flake."
      ;;
  esac
}

# ── refusal guard ────────────────────────────────────────────────────────────
# Isolation is set up unconditionally above, so the guard below is the second
# lock on the same door: if something in the environment redirects herdr back at
# the developer's own config after the fact, this stops the run BEFORE anything is
# linked, started or deleted.
#
# It checks the two ways herdr can be pointed at a real config dir: the resolved
# XDG location, and an explicit socket override. Checking only one is how a guard
# gives false comfort — HERDR_SOCKET_PATH alone is enough to make every call in
# this file land on the wrong server while config_dir still looks correct.
#
# The rule is deliberately narrow: the config dir must live inside E2E_XDG_ROOT,
# the directory this run created for it. Not "somewhere plausible", not "a temp
# dir" — inside THIS root, which is removed on exit. Anything else is refused,
# including a developer's deliberate XDG_CONFIG_HOME, because this suite has no
# business writing to a location it did not create.
refuse_unless_isolated() { # refuse_unless_isolated <config-dir> <socket-path-or-empty>; 0 = safe
  local cfg="$1" sock="$2" real="${REAL_USER_CONFIG_DIR:-}"

  if [ -n "$sock" ] && [ -n "$real" ] && [ "${sock%/*}" = "$real" ]; then
    printf 'e2e: REFUSING TO RUN — the socket override points into your real herdr config.\n' >&2
    printf '  socket:      %s\n' "$sock" >&2
    printf '  real config: %s\n' "$real" >&2
    printf '  This suite links a plugin into a registry that is shared by every\n' >&2
    printf '  session, and would replace what you have installed. Unset\n' >&2
    printf '  HERDR_SOCKET_PATH and re-run.\n' >&2
    return 1
  fi

  case "$cfg" in
    "$E2E_XDG_ROOT"/*) : ;;
    *)
      printf 'e2e: REFUSING TO RUN — the herdr config dir is not inside this run own root.\n' >&2
      printf '  config dir:  %s\n' "$cfg" >&2
      printf '  own root:    %s\n' "$E2E_XDG_ROOT" >&2
      printf '  This suite starts a real server and links a real plugin. It must do\n' >&2
      printf '  that in a directory it created, not in yours. Unset XDG_CONFIG_HOME\n' >&2
      printf '  and re-run, or point it at a throwaway directory.\n' >&2
      return 1
      ;;
  esac

  # Belt and braces, and the reason the two checks above are not redundant: name
  # the user's real directory explicitly, in case it is somewhere unusual.
  if [ -n "$real" ] && [ "$cfg" = "$real" ]; then
    printf 'e2e: REFUSING TO RUN — the config dir is your real %s.\n' "$real" >&2
    return 1
  fi
  return 0
}

# Self-test for the guard above, run as part of the suite so the guard is not
# merely present but exercised. A refusal path that has never run is a guess.
#
#   ./tests/e2e/run.sh --self-test-isolation
#
# It checks the three ways the guard must fire — a real config dir, a real socket
# override, and the case that matters most, a path that LOOKS isolated but is not
# (a workdir-prefixed string that is really someone's home) — and the one way it
# must not. It runs no herdr and touches no registry, so it is safe anywhere.
self_test_isolation() {
  local failures=0 total=5

  check() { # check <expect-0-or-1> <label> <config-dir> <socket>
    local want="$1" label="$2" got
    if refuse_unless_isolated "$3" "$4" >/dev/null 2>&1; then got=0; else got=1; fi
    if [ "$got" = "$want" ]; then
      printf 'ok    isolation: %s\n' "$label"
    else
      printf 'FAIL  isolation: %s (wanted %s, got %s)\n' "$label" "$want" "$got" >&2
      failures=$((failures + 1))
    fi
  }

  check 1 "refuses the user's real config dir" \
    "$HOME/.config/herdr" ""
  check 1 "refuses a socket pointing into the user's real config" \
    "$WORKDIR/xdg/herdr" "$HOME/.config/herdr/herdr.sock"
  check 1 "refuses a config dir outside this run own root" \
    "/tmp/somewhere-else/herdr" ""
  # The near-miss: a path that starts with the root string but is not under it.
  # A prefix test without a separator would wave this through, so it is checked.
  check 1 "refuses a root-prefixed path that is not under the root" \
    "${E2E_XDG_ROOT}-lookalike/herdr" ""
  check 0 "accepts this run own isolated root" \
    "$E2E_XDG_ROOT/herdr" "$E2E_XDG_ROOT/herdr/herdr.sock"

  if [ "$failures" -eq 0 ]; then
    printf -- '---\n'
    printf '5 case(s), all passed\n'
    return 0
  fi
  printf -- '---\n'
  printf '%d case(s), %d failed\n' "$total" "$failures" >&2
  return 1
}

# Self-test for the resume triage, run as part of the suite.
#
#   ./tests/e2e/run.sh --self-test-triage
#
# The triage exists to stop a failure being described wrongly, and the way it
# was described wrongly is a fact worth keeping in front of the next editor: a
# herdr REFUSAL was reported as "the resume was reported and herdr ACCEPTED it,
# but the snapshot never gained it". Both halves of that sentence are false —
# herdr refused, and it stored nothing that could be lost — and the cost of the
# false claim was a hunt for a dropped-record bug in herdr that does not exist.
#
# So the decision is pure, and the pure part is checked here with no herdr, no
# server and no sleeping. The only case that would catch the original defect is
# the FIRST one: refused must not be reported as a lost record, and the two must
# stay different strings even when the record and client facts are identical.
self_test_triage() {
  local failures=0 total=6

  check() { # check <expected-mode> <label> <refused> <has-record> <client>
    local want="$1" label="$2" got
    got="$(resume_failure_mode "$3" "$4" "$5")"
    if [ "$got" = "$want" ]; then
      printf 'ok    triage: %s\n' "$label"
    else
      printf 'FAIL  triage: %s (wanted %s, got %s)\n' "$label" "$want" "$got" >&2
      failures=$((failures + 1))
    fi
  }

  # The regression this function was written for: identical record and client
  # facts, opposite verdicts, decided only by whether herdr refused.
  check refused            "a refusal is never reported as a lost record" 1 0 0
  check lost               "accepted but no record, with a client"          0 0 1
  # A refusal outranks every record-based verdict. If a stale record from an
  # earlier pane is present, it must not turn this into a pass-looking diagnosis.
  check refused            "a refusal outranks a record already in the snapshot" 1 1 1
  check lost               "nothing recorded and no client: still a lost record" 0 0 0
  # "no client" is reachable ONLY alongside a record. That is inherited from the
  # inline branches this function replaced, where the no-record case was tested
  # first and swallowed everything else, and it is the one mapping here that is
  # easy to "fix" into being wrong — the draft of this self-test asserted
  # otherwise and was corrected by the run below, which is the whole reason it
  # exists rather than a comment.
  check no-client          "recorded, but no client ever attached"           0 1 0
  check stored-but-no-token "recorded and connected, but the token is absent" 0 1 1

  if [ "$failures" -eq 0 ]; then
    printf -- '---\n'
    printf '6 case(s), all passed\n'
    return 0
  fi
  printf -- '---\n'
  printf '%d case(s), %d failed\n' "$total" "$failures" >&2
  return 1
}

# Where the developer's REAL config lives, computed once. Used only by the
# refusal guard — never as a path anything else in this file reads or writes.
# Resolved by asking herdr nothing and looking at the environment the way herdr
# itself does, so the check is about what herdr WOULD use, not about what this
# script happens to have exported.
REAL_USER_CONFIG_DIR="$HOME/.config/herdr"
if [ -n "${XDG_CONFIG_HOME_BEFORE_ISOLATION:-}" ]; then
  REAL_USER_CONFIG_DIR="$XDG_CONFIG_HOME_BEFORE_ISOLATION/herdr"
fi

# The guard runs BEFORE anything is linked, started or deleted. Exit 2 rather than
# 1 so a refusal is distinguishable from a test failure in CI.
if ! refuse_unless_isolated "$HERDR_CONFIG_DIR" "${HERDR_SOCKET_PATH:-}"; then
  exit 2
fi

# The self-test needs the guard but not a server, so it short-circuits here. It
# still ran the guard above, so a broken guard cannot reach the point of
# reporting itself healthy.
case "${1:-}" in
  --self-test-isolation)
    self_test_isolation
    exit $?
    ;;
  --self-test-triage)
    self_test_triage
    exit $?
    ;;
esac

# ── main ─────────────────────────────────────────────────────────────────────
printf 'e2e: driving a REAL herdr (%s), config isolated under %s\n' "$HERDR" "$HERDR_CONFIG_DIR"

# Snapshot the registry BEFORE linking, so cleanup can put it back exactly.
# Within THIS run's isolated registry, set above — never the developer's.
PRIOR_LINK="$("$HERDR" plugin list --json 2>/dev/null \
  | jq -r --arg id "$PLUGIN_ID" '.result.plugins[]? | select(.plugin_id == $id) | .plugin_root // empty' 2>/dev/null)"

"$HERDR" plugin unlink "$PLUGIN_ID" >/dev/null 2>&1
if ! "$HERDR" plugin link "$repo" >/dev/null 2>&1; then
  printf 'FATAL: could not link the plugin from %s\n' "$repo" >&2
  exit 2
fi
LINKED_BY_US=1

# Gate from issue #41: the field is `warnings`, PLURAL. A misspelled event name
# warns; querying `.warning` looks like "no warnings" for a hook that does not
# exist. Cheap to assert here and it catches a dead hook the moment one lands.
WARNINGS="$("$HERDR" plugin list --json 2>/dev/null \
  | jq -c --arg id "$PLUGIN_ID" '.result.plugins[]? | select(.plugin_id == $id) | (.warnings // [])' 2>/dev/null)"

# PREFLIGHT, before the server starts and before anything is linked: clear any
# watcher this checkout left behind in an EARLIER run. Teardown does the same on
# the way out, and both are needed - teardown alone cannot help a run that follows
# a crashed one, and that is exactly the case where a stale watcher sits on pane
# w1:p2 and makes the event-hook case count two.
#
# Scoped to this checkout's own script path, for the reason given on
# kill_own_watchers: the developer's real watchers run their installed copy and
# must survive this untouched.
kill_own_watchers "preflight"

# The stub launcher MUST be on PATH before the server starts: the action is
# spawned by the server and inherits the server's environment, not this
# script's. See prepare_stub_mcode for what that cost on the first CI run.
prepare_stub_mcode

# Both self-tests run inside the full suite, not only behind their flags: a
# guard or a decision that is only exercised on demand is one that silently rots
# between the runs nobody remembers making.
self_test_isolation
self_test_triage

# ── case: the mcode SessionStart hook, against THIS real herdr ───────────────
# Issue #118. Every other case here drives the plugin's launcher or the watcher
# directly. This one drives what #118 actually added: the mcode-side hook, which
# finds its own pane by walking its process ancestry and reports that pane once.
#
# WHY THE HOOK RUNS AS A CHILD OF THE PANE'S SHELL, RATHER THAN A REAL `mcode`.
# mcode's entire contribution to the ancestry is "be a descendant of the pane's
# shell", and the hook reads nothing else about it — no mcode on PATH, no
# credentials, no API call, nothing from the session store. Running the hook as a
# child of the pane's own shell therefore exercises the real mechanism against a
# real herdr, on a CI runner with no mcode installed and no account to sign in
# with. A real `mcode` session is verified by hand in an isolated session instead;
# that evidence is on the #118 PR, and it is not reproducible in CI, so it is not
# pretended at here.
#
# What this proves, and only this: real herdr, a real pane, a real process tree, a
# real `pane report-agent` on the pane the ancestry proved, and the real
# `ensure-watcher` picking that registration up and starting exactly one watcher.
run_case_hook_bootstrap() {
  local name="hook: a SessionStart run registers its own pane and starts a watcher"

  if ! command -v pgrep >/dev/null 2>&1; then
    fail "$name" "pgrep is required to assert a watcher process exists"
    return
  fi

  # A fresh pane, so the assertion is about this hook and not about a registration
  # the launch case already made.
  local src pane
  src="$(pane_ids | head -1)"
  if [ -z "$src" ]; then
    fail "$name" "no source pane to split from"
    return
  fi
  pane="$("$HERDR" --session "$SESSION" pane split "$src" --direction right --no-focus 2>/dev/null \
    | jq -r '.result.pane.pane_id' 2>/dev/null)"
  if [ -z "$pane" ]; then
    fail "$name" "could not split a pane for the hook to claim"
    return
  fi
  THROWAWAY_PANE="$pane"
  note_created_pane "$pane"

  # The topology here is the production one, and BOTH halves of it are
  # load-bearing. Measured while writing this case:
  #
  #   * If the hook is the only process in the pane's foreground, the registration
  #     lasts about 300 ms and then herdr's detection pass drops it again. That
  #     looks exactly like a hook that never reported, and it is a test artefact
  #     rather than the production shape.
  #   * With a LONG-LIVED foreground process holding the pane and the hook running
  #     as its short-lived child -- which is what `mcode` does -- the registration
  #     persists: measured steady across a 10s poll, state_change_seq holding at 1.
  #   * And it must NOT be `exec sleep 300`: `exec` REPLACES the pane's shell, and a
  #     command typed into `sleep` goes to its stdin and is discarded, so the hook
  #     would never run at all.
  # XDG_CONFIG_HOME IS LEFT SET FOR THIS CASE, AND THAT IS A DIVERGENCE FROM
  # PRODUCTION, recorded here rather than hidden.
  #
  # Measured: mcode strips it. An exported XDG_CONFIG_HOME came through as
  # literally `<unset>` inside a live SessionStart hook, so a real hook ALWAYS
  # resolves herdr's config root from $HOME. This case runs the hook from a shell
  # rather than through mcode, which keeps the suite's isolated root visible and is
  # the only way to point the hook at the session under test. Stripping it, as mcode
  # does, would aim the hook at the developer's real config root, where this pane
  # does not exist, and the hook would correctly refuse.
  #
  # So this case proves the ancestry walk, the registration and the watcher handoff
  # against a real herdr; it does NOT prove config-root resolution. On a machine
  # whose herdr runs on the default root -- the case this feature targets, and what
  # a normal user has -- the two coincide. The limit is in README.md and CLAUDE.md,
  # and the real-mcode attempt, including this failure, is on the #118 PR.
  local stand_in="$WORKDIR/fake-mcode-foreground.sh"
  cat >"$stand_in" <<STANDIN
#!/bin/sh
# Stands in for mcode in a pane: holds the foreground for its lifetime and runs
# the hook as its own child, so the ancestry the hook walks is the real one.
sleep 300 &
HOLDER=\$!
env -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \\
  "$repo/mcode-plugin/hooks/herdr-bootstrap.sh" SessionStart >"$WORKDIR/hook.out" 2>&1
wait \$HOLDER
STANDIN
  # Asserted BEFORE the stand-in starts, because the stand-in runs the hook
  # immediately: checked afterwards, this would always find the pane already
  # registered and the case would report its own setup as a failure.
  if [ -n "$(agent_row "$pane")" ]; then
    fail "$name" "pane $pane was already registered before the hook ran"
    return
  fi

  chmod +x "$stand_in"
  "$HERDR" --session "$SESSION" pane run "$pane" "$stand_in" >/dev/null 2>&1
  sleep 1

  # `pane run` types the command into the pane; the shell there runs it, so give
  # the ancestry walk and the report a bounded window rather than reading once.
  local i registered=0
  for i in $(seq 1 40); do
    if [ -n "$(agent_row "$pane")" ]; then registered=1; break; fi
    sleep 0.25
  done
  if [ "$registered" -ne 1 ]; then
    fail "$name" "the hook did not register pane $pane within 10s" \
      "the hook resolves its pane by process ancestry; if the pane's shell is not" \
      "an ancestor of the hook process it must refuse rather than guess" \
      "hook output: $(tail -4 "$WORKDIR/hook.out" 2>/dev/null | tr '\n' '|')" \
      "pane state: $("$HERDR" --session "$SESSION" agent get "$pane" 2>/dev/null | jq -c '.result.agent // .error' 2>/dev/null)"
    return
  fi

  # THE STATE IS DELIBERATELY NOT ASSERTED, and reading that as an omission would be
  # a mistake. The hook's one report is `--state idle`, but by the time this case
  # reads the pane the watcher — started BY that report — has already classified the
  # pane from its screen and owns the value. Measured here: `unknown`, because the
  # stand-in is not a real mcode screen. That is the design working, not a
  # regression, and asserting `idle` would be asserting that the watcher had not yet
  # run — i.e. asserting a race. What must hold is that the pane is registered under
  # the shared label and that exactly one watcher now owns it.
  local row
  row="$(agent_row "$pane")"
  if [ "$(printf '%s' "$row" | jq -r '.agent // empty')" != "$AGENT_LABEL" ]; then
    fail "$name" "pane $pane reports agent '$(printf '%s' "$row" | jq -r '.agent // empty')', expected $AGENT_LABEL" \
      "hook output: $(tail -3 "$WORKDIR/hook.out" 2>/dev/null | tr '\n' '|')"
    return
  fi

  # And the registration must have started exactly one watcher — the mechanism the
  # whole bootstrap-only design rests on: the hook reports once, herdr fires
  # pane.agent_status_changed, and ensure-watcher takes over.
  local found=0
  for i in $(seq 1 40); do
    if pgrep -f "mcode-watch.sh $pane" >/dev/null 2>&1; then found=1; break; fi
    sleep 0.25
  done
  if [ "$found" -ne 1 ]; then
    fail "$name" "no watcher was started for $pane within 10s of the hook registering it" \
      "the hook reports once and never again; the watcher it triggers is what owns" \
      "state, so a registration with no watcher leaves the pane frozen at idle"
    return
  fi
  # AT LEAST ONE, not exactly one, and the reason is a measured pre-existing race
  # rather than leniency. `run_case_event_watcher` already owns the "exactly one
  # watcher per pane" invariant, and asserting it here as well would double this
  # suite's exposure to that race without adding coverage of anything new.
  #
  # The race is real and it is not this PR's: on UNMODIFIED origin/dev, 2 of 10
  # local e2e runs failed that same case with "2 watchers were started for one
  # pane", and this case reproduced it on its first run. `ensure-watcher` guards
  # with an anchored `pgrep` and then spawns, which is check-then-act; two
  # registrations landing together can both pass the check. Filed separately with
  # the evidence rather than absorbed here.
  pass "$name"
}

run_case_bootstrap
run_case_launch
run_case_hook_bootstrap
run_case_registered
run_case_readable
run_case_name_addressable
run_case_tripwire
run_case_event_watcher
run_case_foreign_pane_untouched
# LAST, and it has to be. It stops and restarts the session server, so every case
# above it must already have run against the first server.
run_case_resume_restored

printf -- '---\n'
if [ "$WARNINGS" != "[]" ] && [ -n "$WARNINGS" ]; then
  printf 'manifest warnings: %s\n' "$WARNINGS" >&2
  CASES_FAILED=$((CASES_FAILED + 1))
fi
if [ "$CASES_FAILED" -eq 0 ]; then
  # The skip count rides on the green line. A suite that says "all passed" while
  # one case did not run is the false assurance this file exists to remove, and
  # the number is what stops someone reading only the last line from missing it.
  if [ "$CASES_SKIPPED" -gt 0 ]; then
    printf '%d case(s), all passed, %s SKIPPED (99 above - see the skip reason)\n' \
      "$CASES_RUN" "$CASES_SKIPPED"
  else
    printf '%d case(s), all passed\n' "$CASES_RUN"
  fi
  exit 0
fi
printf '%d case(s), %d failed\n' "$CASES_RUN" "$CASES_FAILED"
exit 1
