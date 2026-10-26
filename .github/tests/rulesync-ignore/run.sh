#!/usr/bin/env bash
# The rule source must stay editable from a Claude Code session, here and in
# every repo that syncs from here.
#
# rulesync's `ignore` feature turns every line of .rulesync/.aiignore into a
# `Read(<pattern>)` deny in the generated .claude/settings.json (and a line in
# .cursorignore / .geminiignore). A Claude Code Read deny also blocks Edit,
# Write and path-naming Bash commands. reusable-sync-ai-rules.yml fetches the
# `ignore` feature too, so every consumer inherits these lines: an .aiignore
# line covering `.rulesync/` or `rulesync.jsonc` makes the rule source
# uneditable wherever it is generated.
#
# Assertions:
#   1. .rulesync/.aiignore lists no pattern covering the rule sources
#      (.rulesync/, rulesync.jsonc).
#   2. Class-wide: no .aiignore pattern covers any git-tracked file, and no
#      Read/Edit/Write deny in any .claude/settings*.json in the repo (none is
#      committed today) covers a git-tracked file.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# .aiignore content: a direct read works in CI; inside a Claude Code session
# whose settings still deny the path, fall back to the committed copy.
if aiignore="$(cat .rulesync/.aiignore 2>/dev/null)"; then
  aiignore_src="working tree"
else
  aiignore="$(git show HEAD:.rulesync/.aiignore)"
  aiignore_src="HEAD"
fi

tracked="$(git ls-files)"
settings_files="$(find . -path ./.git -prune -o -path ./node_modules -prune -o -path ./.claude/worktrees -prune -o -type f -path '*/.claude/settings*.json' -print | sed 's|^\./||' | sort)"

AIIGNORE="$aiignore" AIIGNORE_SRC="$aiignore_src" TRACKED="$tracked" SETTINGS_FILES="$settings_files" python3 - <<'PY'
import fnmatch
import json
import os
import re
import sys

failures = []
assertions = 0


def check(cond, msg):
    global assertions
    assertions += 1
    if not cond:
        failures.append(msg)


def covers(pattern, path):
    """gitignore-style: does `pattern` cover repo-relative `path`?"""
    p = pattern
    if p.startswith("./"):
        p = p[2:]
    anchored = p.startswith("/")
    p = p.lstrip("/")
    if not p:
        return False
    parts = path.split("/")
    if p.endswith("/"):
        d = p[:-1]
        if "/" in d or anchored:
            return path.startswith(d + "/")
        # unanchored dir name: any leading directory component
        return any(fnmatch.fnmatchcase(c, d) for c in parts[:-1])
    if "/" in p or anchored:
        return fnmatch.fnmatchcase(path, p) or path.startswith(p + "/")
    return any(fnmatch.fnmatchcase(c, p) for c in parts)


def patterns(text):
    return [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]


def deny_paths(settings_path):
    """(entry, pattern) for every repo-relative Read/Edit/Write deny."""
    with open(settings_path) as f:
        data = json.load(f)
    out = []
    for entry in data.get("permissions", {}).get("deny", []) or []:
        m = re.fullmatch(r"(Read|Edit|Write)\((.*)\)", entry)
        if not m:
            continue
        pat = m.group(2)
        if pat.startswith(("//", "~")):
            continue  # absolute / home paths are outside the repo
        out.append((entry, pat))
    return out


# Matcher self-test, so a broken matcher cannot make the scans vacuous.
check(covers(".rulesync/", ".rulesync/rules/ci-cd-workflows.md"), "matcher self-test: dir pattern")
check(covers("rulesync.jsonc", "rulesync.jsonc"), "matcher self-test: file pattern")
check(covers("node_modules/", "a/node_modules/x.js"), "matcher self-test: unanchored dir pattern")
check(not covers("node_modules/", "README.md"), "matcher self-test: non-match")

guarded = [".rulesync/rules/ci-cd-workflows.md", ".rulesync/.aiignore", "rulesync.jsonc"]
tracked = [t for t in os.environ["TRACKED"].splitlines() if t]
check(tracked, "git ls-files returned nothing")
check(all(g in tracked for g in guarded), f"a guarded rule-source path is not tracked: {guarded}")

# 1. The .aiignore source does not deny the rule sources.
src = os.environ["AIIGNORE_SRC"]
src_patterns = patterns(os.environ["AIIGNORE"])
check(src_patterns, f".rulesync/.aiignore ({src}) has no patterns; expected at least node_modules/")
for pat in src_patterns:
    for g in guarded:
        check(not covers(pat, g), f".rulesync/.aiignore ({src}) line {pat!r} covers rule source {g}")

# 2. Class-wide: no ignore pattern or committed deny covers a tracked file.
for pat in src_patterns:
    hit = [t for t in tracked if covers(pat, t)]
    check(not hit, f".rulesync/.aiignore ({src}) line {pat!r} covers tracked file(s): {', '.join(hit[:5])}")

for sf in (s for s in os.environ["SETTINGS_FILES"].splitlines() if s):
    base = os.path.dirname(os.path.dirname(sf))  # dir that holds .claude/
    prefix = base + "/" if base else ""
    scoped = [t[len(prefix):] for t in tracked if t.startswith(prefix)]
    for entry, pat in deny_paths(sf):
        hit = [t for t in scoped if covers(pat, t)]
        check(not hit, f"{sf} deny {entry} covers tracked file(s): {', '.join(hit[:5])}")

if failures:
    for msg in failures:
        print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)
print(f"PASS: rulesync-ignore ({assertions} assertion(s))")
PY
