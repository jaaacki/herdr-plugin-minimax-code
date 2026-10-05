#!/usr/bin/env bash
# no-trash-run.sh - every delete in bin/ and tests/ must call /bin/rm.
#
# MiniMax Code puts ~/.minimax/shims/rm ahead of /bin/rm on its agent's PATH and
# routes it to mavis-trash, so under an mcode agent a bare `rm` sends each test
# sandbox to the system Trash, one audible item at a time (#109). The paths we
# delete are ones we created ourselves (mktemp sandboxes, temp files), so they
# are unlinked directly.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fails=0

# A bare rm: `rm` as a command word, i.e. not preceded by a path or name char.
# Comment lines are skipped. This file is excluded: it names the pattern.
bare_rm="$(grep -rnE '(^|[^[:alnum:]_/.-])rm[[:space:]]+-' "$ROOT/bin" "$ROOT/tests" \
  --exclude=no-trash-run.sh --exclude='*.md' --exclude='*.json' --exclude='*.txt' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$bare_rm" ]; then
  printf 'FAIL  bare-rm-is-banned\n%s\n' "$bare_rm"
  fails=$((fails + 1))
else
  printf 'ok    bare-rm-is-banned\n'
fi

trashers="$(grep -rnwE 'trash|mavis-trash' "$ROOT/bin" "$ROOT/tests" \
  --exclude=no-trash-run.sh --exclude='*.md' --exclude='*.json' --exclude='*.txt' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$trashers" ]; then
  printf 'FAIL  no-trash-command\n%s\n' "$trashers"
  fails=$((fails + 1))
else
  printf 'ok    no-trash-command\n'
fi

printf -- '---\n'
if [ "$fails" -eq 0 ]; then
  printf '2 case(s), all passed\n'
else
  printf '2 case(s), %d failed\n' "$fails"
  exit 1
fi
