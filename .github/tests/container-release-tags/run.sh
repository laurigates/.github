#!/usr/bin/env bash
# Regression test: container-release image tags come from ONE parser.
#
# 1. Every docker/metadata-action step in .github/workflows/ is scanned: a
#    `tags:` block that mixes `type=semver` and `type=match` entries encodes two
#    competing parsers, one of which warns on every release (and the match arm
#    tags component pre-releases as stable).
# 2. The shipped `version` step of reusable-container-release.yml is extracted
#    and executed against fixtures, including a tag-prefix that does not prefix
#    the tag, which must fail with an ::error:: line.
# 3. The shipped `tags:` block is fed through an emulation of
#    docker/metadata-action v5.10.0 (src/meta.ts procSemver/procMatch/
#    setVersion at c299e40c65443455700f0fdfc63efafe5b349051) and the resulting
#    tag set and warning count are asserted. The emulation is of that version,
#    not the action itself: re-check it when the pin in the workflow moves.
#
# Requires bash, python3 (stdlib only) and yq (mikefarah v4).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: yq is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 is required" >&2; exit 1; }

python3 - <<'PY'
import glob, json, os, re, subprocess, sys, tempfile

WF = ".github/workflows/reusable-container-release.yml"
PIN = "docker/metadata-action@c299e40c65443455700f0fdfc63efafe5b349051"
failures, assertions = [], 0


def check(cond, msg):
    global assertions
    assertions += 1
    if not cond:
        failures.append(msg)


def yq_json(expr, path):
    out = subprocess.run(["yq", "-o=json", "-I=0", expr, path],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


EXPR = re.compile(r"\$\{\{\s*([^}]+?)\s*\}\}")


def substitute(text, ctx):
    """Resolve ${{ expr }} the way Actions does before a step runs."""
    def repl(m):
        key = m.group(1)
        if key not in ctx:
            raise KeyError(f"harness has no value for expression '${{{{ {key} }}}}'")
        return ctx[key]
    return EXPR.sub(repl, text)


def entries(tags_block):
    """Tag entries as metadata-action reads them: one per line, '#' comments dropped."""
    out = []
    for line in tags_block.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        attrs = {}
        for part in line.split(","):
            k, _, v = part.partition("=")
            attrs[k.strip()] = v.strip()
        attrs.setdefault("type", "raw")
        out.append(attrs)
    return out


# ---- 1. no workflow mixes type=semver and type=match in one tags block ------
files = sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"))
found = []
for f in files:
    steps = yq_json('[.jobs[]?.steps[]? | select((.uses // "") | test("^docker/metadata-action@")) '
                    '| {"name": (.name // ""), "uses": .uses, "tags": (.with.tags // "")}]', f)
    for s in steps:
        found.append((f, s))
        types = {e["type"] for e in entries(s["tags"])}
        check(not ({"semver", "match"} <= types),
              f"{f} step '{s['name']}': tags block mixes type=semver and type=match "
              f"entries (two competing tag parsers; one warns on every release)")

# Control: the scan must see the known metadata-action step, or it proves nothing.
check(any(f == WF for f, _ in found), f"scan found no docker/metadata-action step in {WF}")
meta = [s for f, s in found if f == WF]
check(len(meta) == 1, f"expected exactly one metadata-action step in {WF}, found {len(meta)}")
if meta:
    check(meta[0]["uses"].startswith(PIN),
          f"{WF} pins {meta[0]['uses']}; the emulation below models {PIN} (v5.10.0), re-verify it")


# ---- 2. the shipped version step -------------------------------------------
step = yq_json('.jobs.release.steps[] | select(.id == "version")', WF)
IMAGE = "laurigates/example"


def run_version(tag, prefix):
    ctx = {"github.ref_name": tag, "inputs.tag-prefix": prefix, "inputs.image-name": IMAGE}
    env = dict(os.environ)
    for k, v in (step.get("env") or {}).items():
        env[k] = substitute(str(v), ctx)
    with tempfile.TemporaryDirectory() as d:
        script, out = os.path.join(d, "step.sh"), os.path.join(d, "output")
        with open(script, "w") as fh:
            fh.write(substitute(step["run"], ctx))
        open(out, "w").close()
        env["GITHUB_OUTPUT"] = out
        # The step sets no `shell:`, so Actions runs it as `bash -e {0}`.
        p = subprocess.run(["bash", "-e", script],
                           env=env, capture_output=True, text=True)
        with open(out) as fh:
            outputs = dict(l.split("=", 1) for l in fh.read().splitlines() if "=" in l)
    return p.returncode, p.stdout + p.stderr, outputs


POSITIVE = [  # (prefix, tag, expected version, expected tag set)
    ("v", "v0.1.1", "0.1.1", {"0.1.1", "0.1", "0", "latest"}),
    ("my-app-v", "my-app-v1.58.0", "1.58.0", {"1.58.0", "1.58", "1", "latest"}),
    ("v", "v1.2.3-rc.1", "1.2.3-rc.1", {"1.2.3-rc.1"}),
    # Component pre-release: the old type=match arm published this as 1.2.3/1.2/1/latest.
    ("comp-v", "comp-v1.2.3-rc.1", "1.2.3-rc.1", {"1.2.3-rc.1"}),
]
versions = {}
for prefix, tag, want, _ in POSITIVE:
    rc, log, outputs = run_version(tag, prefix)
    check(rc == 0, f"version step exited {rc} for tag {tag} prefix {prefix}: {log.strip()}")
    check(outputs.get("version") == want,
          f"version step: tag {tag} prefix {prefix} gave version={outputs.get('version')!r}, want {want!r}")
    check(outputs.get("next_image") == f"ghcr.io/{IMAGE}:next-{want}",
          f"version step: tag {tag} gave next_image={outputs.get('next_image')!r}")
    versions[tag] = outputs.get("version", "")

rc, log, _ = run_version("v1.2.3", "app-v")
check(rc != 0, "version step: tag-prefix 'app-v' on tag 'v1.2.3' exited 0; a prefix that does "
               "not prefix the tag must fail the release")
check("::error::" in log and "app-v" in log and "v1.2.3" in log,
      f"version step: wrong tag-prefix must print an ::error:: naming prefix and tag, got: {log.strip()!r}")


# ---- 3. emulate docker/metadata-action v5.10.0 over the shipped tags block ---
# node-semver valid(): optional leading 'v'/'=', MAJOR.MINOR.PATCH, prerelease, build.
IDENT = r"(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER = re.compile(r"^[v=\s]*(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
                    rf"(?:-({IDENT}(?:\.{IDENT})*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$")
PRIORITY = {"semver": 900, "match": 800, "raw": 200}


def render(pattern, m, raw):
    major, minor, patch, pre = m.groups()
    version = f"{major}.{minor}.{patch}" + (f"-{pre}" if pre else "")
    vals = {"version": version, "major": major, "minor": minor, "patch": patch, "raw": raw}
    return re.sub(r"\{\{\s*(\w+)\s*\}\}", lambda x: vals[x.group(1)], pattern)


def metadata(tags_block, ref_tag, ctx):
    main, partial, latest, warnings = None, [], None, []

    def set_version(val, is_latest):
        nonlocal main, latest
        if not val:
            return
        if main is None:
            main = val
        elif val != main:
            partial.append(val)
        if latest is None:
            latest = is_latest

    ents = [{k: substitute(v, ctx) for k, v in e.items()} for e in entries(tags_block)]
    for e in ents:
        if e["type"] not in PRIORITY:
            raise ValueError(f"emulation does not model type={e['type']}")
    ents = [e for e in ents if e.get("enable", "true") != "false"]
    ents.sort(key=lambda e: -int(e.get("priority", PRIORITY[e["type"]])))  # stable, like JS sort
    for e in ents:
        vraw = e.get("value") or ref_tag
        if e["type"] == "semver":
            if e.get("match"):
                mm = re.search(e["match"], vraw)
                if not mm:
                    warnings.append(f"{e['match']} does not match {vraw}.")
                else:
                    vraw = mm.group(1)
            vraw = vraw.replace("/", "-")
            m = SEMVER.match(vraw)
            if not m:
                warnings.append(f"{vraw} is not a valid semver.")
                continue
            if m.group(4):  # prerelease: only {{version}} (or {{raw}})
                pat = e["pattern"] if "{{raw}}" in e["pattern"] else "{{version}}"
                set_version(render(pat, m, vraw), False)
            else:
                set_version(render(e["pattern"], m, vraw), True)
        elif e["type"] == "match":
            # JS String.prototype.match with a string pattern: unanchored search.
            mm = re.search(e["pattern"], vraw)
            if not mm:
                warnings.append(f"{e['pattern']} does not match {vraw}.")
                continue
            set_version(mm.group(int(e.get("group", "0"))), True)
        else:
            set_version(e.get("value", ""), False)
    partial = list(dict.fromkeys(partial))
    tags = ([main] + partial + (["latest"] if latest else [])) if main else []
    return main, tags, warnings


if meta:
    for prefix, tag, want_version, want_tags in POSITIVE:
        ctx = {"steps.version.outputs.version": versions.get(tag, ""), "github.ref_name": tag}
        main, tags, warnings = metadata(meta[0]["tags"], tag, ctx)
        check(set(tags) == want_tags,
              f"metadata tags for {tag} (prefix {prefix}): got {sorted(tags)}, want {sorted(want_tags)}")
        check(len(tags) == len(set(tags)), f"metadata tags for {tag} contain duplicates: {tags}")
        check(not warnings, f"metadata-action would warn {len(warnings)}x for {tag}: {warnings}")
        # steps.meta.outputs.version feeds the Trivy image-ref and the job's version output.
        check(main == want_version, f"metadata version output for {tag}: got {main!r}, want {want_version!r}")

if failures:
    for f in failures:
        print(f"FAIL: {f}")
    print(f"container-release-tags: {len(failures)} of {assertions} assertion(s) failed")
    sys.exit(1)
print(f"PASS: container-release-tags ({assertions} assertion(s))")
PY
