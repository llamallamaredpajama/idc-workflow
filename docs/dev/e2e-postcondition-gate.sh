#!/bin/bash
# e2e-postcondition-gate.sh — the sandbox e2e post-condition gate (design §E.3, RC6).
#
# OPERATOR-LOCAL DEV AID — not part of the shipped plugin, not lint-enforced. Wraps any spawned e2e
# wave with two guarantees the pre-#103 e2e loop lacked:
#   (1) a JANITOR SCAN post-condition — the run FAILS (non-zero) if the finished board↔git state is
#       incoherent (orphan worktrees, merged-but-surviving branches, board/issue drift). Reuses the
#       shipped deterministic reconciler `scripts/idc_git_janitor.py` (Unit 2) as the coherence oracle,
#       so the gate can never disagree with `/idc:janitor`.
#   (2) an API-COST DELTA — `gh api rate_limit` (graphql + core) is snapshotted before AND after the
#       wave and the delta is written into the run capture, making per-run GitHub API cost visible and
#       catching regressions of the §C cost fixes (item-id cache #98, rate-limit resilience #99).
#
# Usage:
#   e2e-postcondition-gate.sh --repo <dir> --backend github --owner <login> --project <N> \
#       --report <out.json> [--label <name>] -- <wave command...>
#   e2e-postcondition-gate.sh --repo <dir> --backend filesystem --tracker <TRACKER.md> \
#       --report <out.json> -- <wave command...>
#
# Everything after `--` is the wave (e.g. a spawned `claude -p "/idc:autorun"` per the repo CLAUDE.md
# spawn recipe). Omit it to gate the CURRENT state (a bare post-condition check). Exit code:
#   0 = wave ok AND janitor COHERENT ; 1 = janitor found incoherence (gate failed) ; 2 = bad args /
#   the janitor could not establish ground truth ; the wave's own non-zero exit is surfaced too.
#
# NOTE on remote-branch findings: the janitor reads the repo clone's remote-tracking refs
# (refs/remotes/origin/*). A clone that has not fetched recently can carry STALE tracking refs for
# branches already deleted on the remote — the gate runs `git fetch --prune` first so the scan sees
# live remote reality, not a stale cache.
set -uo pipefail

REPO="" BACKEND="" OWNER="" PROJECT="" TRACKER="" REPORT="" LABEL="wave"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --tracker) TRACKER="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "gate: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
WAVE_CMD=("$@")

[ -n "$REPO" ] && [ -n "$BACKEND" ] && [ -n "$REPORT" ] || { echo "gate: --repo, --backend, --report required" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/../.." && pwd)"          # docs/dev/ -> repo root
JAN="$HERE/scripts/idc_git_janitor.py"
[ -f "$JAN" ] || { echo "gate: janitor scanner not found at $JAN" >&2; exit 2; }

# One `gh api rate_limit` returns BOTH buckets — snapshot them in a single round-trip (the call
# itself doesn't consume the graphql/core budget, but one call beats the deltas' own gate over-spending).
snap() { gh api rate_limit --jq '[.resources.graphql.remaining, .resources.core.remaining] | @tsv' 2>/dev/null || printf 'NA\tNA'; }
delta() { case "$1$2" in *NA*) echo NA ;; *) echo $(( $1 - $2 )) ;; esac; }

# --- snapshot BEFORE (github backend only — a filesystem wave costs no API) -------------------------
if [ "$BACKEND" = "github" ]; then IFS=$'\t' read -r GQL0 CORE0 < <(snap); else GQL0=NA CORE0=NA; fi

# --- run the wave (if any); surface its exit but keep going to the gate -----------------------------
WAVE_RC=0
if [ "${#WAVE_CMD[@]}" -gt 0 ]; then
  echo "gate: driving wave [$LABEL]: ${WAVE_CMD[*]}"
  "${WAVE_CMD[@]}"; WAVE_RC=$?
  echo "gate: wave exit = $WAVE_RC"
fi

# --- snapshot AFTER ---------------------------------------------------------------------------------
if [ "$BACKEND" = "github" ]; then IFS=$'\t' read -r GQL1 CORE1 < <(snap); else GQL1=NA CORE1=NA; fi

# --- prune stale remote-tracking refs so the janitor sees live remote reality ----------------------
git -C "$REPO" fetch -q --prune origin 2>/dev/null || true

# --- the JANITOR post-condition (the gate) ----------------------------------------------------------
if [ "$BACKEND" = "github" ]; then
  [ -n "$OWNER" ] && [ -n "$PROJECT" ] || { echo "gate: github backend needs --owner and --project" >&2; exit 2; }
  python3 "$JAN" --repo "$REPO" --backend github --owner "$OWNER" --project "$PROJECT" --json > "$REPORT.janitor" 2>"$REPORT.err"
else
  [ -n "$TRACKER" ] || { echo "gate: filesystem backend needs --tracker" >&2; exit 2; }
  python3 "$JAN" --repo "$REPO" --tracker "$TRACKER" --json > "$REPORT.janitor" 2>"$REPORT.err"
fi
JAN_RC=$?

VERDICT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$REPORT.janitor" 2>/dev/null || echo unknown)"

# --- write the combined run report ------------------------------------------------------------------
python3 - "$REPORT" "$LABEL" "$GQL0" "$GQL1" "$CORE0" "$CORE1" "$(delta "$GQL0" "$GQL1")" \
  "$(delta "$CORE0" "$CORE1")" "$WAVE_RC" "$JAN_RC" "$VERDICT" "$REPORT.janitor" <<'PY'
import json, sys
(out,label,g0,g1,c0,c1,gd,cd,wave_rc,jan_rc,verdict,jfile)=sys.argv[1:13]
try: jan=json.load(open(jfile))
except Exception: jan={}
rep={"label":label,
     "api_cost":{"graphql_before":g0,"graphql_after":g1,"graphql_delta":gd,
                 "core_before":c0,"core_after":c1,"core_delta":cd},
     "wave_exit":int(wave_rc),
     "janitor":{"exit":int(jan_rc),"verdict":verdict,"counts":jan.get("counts"),
                "findings":jan.get("findings")}}
json.dump(rep,open(out,"w"),indent=2); open(out,"a").write("\n")
print(f"gate: [{label}] API cost — graphql Δ={gd} core Δ={cd}")
print(f"gate: janitor verdict={verdict} (exit {jan_rc}); counts={jan.get('counts')}")
PY

# --- gate verdict: fail the run on incoherence or a wave failure ------------------------------------
[ "$WAVE_RC" -ne 0 ] && { echo "gate: FAILED — the wave itself exited $WAVE_RC"; exit "$WAVE_RC"; }
[ "$JAN_RC" -eq 0 ] && { echo "gate: PASS — coherent end-state, wave clean (report: $REPORT)"; exit 0; }
echo "gate: FAILED — janitor found incoherence ($VERDICT); review $REPORT before trusting this drain"
exit "$JAN_RC"
