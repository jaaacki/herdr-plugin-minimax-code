# mcode detection snapshots — captured real screens

These are the inputs `bin/mcode-watch.sh` classifies. Nothing here is invented:
each file is real output from a real `mcode` or non-mcode pane, and every rule in
the watcher was read out of these files rather than assumed.

Captured **2026-10-04** (~05:20–05:40 +0800) against **herdr 0.9.3**
(`/Users/noonoon/.local/bin/herdr`), mcode **v0.6.2** (`/Users/noonoon/.minimax-code/bin/mcode`).

| File | Exact capture command | Pane | Classified |
|---|---|---|---|
| `idle.txt` | `herdr pane read wZ:p1A --source detection --lines 40` | `wZ:p1A` — fresh session, never used | `idle` |
| `working.txt` | `herdr pane read wZ:p5 --source detection --lines 40` | `wZ:p5` — another member's live busy session | `working` |
| `idle-after-working.txt` | `herdr pane read wZ:p1A --source detection --lines 40` | `wZ:p1A` — after `herdr pane run wZ:p1A "reply with the single word ok"` completed | `idle` |
| `not-mcode.txt` | `herdr pane read wZ:p1 --source detection --lines 40` | `wZ:p1` — a `claude` pane, not mcode at all | `unknown` |
| `stale-scrollback.txt` | **constructed**, see below | — | `idle` |

`wZ:p1A` was created for this issue (`herdr pane split wZ:p4 --direction down --no-focus`, then
`herdr pane run wZ:p1A "$(command -v mcode)"`) and closed after capture. `wZ:p5` and `wZ:p1`
belong to other flock members; only their screens were read, never their state.

## The three states mcode actually has, not two

Capturing a *completed* turn turned up a resting shape that the first two captures
did not show, and it changed the rules:

```
working          ⠸ Retrying model request · … · ⚡ 26117 tok/s · Ctrl+O details · Esc stop
fresh idle       ● Ready
                 Start · @ file or Plugin · / autocomplete
after a turn     └ Completed in 3s · ⚡ 667 tok/s
                 Message · Enter send · Shift+Enter newline
```

`after a turn` is idle, and it is the *common* case. A watcher that only knew
`Start · @` would have reported `unknown` for nearly every finished session.

## Markers, and the two that were rejected on the evidence

Checked against all three real mcode snapshots:

| Marker | fresh idle | after a turn | working | verdict |
|---|---|---|---|---|
| `Esc stop` | – | – | yes | working |
| `Ctrl+O details` | – | – | yes | working |
| `Ctrl+T expand` | – | – | yes | working |
| `Start · @` | yes | – | – | idle |
| `● Ready` | yes | – | – | idle |
| `Completed in` | – | yes | – | idle |
| `Message · Enter send` | – | yes | – | idle |
| `tok/s` | – | **yes** | yes | **rejected** |
| `Ask Mcode to do anything` | **yes** | **yes** | **yes** | **rejected** |

`tok/s` looked like a working signal and is not: it also appears inside
`Completed in 3s · ⚡ 667 tok/s`, a turn that has **finished**. Using it would have
reported every completed session as working — the exact stale-lie the watcher exists
to prevent. `Ask Mcode to do anything` is the input placeholder and appears in every
snapshot, so it discriminates nothing.

## `stale-scrollback.txt` is constructed, and why

No single capture had a stale spinner in scrollback: a turn's status line is
rewritten as it runs, so a clean completion leaves nothing behind. But a turn that
errors, is interrupted, or is compacted does, and matching the whole snapshot would
then report `working` forever.

So this file is a **constructed composite**, not a single `herdr` read: the real
`working.txt` followed by a separator line and the real `idle-after-working.txt`. It
reproduces exactly the property that matters — a working marker present in the file
but absent from the live tail. It is labelled as constructed here and the case that
uses it (`stale-scrollback-is-idle`) is what forces `classify()` to read only the
tail. Replacing it with a genuine single read of an interrupted turn would be better;
it could not be produced in this session.

## Not captured: `blocked`

There is no `blocked` fixture and the watcher never reports `blocked`. mcode 0.6.2 runs
these sessions at `Full access`, where no permission prompt is raised, and permission
level is a session setting rather than a CLI flag (`mcode --help` exposes no
permission option), so no snapshot of that state could be produced without guessing.

A `blocked` rule that never fires is a lie in the code, so the gap is documented in
the watcher instead, and `not-mcode.txt` pins the behaviour that an unmatched screen
reports `unknown` rather than inventing `blocked`.
