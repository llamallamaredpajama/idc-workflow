#!/bin/bash
# idc-assert-class: behavior
# controlled-default-release-lockstep.sh — U9 capstone: the effective default flip + release lockstep.
#
# Spec §2.1 says `controlled` is the default security claim for governed GitHub-backed repositories,
# and that the filesystem tracker "MUST NOT claim hard pathway security". Spec §7.9 makes enabling
# that default the LAST implementation step — legal only once integration enforcement (U8) exists.
# This scenario proves the flip landed as BACKEND-AWARE FIXED CODE and that the release surfaces
# which announce it move as one atomic contract.
#
# What it proves:
#   A. a github-backed scaffold yields `pathway_enforcement.mode: controlled` — read through the
#      SHIPPED consumer (idc_path_gate.pathway_mode), not a grep, so the parser the Path Gate
#      actually uses is what sees `controlled`;
#   B. a filesystem-backed scaffold stays `off`;
#   C. the flip is CODE, not a template edit — templates/WORKFLOW-config.yaml still ships `mode: off`
#      so a hermetic/filesystem scaffold never inherits a security claim it cannot honor;
#   D. a filesystem-backed repo that CLAIMS `controlled`/`app-locked` is REFUSED by the scaffold door
#      (the honest-claim rule; a filesystem repo may not assert hard pathway security);
#   E. the flip never rewrites an operator's existing config — re-scaffold is byte-identical
#      (the idempotency contract phase7-file-commands-noop-default.sh also depends on);
#   F. /idc:init and /idc:update state the backend-aware default in their prose contract;
#   G. release lockstep — plugin.json, marketplace.json, the latest CHANGELOG heading and the one
#      README version badge all name the SAME version, and THAT release section is the one that
#      announces the controlled default. Stale any single surface and this goes red.
#
# Red-when-broken: delete the github default flip (A), the filesystem refusal (D), or stale any one
# release surface (G) and the matching assertion fails.
#
# Usage: bash tests/smoke/governance/controlled-default-release-lockstep.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
SCAFFOLD="$PLUGIN/scripts/idc_init_scaffold.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SCAFFOLD" ] || fail "scaffold helper not found at $SCAFFOLD"

# The mode the SHIPPED Path Gate parser reads out of a scaffolded repo (read-only consumption of
# idc_path_gate — U9 never edits core path logic).
mode_of() {
  PYTHONPATH="$PLUGIN/scripts" python3 -c '
import sys
import idc_path_gate as G
print(G.pathway_mode(sys.argv[1]))
' "$1"
}

new_repo() {
  local d="$1"
  mkdir -p "$d" && ( cd "$d" && git init -q ) || return 1
}

# ── A. github-backed scaffold defaults to `controlled` ─────────────────────────────────────────────
GH="$WORK/gh-repo"
new_repo "$GH" || fail "could not init the github-backend fixture repo"
bash "$SCAFFOLD" "$PLUGIN" "$GH" "Gh Proj" github >/dev/null \
  || fail "scaffold helper failed on the github backend"
got="$(mode_of "$GH")"
[ "$got" = "controlled" ] \
  || fail "a github-backed scaffold must default pathway_enforcement.mode to 'controlled' (spec §2.1, enabled by §7.9 step 9 now that U8 integration enforcement exists) — the Path Gate parser read '$got'"

# ── B. filesystem-backed scaffold stays `off` ──────────────────────────────────────────────────────
FS="$WORK/fs-repo"
new_repo "$FS" || fail "could not init the filesystem-backend fixture repo"
bash "$SCAFFOLD" "$PLUGIN" "$FS" "Fs Proj" filesystem >/dev/null \
  || fail "scaffold helper failed on the filesystem backend"
got="$(mode_of "$FS")"
[ "$got" = "off" ] \
  || fail "a filesystem-backed scaffold must stay 'off' — it makes no hard pathway-security claim (spec §2.1) — read '$got'"

# ── C. the flip is fixed code, not a template edit ─────────────────────────────────────────────────
# templates/WORKFLOW-config.yaml is backend-agnostic (both backends copy it), so it must keep the
# honest non-enforcing literal; only the backend-aware scaffold step may raise the claim.
grep -qF 'mode: off' "$PLUGIN/templates/WORKFLOW-config.yaml" \
  || fail "templates/WORKFLOW-config.yaml must still ship 'mode: off' — the controlled default is backend-aware SCAFFOLD code, not a blanket template edit (a filesystem scaffold would otherwise inherit a security claim it cannot honor)"

# ── D. a filesystem-backed repo may not CLAIM controlled/app-locked ────────────────────────────────
# The dishonest-claim refusal, at the door that creates governed repos. Pre-seed the operator config
# with a hard claim, then select the filesystem backend: the scaffold must refuse, not proceed.
for claim in controlled app-locked; do
  BAD="$WORK/fs-claims-$claim"
  new_repo "$BAD" || fail "could not init the false-claim fixture repo"
  printf 'pathway_enforcement:\n  mode: %s\n  attempt_ceiling: 3\n' "$claim" > "$BAD/WORKFLOW-config.yaml"
  if bash "$SCAFFOLD" "$PLUGIN" "$BAD" "Bad Proj" filesystem >"$WORK/out.$claim" 2>"$WORK/err.$claim"; then
    fail "a filesystem-backed scaffold ACCEPTED a config claiming '$claim' — the filesystem tracker MUST NOT claim hard pathway security (spec §2.1)"
  fi
  grep -qiE 'filesystem' "$WORK/err.$claim" \
    || fail "the filesystem/'$claim' refusal must name the filesystem backend: $(cat "$WORK/err.$claim")"
  grep -qF "$claim" "$WORK/err.$claim" \
    || fail "the filesystem/'$claim' refusal must name the offending mode: $(cat "$WORK/err.$claim")"
done

# ── E. the flip never rewrites an existing operator config ─────────────────────────────────────────
# A governed repo's WORKFLOW-config.yaml is operator data. Re-scaffolding must be byte-identical even
# when the operator deliberately chose a mode that differs from the backend default.
python3 - "$GH/WORKFLOW-config.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r"(?m)^(\s*)mode:[^\n]*$", r"\1mode: off          # operator override", s, count=1)
open(p, "w", encoding="utf-8").write(s)
PY
before="$(shasum -a 256 "$GH/WORKFLOW-config.yaml" | awk '{print $1}')"
bash "$SCAFFOLD" "$PLUGIN" "$GH" "Gh Proj" github >/dev/null \
  || fail "re-scaffold over an existing github-backed repo exited non-zero"
[ "$before" = "$(shasum -a 256 "$GH/WORKFLOW-config.yaml" | awk '{print $1}')" ] \
  || fail "the backend-aware default REWROTE an operator's existing WORKFLOW-config.yaml — the default applies only when the scaffold CREATES the config (init idempotency contract)"
[ "$(mode_of "$GH")" = "off" ] \
  || fail "an operator's explicit 'off' choice must survive a re-scaffold"

# ── F. the command prose contract states the backend-aware default ────────────────────────────────
I="$PLUGIN/commands/init.md"
U="$PLUGIN/commands/update.md"
grep -qiE 'backend-aware pathway default' "$I" \
  || fail "commands/init.md must document the backend-aware pathway default (github ⇒ controlled, filesystem ⇒ off)"
grep -qF 'pathway_enforcement' "$I" \
  || fail "commands/init.md must name the pathway_enforcement stanza it now sets"
grep -qiE 'backend-aware pathway default' "$U" \
  || fail "commands/update.md must document the backend-aware pathway default for governed repos"
# Update must stay ADVISORY over the data-bearing config (the §A always_ask contract).
grep -qiE 'advis' "$U" \
  || fail "commands/update.md must surface the controlled default as an ADVISORY (it never overwrites a data-bearing config)"

# ── G. release lockstep, bound to the section that announces the flip ─────────────────────────────
python3 "$PLUGIN/scripts/idc_release_check.py" >"$WORK/rc.out" 2>"$WORK/rc.err" \
  || fail "the shipped release surfaces are not in lockstep: $(cat "$WORK/rc.err")"

ANNOUNCE='GitHub-backed repositories now scaffold `pathway_enforcement.mode: controlled` by default'
PLUGIN="$PLUGIN" ANNOUNCE="$ANNOUNCE" python3 - <<'PY' || exit 1
import json, os, re, sys

root = os.environ["PLUGIN"]
announce = os.environ["ANNOUNCE"]


def die(msg):
    print("FAIL: " + msg)
    sys.exit(1)


version = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json"),
                         encoding="utf-8"))["version"]

mkt = json.load(open(os.path.join(root, ".claude-plugin", "marketplace.json"), encoding="utf-8"))
entry = next((p for p in mkt.get("plugins", []) if p.get("name") == "idc"), None)
if entry is None or entry.get("version") != version:
    die("marketplace.json does not name plugin.json's version %r" % version)

readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
if 'alt="version %s"' % version not in readme:
    die("the README version badge does not name %r — release surfaces are out of lockstep" % version)

lines = open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8").read().splitlines()
sections, current = {}, None
for line in lines:
    if line.startswith("## "):
        current = line[3:].strip().split()[0]
        sections[current] = []
        continue
    if current:
        sections[current].append(line)

latest = next((h[3:].strip().split()[0] for h in lines if h.startswith("## ")), None)
if latest != version:
    die("the latest CHANGELOG release heading is %r but plugin.json says %r "
        "(the version claim and its release notes must move together)" % (latest, version))

body = "\n".join(sections.get(version, []))
if announce not in body:
    die("the %s CHANGELOG section does not announce the controlled default — the release that flips "
        "the effective default for GitHub-backed repositories must say so in the release notes "
        "(expected the literal: %s)" % (version, announce))
if "app-locked" not in body:
    die("the %s CHANGELOG section must state that app-locked stays OPT-IN — nothing in this release "
        "may make the GitHub App a normal dependency" % version)
PY

echo "PASS: controlled is the backend-aware default for github-backed repos, filesystem cannot claim it, and the release surfaces that announce it move in lockstep"
