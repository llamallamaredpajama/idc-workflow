#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: the recirc sweep's Stage=Recirculation re-stage is a sanctioned mutation door, so it
# MUST append the canonical transition-journal record (issue #150 — journal every non-engine door).
# Without it, journal replay reports the swept item as a FALSE Stage divergence. This proves BOTH
# backends (filesystem apply + github apply) journal the re-stage, and that a lifecycle INCLUDING a
# sweep re-stage reconstructs to an EMPTY replay diff (the #150 replay-consistency hard requirement).

. "$(dirname "$0")/lib.sh"
gov_engine_env

SWEEP="$GOV_PLUGIN/scripts/idc_recirc_sweep.py"
REPLAY="$GOV_PLUGIN/scripts/idc_journal_replay.py"
JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"

# ── filesystem re-stage journals + replays clean ────────────────────────────────────────────────
# The sweep acts only when a provenance regime is in play: a tracker-config (backend) + a pillar
# matrix (so decide() is not skip-no-matrix). A discovery-marked rogue Buildable is an unambiguous
# re-stage even on a filesystem board (the marker rides in an issue comment).
mkdir -p "$REPO/docs/workflow/pillar-matrices"
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'YAML'
backend: filesystem
YAML
cat > "$REPO/docs/workflow/pillar-matrices/p1.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: p1
    wave: 1
    domain: x
    surfaces: [a/]
YAML

# Seed the rogue THROUGH the engine so its create is journaled (the replay baseline). The discovery
# marker rides in as the create body → a comment scan_filesystem reads → decide() = restage.
MARKER='<!-- idc-discovery: {"what":"x","area":"y","suggested_scope":"z","origin":"#1"} -->'
rogue=$(eng create-ticket --title 'rogue buildable' --body "$MARKER")
[ -f "$JOURNAL" ] || fail "engine create did not write the journal baseline"

# Sanity: before the sweep the item is Buildable/Todo on BOTH journal and board → replay is clean.
python3 "$REPLAY" --journal "$JOURNAL" --tracker "$T" >/dev/null \
  || fail "pre-sweep replay should be clean (baseline sanity)"

# The re-stage (fail-soft auto-correct) must move the rogue to Recirculation AND journal it.
python3 "$SWEEP" --repo "$REPO" --auto-correct || fail "auto-correct must be fail-soft (exit 0)"
[ "$(gov_field "$T" "$rogue" Stage)" = "Recirculation" ] \
  || fail "sweep must re-stage the rogue to Recirculation (got '$(gov_field "$T" "$rogue" Stage)')"

# (1) the journal now carries a re-stage record for the rogue with to.stage = Recirculation.
python3 - "$JOURNAL" "$rogue" <<'PY' || fail "sweep re-stage did not append a canonical journal record (item + to.stage=Recirculation)"
import json, sys
journal, rogue = sys.argv[1], int(sys.argv[2])
recs = [json.loads(l) for l in open(journal, encoding="utf-8") if l.strip()]
restage = [r for r in recs if r.get("item") == rogue and (r.get("to") or {}).get("stage") == "Recirculation"]
if not restage:
    raise SystemExit(f"no re-stage journal record for #{rogue} with to.stage=Recirculation; saw {recs}")
PY
echo "  ok (1) filesystem re-stage appended a canonical journal record"

# (2) THE hard requirement: the full lifecycle (engine create + sweep re-stage) replays to an EMPTY
#     diff. If the re-stage were NOT journaled, replay would say journal='Buildable', board='Recirculation'.
python3 "$REPLAY" --journal "$JOURNAL" --tracker "$T" \
  || fail "post-sweep replay must be clean — the re-stage journal must reconcile journal↔board (#150)"
echo "  ok (2) lifecycle with a sweep re-stage replays to an empty diff"

# ── github re-stage journals (hermetic; the gh/board IO boundaries are monkeypatched) ────────────
python3 - "$GOV_PLUGIN/scripts" <<'PY' || fail "github re-stage did not journal a canonical record"
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m

repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
# read_config supplies the Stage/Wave field ids the re-stage chain resolves.
m.read_config = lambda r: ("7", {"Stage": "PVTF_stage", "Wave": "PVTF_wave"})
# Scripted gh: field-list resolves the Recirculation option id, every item-edit succeeds.
def gh(args, r):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    return True, "", ""
m.gh = gh

ctx = {"owner": "o", "project_node": "PVT_node", "project_number": "7"}
f = m.Finding(207, m.RESTAGE, "rogue, regime active", wave="Wave 2", item_id="PVTI_207")
changed = m.apply_github([f], repo, ctx, lambda _l: None)
if changed != 1:
    raise SystemExit(f"github re-stage should count 1 board change, got {changed}")

journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
recs = [json.loads(l) for l in open(journal, encoding="utf-8") if l.strip()]
restage = [r for r in recs if r.get("item") == 207 and (r.get("to") or {}).get("stage") == "Recirculation"]
if not restage:
    raise SystemExit(f"no github re-stage journal record for #207; saw {recs}")
rec = restage[-1]
if rec.get("backend") != "github":
    raise SystemExit(f"github re-stage record must record backend=github; got {rec.get('backend')}")
if rec.get("project_item_id") != "PVTI_207":
    raise SystemExit(f"github re-stage record must carry the project_item_id; got {rec.get('project_item_id')}")
print("  ok (3) github re-stage appended a canonical journal record (backend=github, project_item_id)")
PY

echo "PASS: recirc sweep journals its Stage=Recirculation re-stage on both backends and replays to an empty diff."
