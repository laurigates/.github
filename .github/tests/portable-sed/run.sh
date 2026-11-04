#!/usr/bin/env bash
# Fails on a `sed` call in a tracked shell file that relies on GNU-only basic
# regex escapes: `\|` (alternation), `\+` and `\?`. GNU sed accepts them in a
# BRE as an extension; BSD sed (macOS) treats them as literals, so the script
# silently matches nothing. That is how claude-failure-type passed in CI and
# failed 10 of its assertions on macOS (ForumViriumHelsinki/.github#192).
#
# Fix a flagged line by switching to an extended regex, which both seds accept:
#   sed -n 's/^\(a\|b\)=.*/\1/p'   ->   sed -nE 's/^(a|b)=.*/\1/p'
#
# Three checks:
#   1. scan: every `sed` without -E/-r in `git ls-files '*.sh'`;
#   2. control: the same scan flags a scratch file holding the pre-fix line (ForumViriumHelsinki/.github#192),
#      so an empty scan cannot pass vacuously;
#   3. teeth: the shipped OUT_KEYS line of claude-failure-type, extracted from
#      that file, still yields all four keys under a POSIX sed (GNU
#      `--posix`, which rejects `\|` the way BSD sed does, or BSD sed itself).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

NAME=portable-sed
fail=0
assertions=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# scan <file>... : prints file:line for each offending sed call.
scan() {
  python3 - "$@" <<'PY'
import re
import sys

SED = re.compile(r"(?<![\w-])sed(?![\w-])")
GNU_BRE = re.compile(r"\\[|+?]")


def segments(line):
    """Yield the text after each `sed` word, cut at the first unquoted
    pipe or command separator."""
    for m in SED.finditer(line):
        rest = line[m.end():]
        out, quote, i = [], None, 0
        while i < len(rest):
            c = rest[i]
            if quote:
                if c == quote:
                    quote = None
                elif c == "\\" and quote == '"' and i + 1 < len(rest):
                    out.append(c)
                    i += 1
                    c = rest[i]
            elif c in "'\"":
                quote = c
            elif c in "|;&)":
                break
            out.append(c)
            i += 1
        yield "".join(out)


def quoted(seg):
    return re.findall(r"'([^']*)'|\"((?:[^\"\\]|\\.)*)\"", seg)


def extended(seg):
    # Flags are the unquoted words before the first quoted argument.
    head = re.split(r"['\"]", seg, maxsplit=1)[0]
    for tok in head.split():
        if tok in ("--regexp-extended",):
            return True
        if re.fullmatch(r"-[A-Za-z]+", tok) and re.search(r"[Er]", tok):
            return True
    return False


for path in sys.argv[1:]:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            if line.lstrip().startswith("#"):
                continue
            for seg in segments(line):
                if extended(seg):
                    continue
                scripts = ["".join(q) for q in quoted(seg)]
                if any(GNU_BRE.search(s) for s in scripts):
                    print(f"{path}:{n}")
                    break
PY
}

# 1. The tree.
mapfile -t files < <(git ls-files '*.sh')
assertions=$((assertions + 1))
if [ "${#files[@]}" -eq 0 ]; then
  echo "FAIL: $NAME: git ls-files '*.sh' listed no files"
  fail=1
fi
hits="$(scan "${files[@]}")"
assertions=$((assertions + 1))
if [ -n "$hits" ]; then
  echo "FAIL: $NAME: sed with a GNU-only BRE escape (\\| \\+ \\?); use sed -E:"
  printf '  %s\n' $hits
  fail=1
fi

# 2. Control: the pre-fix line (ForumViriumHelsinki/.github#192) must be flagged. Built with printf so this
# file's own source does not contain the pattern it scans for.
bs='\\'
printf '  OUT_KEYS="$(sed -n %s "$f")"\n' \
  "'s/^${bs}([A-Za-z_][A-Za-z0-9_-]*${bs})${bs}(=${bs}|<<${bs}).*/${bs}1/p'" > "$work/control.sh"
printf 'x=$(echo a | sed %s)\n' "'s/a${bs}+/b/'" >> "$work/control.sh"
printf 'y=$(sed -E %s f)\n' "'s/(a|b)+/c/'" >> "$work/control.sh"
control="$(scan "$work/control.sh")"
assertions=$((assertions + 1))
if [ "$control" != "$work/control.sh:1
$work/control.sh:2" ]; then
  echo "FAIL: $NAME: control scan expected lines 1 and 2 flagged, got: ${control:-<nothing>}"
  fail=1
fi

# 3. Teeth: run the shipped OUT_KEYS line under a POSIX sed.
src=.github/tests/claude-failure-type/run.sh
line="$(grep -m1 'OUT_KEYS="$(sed ' "$src" || true)"
assertions=$((assertions + 1))
if [ -z "$line" ]; then
  echo "FAIL: $NAME: no OUT_KEYS sed line found in $src"
  fail=1
else
  # Everything between `$(` and the output-file argument is the sed call.
  cmd="${line#*\$(}"
  cmd="${cmd%% \"\$work/run/output\"*}"
  if sed --version >/dev/null 2>&1; then
    cmd="sed --posix ${cmd#sed }"
  fi
  printf '%s\n' 'subtype=error_max_turns' 'num_turns=7' 'errors<<EOF' 'x' 'EOF' 'type=max_turns' > "$work/output"
  got="$(eval "$cmd \"\$work/output\"" 2>"$work/sed.err" | sort | tr '\n' ' ' || true)"
  assertions=$((assertions + 1))
  if [ "$got" != "errors num_turns subtype type " ]; then
    echo "FAIL: $NAME: shipped OUT_KEYS line under POSIX sed gave '${got}', want 'errors num_turns subtype type ' (cmd: $cmd; stderr: $(head -c 200 "$work/sed.err"))"
    fail=1
  fi
fi

[ "$fail" -eq 0 ] || exit 1
echo "PASS: $NAME ($assertions assertion(s))"
