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
  #    --state is `idle`, not `working`: the pane was just created and mcode is
  #    still starting. Claiming work we have not observed is a lie the agent
  #    surface would then display.
  #
  #    --seq is omitted on purpose. Herdr assigns state_change_seq itself (it
  #    did, 122, on a first report in a live check), so inventing our own
  #    counter would add a second, competing ordering scheme.
  #
  #    --agent-session-id is omitted: mcode does not hand us one at launch, and
  #    inventing a session id would be worse than reporting none.
  if ! "$HERDR" pane report-agent "$new_pane" --source minimax-code --agent "$MCODE_BIN_NAME" --state idle; then
    log "minimax-code: could not register pane ${new_pane} with Herdr's agent surface, so it will not appear in \`herdr agent list\`. The launch itself succeeded; nothing was rolled back. \`herdr agent list\` will show it once Herdr detects it, if it ever does."
  fi
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
