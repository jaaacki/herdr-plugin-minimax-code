# mcode detection snapshots — captured real screens

These are the inputs `bin/mcode-watch.sh` classifies. Nothing here is invented:
each file is real output from a real `mcode` or non-mcode pane, and every rule in
the watcher was read out of these files rather than assumed.

Captured **2026-10-04** (~05:20–05:40 +0800) and **2026-10-05** (~13:05 +0800) against
**herdr 0.9.3** (`~/.local/bin/herdr`), mcode **v0.6.2** (`~/.minimax-code/bin/mcode`).

**Captures from panes this plugin does not own are banked TAIL-ONLY.** The repo is
public and these files ship in the release tarball, so a full 40-line snapshot of
someone else's pane is not ours to publish: their scrollback carries their private
work — issue and PR numbers, incident write-ups, file paths, in-flight diagnoses.
The rule for such a capture is:

1. **Keep only the live tail.** The last 10 non-blank lines, a superset of the 8
   non-blank lines `classify()` reads (`TAIL_LINES=8`). Every marker a case depends
   on must survive inside the classifier's own 8 lines, or the case cannot fail and
   the fixture is decoration.
2. **Withhold private text inside even that tail.** Task titles are the author's own
   words, so they are private too: the title's *words* become `[redacted]` and its
   glyphs (`✓ ● ○ │ └`) are kept, so a reader can still see it was a task entry and
   not a marker. The same applies to the cwd segment of the status strip.
3. **Record both edits** in the provenance row, per file.

Redaction is applied by an allow-list of *structural* shapes — the footer, the Tasks
chip, the live status lines, box rules, the composer placeholder, the strip — and
anything not on that list is redacted by default. Default-deny, because a line shape
nobody has classified must be reviewed by a human rather than published by omission.

**One edit was made after capture** in the older files, and it is the only one:
`not-mcode.txt` contained the operator's real home directory inside the captured
screen text, now rendered `~/…`. These files ship inside the public release tarball.
The pane ids, the screen contents and every classification in the table below are
exactly as captured, except where a row records that the capture is tail-only.
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
| `idle-with-task-list-footer.txt` | `herdr pane read wT:p7Y --source detection --lines 40` | `wT:p7Y` — idle at a `Message · Enter send` prompt, task list above it. **tail-only**: last 10 non-blank lines of the 40-line capture; scrollback withheld (third-party private content); task titles within the tail replaced with `[redacted]` | `idle` |
| `idle-with-task-list-footer-2.txt` | `herdr pane read wT:p81 --source detection --lines 40` | `wT:p81` — same shape, second pane. **tail-only**, as above | `idle` |
| `working-with-task-list-footer.txt` | `herdr pane read wT:p7Z --source detection --lines 40` | `wT:p7Z` — mid-turn, spinner on the live status line, task list above it. **tail-only**, as above | `working` |
| `working-with-task-list-footer-2.txt` | `herdr pane read wT:p82 --source detection --lines 40` | `wT:p82` — same shape, second pane. **tail-only**, as above | `working` |
| `idle-empty-composer.txt` | `herdr pane read w1S:p1 --source detection --lines 40` | `w1S:p1` — **launched by this work for this capture**, fresh session, composer empty. **tail-only**: blank lines stripped, all 5 non-blank lines retained (they all fall inside the classifier's 8-line window) | `idle` |
| `idle-with-single-line-draft.txt` | `herdr pane read w1S:p1 --source detection --lines 40` | same pane, minutes later, one line of text typed and **not** submitted | `idle` |
| `idle-with-multi-line-draft.txt` | `herdr pane read w1S:p1 --source detection --lines 40` | same pane, same session, three lines of text typed and not submitted | `idle` |
| `working-with-composer-text.txt` | `herdr pane read w1S:p1 --source detection --lines 40` | same pane, same session, a turn **in flight** with text typed into the composer mid-turn | `working` |
| `working-with-multiline-composer.txt` | `herdr pane read w1T:p1 --source detection --lines 40` | `w1T:p1` — a second pane launched by this work, a turn **in flight** with a **three-line** draft typed into the composer. **tail-only**: last 10 non-blank lines | `working` |

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
turned up two more resting shapes — an idle screen carrying a task list, and an idle
screen with a drafted message — and the first of those exposed a real
working/idle misclassification. The count of mcode's resting shapes is not three, and
is probably not closed. See `Ctrl+T expand` below.

## Markers, and the three that were rejected on the evidence

Checked against all the real mcode snapshots:

| Marker | fresh idle | after a turn | idle + task list | unsent draft | working | verdict |
|---|---|---|---|---|---|---|
| `Esc stop` | – | – | – | – | yes | working |
| `Ctrl+O details` | – | – | – | – | yes | working |
| `Ctrl+T expand` | – | – | **yes** | – | **yes** | **rejected** |
| `Start · @` | yes | – | – | – | – | idle |
| `● Ready` | yes | – | – | – | – | idle |
| `Completed in` | – | yes | yes | yes † | – | idle |
| `Enter send` (the shared suffix) | – | yes | yes | yes § | – | idle |
| `Message · Enter send` (one shape) | – | yes | yes | – ‡ | – | idle |
| `Prompt · Enter send` (one shape) | – | – | – | yes ¶ | – | idle |
| `Long draft · Ctrl+G edit · Enter send` (one shape) | – | – | – | yes ρ | – | idle |
| `tok/s` | – | **yes** | **yes** | – | yes | **rejected** |
| `Ask Mcode to do anything` | **yes** | **yes** | **yes** | – ‡ | **yes** | **rejected** |

† present only when the last turn's completion line is still inside the tail, and
it scrolls out at 5+ draft lines — so it is not a reliable draft marker.
‡ the composer hint and the placeholder are *replaced* by the draft text, which is
the whole mechanism; see the composer section below.
§ all three hint texts end in it — one line of text, two or more, or an empty
composer after a turn — and only while the hint is still inside the tail.
¶ one line of text only. ρ two lines or more, and only while the hint is still
inside the tail. Both are subsumed by the row above, which is why the table
carries one rule and not three.

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

All four are **tail-only** banked captures, under the rule at the top of this file:
pane `wT:p7Y` and the three panes beside it belong to another team, so each file is the
last 10 non-blank lines of a 40-line read, with that team's task titles and cwd
withheld as `[redacted]`. Nothing else was changed — the footer, the Tasks chip, the
live status line, the composer and the status strip are exactly as captured.

**Nothing was lost by removing the rule.** Every captured *working* screen — all four
of them here, plus `working.txt` — also carries `Esc stop` on the live status line, and
that is what now detects working. The footer added no coverage that `Esc stop` did not
already provide, and it was actively wrong on the idle side. Pinned by
`ctrl-t-expand-is-not-a-working-marker`, which reads `RULES` rather than a
classification, because the decision itself is the thing worth making deliberate.

Note the shape of the mistake, since it is the same one the other two rejections
record: the marker was read out of a *working* capture, where it appears, and never
checked against an idle capture that has a task list. `Esc` and `tok/s` were caught
before shipping. This one shipped, and only a fresh pair of idle captures found it.

### The fifth capture in that batch, and why it is not banked

The same 13:05 batch produced one more screen, from pane `wT:p70`. It is
deliberately **not** in this directory, for two independent reasons.

1. **It is not this repo's content to publish.** It is a third team's private
   correspondence, and tail-only truncation would not save it: the unsent draft
   *is* the defect, so the tail-only rule and a usable fixture pull in opposite
   directions here. The right answer is a capture from a pane the plugin owns —
   which is what the next section did.
2. Reading it did pay off, though: its composer read `Long draft · Ctrl+G edit ·
   Enter send`, which is the hint for a **multi-line** draft. That is a different
   state from the one-line draft, and it is why the fix below needs two markers
   rather than one. The shape is reproduced in `idle-with-multi-line-draft.txt`,
   captured from a pane this work owns.

## The composer has three hint texts, not one — `wT:p70`'s real lesson

Issue #91 assumed the composer hint simply *disappears* when the composer has
content. It does not. It is **replaced**, with a different string each time the
composer changes shape. All four states below were captured on **2026-10-05
~13:4x** from `w1S:p1`, a pane launched by `herdr workspace create` and
`herdr pane run w1S:p1 "$(command -v mcode)"` for exactly this purpose:

```
empty, fresh session    Start · @ file or Plugin · / autocomplete
empty, after a turn     Message · Enter send · Shift+Enter newline
ONE line of text        Prompt · Enter send · Shift+Enter newline
TWO lines or more       Long draft · Ctrl+G edit · Enter send
```

The consequence is the bug: typing into the composer removes the only idle
marker the tail had (`Start · @` on a fresh session) and substitutes one of its
own, and the old table knew neither of the new strings. An unsent draft reported
`unknown`.

That is not cosmetic. An unsent draft is exactly what a failed doorbell leaves
behind, so this is a state an operator will actually hit.

### The two new rules cannot match a working screen, and that is measured

The obvious way to break this is that mcode lets you type **into the composer
while a turn is running** — the working status line advertises `Enter steer`. If
the hint appeared there, a composer marker would report a running turn as idle.

Captured, it does not. Two banked screens, both mid-turn with text in the
composer:

`working-with-composer-text.txt` — one line typed:

```
    ⠦ Loading 4s · Option+Enter queue · Enter steer · Ctrl+O details · Esc stop
    ────────────────────────────────────────────────────────────────────────
  ›  text typed into the composer while the turn runs
```

`working-with-multiline-composer.txt` — **three** lines typed, which is the shape
that matters, because a multi-line composer is what makes mcode want to print
`Long draft … Enter send` at all:

```
    ⠼ Loading 1s · Option+Enter queue · Enter steer · Ctrl+O details · Esc stop
    ───────────────────────────────────────────────────────────────────────────
  ›  typed during a running turn
     second line of steering text
     third line of steering text
```

Neither contains `Enter send` anywhere in its tail. While a turn is in flight the
status line occupies the hint's row and the composer renders as bare prompt
lines.

**One rule, not three: `idle|Enter send`.** The leading noun changes with the
composer's shape (`Message` / `Prompt` / `Long draft`) and the trailing
affordance does not, so the suffix is the string that survives all three. A
marker's job is to survive, not to name a shape — three specific rules would need
a fourth the next time the noun changes. It is still a **phrase**: a bare `Enter`
would match `Option+Enter queue` on every working screen, which is the same
mistake as bare `Esc` matching mcode's own changelog prose on a captured idle
screen.

Across every captured screen the split is clean — `Enter send` in the idle tails,
`Enter steer` in the working ones, never both, and never in the non-mcode pane:

| | `Enter send` | `Enter steer` |
|---|---|---|
| idle captures (5, incl. both task-list ones and the composite) | yes | – |
| fresh-idle with an empty composer | – | – (matched by `Start · @`) |
| working captures (6) | **–** | yes |
| `not-mcode.txt` (a `claude` pane) | – | – |

Proven by mutation: hoisting `idle|Enter send` **above every working rule** leaves
all 28 cases green, including both working-with-composer cases. So the rule is
idle-only by *content*, not by table order — the opposite of the `Ctrl+T expand`
situation, where the ordering was the entire bug. `enter-send-covers-every-composer-hint`
stops it being "simplified" back to a single hint's noun.

### Rejected: the composer's `›` prompt line

The obvious marker to reach for, and rejected on the same evidence discipline as
bare `Esc` and `tok/s`. It is on **every** mcode screen, idle and working alike,
`›` is a generic glyph, and it is precisely what would be needed to cover the gap
below. It happens to be absent from the one captured non-mcode pane — but one
sample is not evidence that no other pane carries it, and reporting a foreign
pane as an idle mcode session is worse than reporting it `unknown`. Pinned by
`composer-prompt-is-not-a-working-marker`.

### Known limit, measured rather than guessed

The hint renders **above** the composer, so a draft long enough to push its own
hint out of the 8-line tail matches nothing and still reports `unknown`. Captured
on the same pane by growing the draft one line at a time:

| draft lines | hint in the 8-line tail? | classification |
|---|---|---|
| 1 | yes (`Prompt · Enter send`) | `idle` |
| 3 | yes (`Long draft · Ctrl+G edit · Enter send`) | `idle` |
| 4 | yes (`Long draft · Ctrl+G edit · Enter send`) | `idle` |
| 5 | **gone** | `unknown` |
| 6 | **gone** | `unknown` |

At 5 lines the tail holds only `›` lines, box rules and the status strip. Closing
this needs a marker on one of those, and the only candidate is the rejected `›`
above, so it is documented rather than papered over. Raising `TAIL_LINES` would
move the boundary but is a global change to every fixture's window, not this
issue's call.
