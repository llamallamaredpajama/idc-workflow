#!/bin/bash
# idc-assert-class: behavior
# plan-provenance-recipe-runs.sh — the SHIPPED provenance-check recipe in agents/idc-plan.md must
# RUN from the repo root, which is where Plan runs (`from the target repo root` / cwd-rooted `$PWD`
# recipes everywhere else in the playbook). `idc_provenance_check.py --matrix` is a real path
# resolved against the cwd; the prior prose passed the matrix BASENAME (`<phase-tag>-matrix.yaml`),
# so the first copy-pasted call died `cannot read matrix … No such file` (exit 2) from the repo
# root — the 4.0.0 U6 install-sandbox e2e hit exactly that (issue #162). Matrices live at
# `docs/workflow/pillar-matrices/` (commands/plan.md Phase 4), so the documented form must be the
# repo-relative path. This extracts the recipe AS WRITTEN and runs it in a hermetic repo.
#
# Red-when-broken: revert idc-plan.md's example to `--matrix <phase-tag>-matrix.yaml` (the bare
# basename) → the extracted recipe exits 2 (`cannot read matrix`) and this scenario FAILs.
#
# Hermetic: a PATH `gh` stub serves `gh issue view <n> --json body -q .body` from a fixture file —
# no live GitHub (same stub shape as tests/smoke/phase3-provenance-gate.sh).
# Usage: bash tests/smoke/governance/plan-provenance-recipe-runs.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
PLAN="$PLUGIN/agents/idc-plan.md"
SCRIPT="$PLUGIN/scripts/idc_provenance_check.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$PLAN" ] || fail "idc-plan.md not found at $PLAN"
[ -f "$SCRIPT" ] || fail "idc_provenance_check.py not found at $SCRIPT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- hermetic governed-repo shape: the matrix lives where Plan authors it ----------------------
mkdir -p "$WORK/docs/workflow/pillar-matrices"
cat > "$WORK/docs/workflow/pillar-matrices/p1-matrix.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: P1
    wave: 1
    domain: api
    surfaces: [scripts/idc_provenance_check.py]
YAML

# ---- fixture issue body: a Buildable WITH a valid marker (matrix value = the BASENAME, which the
# checker derives itself via os.path.basename — the repo-relative --matrix must not change it) ----
mkdir -p "$WORK/bodies" "$WORK/bin"
cat > "$WORK/bodies/10" <<'EOF'
Some goal-contract prose.

<!-- idc-provenance: {"matrix":"p1-matrix.yaml","pillar":"P1"} -->
EOF

# ---- gh stub: `gh issue view <n> --json body -q .body` -> fixture file content ------------------
cat > "$WORK/bin/gh" <<STUB
#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if args[:2] == ["issue", "view"]:
    n = args[2]
    try:
        sys.stdout.write(open("$WORK/bodies/" + n).read())
    except OSError:
        sys.stdout.write("")
    sys.exit(0)
sys.stderr.write("gh stub: unhandled " + repr(args) + "\\n")
sys.exit(99)
STUB
chmod +x "$WORK/bin/gh"

echo "== the SHIPPED provenance-check recipe from idc-plan.md runs AS WRITTEN from the repo root =="
# Extract the shipped invocation (backslash-newline continuations joined), bind the documented
# placeholders (<phase-tag> -> p1, <n1,n2,...> -> 10), substitute ${CLAUDE_PLUGIN_ROOT}, and RUN it
# with cwd = the hermetic repo root. A recipe passing the matrix basename fails to open the matrix
# from there → non-zero exit → FAIL.
run_recipe() {
  cd "$WORK" && PATH="$WORK/bin:$PATH" python3 - "$PLAN" "$PLUGIN" <<'PY'
import re, shlex, subprocess, sys
plan, plugin = sys.argv[1:3]
text = open(plan, encoding="utf-8").read().replace("\\\n", " ")   # join shell line-continuations
m = re.search(
    r'python3\s+"?\$\{CLAUDE_PLUGIN_ROOT\}/scripts/idc_provenance_check\.py"?\s+([^`\n]*)',
    text)
if not m:
    sys.exit("could not locate the shipped idc_provenance_check.py recipe in idc-plan.md")
args = shlex.split(m.group(1))
args = [a.replace("<phase-tag>", "p1").replace("<n1,n2,...>", "10") for a in args]
cmd = ["python3", f"{plugin}/scripts/idc_provenance_check.py", *args]
print("  recipe:", " ".join(cmd))
r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
sys.stdout.write(r.stdout)
if r.returncode != 0:
    sys.exit(f"recipe exited {r.returncode}\nstdout={r.stdout}\nstderr={r.stderr}")
PY
}
out="$(run_recipe 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
[ "$rc" -eq 0 ] || fail "the shipped provenance-check recipe did not run from the repo root — does the example pass the matrix BASENAME instead of docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml? (issue #162)"
printf '%s\n' "$out" | grep -q '^provenance: ok 1$' \
  || fail "the recipe ran but did not report 'provenance: ok 1' — got: $out"

# ---- discriminator control: the OLD documented form (bare basename) really does fail from the
# repo root — proving the fixture distinguishes the fixed recipe from the broken one, so the pass
# above is not vacuous. -----------------------------------------------------------------------
old_out="$(cd "$WORK" && PATH="$WORK/bin:$PATH" timeout 60 \
  python3 "$SCRIPT" --matrix p1-matrix.yaml --issues 10 2>&1)"
old_rc=$?
[ "$old_rc" -eq 2 ] || fail "control: the pre-fix basename form should exit 2 from the repo root, got $old_rc: $old_out"
printf '%s\n' "$old_out" | grep -q 'cannot read matrix' \
  || fail "control: the pre-fix basename form should die 'cannot read matrix', got: $old_out"
echo "  ok control: the bare-basename form still fails from the repo root (exit 2, cannot read matrix)"

echo "PASS: idc-plan.md's provenance-check example uses the repo-relative matrix path, so the documented recipe runs from the repo root and reports provenance: ok 1"
