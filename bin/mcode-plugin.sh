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

# WHY THIS PRINTS A COMMAND INSTEAD OF STARTING THE WATCHER (issue #47).
#
# Issue #47 asked for `bin/mcode-watch.sh <pane>` to be running after every
# launch, and explicitly invited the alternative. The alternative won, on
# evidence, not on effort:
#
#   1. The watcher's own exit path deletes the thing we just created.
#      mcode-watch.sh calls `pane release-agent` from its INT/TERM/EXIT traps
#      and when the watched pane dies, and `release-agent` REMOVES the agent
#      entry - measured and reproduced live (register + rename, run one
#      `mcode-watch.sh --once`, and the entry is gone from `agent list`).
#      Auto-starting it would unregister every pane it watched the moment that
#      pane closed or the operator hit Ctrl-C. That is worse than the stale
#      `idle` claim, because a missing registration also costs `get`, `read`,
#      `wait` and the name. The defect is in bin/mcode-watch.sh, not here, so
#      wiring the watcher before that is fixed means shipping a known bug and
#      calling it a feature.
#
#   2. A detached watcher has no honest way to learn that Herdr exited. The
#      foreground design was precisely the answer to that: a watcher the human
#      can see, and stop with Ctrl-C. Backgrounding it means inventing a
#      supervisor - PID bookkeeping, reaping, an orphan sweep - to answer a
#      question the foreground form already answers for free. That is a much
#      larger change than this issue, in a file this member does not own.
#
#   3. The actual harm #47 names - "the agent claims `idle` forever while it is
#      working" - is fixed by the `--state unknown` change at the report-agent
#      call, not by the watcher. With `unknown` there is no stale lie to
#      prevent, so the missing watcher costs accuracy the user has to opt into,
#      rather than accuracy the user was given and can trust.
#
# So the watcher stays opt-in and discoverable: one line, on stderr, next to
# the line that already says the pane started. The same failure policy as
# registration applies - a hint that cannot be produced is a warning, and the
# launch still exits 0, because the launch is what the user asked for and it
# already worked.
# WHY THE WATCHER IS STARTED NOW RATHER THAN ONLY SUGGESTED (issue #75).
#
# It was opt-in for a long time, and the opt-in nobody takes is the same as no
# state tracking at all. Measured on this machine, 2026-10-04: `ps` found ZERO
# mcode-watch.sh processes, so every state herdr displayed came from a one-time
# adopt-time measurement and never moved again. That is the owner's report, and it
# is the reason `working` stuck after a turn finished - the orange dot.
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
#
# So lifetime is tied to the thing being watched rather than to a supervisor that
# could itself outlive it or die silently.
#
# FAILURE POLICY, same asymmetry as every other step after the split: the launch
# already worked and the user can see mcode running. Failing now would report a
# success as a failure and could make a caller retry, spawning a second pane. So
# every failure below is a warning and exit 0 - and the warning says what is lost,
# because "state is not tracked" with no remedy is how this gets misdiagnosed.
watcher_autostart() { # watcher_autostart <pane-id>
  local pane="$1"
  local dir watcher

  # Resolved from this script's own directory, NOT $HERDR_PLUGIN_ROOT: the env
  # var is only injected when Herdr runs the action, so a hand-run of the
  # entrypoint would resolve an empty string.
  #
  # `..` because this file IS the plugin's bin/mcode-plugin.sh, so its own
  # directory is `bin/` and the watcher sits one level up. Getting this wrong
  # yields <root>/bin/bin/mcode-watch.sh - short enough to look right, and
  # `-x`-false. `pwd -P` collapses the `..` and resolves symlinks.
  #
  # `|| true` matters under `set -e`: a failing `cd` in this substitution would
  # abort the launch *after* it succeeded, turning a cosmetic failure into a
  # failed action.
  dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P || true)"
  watcher="${dir}/bin/mcode-watch.sh"

  # Opt-out, checked BEFORE anything else so it costs nothing and starts nothing.
  # Compared as the exact string "0" rather than "any non-empty value", so
  # MCODE_WATCH_AUTOSTART= (set but empty) keeps the default on - an empty value
  # reads as "not configured", and treating it as "off" would silently disable a
  # default the user never turned off.
  if [ "${MCODE_WATCH_AUTOSTART:-1}" = "0" ]; then
    log "minimax-code: state for pane ${pane} will NOT be tracked, because MCODE_WATCH_AUTOSTART=0. Until you start a watcher, \`herdr agent list\` will keep showing whatever state it last saw - which goes stale in BOTH directions when a turn starts or finishes. To start it by hand: ${watcher} ${pane}"
    return 0
  fi

  if [ -z "$dir" ]; then
    log "minimax-code: could not resolve this plugin's own directory, so the state watcher was not started and pane ${pane} will stay 'unknown' in \`herdr agent list\` - and 'unknown' is the only state this plugin can keep true without a watcher. The launch itself succeeded."
    return 0
  fi
  if [ ! -x "$watcher" ]; then
    log "minimax-code: could not start the state watcher - ${watcher} is missing or not executable - so pane ${pane} will stay 'unknown' in \`herdr agent list\`, and that state will NOT follow the pane as it works and idles. The launch itself succeeded."
    return 0
  fi
  # Checked rather than assumed: this is a POSIX tool, but the plugin supports
  # platforms where a stripped-down install may not carry it, and a missing
  # nohup would otherwise produce a watcher that dies the moment this script
  # exits - the worst failure mode, because it looks started.
  if ! command -v nohup >/dev/null 2>&1; then
    log "minimax-code: \`nohup\` is not on PATH, so the state watcher was not started and pane ${pane} will stay 'unknown'. Start it in another terminal to get real states: ${watcher} ${pane}. The launch itself succeeded."
    return 0
  fi

  # WHY OUTPUT GOES TO /dev/null. The watcher's stdout and stderr are its own
  # per-transition commentary, and herdr already records every state transition
  # it reports - \`herdr agent list\` and the pane's own state history are the
  # durable record. A detached process with no reader is writing to a void, and
  # a log file would be state this plugin does not otherwise keep and would have
  # to explain, rotate and clean up. If a transition is ever refused, the
  # watcher says so on ITS stderr and continues, which is worth knowing about
  # but not at the cost of an unowned file.
  #
  # `disown` detaches it from this shell's job table so the launch's own exit
  # does not signal it. Harmless if it fails: nohup already ignores SIGHUP, so
  # disown is belt-and-braces, and a non-interactive shell may legitimately have
  # nothing to disown.
  nohup "$watcher" "$pane" >/dev/null 2>&1 &
  disown 2>/dev/null || true

  log "minimax-code: started the state watcher for pane ${pane}, so idle/working will follow the pane. It stops by itself when the pane closes. Set MCODE_WATCH_AUTOSTART=0 to skip this next time; \`blocked\` is never reported - MiniMax Code 0.6.2 exposes no hook a plugin can read, so idle/working/unknown is the whole range."
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
session_report() { # session_report <pane-id>
  local pane="$1"
  local dir sibling

  dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P || true)"
  sibling="${dir}/bin/mcode-session.sh"

  if [ -z "$dir" ] || [ ! -x "$sibling" ]; then
    log "minimax-code: could not run the session reporter - ${sibling} is missing or not executable - so no session id and no resume command were recorded for pane ${pane}. The pane IS registered and named, and state tracking is unaffected; only resume is unavailable. The launch itself succeeded."
    return 0
  fi

  # stderr is DELIBERATELY INHERITED, not captured. The sibling's read-back
  # diagnostic - "herdr 0.9.3 did not persist it", naming the session and the
  # pane - is the entire point of calling it from the launch path, and capturing
  # stderr into a variable to print only on failure would swallow it on the
  # success path, which is the path it actually takes on 0.9.3.
  #
  # HERDR_BIN_PATH is passed through with the value THIS script resolved, so the
  # sibling talks to the same multiplexer instance as the rest of the launch
  # rather than re-resolving `herdr` from PATH. It is the same string the
  # default would use, so passing it is a no-op unless the operator overrode it.
  #
  # HERDR_PANE_ID is required by the sibling and is the whole mechanism: it only
  # reports for the pane the reporter holds. HERDR_PANE_ID in this process is the
  # SOURCE pane, so exporting it and inheriting would report the wrong one - it is
  # set per-invocation here, never exported.
  #
  # MCODE_RESUME_CMD and MCODE_HOME are inherited untouched on purpose: an
  # operator who set either meant it for this session too.
  if HERDR_PANE_ID="$pane" HERDR_BIN_PATH="$HERDR" "$sibling" report; then
    return 0
  fi
  # The sibling's own stderr has already said why. This line adds the one thing
  # it cannot know - which pane the launch was for - so a failure is attributable
  # without scrolling back through interleaved output.
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
    rm -f "$get_err_file"
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
  #    created and mcode was still starting. But nothing in the plugin ever
  #    updates that claim, so it was not a cautious placeholder - it was a
  #    permanent false one. Measured on 0.9.3: a pane registered `idle` here
  #    still read `idle` twenty-five seconds later with the MiniMax Code TUI up
  #    and visibly working, and `herdr agent list` would have shown the lie for
  #    as long as the pane lived. `unknown` is the only state this process can
  #    keep true, and it is what Herdr shows for a pane nobody has registered.
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
  if "$HERDR" pane report-agent "$new_pane" --source herdr:minimax-code --agent "$MCODE_BIN_NAME" --state unknown; then
    local agent_name
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
  session_report "$new_pane"

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
  watcher_autostart "$new_pane"
}

main() {
  case "${1:-}" in
    start)
      cmd_start
      ;;
    *)
      log "usage: mcode-plugin.sh start"
      exit 2
      ;;
  esac
}

main "$@"
