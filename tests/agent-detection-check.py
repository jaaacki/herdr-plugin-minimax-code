#!/usr/bin/env python3
r"""Check agent-detection/minimax-code.toml: schema shape, evidence, and exclusivity.

Run by tests/agent-detection-run.sh. Kept as a separate file so the bash suite
stays a thin wrapper, matching the style of the other suites in this repo.

The regex translation is the interesting part. The manifest uses Rust-style
`\x{2800}` escapes, which Python's `re` does not understand. Rather than change
the manifest to suit the test, this translates the escapes so the *shipped*
patterns are the ones actually executed. A test that silently rewrites the thing
it is checking would be worse than no test.
"""
import hashlib
import os
import re
import sys
import tomllib

manifest_path, fix_dir = sys.argv[1], sys.argv[2]

# The reference is VENDORED IN THE REPO, not read from one developer's home
# directory. The first version of this check hardcoded an absolute path into
# herdr's own manifest cache; it passed on that machine and nowhere else, and CI
# on both legs failed with a FileNotFoundError naming a home directory.
REF = os.path.join(fix_dir, "reference-claude.toml")
# Pin the vendored body, so deriving the allow-list from it is trustworthy.
# Deriving is what makes the schema check honest -- the previous version loaded
# this reference and then never read it, comparing against a hand-copied key set
# that had to be kept in sync by hand. But derivation's failure mode is
# asymmetric: dropping a key narrows the allow-list and turns the suite red
# (harmless), while ADDING an invented key widens it and would let an invented
# key in our manifest pass unchecked, which is the one thing this case exists to
# catch. The digest makes any edit to the copied rules a loud failure instead.
# It covers the manifest body only; the leading comment header is ours, so
# documenting the file cannot break the pin. On an intentional re-vendor, update
# this constant in the same commit that re-copies the file, after re-deriving
# the key union as that file's own header instructs.
REF_SHA256 = "2bb543fefeb1192fec81ceaebc794d11faa6c77453bedb55004519a7e1acf82d"
VALID_STATES = {"idle", "working", "blocked", "unknown"}

failures = []


def read(p):
    with open(os.path.join(fix_dir, p), encoding="utf-8") as fh:
        return fh.read()


def to_py(pattern):
    """Rust-style \\x{...} -> Python \\u...."""
    return re.sub(r"\\x\{([0-9A-Fa-f]{1,6})\}", lambda m: "\\u%04x" % int(m.group(1), 16), pattern)


def line_matchers(rule):
    """Yield compiled matchers for a rule's `regex` and `line_regex`.

    `line_regex` is per-line by definition, so it must be compiled with re.M or
    `^` anchors to the start of the whole buffer and silently matches nothing.
    That bug is why the first version of this check reported four rules as
    unevidenced when all five were fine: only the one rule carrying an inline
    `(?m)` on its `regex` had ever matched.
    """
    for p in rule.get("regex", []):
        yield re.compile(to_py(p), re.M)
    for p in rule.get("line_regex", []):
        yield re.compile(to_py(p), re.M)


def region_text(rule, text):
    """The text a rule actually gets to see, per its `region`.

    Only `bottom_non_empty_lines(N)` is implemented, because that is the only
    region this manifest uses. Getting this right matters: without it the check
    scans the whole buffer, so a rule correctly scoped to the live status strip
    gets blamed for matching the same words in scrollback. That is the same trap
    bin/mcode-watch.sh fell into before it started reading only the tail.
    """
    region = rule.get("region", "")
    m = re.match(r"^bottom_non_empty_lines\((\d+)\)$", region)
    if not m:
        return text
    n = int(m.group(1))
    lines = [ln for ln in text.splitlines() if ln.strip()]
    return "\n".join(lines[-n:])


def rule_fires(rule, text):
    """True if any positive matcher hits within the rule's region AND no `not`
    clause vetoes it."""
    scoped = region_text(rule, text)
    hit = any(rx.search(scoped) for rx in line_matchers(rule))
    if not hit:
        return False
    for veto in rule.get("not", []):
        for p in veto.get("regex", []):
            if re.search(to_py(p), scoped, re.M):
                return False
        for p in veto.get("contains", []):
            if p in scoped:
                return False
    return True


def observed_state(text):
    """What state this capture actually shows, resolved the way herdr would:
    the highest-priority rule that fires wins. Returns None if nothing fires."""
    fired = [r for r in doc.get("rules", []) if rule_fires(r, text)]
    if not fired:
        return None
    return max(fired, key=lambda r: r.get("priority", 0)).get("state")


with open(manifest_path, "rb") as fh:
    doc = tomllib.load(fh)

if not os.path.exists(REF):
    print(f"FAIL  preflight: the vendored reference manifest {REF} is missing")
    print("        the schema case derives the allowed keys from a real herdr manifest;")
    print("        falling back to a remembered key set is the failure this check catches")
    sys.exit(2)
ref_text = open(REF, encoding="utf-8").read()


def manifest_body(text):
    """The manifest with our provenance header stripped off.

    Leading `#` and blank lines are ours; everything from the first other line
    down must be the bytes herdr shipped, or the pin below is meaningless.
    """
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines) and (lines[i].startswith("#") or not lines[i].strip()):
        i += 1
    return "".join(lines[i:])


# Digest BEFORE parsing, so that a tampered file is reported as tampered even
# when the tampering also broke its TOML. Parse-first would raise a
# TOMLDecodeError traceback here instead, naming the wrong fault -- the same
# "clear requirement became a stack trace" fault this preflight exists to fix.
digest = hashlib.sha256(manifest_body(ref_text).encode("utf-8")).hexdigest()
if digest != REF_SHA256:
    print("FAIL  preflight: the vendored reference manifest does not match its pinned digest")
    print(f"        expected {REF_SHA256}")
    print(f"        actual   {digest}")
    print("        the copied rules must stay byte-identical to the herdr manifest they came")
    print("        from; if you re-vendored it on purpose, update REF_SHA256 in the same commit")
    sys.exit(2)

with open(REF, "rb") as fh:
    ref = tomllib.load(fh)

ref_rules = ref.get("rules") or []
# An empty allow-list would not be a stricter check, it would be a broken one:
# without this guard the comparisons below would pass vacuously. Refuse, loudly.
if not ref_rules:
    print(f"FAIL  preflight: {REF} declares no rules, so it cannot define a key set")
    sys.exit(2)

# The specification is the file's own keys, not a copy of them.
REF_TOP = set(ref)                       # includes "rules": that is a real key
REF_RULE = {k for r in ref_rules for k in r}

# --- case 1: schema shape matches what herdr ships ---------------------------
problems = []
extra_top = set(doc) - REF_TOP
if extra_top:
    problems.append(f"unknown top-level keys: {sorted(extra_top)}")
# A second "unknown top-level keys" test used to sit here, phrased as "missing
# required top-level keys". It could only ever fire on the condition above --
# "rules" is itself a member of REF_TOP -- so the only thing it added was a
# message naming the wrong fault. Required keys are checked by name below, which
# is what can actually report a missing one.
for key in ("id", "version", "min_engine_version", "updated_at"):
    if key not in doc:
        problems.append(f"missing {key}")
if doc.get("id") != "mcode":
    problems.append(f"id is {doc.get('id')!r}, expected 'mcode'")
if not doc.get("aliases"):
    problems.append("no aliases")
else:
    for want in ("mcode", "minimax", "minimax-code"):
        if want not in doc["aliases"]:
            problems.append(f"alias {want!r} missing")
for r in doc.get("rules", []):
    extra = set(r) - REF_RULE
    if extra:
        problems.append(f"rule {r.get('id')!r} has keys herdr never uses: {sorted(extra)}")
    for key in ("id", "state", "region"):
        if key not in r:
            problems.append(f"rule {r.get('id')!r} missing {key}")
    if r.get("state") not in VALID_STATES:
        problems.append(f"rule {r.get('id')!r} has invalid state {r.get('state')!r}")
if not doc.get("rules"):
    problems.append("no rules at all")

if problems:
    print("FAIL  schema-matches-the-shipped-manifests")
    for p in problems:
        print(f"        {p}")
    failures.append("schema")
else:
    print("ok    schema-matches-the-shipped-manifests")

# --- case 2: every rule has a capture that demonstrates it --------------------
# Which capture shows which rule firing. If you add a rule you must add it here
# and add its capture; the test refuses to let a rule exist unevidenced.
EXPECTED = {
    "mcode_status_strip_working": ("working.txt", "working"),
    "mcode_steps_working": ("working.txt", "working"),
    "mcode_composer_idle": ("idle-after-working.txt", "idle"),
    "mcode_turn_complete_idle": ("idle-after-working.txt", "idle"),
    "mcode_start_prompt_idle": ("idle.txt", "idle"),
}

unproven = [r["id"] for r in doc["rules"] if r["id"] not in EXPECTED]
missing_capture = [
    r["id"] for r in doc["rules"]
    if r["id"] in EXPECTED and not os.path.exists(os.path.join(fix_dir, EXPECTED[r["id"]][0]))
]
not_firing = [
    f"{r['id']} does not fire on {EXPECTED[r['id']][0]}"
    for r in doc["rules"]
    if r["id"] in EXPECTED and not rule_fires(r, read(EXPECTED[r["id"]][0]))
]
if unproven or missing_capture or not_firing:
    print("FAIL  every-rule-has-a-capture-that-demonstrates-it")
    for m in unproven:
        print(f"        rule {m!r} has no declared evidence fixture")
    for m in missing_capture:
        print(f"        rule {m!r} names a capture that is not in the repo")
    for m in not_firing:
        print(f"        {m}")
    failures.append("evidence")
else:
    print("ok    every-rule-has-a-capture-that-demonstrates-it")

# --- case 3: rules do not fire on the other states' captures ------------------
# The false-positive that matters: a working rule that also matches a finished
# turn reports "working" forever, because the finished turn's line carries a
# throughput counter. Fixtures that show the other states must not trigger it.
crossed = []
for r in doc["rules"]:
    for fixture in ("working.txt", "idle.txt", "idle-after-working.txt",
                    "not-mcode.txt", "stale-scrollback.txt"):
        path = os.path.join(fix_dir, fixture)
        if not os.path.exists(path):
            continue
        want_fixture, want_state = EXPECTED.get(r["id"], (None, None))
        if fixture == want_fixture:
            continue          # its own evidence: firing is the point
        if rule_fires(r, read(fixture)) and want_state is not None:
            # Firing on a non-evidence capture is only a defect if it contradicts
            # what that capture actually shows.
            actual = observed_state(read(fixture))
            if actual is not None and actual != r["state"]:
                crossed.append(
                    f"rule {r['id']!r} ({r['state']}) fires on {fixture}, which shows {actual}"
                )

if crossed:
    print("FAIL  rules-do-not-false-positive-across-states")
    for c in crossed:
        print(f"        {c}")
    failures.append("crossfire")
else:
    print("ok    rules-do-not-false-positive-across-states")

sys.exit(1 if failures else 0)
