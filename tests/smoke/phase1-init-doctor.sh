#!/bin/bash
# idc-assert-class: mixed
# Phase 1 smoke — init scaffolds the v2 tree + doctor's deterministic checks pass, on a
# throwaway filesystem-backend repo (no live GitHub). REAL artifacts + assertions:
# exercises the shipped scaffold helper, then asserts exactly what /idc:doctor checks.
# Also statically guards the github-backend board-mutation ordering in commands/init.md (the
# hermetic suite has no live GitHub, so this is a line-order assertion, not a round-trip).
# Failing-test-first: fails until scripts/idc_init_scaffold.sh exists.
#
# Usage: bash tests/smoke/phase1-init-doctor.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCAFFOLD="$PLUGIN/scripts/idc_init_scaffold.sh"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SCAFFOLD" ] || fail "scaffold helper not found at $SCAFFOLD (not implemented yet)"

( cd "$SBX" && git init -q )

# run the real init filesystem scaffold
bash "$SCAFFOLD" "$PLUGIN" "$SBX" "Test Project" filesystem >/dev/null || fail "scaffold helper failed"

# --- assertions mirror /idc:doctor checks 3, 4, 5 ---
# scaffold files present
[ -f "$SBX/WORKFLOW.md" ]                         || fail "WORKFLOW.md not scaffolded"
[ -f "$SBX/WORKFLOW-config.yaml" ]                || fail "WORKFLOW-config.yaml not scaffolded"
[ -f "$SBX/docs/workflow/tracker-config.yaml" ]  || fail "tracker-config.yaml not scaffolded"
# The transition engine's legal-transition table (v4 Phase 2) is scaffolded operator-visibly, byte-
# identical to the template, and the engine then loads the REPO-LOCAL copy (machine_path_for prefers
# it over the bundled fallback). Red-when-broken: drop the copy line from idc_init_scaffold.sh → absent.
[ -f "$SBX/docs/workflow/workflow-machine.yaml" ] || fail "workflow-machine.yaml not scaffolded (engine falls back to the bundled template, but the governed copy must exist for operator-visibility + /idc:update)"
diff -q "$PLUGIN/templates/workflow-machine.yaml" "$SBX/docs/workflow/workflow-machine.yaml" >/dev/null \
  || fail "scaffolded workflow-machine.yaml is not byte-identical to the template"
PYTHONPATH="$PLUGIN/scripts" python3 -c "import idc_transition as T,os,sys; p=T.machine_path_for(sys.argv[1]); sys.exit(0 if p==os.path.join(sys.argv[1],'docs','workflow','workflow-machine.yaml') else 1)" "$SBX" \
  || fail "the engine did not load the scaffolded repo-local workflow-machine.yaml (machine_path_for should prefer it over the bundled fallback)"
# token substitution happened (no leftover {{PROJECT_NAME}}; name present)
grep -q "Test Project" "$SBX/WORKFLOW.md"        || fail "PROJECT_NAME not substituted in WORKFLOW.md"
! grep -q "{{PROJECT_NAME}}" "$SBX/WORKFLOW.md" "$SBX/WORKFLOW-config.yaml" "$SBX/docs/workflow/tracker-config.yaml" \
                                                 || fail "leftover {{PROJECT_NAME}} token after scaffold"
# doctor check 4: exactly the two v2 subdirs, no v1 subdirs
[ -d "$SBX/docs/workflow/pillar-matrices" ]      || fail "docs/workflow/pillar-matrices missing"
[ -d "$SBX/docs/workflow/code-reviews" ]         || fail "docs/workflow/code-reviews missing"
for v1 in audits ledgers recirculator operator-todos phase-planning pillar-conflicts handoffs diagrams plans; do
  [ -e "$SBX/docs/workflow/$v1" ] && fail "v1 subdir docs/workflow/$v1 should not be scaffolded in v2"
done

# F2 (overnight-e2e-hardening): review reports are LOCAL working artifacts (the PR body is the
# audit trail — see templates/docs-tree/README.md), so a fresh scaffold must gitignore them and a
# clean autorun/build exit leaves no untracked review litter. Matrices stay durable (NOT ignored).
CR="$SBX/docs/workflow/code-reviews"
[ -f "$CR/.gitignore" ] || fail "code-reviews/.gitignore not scaffolded (review reports would be left as untracked litter)"
[ -f "$SBX/docs/workflow/pillar-matrices/.gitignore" ] \
  && fail "pillar-matrices must NOT be gitignored — matrices are the durable deconfliction record"
printf 'x'  > "$CR/pr-9-issue-1-run-checks.report.md"
printf '{}' > "$CR/pr-9-issue-1-run-checks.verdict.json"
( cd "$SBX" && git add -A ) >/dev/null 2>&1
# the review report + verdict must be IGNORED (never appear in status), but .gitkeep stays tracked
git -C "$SBX" check-ignore -q "docs/workflow/code-reviews/pr-9-issue-1-run-checks.report.md" \
  || fail "code-reviews/.gitignore does not ignore *.report.md (untracked review litter would remain)"
git -C "$SBX" check-ignore -q "docs/workflow/code-reviews/pr-9-issue-1-run-checks.verdict.json" \
  || fail "code-reviews/.gitignore does not ignore *.verdict.json"
git -C "$SBX" status --porcelain | grep -q 'code-reviews/pr-9-' \
  && fail "review report/verdict showed up as an untracked/added change — gitignore not effective"
git -C "$SBX" ls-files --error-unmatch "docs/workflow/code-reviews/.gitkeep" >/dev/null 2>&1 \
  || fail "code-reviews/.gitkeep must stay tracked so the scaffold survives a fresh clone"

# --- Task 8 Step 1: /idc:init owns docs/workflow/intakes/, the durable home for /idc:intake ----
# manifests. The scaffold must create it; its .gitkeep must be tracked (an empty dir does not
# survive a clone); and — unlike code-reviews/ — it must NOT be gitignored: an intake manifest is a
# durable record of what a foreign artifact compiled to, like a pillar matrix, not review litter.
INTK="$SBX/docs/workflow/intakes"
[ -d "$INTK" ] \
  || fail "docs/workflow/intakes/ not scaffolded — /idc:intake has no durable manifest home"
[ -f "$INTK/.gitkeep" ] \
  || fail "docs/workflow/intakes/.gitkeep not scaffolded (the empty intake home would not survive a fresh clone)"
[ -f "$INTK/.gitignore" ] \
  && fail "docs/workflow/intakes must NOT be gitignored — an intake manifest is a durable record, not review litter"
git -C "$SBX" ls-files --error-unmatch "docs/workflow/intakes/.gitkeep" >/dev/null 2>&1 \
  || fail "docs/workflow/intakes/.gitkeep must stay tracked so the intake home survives a fresh clone"

# The receipt contract: init.md's Phase 7 stamp list must account for EVERY file the scaffold lays
# down. Parse the REAL command body's stamp invocation (no hardcoded copy of the list here, so the
# test and the command can never drift), then stamp the freshly-scaffolded repo with exactly those
# paths and let the SHIPPED verifier judge. Red-when-broken: drop any path from init.md's stamp
# block and the fresh receipt leaves that governed file `unrecorded` — precisely the 4.0.0-shaped
# migration gap phase7-update-unrecorded-files.sh exists to catch, but at install time.
INIT_MD="$PLUGIN/commands/init.md"
STAMP_PATHS="$(python3 - "$INIT_MD" <<'PY'
import re, shlex, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'idc_receipt_check\.py"?\s+stamp\b(.*?)```', text, re.S)
if not m:
    sys.exit("could not find the idc_receipt_check.py stamp block in commands/init.md")
body = m.group(1).replace("\\\n", " ")
toks = shlex.split(body, comments=True)
VALUED = {"--repo", "--out", "--plugin-version", "--written-by", "--customized"}
paths, i = [], 0
while i < len(toks):
    tok = toks[i]
    if tok in VALUED:
        i += 2
        continue
    if tok.startswith("--"):
        i += 1
        continue
    paths.append(tok)
    i += 1
if not paths:
    sys.exit("parsed no positional stamp paths out of init.md's Phase 7 block")
print("\n".join(paths))
PY
)" || fail "could not parse commands/init.md's Phase 7 stamp path list"
echo "$STAMP_PATHS" | grep -qxF 'docs/workflow/intakes/.gitkeep' \
  || fail "init.md Phase 7 stamp list omits docs/workflow/intakes/.gitkeep — a fresh /idc:init would leave the intake home unrecorded"

RCHK="$PLUGIN/scripts/idc_receipt_check.py"
stamp_scaffold() {
  echo "$STAMP_PATHS" | xargs python3 "$RCHK" stamp \
    --repo "$SBX" --out "$SBX/docs/workflow/install-receipt.yaml" \
    --plugin-version 9.9.9 --written-by idc:init \
    --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml
}
stamp_scaffold >/dev/null || fail "stamping the fresh scaffold with init.md's own path list failed"
vout="$(python3 "$RCHK" verify --repo "$SBX" --json)" || fail "verify of the fresh receipt exited non-zero"
echo "$vout" | python3 -c '
import json, sys
o = json.load(sys.stdin)
u = o.get("unrecorded")
assert u == [], f"a fresh /idc:init left governed files unrecorded (init.md stamp list incomplete): {u}"
ok, summary = o.get("ok"), o.get("summary")
assert ok is True, f"the fresh receipt must verify ok, got {ok!r} ({summary})"
listed = o["unchanged"] + o["modified"] + o["missing"]
intake = sorted(p for p in listed if p.startswith("docs/workflow/intakes/"))
assert intake == ["docs/workflow/intakes/.gitkeep"], \
    f"an EMPTY docs/workflow/intakes/ must be receipt-listed by its .gitkeep only, got {intake}"
' || fail "fresh-init receipt assertions failed: $vout"

# A POPULATED intakes/ must not change the receipt: an intake manifest is a work product
# /idc:intake writes, never scaffold /idc:init installed. The receipt is /idc:uninstall's removal
# manifest ("only delete what IDC created") — listing a manifest there would let uninstall delete
# the operator's compiled intake as if it were pristine scaffold.
printf '{"schema_version":1,"intake_id":"smoke"}' > "$INTK/vendor-plan.intake.json"
stamp_scaffold >/dev/null || fail "re-stamping with a populated intakes/ failed"
vout2="$(python3 "$RCHK" verify --repo "$SBX" --json)" || fail "verify with a populated intakes/ exited non-zero"
echo "$vout2" | python3 -c '
import json, sys
o = json.load(sys.stdin)
listed = o["unchanged"] + o["modified"] + o["missing"] + o.get("unrecorded", [])
stray = sorted(p for p in listed if p.startswith("docs/workflow/intakes/")
               and p != "docs/workflow/intakes/.gitkeep")
assert not stray, f"an intake manifest entered the receipt/removal manifest as scaffold: {stray}"
unrec = o.get("unrecorded")
assert unrec == [], f"an intake manifest must not be governed scaffold: {unrec}"
' || fail "populated-intakes receipt assertions failed: $vout2"
rm -f "$INTK/vendor-plan.intake.json" "$SBX/docs/workflow/install-receipt.yaml"

# --- The scaffold gap-fills FILE-BY-FILE, not all-or-nothing per directory --------------------
# Found live by the Task-8 incident e2e (_idc-observability/run-t8e2e.txt, "Setup findings" §2):
# the docs-tree copy was guarded per top-level entry (`[ -e docs/workflow/<name> ] || cp -R`), so a
# repo whose docs/workflow/<dir>/ already existed WITHOUT its hidden keepfile — a partial scaffold, a
# re-init, or an operator who made the directory by hand — never received the keepfile, while
# init.md's Phase 7 stamp list still names it BY PATH. The run died at the receipt with:
#     idc-receipt: cannot stamp missing file: docs/workflow/pillar-matrices/.gitkeep
# and the operator had to add the file by hand to proceed. init.md Phase 2 promises the opposite
# ("checked individually — a partial tree gets its missing entries filled, so /idc:doctor
# converges"); this asserts that promise at FILE granularity, which is the granularity the receipt
# stamps at. `intakes/` is the newest instance of the same class, so it is covered here too.
# Red-when-broken: restore the per-directory guard → the keepfiles stay absent and the stamp exits 2.
SBX2="$(mktemp -d)"
trap 'rm -rf "$SBX" "$SBX2"' EXIT
( cd "$SBX2" && git init -q )
mkdir -p "$SBX2/docs/workflow/pillar-matrices" "$SBX2/docs/workflow/intakes" \
         "$SBX2/docs/workflow/code-reviews"
# Operator content that must survive untouched: the gap-fill is ADDITIVE, never a re-copy.
printf 'operator-matrix\n'                     > "$SBX2/docs/workflow/pillar-matrices/p1-matrix.yaml"
printf '{"schema_version":1,"id":"legacy"}\n'  > "$SBX2/docs/workflow/intakes/vendor.intake.json"
bash "$SCAFFOLD" "$PLUGIN" "$SBX2" "Partial Repo" filesystem >/dev/null \
  || fail "scaffold helper failed over a pre-existing partial docs/workflow tree"
for f in pillar-matrices/.gitkeep intakes/.gitkeep code-reviews/.gitkeep code-reviews/.gitignore; do
  [ -f "$SBX2/docs/workflow/$f" ] \
    || fail "scaffold skipped docs/workflow/$f because its DIRECTORY already existed — init.md's receipt stamp names that file by path and aborts (run-t8e2e.txt Setup findings 2)"
done
grep -qx 'operator-matrix' "$SBX2/docs/workflow/pillar-matrices/p1-matrix.yaml" \
  || fail "the gap-fill clobbered an operator's matrix — it must add missing template files only"
grep -qF '"id":"legacy"' "$SBX2/docs/workflow/intakes/vendor.intake.json" \
  || fail "the gap-fill touched an operator's intake manifest — a work product is never scaffold"
# The surface that actually broke: the receipt stamp init.md prescribes must now succeed here.
echo "$STAMP_PATHS" | xargs python3 "$RCHK" stamp \
  --repo "$SBX2" --out "$SBX2/docs/workflow/install-receipt.yaml" \
  --plugin-version 9.9.9 --written-by idc:init \
  --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml >/dev/null \
  || fail "the receipt stamp aborted over a pre-existing partial tree (the run-t8e2e.txt failure: cannot stamp missing file)"
v3="$(python3 "$RCHK" verify --repo "$SBX2" --json)" || fail "verify over the gap-filled tree exited non-zero"
echo "$v3" | python3 -c '
import json, sys
o = json.load(sys.stdin)
unrec = o.get("unrecorded")
assert unrec == [], f"a re-init over a partial tree left governed files unrecorded: {unrec}"
ok, summary = o.get("ok"), o.get("summary")
assert ok is True, f"the gap-filled receipt must verify ok, got {ok!r} ({summary})"
' || fail "partial-tree receipt assertions failed: $v3"

# doctor check 3: filesystem backend selected + TRACKER.md present and valid
grep -q "^backend: filesystem" "$SBX/docs/workflow/tracker-config.yaml" || fail "backend not set to filesystem"
[ -f "$SBX/TRACKER.md" ]                          || fail "filesystem backend should init TRACKER.md"
grep -q "idc-tracker-state:begin" "$SBX/TRACKER.md" || fail "TRACKER.md missing the state block"
# the tracker is actually usable post-scaffold (round-trip one op)
python3 "$PLUGIN/scripts/idc_tracker_fs.py" --tracker "$SBX/TRACKER.md" create --title "smoke" >/dev/null \
                                                 || fail "tracker unusable after scaffold"

# --- doctor's honest-claim rule: a filesystem repo never carries a hard pathway-security claim ----
# Spec §2.1: `controlled`/`app-locked` promise that supported runtimes deny off-path mutations AND
# that a required GitHub check plus repository rules block off-path integration. A filesystem-backed
# repo has no integration boundary, so it "MUST NOT claim hard pathway security". Two halves:
#   1. the scaffold LEAVES a filesystem repo `off` (read through the shipped Path Gate parser, so
#      this asserts what the enforcement code actually sees, not what the YAML looks like);
#   2. the scaffold REFUSES to proceed over a config that claims otherwise.
# Red-when-broken: make the backend-aware default unconditional (or drop the refusal) and this fails.
fs_mode="$(PYTHONPATH="$PLUGIN/scripts" python3 -c \
  'import sys; import idc_path_gate as G; print(G.pathway_mode(sys.argv[1]))' "$SBX")"
[ "$fs_mode" = "off" ] \
  || fail "a filesystem-backed scaffold must leave pathway_enforcement.mode 'off' — it makes no hard pathway-security claim (spec §2.1); the Path Gate parser read '$fs_mode'"

CLAIM="$(mktemp -d)"
( cd "$CLAIM" && git init -q )
printf 'pathway_enforcement:\n  mode: controlled\n  attempt_ceiling: 3\n' > "$CLAIM/WORKFLOW-config.yaml"
if bash "$SCAFFOLD" "$PLUGIN" "$CLAIM" "False Claim" filesystem >/dev/null 2>"$CLAIM/err"; then
  rm -rf "$CLAIM"
  fail "the scaffold ACCEPTED a filesystem-backed repo claiming pathway_enforcement.mode: controlled — /idc:doctor's honest-claim rule (spec §2.1) must refuse it"
fi
grep -qi 'filesystem' "$CLAIM/err" \
  || { cp "$CLAIM/err" /tmp/idc-phase1-claim-err.txt 2>/dev/null; rm -rf "$CLAIM"; \
       fail "the filesystem/controlled refusal must name the backend (see /tmp/idc-phase1-claim-err.txt)"; }
rm -rf "$CLAIM"

# The github-backed counterpart: the SAME scaffold defaults an enforcing repo to `controlled`, so
# the two backends are proven to diverge deliberately rather than by accident.
GHB="$(mktemp -d)"
( cd "$GHB" && git init -q )
bash "$SCAFFOLD" "$PLUGIN" "$GHB" "Gh Backend" github >/dev/null \
  || { rm -rf "$GHB"; fail "scaffold helper failed on the github backend"; }
gh_mode="$(PYTHONPATH="$PLUGIN/scripts" python3 -c \
  'import sys; import idc_path_gate as G; print(G.pathway_mode(sys.argv[1]))' "$GHB")"
[ "$gh_mode" = "controlled" ] || { rm -rf "$GHB"; \
  fail "a github-backed scaffold must default to 'controlled' (spec §2.1 default claim, enabled once integration enforcement exists) — read '$gh_mode'"; }
rm -rf "$GHB"

# --- static guard: EVERY post-provenance github board mutation runs AFTER the Status gate ---
# The validating adapter's `ensure-field` (adds fields) and `ensure-link` (publishes the board)
# both mutate an operator's board, so they
# must run only AFTER the destructive Status-options **STOP** gate — otherwise an existing populated
# board with incompatible Status options gets stray fields added / gets linked, then init STOPs
# half-provisioned. The hermetic suite has no live GitHub, so assert both mutation lines sit below
# the **STOP** gate line in commands/init.md.
INIT_MD="$PLUGIN/commands/init.md"
stop_ln=$(grep -nF '**STOP**' "$INIT_MD" | head -1 | cut -d: -f1)
[ -n "$stop_ln" ] || fail "init.md: destructive Status **STOP** gate not found"
for marker in 'python3 "$BOARD_DOOR" ensure-field' 'idc_gh_board.py" ensure-link'; do
  mut_ln=$(grep -nF "$marker" "$INIT_MD" | head -1 | cut -d: -f1)
  [ -n "$mut_ln" ] || fail "init.md: board mutation '$marker' not found"
  [ "$mut_ln" -gt "$stop_ln" ] \
    || fail "init.md: '$marker' (line $mut_ln) must run AFTER the Status **STOP** gate (line $stop_ln)"
done

# --- static guard: /idc:init --pi is wired (parity with --codex) ---
# Track 3 (pi-first-class): --pi must appear in the argument-hint AND a Phase 6b Pi-adapter
# section must invoke install-pi.sh, mirroring the --codex wiring (Phase 6 -> install-codex.sh).
# Hermetic (no live install) — a shape assertion on commands/init.md.
grep -qF '[--pi]' "$INIT_MD"        || fail "init.md: --pi missing from the argument-hint"
grep -qF 'Phase 6b' "$INIT_MD"      || fail "init.md: Phase 6b Pi-adapter section missing"
grep -qF 'install-pi.sh' "$INIT_MD" || fail "init.md: Phase 6b must invoke scripts/install-pi.sh"

echo "PASS: init scaffolds the v2 tree (filesystem backend) + doctor checks satisfied + board-mutation ordering guarded + --pi wired"
