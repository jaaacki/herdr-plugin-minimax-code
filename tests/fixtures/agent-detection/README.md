# Captured mcode screens behind `agent-detection/minimax-code.toml`

Every rule in that manifest was read out of these files. Nothing in it is imagined,
and nothing here is hand-edited.

The captures are the same ones the watcher in `bin/mcode-watch.sh` classifies against
(issue #35, `tests/fixtures/detection/`), re-stated here so the manifest and its
evidence travel together as one self-contained unit for the upstream contribution in
issue #37. They are the same bytes, copied — not a second capture.

Captured **2026-10-04** (~05:20–05:40 +0800) against **herdr 0.9.3**
(`/Users/noonoon/.local/bin/herdr`), **mcode v0.6.2** (`/Users/noonoon/.minimax-code/bin/mcode`).

| File | Exact capture command | Pane | What it shows |
|---|---|---|---|
| `working.txt` | `herdr pane read wZ:p5 --source detection --lines 40` | `wZ:p5` | genuinely busy; carries the live status strip |
| `idle.txt` | `herdr pane read wZ:p1A --source detection --lines 40` | `wZ:p1A` | fresh session, never used — the start prompt |
| `idle-after-working.txt` | `herdr pane read wZ:p1A --source detection --lines 40` | `wZ:p1A` | a turn that has finished — the composer |
| `stale-scrollback.txt` | **constructed**, see below | — | finished work still in the scrollback |
| `not-mcode.txt` | `herdr pane read wZ:p1 --source detection --lines 40` | `wZ:p1` | a `claude` pane, not mcode at all |

`wZ:p1A` was created for this work and closed after capture. `wZ:p5` and `wZ:p1` belong
to other flock members; only their screens were read, never their state.

## The lines the rules match

Working — `working.txt:35` and `:34`:

```
   ⠸ Retrying model request · 1/5 · next in 697ms · Timeout · code 50113 7min7s · ⚡ 26117 tok/s · Option+Enter queue · Enter steer · Ctrl+O details · Esc stop
   … +4 more · 0/7 done · 6 pending · Ctrl+T expand
```

Idle, two shapes. Fresh (`idle.txt:20`):

```
   Start · @ file or Plugin · / autocomplete
```

After a turn (`idle-after-working.txt:22,24`):

```
   └ Completed in 3s · ⚡ 667 tok/s
   Message · Enter send · Shift+Enter newline
```

## Why every rule is scoped to a bottom window

`idle-after-working.txt:22` contains `⚡ 667 tok/s` — a throughput counter on a turn that
has **already finished**. A rule scanning the whole buffer for throughput markers would
call a finished session "working" forever. Every rule is therefore scoped to
`bottom_non_empty_lines(12)`, which is the manifest-native form of the tail window the
watcher had to hand-roll.

`stale-scrollback.txt` is a **constructed composite**, not a single read: the real
`working.txt`, a separator, then the real `idle-after-working.txt`. It reproduces the
case where a live status strip sits above an idle tail. Labelled as constructed here
rather than passed off as a capture.

## Why there is no `blocked` fixture

There is none, and the manifest has no `blocked` rule. mcode 0.6.2 runs these sessions at
`Full access`, where no permission prompt is raised, and permission level is a session
setting rather than a CLI flag, so the state could not be produced without inventing it.
`/permission` makes an approval prompt reachable by a human; whoever captures one should
add the rule and the fixture together.

## One guard that is not exercised

The `not` clause on `mcode_turn_complete_idle` is **not** proven by any file here — a
mutation check confirmed that deleting it changes no current classification, because no
capture exists where a "Completed in" line and a live spinner share a bottom window. It is
kept as defence against a plausible case and is labelled as unexercised in the manifest.
See the note there.
