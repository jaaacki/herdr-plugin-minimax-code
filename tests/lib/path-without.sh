# path_without <basename> - print a PATH in which <basename> is UNREACHABLE.
#
# The reason this exists at all: a shim earlier on PATH would still satisfy
# `command -v <tool>`, so a case that wants to assert "the tool is absent" would
# pass without the tool ever being missing. Mirroring PATH and removing the tool
# is what makes that assertion honest. No shim is involved.
#
# WHY THIS IS A SHARED FILE. There were two byte-different copies of this
# function, in tests/run.sh and tests/drive-run.sh, and they disagreed: run.sh
# skipped a basename it had already linked (FIRST directory on PATH wins) while
# drive-run.sh used `ln -sf` (LAST wins). Only one of those is how PATH itself
# resolves a name. One definition, PATH semantics.
#
# WHY IT MIRRORS SO LITTLE. The previous version symlinked EVERY executable on
# PATH into a fresh directory on every call and returned that directory as the
# ENTIRE PATH: 1,710 files on the maintainer's machine, three calls per full
# suite run. Mutation-checking reruns the suites dozens of times, and that churn
# was visible to the owner. Mirroring only the directories that actually HOLD the
# tool cuts that to 15 files for `mcode` and 931 for `jq` - and the count for
# `jq` cannot go lower, because the tool lives in /usr/bin and every other tool
# in that directory has to stay reachable (the script under test starts with
# `#!/usr/bin/env bash`; a PATH that loses `env` or `bash` fails for a reason
# that looks like a pass).
#
# WHY THE MIRROR GOES WHERE THE FIRST MATCHING DIRECTORY WAS. Not at the front of
# PATH. A front-loaded mirror would silently change which copy wins for any
# basename that also exists in an EARLIER directory: the original PATH resolves
# that name to the earlier copy, a front-loaded mirror resolves it to the later
# one. Taking the first containing directory's position preserves that exactly,
# and 5 such basenames exist for /usr/bin alone on the maintainer's PATH.
#
# bash 3.2 compatible: no [[ ]], no mapfile, no declare -A, no ${var^^}.

path_without() { # path_without <basename>
  local drop="${1:-}"
  if [ -z "$drop" ]; then
    printf 'path_without: a basename is required\n' >&2
    return 1
  fi
  # A mirror written nowhere is worse than no mirror: an empty PATH would make
  # every `command -v` fail, so a "the tool is absent" case would pass for a
  # reason that has nothing to do with the helper.
  local case_dir="${PATH_WITHOUT_DIR:-${CASE_DIR:-}}"
  if [ -z "$case_dir" ]; then
    printf 'path_without: set CASE_DIR (or PATH_WITHOUT_DIR) so there is somewhere to mirror\n' >&2
    return 1
  fi

  local mirror="$case_dir/no-$drop"
  local -a kept=()
  local dir f base placed=0
  mkdir -p "$mirror" || return 1

  # Split PATH on ':' only, for this loop AND for the join at the end. IFS is
  # re-declared locally rather than `unset`: unsetting a `local IFS` drops the
  # local binding and exposes the global one mid-function, which would join the
  # array with a space and hand the caller a PATH with no colons in it. Measured,
  # that emptied PATH entirely and every reachability assertion failed at once.
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    # A PATH entry that is not a readable directory cannot hold the tool, so it
    # is kept verbatim: dropping it would change resolution for unrelated tools.
    if [ ! -d "$dir" ] || [ ! -e "$dir/$drop" ]; then
      kept+=("$dir")
      continue
    fi
    # This directory DOES hold the tool. Mirror its contents minus the tool, and
    # take the directory itself out of PATH so the real copy cannot be found.
    if [ "$placed" -eq 0 ]; then
      kept+=("$mirror")
      placed=1
    fi
    for f in "$dir"/*; do
      [ -e "$f" ] || continue
      base="${f##*/}"
      [ "$base" = "$drop" ] && continue
      # First directory on PATH wins, which is how PATH itself resolves a name.
      [ -e "$mirror/$base" ] && continue
      ln -s "$f" "$mirror/$base" 2>/dev/null || true
    done
  done

  local out IFS=:
  out="${kept[*]}"
  printf '%s' "$out"
}

# path_without_mirror_files <basename> - how many files the call above mirrored.
#
# Exists so the churn this file exists to reduce is itself testable: a helper
# that quietly starts mirroring everything again would still pass every
# reachability assertion, because the tool would still be absent. The count is
# what catches that.
path_without_mirror_files() { # path_without_mirror_files <basename>
  local case_dir="${PATH_WITHOUT_DIR:-${CASE_DIR:-}}"
  local mirror="$case_dir/no-${1:-}"
  [ -d "$mirror" ] || { printf '0\n'; return 0; }
  local n=0 f
  for f in "$mirror"/*; do
    [ -e "$f" ] && n=$(( n + 1 ))
  done
  printf '%s\n' "$n"
}
