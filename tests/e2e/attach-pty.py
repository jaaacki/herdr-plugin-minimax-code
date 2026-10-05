#!/usr/bin/env python3
"""Attach a herdr client to a named session, inside a pty, for N seconds.

WHY THIS EXISTS. Proving that herdr restarts a pane and runs its resume command
needs a CLIENT CONNECTED. That is not a convenience, it is a hard requirement in
herdr's own code: `pending_agent_resume_candidates` returns an empty list while
the terminal area is 0x0 (src/app/agent_resume.rs:99), and a headless server with
no client is exactly that. Measured on herdr 0.9.3 — restart a session with no
client, wait, and the panes come back as plain shells with the resume silently
skipped and nothing logged. Without this helper the resume test passes by
never running the thing it claims to test.

WHY python3 AND NOT `script`. `script(1)` is not one interface. BSD (macOS) takes
the command as a positional argument; util-linux (Ubuntu) documents `-c/--command`
and only grew positional-command support late. This suite runs on both runners,
so `script -q /dev/null herdr ...` and `script -q -c 'herdr ...' /dev/null` each
break on one of them. `pty` is in the standard library of the python3 both runners
already have, and it also lets us set the window size — which `script` will not do
for us, and without a non-zero size the client refuses to attach at all
("terminal reported a zero-sized grid").

The window size is not decoration either: it is what gives the server a non-zero
terminal area, which is the thing the resume path is gated on.

NESTED HERDR. This must run with HERDR_ENV cleared. Inside a pane of the owner's
herdr, a second herdr client refuses to start ("nested herdr is disabled by
default"), so `env -u HERDR_ENV` at the call site is required, not optional.

usage: attach-pty.py <rows> <cols> <seconds> <command> [args...]
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


def main() -> int:
    if len(sys.argv) < 5:
        sys.stderr.write(__doc__ or "")
        return 2
    rows, cols, seconds = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
    argv = sys.argv[4:]

    # Clear the inherited pane identity. See NESTED HERDR above.
    for name in ("HERDR_ENV", "HERDR_PANE_ID", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID"):
        os.environ.pop(name, None)

    pid, fd = pty.fork()
    if pid == 0:  # child
        os.execvp(argv[0], argv)
        os._exit(127)

    # Size the pty BEFORE the client can measure it, and before the server sees
    # any resize from it.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        # Drain, or the pty buffer fills and the client blocks on write.
        try:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                if not os.read(fd, 65536):
                    break
        except OSError:
            break

    # The client is a full-screen TUI; it does not read a quit key from us, and
    # leaving it running would hold the session open after the test is done.
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass
    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
