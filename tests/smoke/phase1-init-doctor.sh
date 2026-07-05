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
# doctor check 3: filesystem backend selected + TRACKER.md present and valid
grep -q "^backend: filesystem" "$SBX/docs/workflow/tracker-config.yaml" || fail "backend not set to filesystem"
[ -f "$SBX/TRACKER.md" ]                          || fail "filesystem backend should init TRACKER.md"
grep -q "idc-tracker-state:begin" "$SBX/TRACKER.md" || fail "TRACKER.md missing the state block"
# the tracker is actually usable post-scaffold (round-trip one op)
python3 "$PLUGIN/scripts/idc_tracker_fs.py" --tracker "$SBX/TRACKER.md" create --title "smoke" >/dev/null \
                                                 || fail "tracker unusable after scaffold"

# --- static guard: EVERY github-backend board mutation runs AFTER the destructive Status gate ---
# Codex adversarial review (PR 40) + altitude follow-up: `gh project field-create` (adds fields)
# and `gh project link` (publishes the board to the repo) both mutate an operator's board, so they
# must run only AFTER the destructive Status-options **STOP** gate — otherwise an existing populated
# board with incompatible Status options gets stray fields added / gets linked, then init STOPs
# half-provisioned. The hermetic suite has no live GitHub, so assert both mutation lines sit below
# the **STOP** gate line in commands/init.md.
INIT_MD="$PLUGIN/commands/init.md"
stop_ln=$(grep -nF '**STOP**' "$INIT_MD" | head -1 | cut -d: -f1)
[ -n "$stop_ln" ] || fail "init.md: destructive Status **STOP** gate not found"
for marker in 'gh project field-create' 'gh project link "$TRACKER_PROJECT_NUMBER"'; do
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
