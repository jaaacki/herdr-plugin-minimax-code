# `tests/e2e/fixtures/` — real captures only

Everything in this directory is a **verbatim capture off a running herdr**. Nothing
here is hand-written, synthesised, or tidied up. If you cannot name the commands
that produced a file, it does not belong in this directory.

## `session-snapshot-agent-resume.json`

A herdr `0.9.3` session snapshot, copied byte-for-byte out of
`~/.config/herdr/sessions/flock85cap3/session.json` on 2026-10-05 (macOS 27.0.0
arm64, `~/.local/bin/herdr`).

Produced in a **named** session, so the machine's real herdr was never started,
stopped or reconfigured:

```bash
W=/tmp/flock85-cap3
mkdir -p "$W/bin"                 # a stub `mcode`: print, then sleep, so the pane stays alive
S=flock85cap3
herdr --session "$S" server </dev/null &
herdr --session "$S" workspace create --cwd "$W"
P=$(herdr --session "$S" pane list | jq -r '.result.panes[0].pane_id')     # w1:p1
herdr --session "$S" pane run "$P" "$W/bin/mcode"
herdr --session "$S" pane report-agent "$P" \
        --source herdr:minimax-code --agent mcode --state unknown
herdr --session "$S" pane report-agent-session \
        --source herdr:minimax-code --agent mcode "$P" -- mcode --continue
sleep 9                            # herdr debounces session saves by 5s
cp ~/.config/herdr/sessions/$S/session.json session-snapshot-agent-resume.json
herdr --session "$S" server stop && herdr session delete "$S"
```

### What it is the evidence for

Two things, and the second is the bug.

1. `agent_resume` **is** persisted, for a reporter whose agent kind herdr does not
   enumerate:

   ```json
   "agent_resume": { "source": "herdr:minimax-code", "agent": "mcode",
                     "argv": ["mcode", "--continue"] }
   ```

2. `agent_session` is **absent from the same document**, even though
   `pane report-agent-session` exited 0. The old read-back checked that field and
   so reported "nothing was stored" about a write that was stored — the whole of
   issue #85.

### NOTHING READS THIS FILE, and that is deliberate

It is here as the record of where that knowledge came from, not as a test input.
An earlier version of this work seeded the read-back from it; that read-back was
then removed, because herdr debounces session saves by five seconds and a check
that reads the file while a launch is in flight reports the resume absent almost
every time. A fixture that a test consults implies the test could fail; this one
cannot, and pretending otherwise would be worse than not having it.

If you want the persistence claim under test, it is proven against a live herdr
instead: `resume: a restart re-runs the recorded resume command in the recreated
pane` in `../run.sh` stops the server, starts it again, attaches a client, and
asserts the command ran in the recreated pane. That is the only assertion which
cannot be faked from a file, which is the reason the e2e suite exists and refuses
to skip when herdr is missing.

### Why the `cwd` still reads `/private/tmp/flock85-cap3`

It is where the capture was made, and it is left exactly as captured. Do not
"tidy" it into something that looks like the sandbox: the read-back matched on the
reporter tuple — `source` + `agent` + `argv` — and never on `cwd`, precisely
because herdr stores a *resolved* path while `pwd` in a pane is the shell's
*logical* one, and on macOS `/tmp` is a symlink to `/private/tmp`.

### What this file cannot prove

That herdr *runs* the command after a restart. A snapshot proves the write landed.
Only a real `server stop` → `server` → client attach can prove the restore.

### If you need to re-capture

Change the session name, the temp dir, and nothing else. Do not edit the JSON: the
point of a real capture is that nobody tidied it up, and the read-back parses
exactly this shape.
