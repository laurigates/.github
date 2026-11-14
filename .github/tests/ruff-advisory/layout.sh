# shellcheck shell=bash
# Sourced by run.sh and gen.sh: writes the fixture tree into a directory.
# Both must lay out the same paths, since ruff's recorded output names them.
#
# layout_base <dir>: the files on the base branch.
# layout_head <dir>: the files the pull request adds.
FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixture"

layout_base() {
  cp "$FIXTURE_DIR/old.py.txt" "$1/old.py"
  printf 'x\n' > "$1/README.md"
}

layout_head() {
  mkdir -p "$1/src"
  cp "$FIXTURE_DIR/hits.py.txt" "$1/src/hits.py"
  cp "$FIXTURE_DIR/clean.py.txt" "$1/src/clean.py"
  cp "$FIXTURE_DIR/broken.py.txt" "$1/src/broken.py"
  # Hostile names: a newline, the annotation property separators, and a
  # leading dash that ruff would read as an option without `--`.
  printf 'print(1)\n' > "$1/src/new
line.py"
  printf 'print(2)\n' > "$1/src/100%,a:b.py"
  printf 'print(3)\n' > "$1/-dash.py"
}
