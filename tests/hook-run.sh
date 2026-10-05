#!/usr/bin/env bash
# tests/hook-run.sh — the suite for mcode-plugin/hooks/herdr-bootstrap.sh (issue #118).
#
# Plain bash, like every other suite here. Discovered by the CI `tests/*run.sh`
# glob, so the name is load-bearing: a suite that does not match the glob is
# committed and never executed.
#
#   ./tests/hook-run.sh          run every case
#   ./tests/hook-run.sh --list   list case names
#
# ---- WHAT THIS SUITE IS ACTUALLY PROVING --------------------------------------
# The hook does one thing: find the herdr pane that owns this process, by walking
# its ancestry, and report that pane once. Every case below attacks one way that
# can go wrong, and each one FAILS if the corresponding behaviour is removed:
#
#   * ancestry, not cwd          — two panes, one sharing the hook's cwd
#   * nearest ancestor wins      — a nested pane must beat the outer one
#   * socket, not session name   — every call carries the proved socket, and
#                                  `--session` never appears
#   * fail closed                — an unproven pane produces NO report at all
#   * no release path            — `release-agent` is never called, ever
#   * exit 0 always              — a broken/absent herdr cannot fail a session
#   * one report, once           — no Stop/PreToolUse/UserPromptSubmit handler
#
# ---- THE ANCESTRY HERE IS REAL, NOT MOCKED ------------------------------------
# Each case starts a real process to act as a pane's shell, and the hook runs as
# THAT process's child, so `ps` inside the hook walks a genuine process tree. The
# mechanism is `$WORK/pane-shell.sh`, written by this suite:
#
#   pane-shell.sh <tag> <cwd> hook          -> runs the hook as its own child
#   pane-shell.sh <tag> <cwd> inner <tag2>  -> spawns a SECOND pane shell, which
#                                              runs the hook; used for nearest-wins
#
# It publishes its own pid to `<tag>.pid` and waits for `<tag>.go` to appear, so a
# case can learn the pid, build a fixture around it, and only then let the hook
# run. A suite that injected the pid list instead would pass just as well if the
# walk itself were deleted, which is the one thing worth proving.

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"

HOOK="$repo/mcode-plugin/hooks/herdr-bootstrap.sh"
STUB="$here/fake-herdr-hook"
MANIFEST="$repo/mcode-plugin/.claude-plugin/plugin.json"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcode-hook-tests.XXXXXX")"
PANE_SHELL_PID=""
cleanup() {
  [ -n "$PANE_SHELL_PID" ] && kill "$PANE_SHELL_PID" 2>/dev/null
  # Never a bare `rm`, never a trash can (issue #109).
  /bin/rm -rf "$WORK" 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM

cat >"$WORK/pane-shell.sh" <<EOF
#!/bin/sh
# A stand-in for a pane's shell. See the header of this suite.
#   \$1 tag   \$2 cwd   \$3 "hook" | "inner"   \$4 inner tag
echo \$\$ >"$WORK/\$1.pid"
while [ ! -f "$WORK/\$1.go" ]; do sleep 0.05; done
cd "\$2" || exit 1
if [ "\${3:-}" = "inner" ]; then
  /bin/sh "$WORK/pane-shell.sh" "\$4" "\$2" hook &
  wait
else
  # mcode writes a JSON payload on the hook's stdin. The suite feeds a real one,
  # because the hook's cheap path reads cwd out of it and a test that never
  # supplied a payload would be testing a fallback the real thing rarely takes.
  # (No backticks anywhere in this heredoc: it is unquoted, so a backticked word in
  # a comment is a command substitution and bash will try to run it.)
  # M4_PAYLOAD_CWD unset means "payload carries no cwd", which is itself a case
  # worth having: the hook must then fall back to its own working directory.
  if [ -n "\${M4_PAYLOAD_CWD:-}" ]; then
    printf '{"session_id":"m4-test","cwd":"%s"}' "\$M4_PAYLOAD_CWD" \
      | HERDR_BIN_PATH="$STUB" /usr/bin/env bash "$HOOK" SessionStart
  else
    printf '{"session_id":"m4-test"}' \
      | HERDR_BIN_PATH="$STUB" /usr/bin/env bash "$HOOK" SessionStart
  fi
fi
EOF
chmod +x "$WORK/pane-shell.sh"

CASES_RUN=0
CASES_FAILED=0
CURRENT_CASE=""
broke=0
note() { broke=1; printf '        %s\n' "$*"; }

export FAKE_HOOK_LOG="$WORK/calls.log"
export FAKE_HOOK_FIXTURE="$WORK/fixture.json"
: >"$FAKE_HOOK_LOG"

# Isolate the hook's DURABLE LOG, and do it once, for the whole suite.
#
# The hook writes to "${MINIMAX_DATA_DIR:-$HOME/.minimax}/state/herdr-bootstrap".
# Six places here run the hook. Two are the durable-log cases, which pass their own
# MINIMAX_DATA_DIR through `env -i`. The other FOUR inherited the developer's real
# $HOME: the stand-in pane shell's heredoc below — which is how most cases reach the
# hook, so it is the largest contributor — and the direct call sites at 352, 428 and
# 432. That was measured, not assumed: on a machine where this suite had been run
# three times, 48 of the 54 fires in that developer's REAL
# ~/.minimax/state/herdr-bootstrap/hook.log were this suite — fake panes w1:p1,
# w1:real, w3:real — and all 21 refusals in the file belonged to it too.
#
# That file is the only record of what a real session's hook did (issue #126
# turns on reading it), so a suite that writes into it destroys the evidence it
# exists to produce. It is the same state-isolation rule this file already
# applies to HERDR_SOCKET_PATH above, for the same reason.
#
# Exported rather than passed per call site, so a case added later inherits the
# isolation instead of having to remember it. tests/e2e/run.sh had the same gap.
#
# No `mkdir -p` here, and deliberately so: the hook's own dlog does it. A guard that
# dereferenced this variable would abort the whole suite under `set -u` the moment
# anyone removed the export — taking the case that exists to catch that removal with
# it. Verified by mutation: with the export removed, this suite now fails on
# suite-env-isolates-the-durable-log instead of dying before it gets there.
export MINIMAX_DATA_DIR="$WORK/minimax-data"

# Simulate the environment mcode actually gives a hook. This is not cosmetic: run
# from inside a herdr pane, the suite would otherwise hand the hook a live
# HERDR_SOCKET_PATH for the owner's real server, which is exactly the variable
# measurement proved is stripped in production. Clearing it here means every case
# proves the hook works from a STRIPPED environment, which is the only environment
# it will ever see.
unset HERDR_SOCKET_PATH HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID

# spawn_pane <tag> [mode] [inner-tag] [cwd]
#
# The pid and go files are cleared FIRST. They are per-tag, not per-case, and a
# stale pid file left by an earlier case makes pane_pid return a DEAD pid
# immediately — before this case's shell has even started — so every assertion
# downstream fails for a reason that has nothing to do with the code under test.
# /bin/rm, never a bare `rm` (issue #109).
spawn_pane() {
  local tag="$1" mode="${2:-hook}" inner="${3:-}" cwd="${4:-$WORK}"
  /bin/rm -f "$WORK/$tag.pid" "$WORK/$tag.go" 2>/dev/null
  if [ -n "$inner" ]; then
    /bin/rm -f "$WORK/$inner.pid" "$WORK/$inner.go" 2>/dev/null
  fi
  # stderr is kept, not discarded: the hook says on stderr what it could not prove,
  # and a suite that throws that away cannot assert on the difference between "the
  # prefilter matched" and "the prefilter missed and we paid for the full scan".
  "$WORK/pane-shell.sh" "$tag" "$cwd" "$mode" "$inner" >"$WORK/$tag.stderr" 2>&1 &
  PANE_SHELL_PID=$!
}

stderr_of() { cat "$WORK/$1.stderr" 2>/dev/null; }

pane_pid() { # pane_pid <tag> -> the pid, or 0
  local i=0
  while [ ! -s "$WORK/$1.pid" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  cat "$WORK/$1.pid" 2>/dev/null || echo 0
}

release_pane() { # release_pane <tag> [inner-tag] — let the hook run, then wait
  local tag="$1" inner="${2:-}" i=0
  if [ -n "$inner" ]; then
    : >"$WORK/$tag.go"
    while [ ! -s "$WORK/$inner.pid" ] && [ "$i" -lt 200 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    : >"$WORK/$inner.go"
  else
    : >"$WORK/$tag.go"
  fi
  wait "$PANE_SHELL_PID" 2>/dev/null
  PANE_SHELL_PID=""
}

# Writing the fixture also invalidates the stub's pre-rendered cache. The suite owns
# the fixture's lifecycle, so the suite owns this: the stub cannot detect the change
# itself, because filesystem timestamps have one-second granularity and two cases
# written inside the same second are indistinguishable by mtime. A stale cache makes
# a case probe the PREVIOUS case's pids, which surfaces as "my pane was not
# reported" and looks exactly like a product bug. /bin/rm, never a bare `rm`
# (issue #109).
write_fixture() {
  printf '%s' "$1" >"$FAKE_HOOK_FIXTURE"
  /bin/rm -f "$FAKE_HOOK_FIXTURE.proc-cache" 2>/dev/null
}
calls() { cat "$FAKE_HOOK_LOG" 2>/dev/null; }
# A failure note must stay readable. The call log runs to hundreds of lines on the
# scale cases, and a note that pastes all of it into the report hides the one line
# that matters.
calls_digest() { calls | head -c 400 | tr '\n' '|'; }
reset_log() { : >"$FAKE_HOOK_LOG"; }
report_calls() { grep -c 'report-agent' "$FAKE_HOOK_LOG" 2>/dev/null || true; }

# A two-session fixture: alpha owns <alpha-pid>, beta owns a pid in no chain.
two_session_fixture() { # <alpha-pid> <alpha-socket> <beta-socket>
  jq -nc --arg sa "$2" --arg sb "$3" --argjson pid "$1" \
    '{sessions:[
       {name:"alpha",socket:$sa,running:true,panes:[{pane_id:"w1:p1",shell_pid:$pid,fg_pgid:0,fg_pids:[]}]},
       {name:"beta", socket:$sb,running:true,panes:[{pane_id:"w9:p9",shell_pid:999999,fg_pgid:0,fg_pids:[]}]}
     ]}'
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

# --- cases -------------------------------------------------------------------

# 1. The manifest registers SessionStart and NOTHING else.
#
# This is the single-reporter property expressed as data. If a Stop or PreToolUse
# handler is ever added, this fails — which is the point. The hook reporting state
# per turn while the watcher also reports state is two writers of one field on one
# pane, and herdr would flip on whichever landed last.
case_manifest_declares_only_session_start() {
  local events
  events="$(jq -r '.hooks | keys[]' "$MANIFEST" 2>/dev/null | sort | tr '\n' ' ')"
  events="${events% }"
  if [ "$events" != "SessionStart" ]; then
    note "manifest declares hooks: ${events:-<none>}"
    note "only SessionStart may be declared; the watcher owns every later state."
  fi
}

# 2. The handler is pinned rather than assumed: a `command` handler running our own
#    script, anchored on $CLAUDE_PLUGIN_ROOT.
#
# mcode runs hooks with cwd set to the PROJECT directory and copies the plugin into
# a read-only content-addressed snapshot, so a relative path resolves against
# neither. A manifest that parses is not a working hook — the Epic 1 defect.
case_handler_is_our_command_script() {
  local cmd
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$MANIFEST" 2>/dev/null)"
  case "$cmd" in
    *herdr-bootstrap.sh*) : ;;
    *) note "SessionStart command does not run herdr-bootstrap.sh: ${cmd:-<none>}" ;;
  esac
  if [ "$(jq -r '.hooks.SessionStart[0].hooks[0].type' "$MANIFEST" 2>/dev/null)" != "command" ]; then
    note "handler type is not \"command\"; mcode rejects other handler kinds outside CLAUDE format"
  fi
  # Anchored on the plugin root, in the BRACED form mcode actually substitutes.
  # This assertion used to require the literal substring CLAUDE_PLUGIN_ROOT, which
  # both pinned the bug (unbraced, and Claude's name rather than mcode's) and would
  # have rejected the fix. Intent is "resolves the hook through the plugin root";
  # the spelling that satisfies it is the one mcode honours.
  case "$cmd" in
    *'${PLUGIN_ROOT}'*|*'${CLAUDE_PLUGIN_ROOT}'*) : ;;
    *) note "command is not anchored on a braced \${PLUGIN_ROOT}; measured cwd is the project dir" ;;
  esac
}

# 3. The pane is found by ANCESTRY. A second pane deliberately shares the hook's
#    cwd and must NOT be chosen: cwd is not an identity, and this repo already
#    documents two mcode panes in one cwd as a collision.
case_pane_is_found_by_ancestry_not_cwd() {
  local pid
  spawn_pane alpha
  pid="$(pane_pid alpha)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi

  # The hook runs with cwd=$WORK, and beta's pane claims that same cwd.
  write_fixture "$(two_session_fixture "$pid" "$WORK/alpha.sock" "$WORK/beta.sock" |
    jq --arg cwd "$WORK" '.sessions[1].panes[0].cwd = $cwd')"
  reset_log
  release_pane alpha

  if ! grep -q 'report-agent w1:p1' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the pane whose shell_pid is our real ancestor (w1:p1) was not reported"
    note "log: $(calls_digest)"
  fi
  if grep -q 'report-agent w9:p9' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "reported w9:p9, which only shares our CWD — cwd is not an identity"
  fi
}

# 4. NEAREST ancestor wins. The outer pane shell is in the chain too, through the
#    inner one, so this is the case that tells the two apart.
case_nearest_ancestor_wins() {
  local outer inner
  spawn_pane outer inner inner
  outer="$(pane_pid outer)"
  if [ "$outer" = "0" ]; then note "could not start the outer stand-in pane shell"; return; fi
  # Releasing the outer shell starts the inner one, which publishes its own pid.
  : >"$WORK/outer.go"
  local i=0
  while [ ! -s "$WORK/inner.pid" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  inner="$(pane_pid inner)"
  if [ "$inner" = "0" ]; then kill "$PANE_SHELL_PID" 2>/dev/null; note "could not start the inner stand-in pane shell"; return; fi

  write_fixture "$(jq -nc --arg so "$WORK/outer.sock" --arg si "$WORK/inner.sock" \
    --argjson po "$outer" --argjson pi "$inner" \
    '{sessions:[
       {name:"outer",socket:$so,running:true,panes:[{pane_id:"w1:p1",shell_pid:$po,fg_pgid:0,fg_pids:[]}]},
       {name:"inner",socket:$si,running:true,panes:[{pane_id:"w2:p2",shell_pid:$pi,fg_pgid:0,fg_pids:[]}]}
     ]}')"
  reset_log
  : >"$WORK/inner.go"
  wait "$PANE_SHELL_PID" 2>/dev/null
  PANE_SHELL_PID=""

  if grep -q 'report-agent w1:p1' "$FAKE_HOOK_LOG" 2>/dev/null &&
    ! grep -q 'report-agent w2:p2' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "reported the OUTER pane; the nearest ancestor must win"
    note "log: $(calls_digest)"
  fi
  if ! grep -q 'report-agent w2:p2' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the inner (nearest) pane was not reported at all"
    note "log: $(calls_digest)"
  fi
}

# 5. Every herdr call is qualified with the socket the ancestry proved, and
#    `--session` is never used.
#
#    `--session <name>` is rejected deliberately: a name resolves against a config
#    root a hook cannot see, so the same name can denote a different server or none.
#    The socket comes from the same `session list` answer as the panes.
case_calls_target_the_proved_socket_and_never_a_name() {
  local pid
  spawn_pane alpha
  pid="$(pane_pid alpha)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi
  write_fixture "$(two_session_fixture "$pid" "$WORK/alpha.sock" "$WORK/beta.sock")"
  reset_log
  release_pane alpha

  if grep -q -- '--session' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the hook passed --session; a name is not a proof of which server answers"
  fi
  if ! grep -F "$WORK/alpha.sock" "$FAKE_HOOK_LOG" >/dev/null 2>&1; then
    note "no call carried the proved socket $WORK/alpha.sock"
  fi
  # PROBING another session is correct and expected — the hook has to look at every
  # running session to find the nearest match. What must never happen is a REPORT
  # going to a session that does not own this pane, so the assertion is on the
  # report line specifically, not on any call.
  if grep -F "$WORK/beta.sock" "$FAKE_HOOK_LOG" 2>/dev/null | grep -q 'report-agent'; then
    note "a REPORT went to the socket of a session that does not own this pane"
  fi
  local unqualified
  unqualified="$(grep -F '(unset)' "$FAKE_HOOK_LOG" 2>/dev/null | grep -v 'session list' | wc -l | tr -d ' ')"
  if [ "$unqualified" != "0" ]; then
    note "$unqualified call(s) reached herdr with no socket; the default session is not a safe default"
  fi
}

# 6. FAIL CLOSED. Nothing in this ancestry belongs to any pane, so the hook must
#    write nothing and report nothing — a half-identified hook can attribute a
#    state change to the WRONG pane. It must still exit 0: a registration that
#    could not be made is a log line, never a failed session.
case_unproven_pane_refuses_and_reports_nothing() {
  local pid rc
  spawn_pane alpha
  pid="$(pane_pid alpha)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi

  write_fixture "$(jq -nc --arg sa "$WORK/alpha.sock" --arg sb "$WORK/beta.sock" \
    '{sessions:[
       {name:"alpha",socket:$sa,running:true,panes:[{pane_id:"w1:p1",shell_pid:999991,fg_pgid:0,fg_pids:[]}]},
       {name:"beta", socket:$sb,running:true,panes:[{pane_id:"w9:p9",shell_pid:999992,fg_pgid:0,fg_pids:[]}]}
     ]}')"
  reset_log
  ( cd "$WORK" && HERDR_BIN_PATH="$STUB" /usr/bin/env bash "$HOOK" SessionStart ) 2>"$WORK/stderr" >/dev/null
  rc=$?
  kill "$PANE_SHELL_PID" 2>/dev/null
  PANE_SHELL_PID=""

  if [ "$(report_calls)" != "0" ]; then
    note "reported $(report_calls) time(s) with no proven pane; this must fail closed"
    note "log: $(calls_digest)"
  fi
  if ! grep -q 'refusing to register' "$WORK/stderr" 2>/dev/null; then
    note "no refusal was logged, so the silence would be undiagnosable"
  fi
  if [ "$rc" != "0" ]; then
    note "exited $rc; a hook must always exit 0 so a session is never failed by it"
  fi
}

# 7. The hook never releases. `release-agent` DELETES a registration rather than
#    handing authority back (measured, recorded in bin/mcode-watch.sh), and Stop
#    is a turn boundary — releasing there would delete the registration out from
#    under a live session. The stub answers release-agent successfully, so a hook
#    that called it would look like it had worked.
case_never_releases_a_registration() {
  local pid
  spawn_pane alpha
  pid="$(pane_pid alpha)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi
  write_fixture "$(jq -nc --arg sa "$WORK/alpha.sock" --argjson pid "$pid" \
    '{sessions:[{name:"alpha",socket:$sa,running:true,panes:[{pane_id:"w1:p1",shell_pid:$pid,fg_pgid:0,fg_pids:[]}]}]}')"
  reset_log
  release_pane alpha

  if grep -q 'release-agent' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the hook called release-agent; that deletes the registration"
  fi
  # Belt and braces: no CALL may be reintroduced behind a branch these cases do not
  # reach. Comment lines are excluded, because this file's own header explains at
  # length why release-agent must never be called — and a grep that cannot tell a
  # comment from a command would forbid documenting the trap.
  if grep -v '^[[:space:]]*#' "$HOOK" | grep -q 'release-agent'; then
    note "the hook source calls release-agent outside a comment"
  fi
}

# 8. Exactly one report, for one pane, declaring the shared namespace.
case_reports_once_with_the_shared_source() {
  local pid n
  spawn_pane alpha
  pid="$(pane_pid alpha)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi
  write_fixture "$(jq -nc --arg sa "$WORK/alpha.sock" --argjson pid "$pid" \
    '{sessions:[{name:"alpha",socket:$sa,running:true,panes:[{pane_id:"w1:p1",shell_pid:$pid,fg_pgid:0,fg_pids:[]}]}]}')"
  reset_log
  release_pane alpha

  n="$(report_calls)"
  if [ "$n" != "1" ]; then
    note "expected exactly 1 report, saw $n"
    note "log: $(calls_digest)"
  fi
  if ! grep -q -- '--source herdr:minimax-code' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the report did not carry --source herdr:minimax-code"
  fi
  if ! grep -q -- '--state idle' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the bootstrap report should be --state idle; a session has just started"
  fi
}

# 9. A missing or broken herdr cannot fail the session. mcode kills an overrun by
#    process group, and a non-zero exit from a command hook is reported back into
#    the session as a hook error.
case_survives_a_missing_herdr_and_bad_json() {
  local rc
  printf 'not json at all' >"$FAKE_HOOK_FIXTURE"
  reset_log

  ( cd "$WORK" && HERDR_BIN_PATH="/nonexistent/herdr" /usr/bin/env bash "$HOOK" SessionStart ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" != "0" ]; then note "exited $rc with herdr absent; must be 0"; fi

  ( cd "$WORK" && HERDR_BIN_PATH="$STUB" /usr/bin/env bash "$HOOK" SessionStart ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" != "0" ]; then note "exited $rc when the enumeration was unparseable; must be 0"; fi
  if [ "$(report_calls)" != "0" ]; then
    note "reported against an unparseable enumeration; that is guessing, not proving"
  fi
}

# 10. The foreground processes are anchors too, not just shell_pid. Here the pane's
#     shell_pid is in NO chain and the match comes from the foreground pid, which
#     is the shape of a pane whose foreground job is the hook's own parent.
case_foreground_process_is_an_anchor() {
  local pid
  spawn_pane alpha
  pid="$(pane_pid alpha)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi
  write_fixture "$(jq -nc --arg sa "$WORK/alpha.sock" --argjson pid "$pid" \
    '{sessions:[{name:"alpha",socket:$sa,running:true,panes:[
       {pane_id:"w1:p1",shell_pid:999993,fg_pgid:0,fg_pids:[$pid]}]}]}')"
  reset_log
  release_pane alpha

  if [ "$(report_calls)" != "1" ]; then
    note "a pane whose foreground process is the hook's own parent was not matched"
    note "log: $(calls_digest)"
  fi
}

# 11. Neither the install nor the uninstall path types a bare `rm` (issue #109).
#
#     BOTH functions that delete things, not just one. This case used to scope
#     itself to cmd_install_hook alone, which was the entire surface when it was
#     written. #118 added cmd_uninstall_hook — a second function that removes a
#     directory — and a one-function scan would have stayed green on a bare
#     `rm -rf` written into the uninstall path, which is precisely the regression
#     issue #109 exists to stop. Widening the scan is the price of adding a second
#     remover, and it is cheaper than finding out later that the test was half the
#     rule.
case_install_never_uses_a_bare_rm() {
  local deleting
  deleting="$(sed -n '/^cmd_install_hook()/,/^}/p; /^cmd_uninstall_hook()/,/^}/p' \
    "$repo/bin/mcode-plugin.sh")"
  if [ -z "$deleting" ]; then
    note "neither cmd_install_hook nor cmd_uninstall_hook found in bin/mcode-plugin.sh"
    return
  fi
  if ! printf '%s' "$deleting" | grep -q 'cmd_uninstall_hook'; then
    note "cmd_uninstall_hook is gone; if it was deleted on purpose, drop it from this case"
  fi
  # The scan must cover BOTH removers, and this is what makes that self-verifying:
  # each of the two functions has exactly one absolute-path removal, so a scan
  # narrowed back to a single function finds one and fails here. Without it, the
  # gap m3 pointed at could be reintroduced silently and this case would still
  # pass - a test that cannot tell whether it is looking at the whole rule.
  #
  # The count is anchored to COMMAND POSITION (`^[[:space:]]*/bin/rm[[:space:]]`)
  # and that anchoring is load-bearing, not tidiness. A plain `grep -c '/bin/rm'`
  # counts MENTIONS, and each function mentions /bin/rm twice - once in the
  # command and once in the comment explaining why the command is absolute. So
  # the unanchored count reads 2 for install alone, 2 for uninstall alone and 4
  # for both, and `covered < 2` was satisfied by every one of those: a scan
  # narrowed to a single function passed. I reported that this check was proven
  # by narrowing it, and that was false - the narrowed run failed on the
  # `grep -q cmd_uninstall_hook` name check above, not on the count. Counting
  # command positions instead gives 1, 1 and 2, so the threshold now fails for
  # the reason it claims to.
  local covered
  covered="$(printf '%s' "$deleting" | grep -cE '^[[:space:]]*/bin/rm[[:space:]]' 2>/dev/null || echo 0)"
  case "$covered" in '' | *[!0-9]*) covered=0 ;; esac
  if [ "$covered" -lt 2 ]; then
    note "the scan found $covered absolute-path removals; it is no longer covering"
    note "both cmd_install_hook and cmd_uninstall_hook, so a bare rm in one of them"
    note "would pass this case. Re-widen the sed range."
  fi
  if printf '%s' "$deleting" | grep -qE '(^|[^/[:alnum:]_])rm[[:space:]]'; then
    note "an install/uninstall function contains a bare rm; issue #109 requires /bin/rm"
    note "offending: $(printf '%s' "$deleting" | grep -nE '(^|[^/[:alnum:]_])rm[[:space:]]' | head -2 | tr '\n' '|')"
  fi
  if ! printf '%s' "$deleting" | grep -q '/bin/rm'; then
    note "no /bin/rm found in the install/uninstall functions"
  fi
}

# 12. The manifest's command uses the BRACED plugin-root reference, not a bare $VAR.
#
#     This is the case that would have caught the real-machine failure, and it exists
#     because the case BELOW could not. That one runs the manifest's command for real,
#     which sounds strictly stronger — and it passed the whole time the shipped hook
#     never fired once. The reason is in its own second line: it exports
#     CLAUDE_PLUGIN_ROOT="$repo/mcode-plugin" into the environment before running the
#     command. So it supplies, by hand, the one variable whose absence is the bug.
#
#     What mcode actually does (measured by m3, and confirmed against mcode's bundle):
#     the hook environment carries PLUGIN_ROOT, and mcode text-substitutes the BRACED
#     literals ${PLUGIN_ROOT} / ${CLAUDE_PLUGIN_ROOT} in manifest strings. A bare
#     $CLAUDE_PLUGIN_ROOT is not substituted and is not in the environment, so it
#     expands to the empty string with no error, and the command degenerates to
#     `bash "/hooks/herdr-bootstrap.sh"` -> exit 127, stderr swallowed by the TUI.
#     That is the whole failure: an enabled, loaded, correct plugin that never ran.
#
#     So this case grades the STRING, because the string is the contract. It cannot be
#     checked by running the command, since running the command requires supplying the
#     variable and thereby hiding the defect.
case_manifest_command_uses_the_braced_plugin_root() {
  local cmd bare
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$MANIFEST" 2>/dev/null)"
  if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
    note "no SessionStart command in the manifest"
    return
  fi

  # Strip every properly braced reference first, so what remains is only the BARE
  # ones. Checking for `$PLUGIN_ROOT` with a plain substring test would flag the
  # correct `${PLUGIN_ROOT}` too, and a test that fails on the right answer is worse
  # than no test.
  bare="$(printf '%s' "$cmd" | sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*\}//g')"
  if printf '%s' "$bare" | grep -qE '\$(CLAUDE_)?PLUGIN_ROOT'; then
    note "the manifest command uses an UNBRACED plugin root; mcode substitutes only the"
    note "braced literal, so this expands to the empty string and the hook never runs"
    note "offending: $(printf '%s' "$cmd" | grep -oE '\$(CLAUDE_)?PLUGIN_ROOT[^ "]*' | head -2 | tr '\n' ' ')"
    note "use \${PLUGIN_ROOT}/... — that is the form mcode text-substitutes"
  fi

  # And the positive half, so the check above cannot pass by having no reference at
  # all. A manifest that stopped pointing at the plugin root would also run nothing.
  if ! printf '%s' "$cmd" | grep -qE '\$\{(CLAUDE_)?PLUGIN_ROOT\}'; then
    note "the manifest command has no braced \${PLUGIN_ROOT}; it must reference the"
    note "plugin root explicitly, or the hook path cannot resolve"
  fi
}

# 14. A run that registers NOTHING still leaves evidence behind.
#
#     This is the case the whole durable log exists for. The 2026-10-05 real-machine
#     run registered nothing and produced no evidence anywhere: the TUI swallowed the
#     hook's stderr, so "the hook never ran" and "the hook ran and failed" were the
#     same observation. A diagnostic that only appears on success is not a diagnostic.
#
#     So this drives a run that REFUSES — no pane can be proven — and requires that
#     the refusal and the exit code are both on disk afterwards.
case_hook_writes_a_durable_log_even_when_it_registers_nothing() {
  local dlog_dir="$WORK/dlog" logf rc
  mkdir -p "$dlog_dir" 2>/dev/null
  logf="$dlog_dir/state/herdr-bootstrap/hook.log"

  rc=0
  (
    cd "$WORK" || exit 1
    printf '%s' "{\"session_id\":\"dlog\",\"cwd\":\"$WORK\"}" |
      env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        MINIMAX_DATA_DIR="$dlog_dir" HERDR_BIN_PATH="$STUB" \
        /bin/bash "$HOOK" SessionStart
  ) >/dev/null 2>&1 || rc=$?

  if [ ! -f "$logf" ]; then
    note "no durable log at $logf"
    note "a run that registers nothing must still be diagnosable after the fact"
    return
  fi
  if ! grep -q 'hook fired' "$logf" 2>/dev/null; then
    note "the durable log has no 'hook fired' line: $(head -2 "$logf" | tr '\n' '|')"
  fi
  # The exit code is the line that separates "ran and refused" from "was killed"
  # from "never started". Without it the file cannot answer the question it exists
  # to answer.
  if ! grep -q 'exit=' "$logf" 2>/dev/null; then
    note "the durable log has no exit-code line; exit=$rc should be recorded"
  fi

  # BOUNDED. Pre-fill past the cap and require the next run to trim rather than grow
  # without limit. A diagnostic that can fill someone's disk is a leak, and a leak on
  # a machine that runs this hook on every session is a slow one.
  local cap
  cap="$(sed -n 's/^DLOG_MAX_BYTES=\([0-9]*\).*/\1/p' "$HOOK" | head -1)"
  case "$cap" in '' | *[!0-9]*) cap=65536 ;; esac
  if [ "$cap" -gt 0 ]; then
    local i line
    : > "$logf"
    i=0
    while [ "$i" -lt "$cap" ]; do
      line="padding line $i ----------------------------------------------------------------"
      printf '%s\n' "$line" >> "$logf"
      i=$((i + 1))
    done
    (
      cd "$WORK" || exit 1
      printf '%s' "{\"session_id\":\"dlog\",\"cwd\":\"$WORK\"}" |
        env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
          MINIMAX_DATA_DIR="$dlog_dir" HERDR_BIN_PATH="$STUB" \
          /bin/bash "$HOOK" SessionStart
    ) >/dev/null 2>&1 || true

    local sz
    sz="$(wc -c < "$logf" 2>/dev/null || echo 0)"
    case "$sz" in '' | *[!0-9]*) sz=0 ;; esac
    if [ "$sz" -gt "$cap" ]; then
      note "the durable log is $sz bytes against a $cap cap; it must be trimmed, not grown"
    fi
  fi
}

# 15. The manifest's command ACTUALLY RUNS. Not "looks right" — executed.
#
#     This case exists because a manifest that parses is not a working hook, which
#     is the Epic 1 defect this repo exists to end, and because it caught a real
#     one: the command was written `/bin/sh "$.../herdr-bootstrap.sh"`, and the
#     script is bash. On macOS /bin/sh is bash in POSIX mode, where process
#     substitution is a syntax error; on Linux /bin/sh is dash, where it is not
#     even a keyword. The manifest loaded cleanly, mcode reported no warning, and
#     the hook would have failed on every single session.
#
#     So the command is taken out of the manifest, $CLAUDE_PLUGIN_ROOT is pointed at
#     this checkout, and it is run. A shell mismatch cannot survive this.
case_manifest_command_actually_executes() {
  local cmd rc
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$MANIFEST" 2>/dev/null)"
  if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
    note "no SessionStart command in the manifest"
    return
  fi

  # A fixture with no matching pane: the hook must run, refuse, and exit 0.
  write_fixture "$(jq -nc --arg sa "$WORK/alpha.sock" \
    '{sessions:[{name:"alpha",socket:$sa,running:true,panes:[{pane_id:"w1:p1",shell_pid:999999,fg_pgid:0,fg_pids:[]}]}]}')"
  reset_log

  # Emulate what mcode does to the command string, rather than guessing at it.
  #
  # mcode text-substitutes the BRACED literal ${PLUGIN_ROOT} with the content-addressed
  # cache directory, and hands the hook an environment carrying PLUGIN_ROOT. This test
  # used to do neither: it exported CLAUDE_PLUGIN_ROOT by hand and ran the string as
  # written. That is why it stayed green through an entire release in which the hook
  # never fired once — it supplied, from the test harness, the exact variable whose
  # absence was the bug. Running the command for real is worth nothing if the harness
  # repairs the command before it runs.
  local resolved
  resolved="$(printf '%s' "$cmd" | sed -e "s#\${PLUGIN_ROOT}#$repo/mcode-plugin#g" \
                                      -e "s#\${CLAUDE_PLUGIN_ROOT}#$repo/mcode-plugin#g")"

  rc=0
  (
    cd "$WORK" || exit 1
    # PLUGIN_ROOT only — that is what m3 measured in a live hook's environment.
    # CLAUDE_PLUGIN_ROOT is deliberately NOT exported: it is Claude's name, mcode
    # does not set it, and exporting it here is precisely what let this case pass
    # green against a manifest that never fires. With it absent, the unbraced form
    # reproduces the real exit 127 and this case fails, which is the point.
    PLUGIN_ROOT="$repo/mcode-plugin" \
      HERDR_BIN_PATH="$STUB" \
      /usr/bin/env bash -c "$resolved"
  ) >/dev/null 2>"$WORK/cmd-stderr" || rc=$?

  if [ "$rc" != "0" ]; then
    note "the manifest command exited $rc when run for real"
    note "stderr: $(head -3 "$WORK/cmd-stderr" 2>/dev/null | tr '\n' '|')"
    note "command: $cmd"
  fi
  # Proof it was the HOOK and not merely a shell that happened to succeed: the
  # hook's own signature on stderr, and its enumeration reaching the stub.
  if ! grep -q 'herdr-bootstrap: hook fired' "$WORK/cmd-stderr" 2>/dev/null; then
    note "the command did not run the hook (no banner on stderr)"
  fi
  if ! grep -q 'session list' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the hook never reached herdr, so the command did not really run it"
  fi
}

# 13. THE EARLY EXIT IS LOAD-BEARING, and this is the case that fails without it.
#
#     The hook has a 3 s internal budget because mcode kills an overrun by process
#     group. So the number of herdr calls it is allowed to make is not a style
#     question — it is the difference between registering and refusing, on exactly
#     the busy machines where registration matters most.
#
#     The fixture is three sessions of 50 panes each, with the matching pane FIRST
#     in the first session. A correct hook proves its pane almost immediately and
#     stops, because a match at chain rank 0 or 1 is definitive: nothing further
#     along the chain can be nearer. Without the early exit this spends ~300 calls
#     to reach a conclusion it already had.
case_scan_stops_at_a_definitive_match() {
  local pid calls_made
  spawn_pane alpha
  pid="$(pane_pid alpha)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi

  # 3 sessions x 50 panes; the match is pane 0 of session 1.
  write_fixture "$(jq -nc --argjson pid "$pid" '
    def filler($n): [range(0; $n) | {pane_id:("wF:p" + tostring), shell_pid:900000, fg_pgid:0, fg_pids:[]}];
    {sessions:[
       {name:"s1",socket:"/tmp/hpmc-scale/s1.sock",running:true,
        panes:([{pane_id:"w1:real",shell_pid:$pid,fg_pgid:0,fg_pids:[]}] + filler(50))},
       {name:"s2",socket:"/tmp/hpmc-scale/s2.sock",running:true,panes:filler(50)},
       {name:"s3",socket:"/tmp/hpmc-scale/s3.sock",running:true,panes:filler(50)}
     ]}')"
  reset_log
  release_pane alpha

  if ! grep -q 'report-agent w1:real' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the matching pane was not reported; log: $(calls_digest)"
  fi
  calls_made="$(wc -l <"$FAKE_HOOK_LOG" | tr -d ' ')"
  # One session list + one pane list + process-info for the panes scanned up to and
  # including the match. The match is pane 0, so ~3 calls. A generous ceiling still
  # fails loudly for a full scan: 150 panes would need ~300.
  if [ "$calls_made" -gt 20 ]; then
    note "spent $calls_made herdr calls with the match at pane 0 of session 1"
    note "a definitive match must end the scan; without that this is O(all panes x all sessions)"
  fi
}

# 14. A budget that expires mid-scan is announced, never silent.
#
#     The failure this replaces is the worst shape of quiet: the hook gives up, the
#     pane never registers, and the only trace is one line in mcode's hook
#     diagnostics. A truncated search must say it was truncated.
case_budget_expiry_is_announced() {
  # One pane shell, launched directly so its stderr — and therefore the hook's
  # stderr — lands in $WORK/stderr where it can be asserted on.
  reset_log
  /bin/rm -f "$WORK/budget.pid" "$WORK/budget.go" 2>/dev/null
  MCODE_HOOK_BUDGET_SECONDS=0 \
    "$WORK/pane-shell.sh" budget "$WORK" hook >"$WORK/stderr" 2>&1 &
  PANE_SHELL_PID=$!
  local i=0
  while [ ! -s "$WORK/budget.pid" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  : >"$WORK/budget.go"
  wait "$PANE_SHELL_PID" 2>/dev/null
  PANE_SHELL_PID=""

  if ! grep -q 'budget expired' "$WORK/stderr" 2>/dev/null; then
    note "the budget expired but nothing announced it; a truncated scan must say so"
    note "stderr: $(head -5 "$WORK/stderr" 2>/dev/null | tr '\n' '|')"
  fi
  if grep -q 'report-agent' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "reported a pane with no budget to examine one; that is guessing, not proving"
  fi
}

# 15. A budget that expires mid-scan still REGISTERS the pane it already found.
#
#     This is the other half of the case above, and the half that was easy to get
#     backwards. Running out of time costs SPEED, not the registration: the pane
#     proved before the budget bit is still the best evidence the hook has, and
#     throwing it away converts "slower" into "invisible" — on exactly the busy
#     machines where a pane most needs to be seen. The warning still fires, so the
#     answer is never passed off as a complete search.
#
#     The match is at chain rank 2, not 0 or 1, so it is NOT definitive and the
#     scan does keep going — which is what makes the truncation real rather than
#     staged. Rank 2 is reached by nesting: hook -> inner pane shell -> outer pane
#     shell, so the outer shell's pid is two steps up the chain. The fixture is
#     large enough that the scan cannot finish inside the one-second budget.
case_budget_trip_still_registers_what_it_found() {
  reset_log
  /bin/rm -f "$WORK/slow.pid" "$WORK/slow.go" "$WORK/slow2.pid" "$WORK/slow2.go" 2>/dev/null

  # The cost of the scan is made DELIBERATE rather than incidental. An earlier
  # revision of this case threw 1500 panes at a one-second budget and hoped the
  # machine would be slow enough; on a loaded runner the INDEX phase alone crossed
  # the second boundary and the scan was cut short before a single pane was
  # examined, which is a different failure than the one this case is about. The
  # budget here is 1s, the probe delay below is a floor the machine cannot beat,
  # and the fixture is small enough that indexing is instant — so the first batch
  # always completes, always finds the pane, and the trip always happens later.
  #
  # Everything is exported BEFORE spawn_pane: the stand-in shell is the hook's
  # parent, so it inherits the environment it was started with, not the one it is
  # released with. Setting these afterwards is a silent no-op.
  export MCODE_HOOK_BUDGET_SECONDS=2
  export FAKE_HOOK_PROBE_DELAY=0.3
  "$WORK/pane-shell.sh" slow "$WORK" inner slow2 >"$WORK/stderr2" 2>&1 &
  PANE_SHELL_PID=$!
  local i=0
  # The outer shell only SPAWNS the inner one after its own .go file appears, so
  # the release comes first and the inner pid second. Waiting for the inner pid
  # before releasing the outer deadlocks until the poll gives up.
  while [ ! -s "$WORK/slow.pid" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  : >"$WORK/slow.go"
  i=0
  while [ ! -s "$WORK/slow2.pid" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  local outer inner
  outer="$(cat "$WORK/slow.pid" 2>/dev/null || echo 0)"
  inner="$(cat "$WORK/slow2.pid" 2>/dev/null || echo 0)"
  if [ "$outer" = "0" ] || [ "$inner" = "0" ]; then
    note "could not start the nested stand-in pane shells"
    return
  fi

  # 3 sessions x 20 panes, and the matching pane is FIRST: found at rank 2 in the
  # very first batch, then 60 more probes at 0.3s each — about 3s of work against a
  # 2s budget. The overrun has to be DECISIVE, not marginal: `budget_left` compares
  # whole seconds, so a scan that finishes 0.1s past its budget trips on a fast
  # machine and not on a slow one, and the case then passes or fails depending on
  # which side of a second boundary it started. Three seconds of sleeps against a
  # two-second budget trips whatever the machine does, while indexing 60 panes and
  # the first batch stay far inside it.
  write_fixture "$(jq -nc --argjson pid "$outer" '
    def filler($n; $pre): [range(0; $n) | {pane_id:($pre + ":p" + tostring), shell_pid:900000, fg_pgid:0, fg_pids:[]}];
    {sessions:[
       {name:"s1",socket:"/tmp/hpmc-slow/s1.sock",running:true,
        panes:([{pane_id:"w1:outer",shell_pid:$pid,fg_pgid:0,fg_pids:[]}] + filler(20;"w1f"))},
       {name:"s2",socket:"/tmp/hpmc-slow/s2.sock",running:true,panes:filler(20;"w2")},
       {name:"s3",socket:"/tmp/hpmc-slow/s3.sock",running:true,panes:filler(20;"w3")}
     ]}')"

  : >"$WORK/slow2.go"
  wait "$PANE_SHELL_PID" 2>/dev/null
  PANE_SHELL_PID=""
  unset MCODE_HOOK_BUDGET_SECONDS FAKE_HOOK_PROBE_DELAY

  if ! grep -q 'budget expired' "$WORK/stderr2" 2>/dev/null; then
    note "expected the scan to be cut short by the 1s budget, but it finished;"
    note "this case cannot prove what it exists to prove unless it truncates"
    note "stderr: $(head -6 "$WORK/stderr2" 2>/dev/null | tr '\n' '|')"
  fi
  if ! grep -q 'report-agent w1:outer' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the budget expired and the pane it had ALREADY proved was discarded;"
    note "a trip must cost speed, never the registration"
  fi
  if grep -q 'report-agent' "$FAKE_HOOK_LOG" 2>/dev/null &&
    [ "$(grep -c 'report-agent' "$FAKE_HOOK_LOG" 2>/dev/null)" != "1" ]; then
    note "registered more than once; one registration per session, always"
  fi
}

# 15. The prefilter finds a pane in the LAST of three sessions, cheaply.
#
#     300 panes exist and exactly ONE is worth a `process-info` call: the only one
#     whose cwd is the hook's. That is the whole point of the prefilter, so this
#     case asserts the COST as well as the answer — the pane is reported, and the
#     call count proves the other 299 were never probed. A hook that ignored the
#     prefilter would report the same pane and pass a correctness-only assertion
#     while giving back the entire saving.
case_match_in_the_last_of_three_sessions() {
  local pid calls_made
  export M4_PAYLOAD_CWD="/m4/project"
  spawn_pane late
  pid="$(pane_pid late)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi

  # 3 sessions x 100 panes, all in some OTHER directory, and the matching pane —
  # last of the last session, in the hook's directory — is the only candidate.
  write_fixture "$(jq -nc --argjson pid "$pid" '
    def filler($n; $pre): [range(0; $n) | {pane_id:($pre + ":p" + tostring), shell_pid:900000,
                                           fg_pgid:0, fg_pids:[], cwd:"/elsewhere"}];
    {sessions:[
       {name:"s1",socket:"/tmp/hpmc-last/s1.sock",running:true,panes:filler(100;"w1")},
       {name:"s2",socket:"/tmp/hpmc-last/s2.sock",running:true,panes:filler(100;"w2")},
       {name:"s3",socket:"/tmp/hpmc-last/s3.sock",running:true,
        panes:(filler(99;"w3") + [{pane_id:"w3:real",shell_pid:$pid,fg_pgid:0,
                                   fg_pids:[], cwd:"/m4/project"}])}
     ]}')"
  reset_log
  release_pane late
  unset M4_PAYLOAD_CWD

  if ! grep -q 'report-agent w3:real' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the matching pane in the LAST session was not reported; log: $(calls_digest)"
  fi
  calls_made="$(wc -l <"$FAKE_HOOK_LOG" | tr -d ' ')"
  # 1 session list + 3 pane list + 1 process-info = 5. The prefilter's entire claim
  # is that the other 299 panes cost nothing, so the ceiling is tight on purpose.
  if [ "$calls_made" -gt 12 ]; then
    note "$calls_made herdr calls for 300 panes; the cwd prefilter did no work,"
    note "so the prefilter is not actually narrowing the search"
  fi
  if ! grep -q 'prefilter cwd (from the SessionStart payload)' "$WORK/late.stderr" 2>/dev/null; then
    note "the hook did not report reading cwd from the payload; stderr: $(stderr_of late | head -3 | tr '\n' '|')"
  fi
}

# 16. A cwd match is a CANDIDATE, never the proof.
#
#     This is the case that keeps the prefilter honest. Two panes share the hook's
#     directory — the collision this repo documents — and the decoy is listed FIRST,
#     so any implementation that treats cwd as identity registers the wrong pane.
#     The decoy's shell_pid is a pid that appears in no ancestry, so the ancestry
#     match rejects it and the real pane wins even though it was found second.
case_cwd_match_is_never_the_proof() {
  local pid
  export M4_PAYLOAD_CWD="/m4/project"
  spawn_pane decoy
  pid="$(pane_pid decoy)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi

  write_fixture "$(jq -nc --argjson pid "$pid" '
    {sessions:[
       {name:"s1",socket:"/tmp/hpmc-decoy/s1.sock",running:true,
        panes:[{pane_id:"w1:decoy",shell_pid:999999,fg_pgid:0,fg_pids:[],cwd:"/m4/project"},
               {pane_id:"w1:real",shell_pid:$pid,fg_pgid:0,fg_pids:[],cwd:"/m4/project"}]}
     ]}')"
  reset_log
  release_pane decoy
  unset M4_PAYLOAD_CWD

  if ! grep -q 'report-agent w1:real' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the proven pane was not reported; a cwd match must not settle the question"
    note "log: $(calls_digest)"
  fi
  if grep -q 'report-agent w1:decoy' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "registered the DECOY: cwd was treated as identity rather than as a filter"
  fi
}

# 17. When cwd matches nothing, the full scan runs — and says so.
#
#     A pane's directory can differ from the project directory, and a `cd` between
#     launch and SessionStart moves it, so the prefilter missing is an ordinary
#     outcome and not an error. The thorough path still has to run, because the
#     ancestry match remains the only thing that may register a pane. What must not
#     happen quietly is the extra cost: a user whose pane is slow to appear should
#     be able to tell this apart from "nothing matched", so the fallback announces
#     itself, and this asserts on the announcement as well as the outcome.
#
#     The concurrency assertion belongs here rather than in the prefilter case
#     because this is the pass that actually has hundreds of panes to get through.
case_cwd_matching_nothing_falls_back_loudly() {
  local pid calls_made conc_max
  # A generous budget, for the same reason the prefilter case has one: this case
  # is about WHICH pass runs and whether it says so, not about how many seconds a
  # throttled CI runner takes to get through 300 stubs. The real-budget behaviour
  # is pinned by `budget-trip-still-registers-what-it-found`, which forces the
  # overrun deliberately and asserts what happens next.
  export MCODE_HOOK_BUDGET_SECONDS=30
  export M4_PAYLOAD_CWD="/m4/project"
  export FAKE_HOOK_CONC="$WORK/conc"
  : >"$FAKE_HOOK_CONC.cur" 2>/dev/null
  : >"$FAKE_HOOK_CONC.max" 2>/dev/null

  spawn_pane nomatch
  pid="$(pane_pid nomatch)"
  if [ "$pid" = "0" ]; then note "could not start the stand-in pane shell"; return; fi

  # Nothing anywhere is in /m4/project, including the pane that owns this process.
  write_fixture "$(jq -nc --argjson pid "$pid" '
    def filler($n; $pre): [range(0; $n) | {pane_id:($pre + ":p" + tostring), shell_pid:900000,
                                           fg_pgid:0, fg_pids:[], cwd:"/elsewhere"}];
    {sessions:[
       {name:"s1",socket:"/tmp/hpmc-fb/s1.sock",running:true,panes:filler(100;"w1")},
       {name:"s2",socket:"/tmp/hpmc-fb/s2.sock",running:true,panes:filler(100;"w2")},
       {name:"s3",socket:"/tmp/hpmc-fb/s3.sock",running:true,
        panes:(filler(99;"w3") + [{pane_id:"w3:real",shell_pid:$pid,fg_pgid:0,
                                   fg_pids:[], cwd:"/elsewhere"}])}
     ]}')"
  reset_log
  release_pane nomatch
  unset M4_PAYLOAD_CWD FAKE_HOOK_CONC MCODE_HOOK_BUDGET_SECONDS

  if ! grep -q 'running the full scan' "$WORK/nomatch.stderr" 2>/dev/null; then
    note "the prefilter missed and the hook did not say it was falling back;"
    note "a silent extra full scan is the same quiet failure as a silent skip"
    note "stderr: $(head -6 "$WORK/nomatch.stderr" 2>/dev/null | tr '\n' '|')"
  fi
  if ! grep -q 'report-agent w3:real' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the fallback scan did not find the pane either; log: $(calls_digest)"
  fi
  calls_made="$(wc -l <"$FAKE_HOOK_LOG" | tr -d ' ')"
  if [ "$calls_made" -lt 290 ]; then
    note "only $calls_made calls for 300 panes; the fallback did not scan every pane,"
    note "so the answer still depends on where the pane happened to sit"
  fi
  conc_max="$(cat "$WORK/conc.max" 2>/dev/null || echo 0)"
  case "$conc_max" in '' | *[!0-9]*) conc_max=0 ;; esac
  if [ "$conc_max" -lt 2 ]; then
    note "peak concurrent herdr calls was $conc_max; the fallback ran sequentially,"
    note "and 300 panes will not fit the budget on a slow machine"
  fi
}

# 19. install-hook ENABLES the plugin, and checks that it took.
#
#     Copying the files is not installing the plugin. mcode keeps enabled state
#     separately from presence, and a present-but-disabled plugin never fires a
#     hook — the manifest loads, `mcode plugin list` shows it, and every session
#     starts as if it were not there. That is exactly the failure this PR was
#     chasing for a day, and it is reachable from the installer, so the installer
#     is where the test belongs.
#
#     This case runs the real installer with a fake `mcode` first on PATH and a
#     throwaway data dir, then asserts on what the installer actually asked mcode
#     to do. A textual check for the string "plugin enable" would pass on a
#     comment; this one cannot.
case_install_hook_enables_the_plugin() {
  local fake="$WORK/fakebin" data="$WORK/fakedata" out="$WORK/install.out"
  mkdir -p "$fake" "$data" 2>/dev/null || { note "cannot create the fake bin dir"; return; }

  # A fake mcode that records its argv, and reports the plugin enabled or not
  # according to M4_FAKE_ENABLED — so the installer's VERIFICATION step is under
  # test too, not just the call.
  cat >"$fake/mcode" <<'FAKEEOF'
#!/bin/sh
printf '%s\n' "$*" >>"$M4_FAKE_LOG"
case "${1:-} ${2:-}" in
  "plugin enable") exit 0 ;;
  "plugin list")
    if [ "${M4_FAKE_JSON:-}" = "1" ]; then
      if [ "${M4_FAKE_ENABLED:-true}" = "true" ]; then
        printf '{"installed":[{"pluginId":"herdr-bootstrap@local","enabled":true}]}\n'
      else
        printf '{"installed":[{"pluginId":"herdr-bootstrap@local","enabled":false}]}\n'
      fi
    fi
    printf '[-] herdr-bootstrap@local\tdisabled\n'
    exit 0
    ;;
esac
exit 0
FAKEEOF
  chmod +x "$fake/mcode"

  export M4_FAKE_LOG="$WORK/mcode-calls.log"
  export M4_FAKE_JSON=1
  : >"$M4_FAKE_LOG"

  PATH="$fake:$PATH" MINIMAX_DATA_DIR="$data" \
    "$repo/bin/mcode-plugin.sh" install-hook >"$out" 2>&1
  local rc=$?

  if ! grep -q '^plugin enable herdr-bootstrap@local$' "$M4_FAKE_LOG" 2>/dev/null; then
    note "install-hook never ran 'mcode plugin enable herdr-bootstrap@local'"
    note "a plugin left disabled never fires a hook; mcode calls were: $(tr '\n' '|' <"$M4_FAKE_LOG" 2>/dev/null)"
  fi
  if ! grep -q 'plugin list' "$M4_FAKE_LOG" 2>/dev/null; then
    note "install-hook enabled the plugin without ever checking whether it took"
  fi
  if ! grep -q 'mcode plugin list reports' "$out" 2>/dev/null; then
    note "install-hook did not print the plugin list line; a hint to go and check"
    note "is how a disabled plugin got reported as an upstream mcode bug"
  fi
  if [ "$rc" -ne 0 ]; then
    note "install-hook exited $rc on a plugin it successfully enabled"
  fi

  # The other half, and the one that matters: if mcode reports the plugin still
  # disabled, the install FAILS. A warn-and-return-success here would move the
  # failure from install time to session time, where a user cannot tell a
  # half-install from a broken mcode.
  export M4_FAKE_ENABLED=false
  : >"$M4_FAKE_LOG"
  local out2="$WORK/install2.out" rc2=0
  PATH="$fake:$PATH" MINIMAX_DATA_DIR="$data" \
    "$repo/bin/mcode-plugin.sh" install-hook >"$out2" 2>&1 || rc2=$?
  if [ "$rc2" -eq 0 ]; then
    note "mcode reported the plugin disabled and install-hook still exited 0;"
    note "copying files into a directory is not an install"
  fi
  if ! grep -q 'NOT enabled' "$out2" 2>/dev/null; then
    note "mcode reported the plugin disabled and install-hook did not say so"
    note "output: $(head -4 "$out2" | tr '\n' '|')"
  fi
  if ! grep -q 'mcode plugin enable herdr-bootstrap@local' "$out2" 2>/dev/null; then
    note "install-hook did not name the command that would fix it"
  fi
  # Every variable this case exported is cleared, not just the one it happened to
  # be using last. The cases share one process, so a var left set here is a var
  # the NEXT case inherits - and it fails then, for a reason nobody can see from
  # the case that broke. m3 caught M4_FAKE_JSON surviving exactly this way.
  unset M4_FAKE_LOG M4_FAKE_JSON M4_FAKE_ENABLED
}

# 20. uninstall-hook takes the plugin back OFF this machine.
#
#     The install path is machine-global — every mcode on the box shares
#     ~/.minimax/plugins — so an install that another agent later removes leaves
#     one of you with a plugin half-present and no idea whose state it is. m3 hit
#     that collision with a probe of their own, so removal is a first-class
#     operation here rather than a `mcode plugin remove` a user has to know about.
#
#     It also runs the same exact-path guard as the installer, because a removal
#     is the operation where a wrong path is most destructive.
case_uninstall_hook_removes_the_plugin() {
  local fake="$WORK/fakebin2" data="$WORK/fakedata2" out="$WORK/uninstall.out"
  mkdir -p "$fake" "$data" 2>/dev/null || { note "cannot create the fake bin dir"; return; }

  # A fake mcode that does NOT remove the directory, so the case exercises the
  # installer's own cleanup path — the one that has to be safe.
  cat >"$fake/mcode" <<'FAKEEOF'
#!/bin/sh
printf '%s\n' "$*" >>"$M4_FAKE_LOG"
case "${1:-} ${2:-}" in
  "plugin list") printf '[-] herdr-bootstrap@local\tdisabled\n'; exit 0 ;;
esac
exit 0
FAKEEOF
  chmod +x "$fake/mcode"

  export M4_FAKE_LOG="$WORK/mcode-calls2.log"
  : >"$M4_FAKE_LOG"
  mkdir -p "$data/plugins/herdr-bootstrap/.claude-plugin" \
           "$data/plugins/herdr-bootstrap/hooks" 2>/dev/null
  printf '{}' >"$data/plugins/herdr-bootstrap/.claude-plugin/plugin.json" 2>/dev/null
  printf 'x' >"$data/plugins/herdr-bootstrap/hooks/herdr-bootstrap.sh" 2>/dev/null
  printf 'neighbour' >"$data/plugins/some-other-plugin" 2>/dev/null

  PATH="$fake:$PATH" MINIMAX_DATA_DIR="$data" \
    "$repo/bin/mcode-plugin.sh" uninstall-hook >"$out" 2>&1
  local rc=$?

  if [ "$rc" -ne 0 ]; then
    note "uninstall-hook exited $rc; output: $(head -3 "$out" | tr '\n' '|')"
  fi
  if ! grep -q '^plugin remove herdr-bootstrap@local$' "$M4_FAKE_LOG" 2>/dev/null; then
    note "uninstall-hook did not ask mcode to remove the plugin"
  fi
  if [ -e "$data/plugins/herdr-bootstrap" ]; then
    note "uninstall-hook left the plugin directory behind; it would keep loading"
  fi
  if [ ! -e "$data/plugins/some-other-plugin" ]; then
    note "uninstall-hook removed a NEIGHBOURING plugin; it must touch only its own"
  fi
  unset M4_FAKE_LOG

  # The guard has to be one that CAN fail. uninstall-hook used to check the path
  # string, which is built from the expected string two lines earlier, so the check
  # could never fire and everyone - including me - read it as the thing preventing
  # a wrong removal. What can be wrong is the CONTENT. A directory at our path that
  # is non-empty and holds no manifest is not ours, and removing it is the accident
  # that would matter. So: seed exactly that, and require a refusal.
  local foreign="$WORK/foreigndata"
  mkdir -p "$foreign/plugins/herdr-bootstrap" 2>/dev/null
  printf 'someone elses files\n' >"$foreign/plugins/herdr-bootstrap/important.txt" 2>/dev/null
  local out3="$WORK/uninstall3.out" rc3=0
  PATH="$fake:$PATH" MINIMAX_DATA_DIR="$foreign" \
    "$repo/bin/mcode-plugin.sh" uninstall-hook >"$out3" 2>&1 || rc3=$?
  if [ "$rc3" -eq 0 ]; then
    note "uninstall-hook removed a non-empty directory that is not this plugin's"
    note "and exited 0; the content guard is not doing anything"
  fi
  if [ ! -e "$foreign/plugins/herdr-bootstrap/important.txt" ]; then
    note "uninstall-hook deleted a directory it did not own; the guard must refuse"
  fi
}

# The suite must not write into the DEVELOPER's real durable log.
#
# The hook writes to "${MINIMAX_DATA_DIR:-$HOME/.minimax}/state/herdr-bootstrap". Any case
# that runs the hook without its own MINIMAX_DATA_DIR therefore writes into the machine
# owner's real ~/.minimax. That was measured rather than assumed: on this repo's own
# machine, 48 of the 54 fires in the real hook.log belonged to THIS SUITE — fake panes
# w1:p1, w1:real, w3:real — along with all 21 refusals in the file.
#
# It matters because that file is the only record of what a real session's hook did;
# issue #126 is decided by reading it. A suite that fills it with fixtures destroys the
# evidence it exists to produce.
#
# This asserts the AMBIENT environment rather than passing its own, on purpose. The two
# durable-log cases above already prove the hook writes where it is told; what can rot is
# a call site added later that forgets. Ambient isolation is inherited, per-call-site
# isolation has to be remembered, and what has to be remembered is what gets forgotten.
case_suite_env_isolates_the_durable_log() {
  local logf
  if [ -z "${MINIMAX_DATA_DIR:-}" ]; then
    note "MINIMAX_DATA_DIR is unset; every hook run here writes to the real \$HOME/.minimax"
    return
  fi
  logf="$MINIMAX_DATA_DIR/state/herdr-bootstrap/hook.log"
  /bin/rm -f "$logf" 2>/dev/null

  # A fixture with no panes at all, so the hook refuses and registers nothing. The
  # assertion is only that it got as far as writing its log.
  write_fixture '{"sessions":[{"name":"ambient","socket":"'"$WORK"'/ambient.sock","running":true,"panes":[]}]}'
  reset_log
  (
    cd "$WORK" || exit 1
    printf '%s' "{\"session_id\":\"ambient\",\"cwd\":\"$WORK\"}" |
      HERDR_BIN_PATH="$STUB" /bin/bash "$HOOK" SessionStart
  ) >/dev/null 2>&1 || true
  reset_log

  if [ ! -f "$logf" ]; then
    note "a hook run with the suite's own environment wrote no log to $logf"
    note "the hook resolved its log path somewhere else — most likely the real \$HOME"
  fi
}

CASES=(
  manifest-declares-only-session-start:case_manifest_declares_only_session_start
  handler-is-our-command-script:case_handler_is_our_command_script
  hook-writes-a-durable-log-when-it-registers-nothing:case_hook_writes_a_durable_log_even_when_it_registers_nothing
  suite-env-isolates-the-durable-log:case_suite_env_isolates_the_durable_log
  manifest-command-uses-braced-plugin-root:case_manifest_command_uses_the_braced_plugin_root
  manifest-command-actually-executes:case_manifest_command_actually_executes
  pane-is-found-by-ancestry-not-cwd:case_pane_is_found_by_ancestry_not_cwd
  nearest-ancestor-wins:case_nearest_ancestor_wins
  calls-target-the-proved-socket-and-never-a-name:case_calls_target_the_proved_socket_and_never_a_name
  unproven-pane-refuses-and-reports-nothing:case_unproven_pane_refuses_and_reports_nothing
  never-releases-a-registration:case_never_releases_a_registration
  reports-once-with-the-shared-source:case_reports_once_with_the_shared_source
  survives-a-missing-herdr-and-bad-json:case_survives_a_missing_herdr_and_bad_json
  foreground-process-is-an-anchor:case_foreground_process_is_an_anchor
  scan-stops-at-a-definitive-match:case_scan_stops_at_a_definitive_match
  match-in-the-last-of-three-sessions:case_match_in_the_last_of_three_sessions
  cwd-match-is-never-the-proof:case_cwd_match_is_never_the_proof
  cwd-matching-nothing-falls-back-loudly:case_cwd_matching_nothing_falls_back_loudly
  budget-expiry-is-announced:case_budget_expiry_is_announced
  budget-trip-still-registers-what-it-found:case_budget_trip_still_registers_what_it_found
  install-never-uses-a-bare-rm:case_install_never_uses_a_bare_rm
  install-hook-enables-the-plugin:case_install_hook_enables_the_plugin
  uninstall-hook-removes-the-plugin:case_uninstall_hook_removes_the_plugin
)

if [ "${1:-}" = "--list" ]; then
  for pair in "${CASES[@]}"; do printf '%s\n' "${pair%%:*}"; done
  exit 0
fi

[ -f "$HOOK" ] || { printf 'FATAL: no hook at %s\n' "$HOOK" >&2; exit 2; }
[ -f "$STUB" ] || { printf 'FATAL: no stub at %s\n' "$STUB" >&2; exit 2; }
[ -x "$STUB" ] || chmod +x "$STUB" 2>/dev/null

for pair in "${CASES[@]}"; do run_case "${pair%%:*}" "${pair#*:}"; done

printf -- '---\n'
if [ "$CASES_FAILED" -eq 0 ]; then
  printf '%d case(s), all passed\n' "$CASES_RUN"
  exit 0
fi
printf '%d case(s), %d failed\n' "$CASES_RUN" "$CASES_FAILED"
exit 1
