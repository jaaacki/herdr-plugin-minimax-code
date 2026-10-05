#!/usr/bin/env bash
# no-private-path-run.sh - no home directory in anything the release ships (#106).
#
# release.yml refuses an artifact containing /Users/<name> or /home/<name>, but
# only at tag time, so a path that entered in a PR surfaced at the last step of
# v0.5.0. This runs the same check on every PR through the CI glob.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

# The release.yml allowlist. Keep in step with its `git archive` path list.
shipped=(herdr-plugin.toml bin agent-detection README.md LICENSE CLAUDE.md tests)

hits="$(grep -rInE '/(Users|home)/[A-Za-z0-9._-]+' "${shipped[@]}" \
  --exclude=no-private-path-run.sh 2>/dev/null || true)"
if [ -n "$hits" ]; then
  printf 'FAIL  no-home-path-in-shipped-files\n%s\n' "$hits"
  printf -- '---\n1 case(s), 1 failed\n'
  exit 1
fi
printf 'ok    no-home-path-in-shipped-files\n---\n1 case(s), all passed\n'
