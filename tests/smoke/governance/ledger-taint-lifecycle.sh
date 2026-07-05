#!/bin/bash
# ledger-taint-lifecycle.sh — the obligations ledger's taint lifecycle + stale-safety invariant
# (v4 Phase 3, plan §3.4). The ledger (scripts/hooks/idc_ledger.py) is the per-session state file
# `.idc-session-state.json` at the governed workspace root that DETERMINISTIC hooks/scripts — never
# the LLM — use to record and clear taints (unfiled_findings, mid_finish:<item>,
# recirc_checkpoint:<ticket>). Later stages' Stop/SubagentStop gates READ it (a hint) and cross-check
# it against the board + `drain --fixpoint` (ground truth). This scenario pins the primitives those
# gates depend on:
#
#   (P) path      — ledger_path resolves to `<repo>/.idc-session-state.json`.
#   (R) roundtrip — set a taint ⇒ pending shows it ⇒ clear_taint ⇒ pending empty (the HEADLINE:
#                   red-when-broken by neutering clear_taint into a no-op — the empty assert FAILs).
#   (F) mid_finish — a keyed mid_finish:<item> set then cleared leaves a quiescent (empty) ledger.
#   (S) stale-safety — a taint written by ANOTHER session is NOT a live obligation for THIS session
#                   (pending_taints scoped to my session_id excludes it), so a stale ledger left by a
#                   dead prior session can never falsely block THIS session's clean board (invariant #1).
#   (C) corrupt   — a corrupt / missing ledger file reads as an EMPTY ledger, never throws (a corrupt
#                   ledger must not brick a gate — tolerant read).
#   (G) repo-gate — outside a governed repo (no docs/workflow/tracker-config.yaml) a write is a no-op
#                   (never litters a non-IDC repo with the state file).
#   (I) gitignore — the scaffold's ensure step adds `.idc-session-state.json` to the repo-root
#                   .gitignore idempotently and non-destructively (never clobbers operator lines).
#
# Filesystem-only, hermetic (no gh, no board). Auto-discovered by the governance lane
# (phase-governance.sh); also runnable standalone under BOTH python3 and `uv run --with pyyaml`.
#
# Red-when-broken (MANDATORY, reviewed): make idc_ledger.clear_taint a no-op → (R)/(F) FAIL; make
# pending_taints ignore session scoping → (S) FAILs; make the read path throw on corrupt json → (C)
# FAILs. The headline neuter is clear_taint.
#
# Usage: bash tests/smoke/governance/ledger-taint-lifecycle.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

LEDGER="$GOV_PLUGIN/scripts/hooks/idc_ledger.py"
SCAFFOLD="$GOV_PLUGIN/scripts/idc_init_scaffold.sh"
[ -f "$LEDGER" ] || fail "idc_ledger.py not found at $LEDGER (not implemented yet)"

# led <repo> <op> [args…] — drive the ledger CLI pinned to a governed workspace root <repo>.
led() { python3 "$LEDGER" --cwd "$1" "${@:2}"; }

# A governed throwaway workspace: a repo root carrying the governance marker so is_governed_repo()
# is true (the ledger writes there; a non-governed dir is the (G) case).
WORK="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
LED_FILE="$REPO/.idc-session-state.json"

# ── (P) path — ledger_path resolves to <repo>/.idc-session-state.json ──────────────────────────────
p="$(led "$REPO" path)" || fail "(P) ledger path op failed"
[ "$p" = "$LED_FILE" ] \
  || fail "(P) ledger_path must be <repo>/.idc-session-state.json, got: $p"
echo "  ok (P) ledger_path resolves to the workspace-root .idc-session-state.json"

# ── (R) roundtrip — set ⇒ pending shows it ⇒ clear ⇒ pending empty [HEADLINE / red-when-broken] ─────
led "$REPO" set --kind unfiled_findings --session S1 >/dev/null || fail "(R) set_taint failed"
led "$REPO" pending --session S1 | grep -q 'unfiled_findings' \
  || fail "(R) a set unfiled_findings taint must be pending for its session"
led "$REPO" clear --kind unfiled_findings >/dev/null || fail "(R) clear_taint failed"
out="$(led "$REPO" pending --session S1)"
[ -z "$out" ] \
  || fail "(R) after clear_taint the ledger must be empty for S1 — got: $(printf '%s' "$out" | tr '\n' '|') [neuter clear_taint ⇒ THIS assert goes RED]"
echo "  ok (R) set → pending shows it → clear_taint → pending empty (roundtrip) [headline]"

# ── (F) mid_finish keyed by item — set then cleared leaves a quiescent ledger ──────────────────────
led "$REPO" set --kind mid_finish --key 42 --session S1 >/dev/null || fail "(F) set mid_finish failed"
led "$REPO" pending --session S1 | grep -q 'mid_finish:42' \
  || fail "(F) a mid_finish:42 taint must be pending (keyed by item)"
led "$REPO" clear --kind mid_finish --key 42 >/dev/null || fail "(F) clear mid_finish failed"
out="$(led "$REPO" pending --session S1)"
[ -z "$out" ] \
  || fail "(F) after clearing mid_finish:42 the ledger must be quiescent — got: $(printf '%s' "$out" | tr '\n' '|')"
echo "  ok (F) mid_finish:<item> set then cleared leaves an empty/quiescent ledger"

# ── (S) stale-safety — an OTHER session's leftover taint is not THIS session's obligation ──────────
# A prior session (S_OLD) sets a taint and dies WITHOUT clearing it (crash mid-finish): the taint
# physically remains in the file. A NEW session (S_NEW) must NOT inherit it as a live obligation —
# pending scoped to S_NEW excludes it — so a stale ledger can never falsely block S_NEW's clean board.
led "$REPO" set --kind mid_finish --key 99 --session S_OLD >/dev/null || fail "(S) seed old-session taint failed"
out="$(led "$REPO" pending --session S_NEW)"
[ -z "$out" ] \
  || fail "(S) a taint owned by S_OLD must NOT be a live obligation for S_NEW — got: $(printf '%s' "$out" | tr '\n' '|') [neuter session scoping ⇒ THIS assert goes RED]"
# ...but it IS still visible to its OWN session (recovery/inspection), and in the unscoped hint view.
led "$REPO" pending --session S_OLD | grep -q 'mid_finish:99' \
  || fail "(S) the taint must remain visible to its OWNING session S_OLD"
led "$REPO" pending | grep -q 'mid_finish:99' \
  || fail "(S) the unscoped hint view must still surface the taint (the board/drain is the truth gate)"
led "$REPO" clear --kind mid_finish --key 99 >/dev/null || fail "(S) cleanup clear failed"
echo "  ok (S) an other-session taint is not a live obligation for THIS session (stale-safety)"

# ── (C) corrupt / missing ledger reads as EMPTY, never throws ──────────────────────────────────────
# missing: fresh repo, no file yet → pending is empty and exits 0 (no throw).
MREPO="$WORK/missing"; mkdir -p "$MREPO/docs/workflow"
printf 'backend: filesystem\n' > "$MREPO/docs/workflow/tracker-config.yaml"
out="$(led "$MREPO" pending --session S1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "(C) a MISSING ledger must read as empty (exit 0, no output), got rc=$rc out=$(printf '%s' "$out" | tr '\n' '|')"
# corrupt: garbage bytes in the file → still empty, still exit 0 (a corrupt ledger must not brick a gate).
printf '}{ not json at all \x00' > "$LED_FILE"
out="$(led "$REPO" pending --session S1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "(C) a CORRUPT ledger must read as empty (exit 0, no throw), got rc=$rc out=$(printf '%s' "$out" | tr '\n' '|')"
# and a write over a corrupt file must recover it (atomic replace), not crash.
led "$REPO" set --kind recirc_checkpoint --key T-7 --session S1 >/dev/null \
  || fail "(C) set_taint over a corrupt file must recover, not crash"
led "$REPO" pending --session S1 | grep -q 'recirc_checkpoint:T-7' \
  || fail "(C) after recovering a corrupt file the new taint must be pending"
led "$REPO" clear --kind recirc_checkpoint --key T-7 >/dev/null || fail "(C) cleanup clear failed"
echo "  ok (C) a corrupt/missing ledger reads as empty (never throws); a write recovers it"

# ── (G) repo-gate — outside a governed repo a write is a no-op (no state-file litter) ──────────────
NGREPO="$WORK/not-governed"; mkdir -p "$NGREPO"     # no docs/workflow/tracker-config.yaml
led "$NGREPO" set --kind unfiled_findings --session S1 >/dev/null \
  || fail "(G) set in a non-governed repo must succeed as a silent no-op (not error)"
[ ! -e "$NGREPO/.idc-session-state.json" ] \
  || fail "(G) a non-governed repo must NOT be littered with a .idc-session-state.json"
echo "  ok (G) outside a governed repo the ledger write is a no-op (never litters)"

# ── (I) gitignore scaffold — idempotent, non-destructive ensure of the repo-root .gitignore ────────
GREPO="$WORK/scaffolded"; mkdir -p "$GREPO"
# Seed an operator-owned .gitignore so we can prove the ensure step is ADDITIVE (never clobbers).
printf '# operator rules\nnode_modules/\n*.log\n' > "$GREPO/.gitignore"
bash "$SCAFFOLD" "$GOV_PLUGIN" "$GREPO" "proj-x" filesystem >/dev/null 2>&1 \
  || fail "(I) idc_init_scaffold.sh failed"
grep -qxF '.idc-session-state.json*' "$GREPO/.gitignore" \
  || fail "(I) the scaffold must add the '.idc-session-state.json*' ignore glob to the repo-root .gitignore"
grep -qx 'node_modules/' "$GREPO/.gitignore" \
  || fail "(I) the scaffold must PRESERVE the operator's existing .gitignore lines (non-destructive)"
grep -qx '\*.log' "$GREPO/.gitignore" \
  || fail "(I) the scaffold must preserve every operator .gitignore line, not just the first"
# idempotent: a second scaffold must not duplicate the line.
bash "$SCAFFOLD" "$GOV_PLUGIN" "$GREPO" "proj-x" filesystem >/dev/null 2>&1 \
  || fail "(I) second idc_init_scaffold.sh run failed"
n="$(grep -cxF '.idc-session-state.json*' "$GREPO/.gitignore")"
[ "$n" -eq 1 ] \
  || fail "(I) the gitignore ensure must be idempotent — expected exactly 1 '.idc-session-state.json*' line, got $n"
echo "  ok (I) scaffold gitignores .idc-session-state.json* idempotently + non-destructively"

# ── (K) concurrent writers — no lost updates (the ledger serializes its read-modify-write) ─────────
# Two+ hook/script processes recording DIFFERENT taints at once must not clobber each other: each does
# read → modify → atomic-replace, so without serialization the last replace wins and silently drops
# the rest (a dropped taint = a dropped obligation, the exact failure Phase 3 prevents). Launch KN
# concurrent sets; require ALL KN to survive.
# Red-when-broken: make idc_ledger._write_lock a bare `yield` (no lock) ⇒ the race drops taints ⇒ got < KN.
KREPO="$WORK/concurrent"; mkdir -p "$KREPO/docs/workflow"
printf 'backend: filesystem\n' > "$KREPO/docs/workflow/tracker-config.yaml"
KN=30
for i in $(seq 1 "$KN"); do led "$KREPO" set --kind mid_finish --key "$i" --session S1 & done
wait
got="$(led "$KREPO" pending --session S1 | grep -c '^mid_finish:')"
[ "$got" -eq "$KN" ] \
  || fail "(K) concurrent writers lost taints — expected $KN mid_finish taints, got $got [drop _write_lock ⇒ RED]"
echo "  ok (K) $KN concurrent writers all recorded — no lost updates (ledger serializes writes)"

echo "PASS: idc_ledger obligations ledger — path/roundtrip/mid_finish/stale-safety/corrupt-tolerance/repo-gate hold; the scaffold gitignores the state file idempotently & non-destructively; clear_taint is the red-when-broken headline"
