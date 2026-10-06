# Self-review — flock member Stop hook (sparkfn/pc-tools#1699 item 1)

Branch `issue/1699-flock-stop-hook`, off `jaaacki/herdr-plugin-minimax-code` @ `ac0b3c9`.

## What this does

A flock member must not end a turn silently. `flock-stop.sh` asks
`pc-tool flock hook stop` whether this turn may end, and translates its answer
into the decision mcode reads off the hook's stdout.

The verb itself is **sparkfn/pc-tools#1710 (head `bcdf1d6b`)**, which is OPEN. This
PR is inert until it merges, and says so in the manifest description.

## The contract, and where each half comes from

**mcode 0.6.2**, verified against the installed bundle
(`releases/0.6.2/lib/node_modules/@minimax-ai/code/chunks/chunk-UI7OHI22.js`), not
from memory:

- The Stop payload on stdin carries `stop_hook_active` and
  `last_assistant_message`; mcode's own payload validator requires both.
- The decision accepts `decision` and `reason` (plus `hookSpecificOutput` in
  CLAUDE/MINIMAX source format).
- **A top-level `decision` must be the STRING `"block"`, or absent.** Anything
  else is discarded — so an envelope that happened to parse would silently not
  block. This is why the wrapper unwraps rather than passing pc-tool's stdout
  through.

**pc-tool #1710**, from the PR's own body and source:

- `flock hook stop` is **two words** (`runFlock` takes the first token, so
  `index.ts` resolves the one two-word verb).
- It reads the Stop payload from **stdin**; `FLOCK_STOP_INPUT` is a test seam
  that overrides it.
- It returns the block in the **decision, not the exit code**, and exits 0
  either way. A hook that exited 2 would be a second, undocumented wake path.
- It answers `decision: "end"` when `stop_hook_active` is true, when the flock is
  closed, when there is no mail, and when the session is not a member.

## Why this fails open, on every path

Every failure path prints nothing and exits 0. A Stop hook that wedges an agent —
refusing to end a turn because pc-tool is missing — does not fail the member, it
**traps** it, and from inside the session the two look identical. A missed nudge
costs one round trip; a wedged agent costs the session. Degrading to "no hook" is
the correct direction.

Covered explicitly: pc-tool absent, the two-word verb refused, unparseable
output, no payload, a reason-less block (mcode **discards** it), and no `jq`.

`jq` is used to unwrap the envelope and to escape the reason. Without it the hook
stands down and says why on stderr. It does **not** hand-roll a JSON parse in
bash: a subtly wrong parse produces either a permanent block or a silently
swallowed nudge, and neither is worth the bytes.

## Two things I did not do, deliberately

**1. Item 2 (`PostToolUse` `additionalContext`) is NOT wired.** I verified from
the 0.6.2 source that mcode *does* support it — `PostToolUse` accepts
`additionalContext`, and plain-text stdout becomes `additionalContext` for
non-CODEX formats. But **#1710 ships only two verbs, `flock wait` and
`flock hook stop`. There is no verb for mid-turn mail.** `flock wait` blocks the
process and exits 2 for an `asyncRewake` wake; it is not a context injector.
Wiring item 2 needs a verb that does not exist yet, and inventing a shell
pipeline that re-implements the mail query would duplicate the authority checks
`#1710` already put behind a store read. So the capability is confirmed and the
wiring is not built.

**2. This is a SEPARATE plugin, not a hook in `herdr-bootstrap`.** Adding `Stop`
to the existing manifest broke `tests/hook-run.sh`, which enforces a deliberate
invariant: *"only SessionStart may be declared; the watcher owns every later
state."* That is a real design rule, not an incidental assertion, so I did not
weaken it. `flock-stop-plugin/` declares exactly one event and
`herdr-bootstrap`'s manifest is byte-unchanged.

**Consequence, and it is not finished:** `bin/mcode-plugin.sh` still installs
only `herdr-bootstrap`. A second plugin needs installer work — its own
`install-hook`/`uninstall-hook` arming, and the exact-path guards the existing
installer has — and that is a wider change than this slice should make
unilaterally. Flagged for the reviewer rather than guessed at.

## Tests

`tests/flock-stop-run.sh`, 14 cases, matching the CI `tests/*run.sh` glob.
`tests/fake-pc-tool` is the stub; because the real verb does not exist on this
machine yet, every case runs against the **documented** contract and none can
pass by accident against a real pc-tool.

Every case fails without the behaviour it names. Verified by mutation: replacing
the hook with `exit 0` turns **4 cases red**; restoring it returns 14/14.

**A bug this suite caught in itself, worth recording.** My first `run_case` used
the case function's exit status for the tally while the FAIL *line* was driven by
a separate `broke` flag. A failed case prints FAIL and is counted as a pass, so
the suite reported `14 case(s), all passed` and **exited 0 while showing a FAIL
line**. That is worse than no suite. `run_case` now counts `broke`, not status.

A second case was wrong for a related reason: `fails-open-without-jq` cleared
`PATH` entirely, so `env` could not find `bash` and the case measured the harness
failing (127) rather than the hook standing down. It now builds a `PATH` with
everything the hook needs except `jq`, and asserts the hook *says why* on stderr
— a machine that silently lost `jq` would otherwise be undiagnosable.

`tests/hook-run.sh` still passes 26/26, unchanged.

## Repo conventions honoured

`/bin/rm` never bare, no trash (issue #109). `set -uo pipefail`, plain bash.
`${PLUGIN_ROOT}` braced. No backticks in unquoted heredocs. No writes outside
`$TMPDIR`. Nothing deleted; scratch left in place.

**Not claimed:** no native Linux check. The repo's own accept asks for
lab-001; this PR has run on darwin only.