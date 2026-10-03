# tests/fixtures/session — a mcode session store

**These are not captures, and cannot be.** Every other fixture in this repo is a
real herdr response recorded live (issue #7). These are mcode's own session
manifests, and no real one of them can exist for the purpose these tests need.

## Why there is no capture to take

`bin/mcode-session.sh` resolves a session by cwd: it looks for the manifest that
records *this pane's* directory. That lookup cannot be exercised against reality,
because mcode's manifest has no `cwd`.

Verified 2026-10-04 against every live session on the development machine. All
manifests carry exactly these seven keys and no others:

```
createdAtMs, layout, paths, schemaVersion, sessionId, source, updatedAtMs
```

There is no `cwd`, no `workspace`, no pid and no pane id, and no session-id
variable exists in a pane's environment. The two alternative discriminators were
measured and are unusable: `.mcode-active/<pid>.json` holds only `pid` and
`startedAtMs`, and correlating those against the store gave 19 live pids against
9 sessions with offsets from +47s to −37 minutes, many pids collapsing onto a
single session.

So the fixtures below are **constructed from that documented real key set**:
the seven keys are verbatim, the values are synthetic. Every manifest here has
that exact seven-key set and no `cwd`, which is precisely what makes the store a
faithful stand-in for a real one.

This is a deliberate, recorded departure from the real-captures-only rule, and
the reason is not convenience. A store containing a `cwd` is the *only* way to
prove the resolver works, and a store without one is the only way to prove it
invents nothing when it cannot resolve. Both halves are fabricated in the same
way; the difference is which key set each one carries.

## The one fixture that is not a static file

`resolve` is called with a cwd that only exists at run time — the per-case
sandbox — so a cwd-bearing manifest **cannot** be a static file: its `cwd` value
could never match. The `resolve-matching-cwd` case therefore generates one
manifest per run from the documented schema, into a copy of the store below.
That is stated here rather than quietly shipped as a file that could not work.

## Layout

| path | role |
|---|---|
| `v2/sessions/2026/10/04/12-00-00-000-session_A/manifest.json` | newest session in the winning store; `updatedAtMs` 1791059999999 |
| `v2/sessions/2026/10/04/12-00-00-000-session_B/manifest.json` | older session, same store; `updatedAtMs` 1791050000000 |
| `v1/sessions/2026/10/01/09-00-00-000-session_C/manifest.json` | legacy `layout: v1-legacy`, `updatedAtMs` 1000000000000 |

`v1` exists to be **lost**. Its `updatedAtMs` is an order of magnitude lower, so
any implementation that ranks versioned stores by the manifests' own timestamps
picks `v2`. This is the regression guard for the `stat -f '%m'` that was removed:
that call is BSD-only, and on GNU `-f` means "filesystem", so it silently picked
the wrong store on every Linux runner. Ranking by mtime instead of
`updatedAtMs` also picks `v2` here — which is why one case swaps the two
stores' timestamps to make the two strategies disagree.

The session ids are `mvs_` plus 32 hex-ish characters, matching the shape
observed in live sessions. They are values, not captures.
