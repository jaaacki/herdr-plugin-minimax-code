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
  HERDR_BIN_PATH="$STUB" /usr/bin/env bash "$HOOK" SessionStart
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
  "$WORK/pane-shell.sh" "$tag" "$cwd" "$mode" "$inner" >/dev/null 2>&1 &
  PANE_SHELL_PID=$!
}

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

write_fixture() { printf '%s' "$1" >"$FAKE_HOOK_FIXTURE"; }
calls() { cat "$FAKE_HOOK_LOG" 2>/dev/null; }
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
  case "$cmd" in
    *CLAUDE_PLUGIN_ROOT*) : ;;
    *) note "command is not anchored on \$CLAUDE_PLUGIN_ROOT; measured cwd is the project dir" ;;
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
    note "log: $(calls | tr '\n' '|')"
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
    note "log: $(calls | tr '\n' '|')"
  fi
  if ! grep -q 'report-agent w2:p2' "$FAKE_HOOK_LOG" 2>/dev/null; then
    note "the inner (nearest) pane was not reported at all"
    note "log: $(calls | tr '\n' '|')"
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
    note "log: $(calls | tr '\n' '|')"
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
    note "log: $(calls | tr '\n' '|')"
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
    note "log: $(calls | tr '\n' '|')"
  fi
}

# 11. The install action is the only way the hook becomes active, and it never
#     types a bare `rm` (issue #109).
case_install_never_uses_a_bare_rm() {
  local install_fn
  install_fn="$(sed -n '/^cmd_install_hook()/,/^}/p' "$repo/bin/mcode-plugin.sh")"
  if [ -z "$install_fn" ]; then
    note "cmd_install_hook not found in bin/mcode-plugin.sh"
    return
  fi
  if printf '%s' "$install_fn" | grep -qE '(^|[^/[:alnum:]_])rm[[:space:]]'; then
    note "cmd_install_hook contains a bare rm; issue #109 requires /bin/rm"
  fi
  if ! printf '%s' "$install_fn" | grep -q '/bin/rm'; then
    note "cmd_install_hook does not use /bin/rm for the replacement"
  fi
}

# 12. The manifest's command ACTUALLY RUNS. Not "looks right" — executed.
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

  rc=0
  (
    cd "$WORK" || exit 1
    CLAUDE_PLUGIN_ROOT="$repo/mcode-plugin" \
      HERDR_BIN_PATH="$STUB" \
      /usr/bin/env bash -c "$cmd"
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
    note "the matching pane was not reported; log: $(calls | tr '\n' '|')"
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

CASES=(
  manifest-declares-only-session-start:case_manifest_declares_only_session_start
  handler-is-our-command-script:case_handler_is_our_command_script
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
  budget-expiry-is-announced:case_budget_expiry_is_announced
  install-never-uses-a-bare-rm:case_install_never_uses_a_bare_rm
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
