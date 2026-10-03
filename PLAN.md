# Epic 1 — Make herdr-plugin-minimax-code a working launcher

Written 2026-10-04 by the architect. Planning artifact only: no implementation code
lives in this file. Companion to `HANDOFF.md`, which holds the architecture research
this epic builds on.

## 1. Goal

Ship v0.2.0 of the plugin as a **launcher**: one action that opens a pane beside the
current one and starts MiniMax Code in it, reliably and testably.

## 2. Decisions already locked by the owner

These are settled. Do not relitigate them in an issue or a PR.

1. **Launcher only.** Detection is out of scope for this epic. MiniMax Code remains
   invisible to herdr until a detection manifest lands upstream.
2. **The two inert surfaces are removed, not fixed.** The `minimax-code-status` action
   and the `pane.agent_status_changed` hook are deleted from the manifest. They cannot
   do anything useful while detection is absent, and shipping them declared-but-dead is
   worse than not shipping them.
3. **Drop `herdr agent start` entirely.** `--kind` is a closed 23-value enum with no
   `mcode`/`minimax` member, so that path is unreachable from this repo. Launching is
   `herdr pane split` + `herdr pane run`.
4. **Windows stays out.** `platforms = ["linux", "macos"]`, because the entrypoint is bash.

## 3. Facts the issues depend on

Verified on this machine on 2026-10-04 against herdr `0.9.3` and local
`~/.minimax-code/bin/mcode`. Re-verify if herdr is upgraded mid-epic.

| Fact | How it was verified |
|---|---|
| `herdr pane split [PANE_ID] [--direction right\|down] [--ratio F] [--cwd PATH] [--env K=V]` | `herdr pane split --help` |
| `herdr pane run <PANE_ID> <COMMAND>...` sends text + Enter in one call | `herdr pane run --help` |
| `herdr pane get <ID>` → `{"result":{"pane":{...,"pane_id","cwd","tab_id","workspace_id"}}}` | live call, `wZ:p1` |
| `herdr pane current` → same shape, `type: pane_current` | live call |
| `herdr agent start --kind` accepts exactly 23 values, none of them mcode | `herdr agent start --help` |
| `herdr plugin` has **no** `validate` subcommand | `herdr plugin --help` |
| `mcode` resolves to `/Users/noonoon/.minimax-code/bin/mcode` | `command -v mcode` |
| `jq` 1.7.1 at `/usr/bin/jq`; `python3` 3.14.6 | `--version` |
| `shellcheck` and `bats` are **not installed** | `command -v` |
| Env var is `HERDR_PLUGIN_ROOT`; `HERDR_PLUGIN_DIR` does not exist | HANDOFF §10, confirmed in `~/.adaai` guidance |

### Explicitly unverified — treat as a task, do not guess

The **JSON path to the new pane id inside the `herdr pane split` response** is not
known. `herdr pane split` mutates state, so it was not called during research. Issue C1
exists to capture a real response and record the exact `jq` path. Nobody may hard-code a
guessed path like `.result.pane.pane_id`; if it is wrong, `pane run` fires at the wrong
pane or not at all.

## 4. Child issues

Refs are GitHub issue numbers, created from the bodies in §7 before any assignment.
`flock assign --ref` is mandatory, so these must be real.

### A — Prune the manifest to launcher-only
**Ref:** issue A · **File ownership:** `herdr-plugin.toml` (exclusively)

Delete the `minimax-code-status` action and the whole `[[events]]` block, plus the
comment above `[[events]]` that documents the removed hook. Keep `minimax-code-start`
unchanged in id, title, `contexts = ["workspace", "pane"]`, and its
`${HERDR_PLUGIN_ROOT}/bin/mcode-plugin.sh start` command. `platforms` unchanged.

Acceptance:
- `herdr-plugin.toml` still parses; required top-level keys `id`, `name`, `version`,
  `min_herdr_version` all present.
- Zero occurrences of the string `HERDR_PLUGIN_DIR` in the **shipped surface** —
  `herdr-plugin.toml`, `bin/`, `README.md`, `tests/`. This is the guard that closes the
  defect recorded in HANDOFF §10 and missed at `herdr-plugin.toml:23` and `:31` in the
  scaffold. Deleting those two entries removes the bug; the guard stops it coming back.
  *Amended 2026-10-04 after member m1's pre-flight finding: the original wording was
  repo-wide and therefore unsatisfiable — the string legitimately survives in `PLAN.md`,
  `HANDOFF.md` and `CLAUDE.md`, which document the wrong name as corrected history. Those
  files keep naming it; the guard covers only what ships.*
- No `[[events]]` section remains.

Not a worker task: running `herdr plugin link .` to prove herdr accepts the manifest. That
mutates the owner's herdr registry, so the architect runs it at the review gate (§6).

### B — Implement `cmd_start`
**Ref:** issue B · **File ownership:** `bin/mcode-plugin.sh` (exclusively)

Replace the TODO stub with a real launch. Required behaviour, in order:

1. **Preflight.** Require `jq` on `PATH`. If absent: stderr message naming `jq` and how to
   install it, non-zero exit. Do not let a missing parser turn into a confusing parse error.
2. **Resolve the source pane.** `$HERDR_PANE_ID` when set and non-empty, otherwise resolve
   the current pane via `herdr pane current`. If neither yields a pane id: stderr diagnostic,
   non-zero exit. The action is registered for both `workspace` and `pane` contexts, so both
   branches are live paths, not defensive padding.
3. **Resolve cwd.** From the source pane's `herdr pane get` → `.result.pane.cwd`. If it is
   missing or empty, **omit** `--cwd`, warn on stderr, and continue — herdr's default
   placement is a reasonable degradation, and failing the whole launch over a missing cwd
   would be worse than the fallback.
4. **Split.** `herdr pane split <source-pane> --direction right [--cwd <cwd>]`. Direction is
   fixed to `right` for this epic; making it configurable is a follow-up, not a nit to fix here.
5. **Extract the new pane id** from the split response, using the path established by C1.
   If it cannot be extracted: stderr diagnostic, non-zero exit, and **`pane run` must not be
   called**. This is the safety-critical branch — never type a command into an unidentified pane.
6. **Run.** `herdr pane run <new-pane-id> mcode`.
7. **On run failure:** stderr naming the new pane id, so the user can find and clean up the
   orphaned pane by hand, and a non-zero exit.

Cross-cutting requirements:
- Every `herdr` invocation goes through `$HERDR` (already `${HERDR_BIN_PATH:-herdr}`). There
  must be no bare `herdr` literal left in the script.
- Resolve the launch target with `command -v mcode` and pass the **absolute path** to
  `pane run`, so the launch does not silently depend on the target pane's `PATH`. If
  `command -v mcode` fails: stderr naming the executable, non-zero exit — better than typing
  `mcode` into a pane and getting `command not found` with no attribution. *(Architect's
  default; a worker may argue for bare `mcode` and I will decide.)*
- The script runs under `set -euo pipefail`. That matters: `out=$("$HERDR" pane split ...)`
  aborts the script on a non-zero exit **before** any diagnostic is printed. Capture with an
  `if ! out=$(...)` form so the custom stderr messages in steps 2–7 actually run. Getting
  this wrong produces a silent non-zero exit with no explanation, which is the exact failure
  mode this issue exists to prevent.
- Prune `cmd_status` and `cmd_on_status_change` and their `main` dispatch entries and the
  usage string. The manifest no longer references them (Issue A), so they are unreachable.
  *(Architect's default is remove; a worker arguing to keep them as manual debug affordances
  is a reasonable position and I will decide.)*
- No dependency beyond `jq` and coreutils.

Acceptance:
- `bash -n bin/mcode-plugin.sh` clean.
- All seven failure paths exit non-zero with a non-empty stderr message.
- Step 5's guard is present and observable (Issue C tests it).

### C — Test suite
**Ref:** issue C · **File ownership:** `tests/run.sh`, `tests/fake-herdr` (exclusively)

Plain bash, no external framework — `bats` is not installed and adding it is not worth it
for this size. One command runs everything; document that command in the PR description,
**not** in `README.md`, which belongs to Issue D.

Mechanism: the script already honours `HERDR_BIN_PATH`, so point it at
`tests/fake-herdr` — a stub that appends its argv to `$FAKE_HERDR_LOG` and emits canned
JSON per subcommand. This is what makes a terminal-multiplexer plugin testable at all;
without it there is no way to assert on the command sequence.

Required cases:
1. Happy path with `HERDR_PANE_ID` set: asserts the exact ordered invocations —
   `pane get`, `pane split --direction right --cwd <cwd>`, `pane run <new-id> <abs mcode>`.
2. `HERDR_PANE_ID` unset: asserts `pane current` is used to resolve the source pane.
3. `pane split` fails: non-zero exit, non-empty stderr, and `pane run` is **never** invoked.
4. `pane split` succeeds but the response carries no pane id: non-zero exit, and `pane run`
   is **never** invoked. This is the branch that must never type into an unknown pane.
5. `pane run` fails: non-zero exit, and stderr names the new pane id.
6. `jq` absent from `PATH`: non-zero exit with a message naming `jq`.

Acceptance:
- Every case above passes.
- **Fixture provenance is a hard requirement.** The canned `pane split` response must be a
  real captured response, with the capture date and the exact command recorded in a comment
  beside it. Hand-invented JSON is grounds for rejection — it will encode a field layout
  that does not exist and the tests will pass against a fiction.
- **Mutation-checked.** The worker breaks the implementation in at least two ways (for
  example: pass the source pane id to `pane run` instead of the new one; drop the `--cwd`),
  shows the suite goes red for each, then reverts. Evidence goes in the PR description.
  A green suite that was never seen failing proves nothing.

### D — Refresh the README
**Ref:** issue D · **File ownership:** `README.md` (exclusively)

Depends on A (the exposed-surface table must match the pruned manifest) and C (for the test
command). Content changes: the "Status" line is no longer a skeleton; the "What it exposes"
table lists exactly one action and no event hook; the 22-event list is no longer relevant to
this plugin and should go; the env var table keeps `HERDR_PLUGIN_ROOT`; the License section
points at the actual `LICENSE` file. Do not document the removed surfaces as "coming soon" —
they are deferred to the detection epic, not promised.

### E — LICENSE and real-response capture
**Ref:** issue E · **File ownership:** `LICENSE`, `tests/fixtures/**` (exclusively)

Two independent jobs, deliberately paired because both are small and neither is on the
critical path.

1. Add a `LICENSE`. **Default MIT, copyright 2026, holder `jaaacki`** — the owner must
   confirm the license and holder before merge; this is a legal choice, not an
   implementation detail, and I will not pick it silently.
2. **Capture real `herdr` responses** into `tests/fixtures/`: one `pane get`, one
   `pane current`, and one `pane split`. Record for each the exact command, the herdr
   version, and the date. Then **document the exact `jq` path to the new pane id in the
   split response** — this is the single most important output of this issue and the
   unverified fact in §3. It is captured here rather than in Issue B precisely so the
   fixture work runs in parallel with the implementation instead of blocking it.

### F — CI
**Ref:** issue F · **File ownership:** `.github/workflows/**` (exclusively)

Depends on C. A GitHub Actions workflow on push and PR to `main`, matrix
`ubuntu-latest` + `macos-latest`, running `bash -n` on the entrypoint and the Issue C
suite. Both runners ship `jq`; assert its presence rather than assuming. This is what makes
the "all platforms" half of the quality bar real rather than aspirational, since the plugin
declares `linux` and `macos`.

Acceptance: pipeline green on both platforms, with the pipeline number and exact commit SHA
in the PR description. Separable — it may be deferred without blocking v0.2.0, but if it is
deferred that deviation gets recorded in the release notes rather than quietly dropped.

## 5. File ownership

No two members may touch the same file. This is the whole point of the table.

| Path | Member | Issue |
|---|---|---|
| `herdr-plugin.toml` | m1 | A |
| `bin/mcode-plugin.sh` | m2 | B |
| `tests/fake-herdr`, `tests/run.sh` | m4 | C |
| `README.md` | m1 (phase 2) | D |
| `LICENSE`, `tests/fixtures/**` | m3 | E |
| `.github/workflows/**` | m5 | F |
| `PLAN.md`, `HANDOFF.md` | architect only | — |

## 6. Sequencing and staffing proposal

```
phase 1   m1 → A (manifest)      m2 → B (cmd_start)      m3 → E (LICENSE + capture)
          └──────────────────────────── parallel ───────────────────────────┘
phase 2   m4 → C (tests)   [after B and m3's fixtures]      m1 → D (README) [after A, C]
phase 3   m5 → F (CI)      [after C]
```

**Recommendation: 3 workers, reused across phases.** Peak concurrency 3, five members used
in total.

Reasoning: this is roughly 4–6 hours of work in total, and the largest single item is the
test suite. Starting eight workers on it would spend more effort on coordination, adoption
and message delivery than on the work itself — and delivery to busy members is already known
to be unreliable. Phasing also respects the real dependencies: tests cannot be written
against a script that does not exist yet, and the fixture capture is the long-pole unknown,
which is exactly why it is pulled forward into phase 1 as independent work.

If you would rather have less coordination overhead, drop to 2 (m1 takes A then D, m2 takes
B then C) and accept a longer wall-clock. Do not go above 4.

Model routing: default coding model for m1, m3 and m5. The strongest model available for
**m2** and **m4** — the `set -e` capture semantics in B and the mutation-checking discipline
in C are the two places where a weak model will produce plausible-looking work that is
subtly wrong, and those are exactly the two places a reviewer has the least context to
catch it cheaply. I need you to name the actual model id; I will not guess at your roster,
and per the team contract I will not change a member's model once it is running — if one
turns out to be unfit, the work gets rebalanced instead.

## 7. Issue bodies to create

Create these with `gh issue create` in `jaaacki/herdr-plugin-minimax-code` before any
assignment, so `--ref` has real values. Each body is §4's issue text with its acceptance
criteria verbatim; the worker sees the issue, not this conversation.

```bash
gh issue create --title "Prune manifest to launcher-only" --body-file <a.md>
gh issue create --title "Implement cmd_start via pane split + pane run" --body-file <b.md>
gh issue create --title "Add test suite with a fake-herdr stub" --body-file <c.md>
gh issue create --title "Refresh README for launcher-only v0.2.0" --body-file <d.md>
gh issue create --title "Add LICENSE and capture real herdr response fixtures" --body-file <e.md>
gh issue create --title "Add CI for linux and macos" --body-file <f.md>
```

## 8. Coordination rules for members

Adopted members get assignment and messages only: no model control, no grants, no merge
delegation. The architect seat is a Claude Code or Codex pane, because a MiniMax pane
cannot hold the role while herdr does not detect MiniMax Code (tracked upstream as #2382).

On status vocabulary, which is overloaded in ways that will otherwise corrupt the board:

- `blocked` means a genuine blocker, with the obstacle named and what would clear it. It is
  never a way to end a turn. Finished a step → `progress`. Finished the slice →
  `ready-for-review`.
- The watcher flags busy members as `stalled`. That is not evidence a member is stuck.
  Corroborate against the board before acting on it.
- Every issue body states its acceptance criteria up front precisely so a member can
  self-assess into `ready-for-review` rather than parking in `blocked`.
- Assignment delivery is verified, never assumed: a verb that exits 0 with
  `RECORDED but delivery failed` did not deliver. Re-send on `push_failed` and do not type
  into member panes.

## 9. Out of scope for this epic

- Detection: a `minimax-code.toml` screen manifest, upstream PR to `herdrdev/herdr`, or a
  new `--kind` enum member. This is the follow-on epic, and until it lands the plugin cannot
  see or track the agents it launches.
- `herdr agent prompt` delegation, and any agent-to-agent handoff.
- Windows support.
- A `[[panes]]` section or any plugin-owned UI surface. The launcher uses plain panes
  precisely so it needs none.
- Marketplace publishing and release tagging.

## 10. Risks

- **The §3 unverified jq path is the epic's largest single unknown.** If the real response
  shape defeats the obvious extraction, Issue B's step 5 guard is what keeps it safe, and
  Issue C's case 4 is what proves the guard works. Neither may be cut for time.
- **"All platforms" is Linux and macOS only.** No Windows claim is made or implied.
- **No CI exists yet.** Until Issue F lands, the platform claim rests on local runs only.
  That deviation is recorded in the release notes, not hidden.
- **The plugin is still unproven against a real herdr load.** The manifest has never been
  accepted by herdr; there is no `validate` subcommand, so the first real proof is
  `herdr plugin link .`, which the architect runs at the review gate because it mutates the
  owner's registry.
