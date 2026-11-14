#!/usr/bin/env bash
# Checks this repository's label taxonomy, .github/issue-labels.json, which
# .github/workflows/issue-labels.yml hands to reusable-issue-labels.yml
# (git-plugin/scripts/issue-labels.py in laurigates/claude-plugins).
#
# The script reads a glob or a scope that matches nothing as "no label", so a
# stale entry routes nothing and reports nothing. Assertions:
#
#   1. Schema: the rules issue-labels.py's check_taxonomy applies with
#      for_provision=True, and a description on every build and area entry
#      (the script allows none). A taxonomy the script rejects fails provision
#      and every classify run.
#   2. Pattern forms: no `[`, `]`, `{`, `}` or backslash, and `**` only as a
#      whole path segment. git's glob pathspec and the script's glob_regex
#      read those forms alike, so check 3 can use git instead of a copy of
#      the script's matcher.
#   3. Every glob matches a tracked file as a whole path
#      (`git ls-files -- ':(glob)<p>'`). A pathspec that names a directory
#      also lists the files under it, which the script does not match, so
#      those are dropped first.
#   4. Every scope selects one label. An entry's key is one of its scopes, as
#      is the key of a built-in core entry the taxonomy does not override;
#      scopes compare lowercased with whitespace runs collapsed.
#   5. Tripwire: every tracked .github/workflows/reusable-*.yml / .yaml,
#      .github/actions/*/action.yml and .github/tests/*/run.sh is matched by
#      some entry. A new workflow, action or test with no routing fails here.
#
# TAXONOMY overrides the file under test (a scratch copy with a defect, to
# show a check fails). The tracked files are always this checkout's.
#
# Usage: bash .github/tests/issue-labels-taxonomy/run.sh
# Requires: git, python3 (standard library).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TAXONOMY="${TAXONOMY:-.github/issue-labels.json}" python3 - <<'PY'
import json
import os
import re
import subprocess
import sys

NAME = "issue-labels-taxonomy"
path = os.environ["TAXONOMY"]
failures = []
assertions = 0


def check(cond, msg):
    global assertions
    assertions += 1
    if not cond:
        failures.append(msg)


def finish():
    if failures:
        for msg in failures:
            print(f"FAIL: {msg}", file=sys.stderr)
        sys.exit(1)
    print(f"PASS: {NAME} ({assertions} assertion(s))")
    sys.exit(0)


def tracked(pattern):
    """Tracked files matching a glob pathspec; a git error fails the test."""
    out = subprocess.run(
        ["git", "ls-files", "-z", "--", f":(glob){pattern}"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        failures.append(f"git ls-files rejected {pattern!r}: {out.stderr.strip()}")
        return set()
    return {f for f in out.stdout.split("\0") if f}


def whole(pattern):
    """Tracked files the glob matches as whole paths, as the script matches.

    git also lists every file under a directory the pathspec names
    (':(glob)profile' lists profile/README.md), while the script's glob_regex
    matches only a path equal to the pattern. Those files are dropped.
    """
    files = tracked(pattern)
    if pattern == "**" or pattern.endswith("/**"):
        return files
    return files - tracked(pattern + "/**")


def norm(text):
    return " ".join(text.lower().split())


try:
    with open(path) as f:
        tax = json.load(f)
except (OSError, ValueError) as err:
    check(False, f"{path}: {err}")
    finish()
check(isinstance(tax, dict), f"{path} is not a JSON object")
if not isinstance(tax, dict):
    finish()

# 1. Schema (check_taxonomy, for_provision=True).
KEY = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
COLOR = re.compile(r"^[0-9a-fA-F]{6}$")
FIELDS = {
    "build": {"description", "color", "paths", "scopes", "renamed_from"},
    "area": {"description", "color", "paths", "scopes", "renamed_from"},
    "core": {"paths", "scopes"},
}
entries = []  # (where, entry) for every well-formed entry
renamed = {}  # old label name -> the entry that renames it
for section, items in tax.items():
    if section.startswith(("$", "_")):
        continue
    check(section in FIELDS, f"section '{section}': only build, area, core may be defined")
    if section not in FIELDS:
        continue
    check(isinstance(items, dict), f"section '{section}' is not an object")
    if not isinstance(items, dict):
        continue
    for key, entry in items.items():
        where = f"{section}.{key}"
        check(KEY.match(key), f"{where}: key must match {KEY.pattern}")
        check(isinstance(entry, dict), f"{where} is not an object")
        if not isinstance(entry, dict):
            continue
        extra = sorted(set(entry) - FIELDS[section])
        check(not extra, f"{where}: field(s) {extra} not allowed in {section}")
        for field in ("paths", "scopes"):
            value = entry.get(field, [])
            check(
                isinstance(value, list) and all(isinstance(v, str) and v.strip() for v in value),
                f"{where}.{field} must be a list of non-empty strings",
            )
        if section in ("build", "area"):
            color = entry.get("color")
            check(isinstance(color, str) and COLOR.match(color),
                  f"{where}.color must be six hex digits, quoted")
            desc = entry.get("description")
            check(isinstance(desc, str) and 0 < len(desc) <= 100,
                  f"{where}.description must be a string of 1 to 100 characters")
            old = entry.get("renamed_from")
            check(old is None or (isinstance(old, str) and old.strip()),
                  f"{where}.renamed_from must be a label name or null")
            if isinstance(old, str) and old.strip():
                # One label is renamed once: the script rejects a second entry
                # that names the same old label.
                first = renamed.setdefault(norm(old), where)
                check(first == where,
                      f"{where}.renamed_from: {old.strip()!r} is already renamed by {first}")
        entries.append((where, entry))
check(entries, f"{path} defines no entries")


def strings(entry, field):
    value = entry.get(field, [])
    return [v for v in value if isinstance(v, str) and v.strip()] if isinstance(value, list) else []


# 2. Pattern forms.
globs = [(where, g) for where, entry in entries for g in strings(entry, "paths")]
check(globs, f"{path} defines no globs")
for where, g in globs:
    bad = sorted(set(g) & set("[]{}\\"))
    check(not bad, f"{where}: glob {g!r} uses {''.join(bad)}, which git and glob_regex read differently")
    segments = [s for s in g.split("/") if "**" in s]
    check(all(s == "**" for s in segments),
          f"{where}: glob {g!r} has '**' inside a path segment; use it only as a whole segment")

# 3. Every glob matches a tracked file as a whole path.
routed = set()
for where, g in globs:
    hits = whole(g)
    check(hits, f"{where}: glob {g!r} matches no tracked file as a whole path")
    routed |= hits

# 4. Every scope selects one label. The script's DEFAULT_CORE gives ci, agent,
# build, quality and docs an entry even when the taxonomy lists none, and an
# entry's key is one of its scopes.
owner = {}
for key in ("ci", "agent", "build", "quality", "docs"):
    if key not in (tax.get("core") if isinstance(tax.get("core"), dict) else {}):
        owner.setdefault(key, []).append(f"core.{key} (built in)")
for where, entry in entries:
    key = where.split(".", 1)[1]
    for scope in {norm(key), *(norm(s) for s in strings(entry, "scopes"))}:
        owner.setdefault(scope, []).append(where)
for scope, owners in sorted(owner.items()):
    check(len(owners) == 1, f"scope {scope!r} selects more than one label: {', '.join(owners)}")

# 5. Tripwire: every reusable workflow, action and test is routed.
for pattern in (
    ".github/workflows/reusable-*.yml",
    ".github/workflows/reusable-*.yaml",
    ".github/actions/*/action.yml",
    ".github/tests/*/run.sh",
):
    found = tracked(pattern)
    if not pattern.endswith(".yaml"):  # GitHub accepts .yaml; none is tracked today
        check(found, f"scan {pattern!r} found no tracked file")
    for f in sorted(found):
        check(f in routed, f"{f} is matched by no taxonomy entry; add it to the entry it belongs to")

finish()
PY
