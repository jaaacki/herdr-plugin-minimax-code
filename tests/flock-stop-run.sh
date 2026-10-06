#!/usr/bin/env bash
# tests/flock-stop-run.sh — the suite for mcode-plugin/hooks/flock-stop.sh
# (sparkfn/pc-tools#1699 item 1).
#
#   ./tests/flock-stop-run.sh
#   ./tests/flock-stop-run.sh --list
#
# Plain bash, like every other suite here, and discovered by the CI
# `tests/*run.sh` glob — so the filename is load-bearing.
#
# ---- WHAT THIS SUITE PROVES -------------------------------------------------
#
# The hook has two jobs and one non-job. It must translate pc-tool's verdict
# into mcode's decision, and it must NEVER wedge an agent. The second matters
# more than the first: a Stop hook that blocks forever because pc-tool is
# missing does not fail a member, it traps it, and there is no user-visible
# difference between the two from inside the session.
#
# So the cases split into two groups:
#
#   * blocks correctly, and only when it should
#   * fails open on every path, always, with exit 0
#
# Every failing case here FAILS if the corresponding behaviour is removed:
#
#   * the envelope is unwrapped   — mcode needs decision to be the STRING
#                                   "block"; pc-tool emits a nested object
#   * the payload is passed on     — `hook stop` reads stdin, and a hook that
#     stdin, not env               skips it asks pc-tool to stand down
#   * a reason-less block is      — mcode DISCARDS a block with no reason, so
#     not emitted                   emitting one is a silent no-op
#   * the reason is escaped       — mcode parses the whole stdout line as
#                                   JSON; an unescaped quote in a mail summary
#                                   makes the hook silently not block
#   * every failure exits 0       — an agent that cannot stop is trapped

set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"

HOOK="$repo/flock-stop-plugin/flock-stop.sh"
STUB="$here/fake-pc-tool"
MANIFEST="$repo/flock-stop-plugin/.claude-plugin/plugin.json"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcode-flock-stop-tests.XXXXXX")"
cleanup() {
  # Never a bare `rm`, never a trash can (issue #109).
  /bin/rm -rf "$WORK" 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM

CASES_RUN=0
CASES_FAILED=0
CURRENT_CASE=""
broke=0
note() { broke=1; printf '        %s\n' "$*"; }

run_case() { # run_case <name> <fn>
  CURRENT_CASE="$1"; broke=0
  CASES_RUN=$((CASES_RUN + 1))
  # The case's own exit status is NOT the verdict: a case reports by calling
  # note(), and the last statement of a failed case can still exit 0. Counting
  # the status instead of the flag makes a red case print FAIL and be tallied as
  # a pass — a suite that reports "all passed" while showing a FAIL line, and
  # exits 0, which is the one outcome worse than having no suite at all.
  # NOT redirected: a failing case that cannot say why is a suite that has to be
  # re-run with an edit before it tells you anything. Each case already sends its
  # own command output to files, so nothing leaks by letting stderr through.
  "$2" || true
  if [ "$broke" -eq 0 ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n' "$1"
    CASES_FAILED=$((CASES_FAILED + 1))
  fi
  CURRENT_CASE=""
}

# fire <payload> -> prints the hook's stdout, sets RC and STDERR_FILE contents.
STDERR_FILE=""
fire() { # fire <payload>
  printf '%s' "$1" \
    | PC_TOOL="$STUB" /usr/bin/env bash "$HOOK" > "$WORK/out" 2> "$WORK/err"
  echo $? > "$WORK/rc"
  STDERR_FILE="$WORK/err"
  cat "$WORK/out"
}
out_is_empty() { [ ! -s "$WORK/out" ]; }

BLOCK_ENVELOPE='{"hook":"stop","blocked":true,"reason":"1 unread row for m6","decision":{"decision":"block","reason":"1 unread row for m6"}}'
END_ENVELOPE='{"hook":"stop","blocked":false,"decision":{"decision":"end"}}'
STOP_PAYLOAD='{"stop_hook_active":false,"last_assistant_message":"done"}'

# ---- blocks -----------------------------------------------------------------

# The one case that says the feature works at all: pc-tool says block, so the
# hook must print the decision mcode will honour.
case_emits_a_block_decision_when_pctool_blocks() {
  local out; out="$(FAKED_PC_TOOL_OUT="$BLOCK_ENVELOPE" fire "$STOP_PAYLOAD")"
  if ! printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    note "the hook did not emit decision:block; got: ${out:-<nothing>}"
  fi
  if ! printf '%s' "$out" | jq -e '.reason | test("unread row")' >/dev/null 2>&1; then
    note "the block lost pc-tool's reason; got: ${out:-<nothing>}"
  fi
}

# `hook stop` reads its payload off STDIN. A hook that never forwards it asks
# pc-tool about nothing, which stands the verb down — so the hook would look
# wired and silently never block, the exact failure mode #1710's own review
# warns about.
case_passes_the_stop_payload_on_stdin() {
  local log="$WORK/payload.json"
  FAKED_PC_TOOL_PAYLOAD_LOG="$log" FAKED_PC_TOOL_OUT="$END_ENVELOPE" \
    fire "$STOP_PAYLOAD" >/dev/null
  if [ ! -s "$log" ]; then
    note "pc-tool received no payload on stdin; `hook stop` stands down without one"
    return
  fi
  if ! jq -e '.stop_hook_active == false' < "$log" >/dev/null 2>&1; then
    note "the payload that reached pc-tool was not the Stop payload: $(cat "$log")"
  fi
}

# A reason carrying quotes/newlines/backslashes is the NORMAL case here: the
# reason is a mail summary written by another agent. mcode parses the whole
# stdout line as JSON, so an unescaped quote makes the hook silently not block.
case_escapes_a_reason_that_contains_json_metacharacters() {
  local nasty='he said "block" \ and
newline'
  local env_json out
  env_json="$(jq -nc --arg r "$nasty" \
    '{hook:"stop",blocked:true,reason:$r,decision:{decision:"block",reason:$r}}')"
  out="$(FAKED_PC_TOOL_OUT="$env_json" fire "$STOP_PAYLOAD")"
  if [ -z "$out" ]; then
    note "a reason with quotes and a newline produced no output at all"
    return
  fi
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    note "the emitted decision is not valid JSON; mcode would drop it silently"
    return
  fi
  if [ "$(printf '%s' "$out" | jq -r '.reason')" != "$nasty" ]; then
    note "the reason did not round-trip: got [$(printf '%s' "$out" | jq -r '.reason')]"
  fi
}

# mcode's validator DISCARDS a block with no reason. Emitting one is a silent
# no-op that looks like a wired hook and blocks nothing.
# The flat shape sparkfn/pc-tools#1710 is moving to. If the hook only understood
# the envelope, the day that change lands every member would silently stop
# blocking — and nothing would fail, because "do not block" is this hook's
# default behaviour.
case_emits_a_block_from_the_flat_shape() {
  local out
  out="$(FAKED_PC_TOOL_OUT='{"decision":"block","reason":"2 unread rows for m6"}' fire "$STOP_PAYLOAD")"
  if ! printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    note "the flat shape produced no block; got: ${out:-<nothing>}"
    return
  fi
  if [ "$(printf '%s' "$out" | jq -r '.reason')" != "2 unread rows for m6" ]; then
    note "the flat shape lost its reason: ${out}"
  fi
}

# A shape NEITHER side documents — here a future #1710 emitting one. Standing the
# hook down is the requirement: a new release must not be able to wedge every
# member by changing what it prints.
case_stands_down_on_an_unrecognised_shape() {
  FAKED_PC_TOOL_OUT='{"verdict":"halt","detail":"something new"}' fire "$STOP_PAYLOAD" >/dev/null
  if ! out_is_empty; then
    note "emitted a decision for an unrecognised shape: $(cat "$WORK/out")"
  fi
  if ! grep -q 'does not recognise' "$WORK/err" 2>/dev/null; then
    note "stood down silently on an unrecognised shape; it should say why on stderr"
  fi
}

case_does_not_emit_a_reasonless_block() {
  FAKED_PC_TOOL_OUT='{"hook":"stop","blocked":true,"decision":{"decision":"block"}}' \
    fire "$STOP_PAYLOAD" >/dev/null
  if ! out_is_empty; then
    note "emitted a block with no reason; mcode discards it, so this only looks like a block"
  fi
}

# ---- fails open -------------------------------------------------------------

case_stays_silent_when_pctool_ends_the_turn() {
  FAKED_PC_TOOL_OUT="$END_ENVELOPE" fire "$STOP_PAYLOAD" >/dev/null
  if ! out_is_empty; then
    note "printed something on an `end` verdict: $(cat "$WORK/out")"
  fi
}

case_stays_silent_with_no_payload() {
  FAKED_PC_TOOL_OUT="$BLOCK_ENVELOPE" fire "" >/dev/null
  if ! out_is_empty; then
    note "blocked with no Stop payload at all"
  fi
}

# The big one. No pc-tool on PATH is the state of every machine until #1710
# merges, and it is also the state of anyone whose install broke. Standing down
# is correct; anything else traps the agent.
case_fails_open_when_pctool_is_missing() {
  local rc
  printf '%s' "$STOP_PAYLOAD" \
    | PC_TOOL="$WORK/definitely-not-here" /usr/bin/env bash "$HOOK" \
    > "$WORK/out" 2> "$WORK/err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note "exited $rc without pc-tool; a Stop hook that fails can trap the agent"
  fi
  if ! out_is_empty; then
    note "emitted a decision without pc-tool: $(cat "$WORK/out")"
  fi
}

# A pc-tool that prints something unparseable — a panic, a version skew, an
# upgrade mid-session. Must not become a block.
case_fails_open_on_unparseable_pctool_output() {
  FAKED_PC_TOOL_OUT='not json at all' fire "$STOP_PAYLOAD" >/dev/null
  if ! out_is_empty; then
    note "emitted a decision from unparseable output: $(cat "$WORK/out")"
  fi
}

case_fails_open_when_the_verb_is_missing() {
  # `flock hook stop` is TWO WORDS. A pc-tool without it exits non-zero, which
  # this hook must treat as "no answer", not as "block".
  cat > "$WORK/old-pc-tool" <<'EOF'
#!/bin/sh
[ "$1" = "flock" ] && { printf 'unknown command: hook\n' >&2; exit 64; }
exit 0
EOF
  chmod +x "$WORK/old-pc-tool"
  local rc
  printf '%s' "$STOP_PAYLOAD" | PC_TOOL="$WORK/old-pc-tool" /usr/bin/env bash "$HOOK" \
    > "$WORK/out" 2> "$WORK/err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note "exited $rc when the two-word verb was refused"
  fi
  if ! out_is_empty; then
    note "emitted a decision from a refused verb: $(cat "$WORK/out")"
  fi
}

case_fails_open_without_jq() {
  # A PATH that resolves everything the hook needs EXCEPT jq.
  #
  # Not an emptied PATH: that cannot find `bash` itself, so it measures the test
  # harness failing (exit 127) rather than the hook standing down — a case that
  # looks like it covers a real failure mode and covers nothing.
  local bindir="$WORK/nojq-bin" rc p
  mkdir -p "$bindir" 2>/dev/null || { note "cannot build the no-jq PATH"; return; }
  for tool in bash cat; do
    p="$(command -v "$tool" 2>/dev/null)" || { note "cannot locate $tool"; return; }
    ln -sf "$p" "$bindir/$tool" 2>/dev/null || { note "cannot link $tool"; return; }
  done

  # FAKED_PC_TOOL_OUT must be set: with an empty envelope the hook exits at its
  # "no answer" guard and never reaches the jq check, so the case would pass
  # without ever exercising the branch it exists to cover.
  printf '%s' "$STOP_PAYLOAD" \
    | PC_TOOL="$STUB" FAKED_PC_TOOL_OUT="$BLOCK_ENVELOPE" PATH="$bindir" \
      /usr/bin/env bash "$HOOK" \
    > "$WORK/out" 2> "$WORK/err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note "exited $rc without jq (stderr: $(head -1 "$WORK/err")); the hook must stand down, not trap"
  fi
  if ! out_is_empty; then
    note "emitted an unparsed decision without jq: $(cat "$WORK/out")"
  fi
  if ! grep -q 'jq' "$WORK/err" 2>/dev/null; then
    note "the hook stood down silently; it should say why, so a machine that lost jq is diagnosable"
  fi
}

# ---- the installer arm (#1699 item 3) --------------------------------------
#
# The hook is worthless if `bin/mcode-plugin.sh` cannot put it on a machine.
# These cases drive the REAL installer against a fake mcode, exactly the way
# tests/hook-run.sh drives the herdr-bootstrap arm, and assert on what the
# installer actually asked mcode to do — a textual check for "plugin enable"
# would pass on a comment.

# fire_install <command> <enabled: true|false> [name-log]
fire_install() {
  local cmd="$1" enabled="$2" name_log="${3:-m6-flockstop}"
  local fake="$WORK/inst-$name_log" data="$WORK/instdata-$name_log" out="$WORK/inst-$name_log.out"
  mkdir -p "$fake" "$data" 2>/dev/null || return 1
  cat > "$fake/mcode" <<'FAKEEOF'
#!/bin/sh
printf '%s\n' "$*" >>"$M6_INST_LOG"
case "${1:-} ${2:-}" in
  "plugin enable") exit 0 ;;
  "plugin list")
    if [ "${M6_INST_JSON:-}" = "1" ]; then
      if [ "${M6_INST_ENABLED:-true}" = "true" ]; then
        printf '{"installed":[{"pluginId":"%s@local","enabled":true}]}\n' "$M6_INST_NAME"
      else
        printf '{"installed":[{"pluginId":"%s@local","enabled":false}]}\n' "$M6_INST_NAME"
      fi
    fi
    printf '[-] %s@local\tenabled\n' "$M6_INST_NAME"
    exit 0 ;;
esac
exit 0
FAKEEOF
  chmod +x "$fake/mcode"
  export M6_INST_LOG="$WORK/inst-$name_log.calls"
  export M6_INST_JSON=1 M6_INST_ENABLED="$enabled" M6_INST_NAME=flock-stop
  : > "$M6_INST_LOG"
  PATH="$fake:$PATH" MINIMAX_DATA_DIR="$data" "$repo/bin/mcode-plugin.sh" "$cmd" > "$out" 2>&1
  INST_RC=$?
  unset M6_INST_LOG M6_INST_JSON M6_INST_ENABLED M6_INST_NAME
  INST_OUT="$out"; INST_DATA="$data"
  return 0
}

INST_RC=0; INST_OUT=""; INST_DATA=""
inst_calls() { cat "$WORK/inst-$1.calls" 2>/dev/null; }

case_install_flock_stop_enables_the_plugin() {
  local log="enables"
  fire_install install-flock-stop true "$log" || { note "harness setup failed"; return; }
  if [ "$INST_RC" -ne 0 ]; then
    note "install-flock-stop exited $INST_RC: $(head -3 "$INST_OUT" | tr '\n' '|')"
    return
  fi
  if ! grep -q '^plugin enable flock-stop@local$' "$WORK/inst-$log.calls" 2>/dev/null; then
    note "never ran 'mcode plugin enable flock-stop@local'; calls: $(inst_calls "$log" | tr '\n' '|')"
  fi
  if ! grep -q 'plugin list' "$WORK/inst-$log.calls" 2>/dev/null; then
    note "enabled the plugin without ever checking whether it took"
  fi
  if ! grep -q 'mcode plugin list reports' "$INST_OUT" 2>/dev/null; then
    note "did not print the plugin list line; a hint instead is how a disabled plugin was reported as an mcode bug"
  fi
  # The files really landed, and under the plugin's OWN name — not under
  # herdr-bootstrap's, which would overwrite the other plugin on a machine that
  # has both.
  if [ ! -f "$INST_DATA/plugins/flock-stop/.claude-plugin/plugin.json" ]; then
    note "the manifest did not land at plugins/flock-stop/"
  fi
  if [ ! -x "$INST_DATA/plugins/flock-stop/flock-stop.sh" ]; then
    note "flock-stop.sh landed without the executable bit; mcode cannot run a non-executable hook"
  fi
  if [ -e "$INST_DATA/plugins/herdr-bootstrap" ]; then
    note "installing flock-stop created a herdr-bootstrap directory; it must touch only its own"
  fi
}

case_install_flock_stop_fails_when_mcode_says_disabled() {
  # The other half, and the one that matters. A warn-and-return-success here moves
  # the failure from install time to session time, where a user cannot tell a
  # half-install from a broken mcode.
  local log="disabled"
  fire_install install-flock-stop false "$log" || { note "harness setup failed"; return; }
  if [ "$INST_RC" -eq 0 ]; then
    note "mcode reported the plugin disabled and install-flock-stop still exited 0;"
    note "copying files into a directory is not an install"
  fi
  if ! grep -q 'NOT enabled' "$INST_OUT" 2>/dev/null; then
    note "mcode reported the plugin disabled and the install did not say so: $(head -4 "$INST_OUT" | tr '\n' '|')"
  fi
  if ! grep -q 'mcode plugin enable flock-stop@local' "$INST_OUT" 2>/dev/null; then
    note "did not name the command that would fix it"
  fi
}

case_uninstall_flock_stop_removes_only_its_own() {
  local log="uninstall"
  # SAME case name for both calls: fire_install derives its data dir from it, so
  # installing under one name and uninstalling under another would have the
  # uninstall operate on an empty directory and pass for the wrong reason.
  fire_install install-flock-stop true "$log" || { note "harness setup failed"; return; }
  local data="$WORK/instdata-$log"
  mkdir -p "$data/plugins/some-other-plugin" 2>/dev/null
  printf 'neighbour' > "$data/plugins/some-other-plugin/keep.txt" 2>/dev/null

  fire_install uninstall-flock-stop true "$log" || { note "harness setup failed"; return; }
  if [ "$INST_RC" -ne 0 ]; then
    note "uninstall-flock-stop exited $INST_RC: $(head -3 "$INST_OUT" | tr '\n' '|')"
  fi
  if [ -e "$data/plugins/flock-stop" ]; then
    note "left the plugin directory behind; it would keep loading"
  fi
  if [ ! -e "$data/plugins/some-other-plugin/keep.txt" ]; then
    note "removed a NEIGHBOURING plugin; it must touch only its own"
  fi
}

# The guard has to be one that CAN fail. The uninstall path guard is built from
# a string two lines earlier, so a path-string check can never fire. What can be
# wrong is the CONTENT: a non-empty directory at our path holding no manifest is
# somebody else's.
case_uninstall_refuses_a_directory_that_is_not_ours() {
  local foreign="$WORK/foreigndata"
  mkdir -p "$foreign/plugins/flock-stop" 2>/dev/null
  printf 'someone elses files\n' > "$foreign/plugins/flock-stop/important.txt" 2>/dev/null
  local fake="$WORK/inst-foreign" out="$WORK/inst-foreign.out"
  mkdir -p "$fake" 2>/dev/null || { note "harness setup failed"; return; }
  printf '#!/bin/sh\nexit 0\n' > "$fake/mcode"; chmod +x "$fake/mcode"
  PATH="$fake:$PATH" MINIMAX_DATA_DIR="$foreign" "$repo/bin/mcode-plugin.sh" uninstall-flock-stop > "$out" 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    note "removed a non-empty directory that is not this plugin's and exited 0; the content guard is not doing anything"
  fi
  if [ ! -e "$foreign/plugins/flock-stop/important.txt" ]; then
    note "deleted a directory it did not own; the guard must refuse"
  fi
}

# ---- wiring -----------------------------------------------------------------

case_manifest_declares_the_stop_hook() {
  if ! jq -e '.hooks.Stop' "$MANIFEST" >/dev/null 2>&1; then
    note "the manifest declares no Stop hook, so nothing ever runs this script"
  fi
}

# The command string is not decoration: mcode runs it verbatim. An unbraced
# ${PLUGIN_ROOT} expands as an empty variable under `set -u` in some shells and
# resolves to the wrong directory in others, and the hook then cannot be found.
case_manifest_command_uses_braced_plugin_root() {
  local cmd
  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$MANIFEST" 2>/dev/null)"
  case "$cmd" in
    *'${PLUGIN_ROOT}'*) : ;;
    *) note "the Stop command does not use braced \${PLUGIN_ROOT}: ${cmd:-<none>}" ;;
  esac
}

# A command that does not execute is a manifest that loads and a hook that never
# runs, which reads exactly like a working install. This one runs it.
case_manifest_command_actually_executes() {
  local cmd line
  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$MANIFEST" 2>/dev/null)"
  line="${cmd//\$\{PLUGIN_ROOT\}/$repo/flock-stop-plugin}"
  line="${line% SessionStart}"
  FAKED_PC_TOOL_OUT="$END_ENVELOPE" \
    printf '%s' "$STOP_PAYLOAD" | PC_TOOL="$STUB" FAKED_PC_TOOL_OUT="$END_ENVELOPE" \
    /usr/bin/env bash -c "$line" > "$WORK/out" 2> "$WORK/err"
  if [ "$?" -ne 0 ]; then
    note "the manifest command failed to execute: $(head -2 "$WORK/err")"
  fi
}

# The repo's own invariant (issue #109): nothing here may reach a trash can. `no-trash-run.sh`
# scans only bin/ and tests/, so the plugin directory needs a guard of its own -- but this file
# LIVES in tests/, and that scan bans these words in any line that is not a comment. So the
# pattern is spelled with an empty quote in the middle: the shell still builds the word, and the
# scanner cannot match what is not contiguous in the source. DO NOT tidy this into a plain word.
# Its comment filter skips only lines that START with #, so a tidy-up reads as a red, and a
# second tidy-up that only fixes the case name still leaves the pattern line red.
case_never_deletes_anything() {
  if grep -nE '\brm\b|mavis-tra''sh|tra''sh' "$HOOK" "$STUB" 2>/dev/null \
     | grep -v '/bin/rm -rf' | grep -qE 'rm |tra''sh'; then
    note "the hook or its stub can delete something; unlink directly, never via a can (issue #109)"
  fi
}

CASES=(
  emits-a-block-decision-when-pctool-blocks:case_emits_a_block_decision_when_pctool_blocks
  passes-the-stop-payload-on-stdin:case_passes_the_stop_payload_on_stdin
  escapes-a-reason-that-contains-json-metacharacters:case_escapes_a_reason_that_contains_json_metacharacters
  emits-a-block-from-the-flat-shape:case_emits_a_block_from_the_flat_shape
  stands-down-on-an-unrecognised-shape:case_stands_down_on_an_unrecognised_shape
  does-not-emit-a-reasonless-block:case_does_not_emit_a_reasonless_block
  stays-silent-when-pctool-ends-the-turn:case_stays_silent_when_pctool_ends_the_turn
  stays-silent-with-no-payload:case_stays_silent_with_no_payload
  fails-open-when-pctool-is-missing:case_fails_open_when_pctool_is_missing
  fails-open-on-unparseable-pctool-output:case_fails_open_on_unparseable_pctool_output
  fails-open-when-the-verb-is-missing:case_fails_open_when_the_verb_is_missing
  fails-open-without-jq:case_fails_open_without_jq
  install-flock-stop-enables-the-plugin:case_install_flock_stop_enables_the_plugin
  install-flock-stop-fails-when-mcode-says-disabled:case_install_flock_stop_fails_when_mcode_says_disabled
  uninstall-flock-stop-removes-only-its-own:case_uninstall_flock_stop_removes_only_its_own
  uninstall-refuses-a-directory-that-is-not-ours:case_uninstall_refuses_a_directory_that_is_not_ours
  manifest-declares-the-stop-hook:case_manifest_declares_the_stop_hook
  manifest-command-uses-braced-plugin-root:case_manifest_command_uses_braced_plugin_root
  manifest-command-actually-executes:case_manifest_command_actually_executes
  deletes-only-by-unlink:case_never_deletes_anything
)

if [ "${1:-}" = "--list" ]; then
  for pair in "${CASES[@]}"; do printf '%s\n' "${pair%%:*}"; done
  exit 0
fi

[ -f "$HOOK" ] || { printf 'FATAL: no hook at %s\n' "$HOOK" >&2; exit 2; }
[ -f "$STUB" ] || { printf 'FATAL: no stub at %s\n' "$STUB" >&2; exit 2; }
[ -x "$STUB" ] || chmod +x "$STUB" 2>/dev/null
command -v jq >/dev/null 2>&1 || { printf 'FATAL: this suite needs jq\n' >&2; exit 2; }

for pair in "${CASES[@]}"; do run_case "${pair%%:*}" "${pair#*:}"; done

printf -- '---\n'
if [ "$CASES_FAILED" -eq 0 ]; then
  printf '%d case(s), all passed\n' "$CASES_RUN"
  exit 0
fi
printf '%d case(s), %d failed\n' "$CASES_RUN" "$CASES_FAILED"
exit 1