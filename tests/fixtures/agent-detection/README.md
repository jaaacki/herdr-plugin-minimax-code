# Captured mcode screens behind `agent-detection/minimax-code.toml`

Every rule in that manifest was read out of these files. Nothing in it is imagined.
The captures are verbatim except for one home path in `not-mcode.txt`, recorded below.

The captures are the same ones the watcher in `bin/mcode-watch.sh` classifies against
(issue #35, `tests/fixtures/detection/`), re-stated here so the manifest and its
evidence travel together as one self-contained unit for the upstream contribution in
issue #37. They are the same bytes, copied — not a second capture.

Captured **2026-10-04** (~05:20–05:40 +0800) against **herdr 0.9.3**
(`~/.local/bin/herdr`), **mcode v0.6.2** (`~/.minimax-code/bin/mcode`).

**One edit was made after capture**, and it is the only one: `not-mcode.txt` contained
the operator's real home directory inside the captured screen text, so that path is now
rendered `~/…`. The file ships inside the public release tarball, and a real person's
home directory does not belong in one. Nothing else changed — not the pane ids, not the
screen contents, and not the classification each file is evidence for. The published
v0.3.0 asset still carried this path, so the statement above is now true of the prose
and true of the captures instead of true of only one of them.

This is stated rather than done quietly: a capture that has been edited without saying
so is worth less than one that never needed editing, and the honest note is cheaper
than the doubt it prevents.

| File | Exact capture command | Pane | What it shows |
|---|---|---|---|
| `working.txt` | `herdr pane read wZ:p5 --source detection --lines 40` | `wZ:p5` | genuinely busy; carries the live status strip |
| `idle.txt` | `herdr pane read wZ:p1A --source detection --lines 40` | `wZ:p1A` | fresh session, never used — the start prompt |
| `idle-after-working.txt` | `herdr pane read wZ:p1A --source detection --lines 40` | `wZ:p1A` | a turn that has finished — the composer |
| `stale-scrollback.txt` | **constructed**, see below | — | finished work still in the scrollback |
| `not-mcode.txt` | `herdr pane read wZ:p1 --source detection --lines 40` | `wZ:p1` | a `claude` pane, not mcode at all |
| `reference-claude.toml` | **copied** from herdr's manifest cache, see below | — | a real herdr manifest; the specification our keys are checked against |

`wZ:p1A` was created for this work and closed after capture. `wZ:p5` and `wZ:p1` belong
to other flock members; only their screens were read, never their state.

## `reference-claude.toml` is a different kind of fixture

The five `.txt` files are captures *we* took. `reference-claude.toml` is a copy of a
manifest **herdr ships**, and it is the only file in this directory that is not
evidence for a rule — it is the spec the rules are measured against.

It is vendored rather than read from disk because the first version of the checker
read it from `~/.local/state/herdr/agent-detection/remote/claude.toml`.
That path exists on exactly one machine, so the suite passed here and failed on both
CI legs with a `FileNotFoundError` naming somebody's home directory.

| | |
|---|---|
| source | `~/.local/state/herdr/agent-detection/remote/claude.toml` |
| sha256 | `038d0aa23fee3f9b39cb3c9ca117d0f95b0b3a5873cf0f38284ccbac279c9664` |
| herdr | 0.9.3 |
| captured | 2026-10-04 07:11 +0800 |
| declares | `version = "2026.09.11.1"`, `updated_at = "2026-09-11T00:00:00Z"` |

It is a **trimmed** copy: herdr's `claude.toml` has 16 rules, this keeps 4. The
top-level block and all 4 kept rules are byte-identical to the source, comments
included. The 4 were chosen because the union of their keys is the union of the keys
over **all 16 of herdr's rules and all 22 manifests in that cache** — the same 14 —
so nothing is lost by the cut. The file's own header carries that measurement, the
command to re-derive it, and the reason a wrong trim here fails red rather than
green.

`tests/agent-detection-check.py` **derives** the allowed key set from this file. It
used to load it and then compare against a hand-copied constant list, which is the
same check with the reference bolted on decoratively.

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
