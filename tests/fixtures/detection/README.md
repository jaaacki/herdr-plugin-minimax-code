# mcode detection snapshots — captured real screens

These are the inputs `bin/mcode-watch.sh` classifies. Nothing here is invented:
each file is real output from a real `mcode` or non-mcode pane, and every rule in
the watcher was read out of these files rather than assumed.

Captured **2026-10-04** (~05:20–05:40 +0800) and **2026-10-05** (~13:05 +0800) against
**herdr 0.9.3** (`~/.local/bin/herdr`), mcode **v0.6.2** (`~/.minimax-code/bin/mcode`).

**One kind of edit was made after capture**, and it is the only one: the operator's
real home directory inside the captured screen text is rendered `~/…`. This applies to
`not-mcode.txt` and to the four `*-task-list-footer*.txt` captures below, whose
scrollback quoted absolute paths like `/Users/<operator>/.adaai/…`. Note that herdr
already shortens the *status line's* cwd to `~/…` in detection reads; it is the
paths inside the scrolled-back conversation text that needed the edit, so the scrub
is a substitution inside otherwise-untouched captures. These files ship inside the
public release tarball. The pane ids, the screen
contents and every classification in the table below are exactly as captured.
`tests/fixtures/agent-detection/` holds an older subset of these captures, under the
same scrub rule; it is the input to the shipped screen-manifest check and is not kept
in sync with this directory (it has no `working-with-tasks-chip.txt` either).

| File | Exact capture command | Pane | Classified |
|---|---|---|---|
| `idle.txt` | `herdr pane read wZ:p1A --source detection --lines 40` | `wZ:p1A` — fresh session, never used | `idle` |
| `working.txt` | `herdr pane read wZ:p5 --source detection --lines 40` | `wZ:p5` — another member's live busy session | `working` |
| `idle-after-working.txt` | `herdr pane read wZ:p1A --source detection --lines 40` | `wZ:p1A` — after `herdr pane run wZ:p1A "reply with the single word ok"` completed | `idle` |
| `not-mcode.txt` | `herdr pane read wZ:p1 --source detection --lines 40` | `wZ:p1` — a `claude` pane, not mcode at all | `unknown` |
| `stale-scrollback.txt` | **constructed**, see below | — | `idle` |
| `working-with-tasks-chip.txt` | `herdr pane read wZ:p2W --source detection --lines 40` | `wZ:p2W` — a pane with a background task in flight | `working` |
| `idle-with-task-list-footer.txt` | `herdr pane read wT:p7Y --source detection --lines 40` | `wT:p7Y` — idle at a `Message · Enter send` prompt, task list above it | `idle` |
| `idle-with-task-list-footer-2.txt` | `herdr pane read wT:p81 --source detection --lines 40` | `wT:p81` — same shape, second pane, second session | `idle` |
| `working-with-task-list-footer.txt` | `herdr pane read wT:p7Z --source detection --lines 40` | `wT:p7Z` — mid-turn, spinner on the status line, task list above it | `working` |
| `working-with-task-list-footer-2.txt` | `herdr pane read wT:p82 --source detection --lines 40` | `wT:p82` — same shape, second pane, second session | `working` |

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

**Read that title as "three as of 2026-10-04", not as a count.** The 13:05 captures
in this directory turned up two more resting shapes — an idle screen carrying a task
list, and an idle screen with a drafted message — and the first of those exposed a
real working/idle misclassification. The count of mcode's resting shapes is not
three, and is probably not closed. See `Ctrl+T expand` below.

## Markers, and the three that were rejected on the evidence

Checked against all the real mcode snapshots:

| Marker | fresh idle | after a turn | idle + task list | working | verdict |
|---|---|---|---|---|---|
| `Esc stop` | – | – | – | yes | working |
| `Ctrl+O details` | – | – | – | yes | working |
| `Ctrl+T expand` | – | – | **yes** | **yes** | **rejected** |
| `Start · @` | yes | – | – | – | idle |
| `● Ready` | yes | – | – | – | idle |
| `Completed in` | – | yes | yes | – | idle |
| `Message · Enter send` | – | yes | yes | – | idle |
| `tok/s` | – | **yes** | **yes** | yes | **rejected** |
| `Ask Mcode to do anything` | **yes** | **yes** | **yes** | **yes** | **rejected** |

`tok/s` looked like a working signal and is not: it also appears inside
`Completed in 3s · ⚡ 667 tok/s`, a turn that has **finished**. Using it would have
reported every completed session as working — the exact stale-lie the watcher exists
to prevent. `Ask Mcode to do anything` is the input placeholder and appears in every
snapshot, so it discriminates nothing.

`Ctrl+T expand` was rejected for a different reason, and it is the one marker here
that **shipped as a working rule first**. See the section below.

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

## `working-with-tasks-chip.txt`, and the capture that does not exist

Captured **2026-10-05** from pane `wZ:p2W`, a pane with one background task in
flight. It is the only real capture of the `◐ Tasks · N background active · N result
ready · /tasks details` chip anywhere in this repo, and it is banked because the
chip is a real part of the mcode status area and a future reader should not have to
rediscover its exact text.

It carries the chip **and** `Esc stop` **and** `Ctrl+O details`, and it carries
none of the idle markers. So it classifies `working` — and it classifies `working`
*because of the other two markers*, not because of the chip. The chip is not in
`RULES` at all.

That is the whole finding, and it is why this fixture is pinned for drift rather
than as a contract test. **A chip-alone assertion cannot fail.** Add `◐ Tasks` to
the working table and this capture still classifies `working`, for the reason it
already did. Building a chip-bearing capture that also carried an idle marker —
the only shape that could falsify "the chip does not drag a screen to working" —
would have required editing a real capture into a shape no real pane was ever
observed in, which is a fixture that passes against a fiction.

`bg-resting-raw.txt`, captured from the same pane, was offered as that capture. It
is not: measured, it contains **no `Tasks` line at all**, and its only markers are
`⠇ Loading … ⚡ tok/s … Ctrl+O details · Esc stop`, so it classifies `working` like
the others. The two captures that do exist are a chip-bearing *working* pane and a
chip-less *idle* pane, and they have never been observed together.

So `chip-is-not-a-working-marker` asserts the decision that is actually available
to pin — the chip is absent from `RULES` — and `chip-bearing-screen-classifies-working`
pins the captured shape. Neither pretends to be the chip-alone test the brief asked
for, because that test cannot be written from real captures.

## `Ctrl+T expand`: the rule that shipped and had to come back out

This is the only marker in `RULES` that was **added as a working rule and later
removed on evidence**. It is worth writing down, because the first three shapes
captured on 2026-10-04 could not have found the bug, and the reason reads like the
marker is genuinely a working signal.

`Ctrl+T expand` is part of mcode's **task-list footer**:

```
    … +5 more · 7/8 done · 1 pending · Ctrl+T expand
```

The footer is a **resting** shape. The task list does not disappear when the turn
ends — it stays on screen, above the input box, and it stays inside the 8-line tail
`classify()` reads. So an idle prompt that still has a task list looks like this:

```
    … +5 more · 7/8 done · 1 pending · Ctrl+T expand     <- footer, still there
    Message · Enter send · Shift+Enter newline           <- idle status line
```

Working rules are tested before idle, so the footer won the screen and the watcher
reported `working` for a session sitting at an idle prompt. The four captures below
were taken on **2026-10-05 ~13:05** from four panes in workspace `wT` precisely to
show this, two of each shape.

| capture | screen | classified before the fix | after |
|---|---|---|---|
| `idle-with-task-list-footer.txt` | `Message · Enter send`, task list | `working` ❌ | `idle` |
| `idle-with-task-list-footer-2.txt` | same shape, second pane | `working` ❌ | `idle` |
| `working-with-task-list-footer.txt` | spinner + `Esc stop`, task list | `working` ✅ | `working` |
| `working-with-task-list-footer-2.txt` | same shape, second pane | `working` ✅ | `working` |

**Nothing was lost by removing it.** Every captured *working* screen — all four of
them here, plus `working.txt` — also carries `Esc stop` on the live status line, and
that is what now detects working. The footer added no coverage that `Esc stop` did
not already provide, and it was actively wrong on the idle side. Pinned by
`ctrl-t-expand-is-not-a-working-marker`, which reads `RULES` rather than a
classification, because the decision itself is the thing worth making deliberate.

Note the shape of the mistake, since it is the same one the other two rejections
record: the marker was read out of a *working* capture, where it appears, and never
checked against an idle capture that has a task list. `Esc` and `tok/s` were caught
before shipping. This one shipped, and only a fresh pair of idle captures found it.

### The fifth capture in that batch, and why it is not banked

The same 13:05 batch produced one more screen, from pane `wT:p70`. It is
deliberately **not** in this directory, for two independent reasons.

1. **It exposes a different, still-open defect.** It is an idle screen in a *third*
   resting shape — the input box reads `Long draft · Ctrl+G edit · Enter send`
   rather than `Message · Enter send`, and there is no `Completed in` line inside
   the tail. No marker in `RULES` matches it, and running the watcher against it
   reports `unknown`, not `idle`. That is a real miss, but it is a **separate issue**
   from removing a working marker, and fixing it here would mean adding a new idle
   marker on the strength of one capture.
2. **It is not this repo's content to publish.** Its scrollback is another session's
   private correspondence, including a verbatim assignment message addressed to a
   different teammate. The four banked captures quote only file paths. This one
   would put a third party's message text into a public release tarball.

Filed as an observation for the epic rather than actioned under #83.
