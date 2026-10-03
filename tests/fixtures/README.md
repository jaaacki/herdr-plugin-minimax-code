# herdr response fixtures

Real, unedited `herdr` responses captured for issue #7. These settle the one fact
`PLAN.md` §3 flagged as *explicitly unverified*: **the `jq` path to the new pane id inside
the `herdr pane split` response.** Nobody should hard-code a guessed path.

## The answer (read this first)

**`herdr pane split` puts the new pane id at `.result.pane.pane_id`** — the same shape as
`pane get` and `pane current`. It is not nested any deeper, and there is no array of panes
to index into.

```console
$ herdr pane split wZ:p4 --direction right --no-focus > split.json
$ jq -r '.result.pane.pane_id' split.json
wZ:p7
```

The response envelope is `{ "id": "cli:pane:split", "result": { "pane": { ... } } }`, and
`result.type` is `pane_info` — *not* `pane_split`. Don't branch on `result.type` to
distinguish the split response; the top-level `id` (`cli:pane:split`) is the reliable
discriminator if you need one.

For the plugin entrypoint this means, in `cmd_start`:

```bash
if ! out=$("$HERDR" pane split --direction right --no-focus); then
  printf 'mcode: pane split failed\n' >&2
  exit 1
fi
new_pane=$(printf '%s' "$out" | jq -r '.result.pane.pane_id')
# exit non-zero here if $new_pane is empty/null before any `pane run`
```

`.result.pane.pane_id` is the only path verified by an actual `jq` run against a captured
response. The alternative guess `.result.pane_id` does **not** resolve — it yields `null`.

## Captures

All three captured on **2026-10-04** (03:51 +0800) against **herdr 0.9.3**
(`/Users/noonoon/.local/bin/herdr`), `jq` 1.7.1 at `/usr/bin/jq`.

| File | Exact command | Response `id` | `result.type` |
|---|---|---|---|
| `pane-get.json` | `herdr pane get wZ:p4` | `cli:pane:get` | `pane_info` |
| `pane-current.json` | `herdr pane current` | `cli:pane:current` | `pane_current` |
| `pane-split.json` | `herdr pane split wZ:p4 --direction right --no-focus` | `cli:pane:split` | `pane_info` |

`pane-get.json` and `pane-current.json` were captured against pane `wZ:p4`, which is the
pane that ran the commands — so both are views of the *caller's own* pane.

`pane-split.json` is a real state mutation: it split `wZ:p4` and returned the newly created
pane `wZ:p7`. That scratch pane was closed again immediately after capture
(`herdr pane close wZ:p7` → `{"id":"cli:pane:close","result":{"type":"ok"}}`), and
`wZ:p4` was left running. No other pane was touched.

## Caveat for whoever writes the test harness

These are verbatim captures, so they contain volatile fields that change on every call:
`revision`, `terminal_id`, `focused`, and `scroll.max_offset_from_bottom`. `cwd` and
`foreground_cwd` are absolute paths from the capturing machine
(`/Users/noonoon/Dev/herdr-plugin-minimax-code`).

Assert on stable fields only — `pane_id`, `tab_id`, `workspace_id`, `id`, and
`result.type`. Do not assert on `revision`, `terminal_id`, or anything under `scroll`.
