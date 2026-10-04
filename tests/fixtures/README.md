# herdr response fixtures

Real, unedited `herdr` responses captured for issue #7. These settle the one fact
`PLAN.md` §3 flagged as *explicitly unverified*: **the `jq` path to the new pane id inside
the `herdr pane split` response.** Nobody should hard-code a guessed path.

## The answer (read this first)

**`herdr pane split` puts the new pane id at `.result.pane.pane_id`** — the same shape as
`pane get` and `pane current`. It is not nested any deeper, and there is no array of panes
to index into.

Verified by an actual `jq` run against the captured response in this directory:

```console
$ jq -r '.result.pane.pane_id' tests/fixtures/pane-split.json
wZ:p8
```

The response envelope is `{ "id": "cli:pane:split", "result": { "pane": { ... } } }`, and
`result.type` is `pane_info` — *not* `pane_split`. Don't branch on `result.type` to
distinguish the split response; the top-level `id` (`cli:pane:split`) is the reliable
discriminator if you need one.

The plausible alternative guess does not resolve — it yields `null`:

```console
$ jq -r '.result.pane_id' tests/fixtures/pane-split.json
null
```

### The shape is flag-independent

Captured twice, with different flags, and the `jq` path and `result.type` were identical
both times:

| Flags | New pane id | `result.type` |
|---|---|---|
| `--direction right --no-focus` | `wZ:p7` | `pane_info` |
| `--direction right --cwd <path> --no-focus` | `wZ:p8` | `pane_info` |

`--cwd` *does* flow through into the response: the returned pane's `cwd` is whatever was
passed to `--cwd`. It does not change where the pane id lives.

## For the `cmd_start` implementer (issue #3)

Verified form — pass the source pane explicitly:

```bash
if ! out=$("$HERDR" pane split "$HERDR_PANE_ID" --direction right --cwd "$PWD"); then
  printf 'mcode: pane split failed\n' >&2
  exit 1
fi
new_pane=$(printf '%s' "$out" | jq -r '.result.pane.pane_id')
# exit non-zero if $new_pane is empty or the string "null" BEFORE any `pane run`
```

This was replayed under `set -euo pipefail` against the fixture and yields `wZ:p8`.

**Unverified — do not assume:** the bare `herdr pane split` form with no `PANE_ID` argument.
`herdr pane split --help` marks `[PANE_ID]` optional, and `herdr pane current` correctly
resolved the calling pane even while a *different* pane held focus — but the bare form was
deliberately **not** tested, because if it resolves to the focused pane rather than the
caller's, testing it would have split another member's pane, which issue #7 forbids. Resolve
the pane id explicitly (`$HERDR_PANE_ID`, or `herdr pane current`) and pass it.

## Why the metadata is in this file and not inside the fixtures

Issue #7 asks for "a comment in the fixture file". **That is not possible for a `.json`
fixture without breaking it** — `jq` does not accept comments:

```console
$ printf '{"a":1}\n# comment\n' > /tmp/c.json
$ jq -r '.a' /tmp/c.json
jq: parse error: Invalid numeric literal at line 2, column 2
1
$ echo $?
5
```

Exit 5. A `#` comment would make the fixture unusable by every consumer that reads it with
`jq` — which, given these fixtures exist to be parsed by `jq`, defeats their entire purpose.
So the per-file command, version, and date live here instead. Stated loudly rather than
silently worked around, per the issue's own instruction not to paper over surprises.

## Captures

All three captured on **2026-10-04** (03:51–03:56 +0800) against **herdr 0.9.3**
(`~/.local/bin/herdr`), `jq` 1.7.1 at `/usr/bin/jq`.

**The `cwd` values inside the three `.json` files are de-identified.** They were captured
with the operator's real home directory in `cwd` and `foreground_cwd`, and `tests/` ships
inside the public release tarball, so that path is now rendered `~/…`. The published
v0.3.0 asset shipped this home path eight times even after the documentation around it
had been cleaned, because the leak was in the response bodies, not in the prose.

Nothing else was touched. In particular the `pane_id` values are the real captured ones
(`wZ:p4`, `wZ:p8`) — the new pane id from `pane-split.json` is the one value in this repo
that must never be invented, and the suite derives its expectations from this file rather
than from a hard-coded literal for exactly that reason. The commands below are the
commands actually run, with the home prefix and the ephemeral worktree path rendered
generically.

| File | Exact command | Response `id` | `result.type` |
|---|---|---|---|
| `pane-get.json` | `herdr pane get wZ:p4` | `cli:pane:get` | `pane_info` |
| `pane-current.json` | `herdr pane current` | `cli:pane:current` | `pane_current` |
| `pane-split.json` | `herdr pane split wZ:p4 --direction right --cwd /path/to/a/worktree --no-focus` | `cli:pane:split` | `pane_info` |

`pane-get.json` and `pane-current.json` were captured against pane `wZ:p4`, which is the
pane that ran the commands — so both are views of the *caller's own* pane.

`pane-split.json` is a real state mutation. It split `wZ:p4` and returned the newly created
pane `wZ:p8`; that scratch pane was closed immediately after capture
(`herdr pane close wZ:p8` → `{"id":"cli:pane:close","result":{"type":"ok"}}`). An earlier
capture during the same session created and closed `wZ:p7` the same way. `wZ:p4` was left
running and no other member's pane was touched.

`pane-split.json` deliberately uses the flag combination issue #4 expects the plugin to emit
(`--direction right --cwd <path>`), so the fixture matches the real invocation rather than a
convenient one.

## For whoever writes the test harness (issue #4 / C2)

The `fake-herdr` stub reads canned responses from `tests/fixtures/`. The three filenames are
exactly:

- `tests/fixtures/pane-get.json`
- `tests/fixtures/pane-current.json`
- `tests/fixtures/pane-split.json`

These captures are verbatim, so they contain volatile fields that change on every call:
`revision`, `terminal_id`, `focused`, `scroll.max_offset_from_bottom`, and absolute `cwd` /
`foreground_cwd`.

Assert on stable fields only — `pane_id`, `tab_id`, `workspace_id`, `id`, and `result.type`.
Do not assert on `revision`, `terminal_id`, `focused`, or anything under `scroll`. If the
harness needs a stable `cwd`, inject it via `--cwd` rather than relying on the captured value.
