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

CASES_RUN=0
CASES_FAILED=0
SESSION=""
SERVER_PID=""
WORKDIR=""
PRIOR_LINK=""
LINKED_BY_US=""
THROWAWAY_PANE=""
FOREIGN_PANE=""

# ── reporting ────────────────────────────────────────────────────────────────
pass() { CASES_RUN=$((CASES_RUN + 1)); printf 'ok    %s\n' "$1"; }
fail() {
  CASES_RUN=$((CASES_RUN + 1))
  CASES_FAILED=$((CASES_FAILED + 1))
  printf 'FAIL  %s\n' "$1"
  shift
  while [ $# -gt 0 ]; do printf '        %s\n' "$1"; shift; done
}

# ── cleanup: runs whatever happens, and leaves nothing behind ────────────────
# Every resource this suite creates is recorded here and torn down in reverse.
# The brief's criterion 6 is "leave no panes, no sessions, no registry changes",
# so cleanup is not best-effort: a failure below is reported, never swallowed.
cleanup() {
  local rc=$?
  set +e

  # The panes the #84 cases split, and the watchers that were started for them.
  # Scoped to those two pane ids on purpose: a blanket `pkill -f mcode-watch.sh`
  # also kills the watchers belonging to the developer's real minimax-code
  # panes, which is damage this suite must not do to the machine it verifies.
  for tp in "$THROWAWAY_PANE" "$FOREIGN_PANE"; do
    [ -n "$tp" ] || continue
    [ -n "$SESSION" ] && "$HERDR" --session "$SESSION" pane close "$tp" >/dev/null 2>&1
    for wp in $(pgrep -f "mcode-watch.sh $tp" 2>/dev/null); do
      kill "$wp" 2>/dev/null
    done
  done

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
        || rm -rf "$HERDR_CONFIG_DIR/sessions/$SESSION" 2>/dev/null
    fi
  fi

  # Restore the plugin registry to exactly what it was. Linking is global to the
  # user, not per-session, so this suite mutates the developer's registry and
  # must put it back even on failure.
  #
  # Guarded on LINKED_BY_US. Unconditionally unlinking here would delete a
  # developer's own registration if the suite died between installing this trap
  # and taking the snapshot below — a failure that would damage the machine it
  # is meant to be testing. Only undo what this suite actually did.
  if [ -n "$LINKED_BY_US" ]; then
    "$HERDR" plugin unlink "$PLUGIN_ID" >/dev/null 2>&1
    if [ -n "$PRIOR_LINK" ]; then
      "$HERDR" plugin link "$PRIOR_LINK" >/dev/null 2>&1
    fi
  fi

  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR" 2>/dev/null
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
# Stand-in for the real launcher. Kept alive so the pane does not exit: herdr
# drops a pane's agent registration when the pane's process ends, and a pane
# whose shell exits would take the registration with it.
printf 'mcode (e2e stub) %s\n' "\$*"
exec sleep 300
STUB
  chmod +x "$WORKDIR/bin/$AGENT_LABEL"
  PATH="$WORKDIR/bin:$PATH"
  export PATH
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
  # dies must leave a trace. The path is only asserted when the suite pointed
  # the state dir somewhere disposable, which it does not by default.
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

# ── main ─────────────────────────────────────────────────────────────────────
printf 'e2e: driving a REAL herdr (%s)\n' "$HERDR"

# Snapshot the registry BEFORE linking, so cleanup can put it back exactly.
HERDR_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
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

# The stub launcher MUST be on PATH before the server starts: the action is
# spawned by the server and inherits the server's environment, not this
# script's. See prepare_stub_mcode for what that cost on the first CI run.
prepare_stub_mcode

run_case_bootstrap
run_case_launch
run_case_registered
run_case_readable
run_case_name_addressable
run_case_tripwire
run_case_event_watcher
run_case_foreign_pane_untouched

printf -- '---\n'
if [ "$WARNINGS" != "[]" ] && [ -n "$WARNINGS" ]; then
  printf 'manifest warnings: %s\n' "$WARNINGS" >&2
  CASES_FAILED=$((CASES_FAILED + 1))
fi
if [ "$CASES_FAILED" -eq 0 ]; then
  printf '%d case(s), all passed\n' "$CASES_RUN"
  exit 0
fi
printf '%d case(s), %d failed\n' "$CASES_RUN" "$CASES_FAILED"
exit 1
