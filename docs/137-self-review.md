# Self-review — expose the flock Stop hook install as an action (#137)

Branch `install-flock-stop-action`, off `jaaacki/herdr-plugin-minimax-code` @ `ccf7578`.
Register entry: [sparkfn/pc-tools#1811](https://github.com/sparkfn/pc-tools/issues/1811).

## What this does

Adds `minimax-code-install-flock-stop` and `minimax-code-uninstall-flock-stop` to
`herdr-plugin.toml`, and four cases — one of them red-first for this change.

## The defect, and why the suite was green through it

#136 merged `flock-stop-plugin/` **and** the dispatcher arms that install it
(`install-flock-stop`, `uninstall-flock-stop`, `install-all`) **and** a suite proving
every arm works. What it could not do was reach them: the manifest declared no
action invoking any of the three.

So every existing case passed and the hook was still unreachable on every machine.
The parts were correct; the join was missing. Nothing in the file referenced
`herdr-plugin.toml`, so it could be empty of these actions and the suite had nothing
to say.

Measured on a real machine: no flock Stop hook in `~/.minimax/plugins`, a member able
to end a turn with unread mail, and no signal that this was why.

## Why two actions, not a change to `install-hook`

Folding flock-stop into `minimax-code-install-hook` would make `uninstall-hook` remove
a plugin from a machine that only ever asked for the session hook, and would change
the meaning of an action users have already run. Explicit and reversible beats
convenient.

## Red-first, verified rather than asserted

Reverting `herdr-plugin.toml` to `origin/main` and re-running:

```
FAIL manifest-exposes-the-flock-stop-actions
24 case(s), 1 failed
```

One red, twenty-three green. Restored: `24 case(s), all passed`. The asymmetry IS the
bug — a suite that proves components work is not a suite that proves something can
reach them.

## The other three cases, and what they were for

Every pre-existing case runs `$HOOK`: the copy **in this checkout**. The file mcode
executes is a different file on disk — `cp -R`'d into `~/.minimax/plugins/flock-stop/`
and `chmod +x`'d by the installer — and nothing ran it.

- `installed-hook-runs-the-verb-as-three-words` — `flock hook stop` is three words,
  and getting it wrong is silent: the verb is resolved by first token, so a bad lookup
  stands down instead of failing. The shared `fake-pc-tool` exits 64 on the wrong
  words, which the hook reads as "pc-tool failed" and fails **open** on — so a
  regression there would surface only as a missing block, and the assertion would be
  reading a symptom. The new stub records argv instead, so a failure names which word
  moved, and the case also asserts the argument count is exactly 3.
- `installed-hook-blocks-with-unread-mail` — the installed copy turns unread mail into
  the decision mcode honours. The whole feature, proven on the artifact that ships.
- `install-flock-stop-is-idempotent` — install twice into one home. The only place
  `cmd_install_hook`'s replace branch can fire.

## Honest limits

- The suite needs `jq`, already true before this change.
- Nothing here installs anything on any real machine. Installing on a given machine is
  that owner's call, so no case and no step touched `~/.minimax`.
- `cmd_install_hook` was **not** changed. It already parameterises plugin name, source
  directory and script-to-chmod, and already replaces rather than merges.

## Left alone deliberately

- The fail-open design of `flock-stop.sh`. A hook that wedges an agent traps it, and a
  missed nudge costs one round trip. Documented and correct.
- The `#1811` residual findings in pc-tools (empty-reason refusal, silent cap
  exhaustion). They belong to `pc-tools` and stay registered there.