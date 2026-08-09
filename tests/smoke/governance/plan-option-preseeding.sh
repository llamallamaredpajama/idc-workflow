#!/bin/bash
# idc-assert-class: behavior
# plan-option-preseeding.sh — #208: a plan beyond wave 1 must not fail closed on a missing board option.
#
# THE DEFECT. `/idc:init` creates the `Wave` single-select with exactly ONE option (`Wave 1`) and
# `Phase` with one (`Phase 1`), and the field-creation helper never appends afterwards — it reports
# "already exists" and moves on. So a two-wave plan on a fresh board fails closed at `Wave 2`, and so
# does any new domain Plan invents (the plan agent is explicitly allowed to invent domains). The
# tracker skill's own doctrine says options are "pre-seeded before a setField that needs it"; nothing
# performed that pre-seeding. Pre-existing — 5.0.0 behaves identically.
#
# THE HAZARD THE FIX MUST NOT CREATE, and the reason this cannot be a one-line "replace the options"
# call: GitHub re-IDs EVERY option when a single-select's option list is replaced wholesale, which
# wipes the values already stored on items. The only safe append re-sends every existing option WITH
# its node id and adds the new one WITHOUT one. That is `idc_stage_options`' existing door, so the
# fix reuses it rather than minting a second write path.
#
# WHAT THIS LANE PROVES, against a stateful `gh` stub (no live GitHub):
#   1. the append is DERIVED FROM THE FROZEN TRANSACTION — only values an operation is about to set;
#   2. it is NON-DESTRUCTIVE — every pre-existing option keeps its node id, so item values survive;
#   3. `Status` and `Stage` are NEVER pre-seeded — their option sets are the machine's own enums, and
#      minting one from a plan's data would let a transaction invent a workflow state;
#   4. it is IDEMPOTENT — an option already present is a no-op, not a duplicate;
#   5. it is FAIL-SOFT — an unreachable board reports and changes nothing, because `set-field`'s own
#      missing-option refusal stays the fail-closed gate.
#
# Red-when-broken: see the per-case notes.
#
# Usage: bash tests/smoke/governance/plan-option-preseeding.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
SO="$PLUGIN/scripts/idc_stage_options.py"
TX="$PLUGIN/scripts/idc_tracker_transaction.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SO" ] || fail "missing shipped helper: scripts/idc_stage_options.py"
[ -f "$TX" ] || fail "missing shipped helper: scripts/idc_tracker_transaction.py"

T_S="${T_S:-120}"
command -v timeout >/dev/null 2>&1 \
  || fail "BLOCKED: \`timeout\` is not on PATH. Every probe here runs under an explicit bound so a
hung helper REDS instead of looking like a slow pass. Run via tests/smoke/run-all.sh (which sources
tests/smoke/smoke-path-preflight.sh), or install coreutils, then re-run."

REPO="$WORK/repo"
mkdir -p "$REPO"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init

# ── a STATEFUL `gh` stub: one JSON file IS the board's option state ───────────────────────────────
# Stateful, not canned, because the assertions below are about how state EVOLVES across appends —
# whether node ids survive, whether a second append sees the first one's result. A canned stub could
# not tell a non-destructive append from a destructive replace.
STATE="$WORK/fields.json"
cat > "$STATE" <<'JSON'
{
  "Wave":   {"id": "PVTSSF_WAVE",   "options": [{"id": "opt-w1", "name": "Wave 1",  "color": "GRAY", "description": ""}]},
  "Phase":  {"id": "PVTSSF_PHASE",  "options": [{"id": "opt-p1", "name": "Phase 1", "color": "GRAY", "description": ""}]},
  "Domain": {"id": "PVTSSF_DOMAIN", "options": [{"id": "opt-d1", "name": "core",    "color": "GRAY", "description": ""}]},
  "Stage":  {"id": "PVTSSF_STAGE",  "options": [{"id": "opt-s1", "name": "Buildable","color": "GRAY", "description": ""}]}
}
JSON

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env python3
import json, os, re, sys

STATE = os.environ["IDC_STUB_STATE"]
LOG = os.environ["IDC_STUB_LOG"]
argv = sys.argv[1:]
with open(LOG, "a", encoding="utf-8") as fh:
    fh.write(" ".join(argv) + "\n")

if os.environ.get("IDC_STUB_UNREACHABLE") == "1":
    sys.stderr.write("stub: board unreachable\n")
    sys.exit(1)

state = json.load(open(STATE, encoding="utf-8"))
query = ""
for i, a in enumerate(argv):
    if a.startswith("query="):
        query = a[len("query="):]

# READ: the field query this module uses to fetch {id, options[...]}.
m = re.search(r'field\(name:"([A-Za-z]+)"\)', query)
if m and "updateProjectV2Field" not in query:
    name = m.group(1)
    field = state.get(name)
    if field is None:
        print(json.dumps({"data": {"user": None, "organization": None}}))
        sys.exit(0)
    print(json.dumps({"data": {"user": {"projectV2": {"field": field}}, "organization": None}}))
    sys.exit(0)

# WRITE: the non-destructive append mutation.
if "updateProjectV2Field" in query:
    fid = re.search(r'fieldId:\s*"([^"]+)"', query).group(1)
    name = next(k for k, v in state.items() if v["id"] == fid)
    # Parse the option literals in order; an entry WITH an id preserves it, one without is created.
    opts = []
    block = query[query.index("singleSelectOptions:"):]
    for lit in re.finditer(r'\{([^{}]*)\}', block):
        body = lit.group(1)
        oid = re.search(r'id:\s*"([^"]+)"', body)
        nm = re.search(r'name:\s*"([^"]*)"', body)
        if not nm:
            continue
        opts.append({"id": oid.group(1) if oid else "opt-new-%d" % len(opts),
                     "name": nm.group(1), "color": "GRAY", "description": ""})
    state[name]["options"] = opts
    json.dump(state, open(STATE, "w", encoding="utf-8"))
    print(json.dumps({"data": {"updateProjectV2Field": {"projectV2Field": {
        "id": fid, "options": [{"id": o["id"], "name": o["name"]} for o in opts]}}}}))
    sys.exit(0)

sys.stderr.write("stub: unhandled gh invocation: %s\n" % " ".join(argv))
sys.exit(1)
SH
chmod +x "$BIN/gh"
LOG="$WORK/gh.log"
export IDC_STUB_STATE="$STATE" IDC_STUB_LOG="$LOG"

opt_names() {   # $1 = field name -> its option names, comma-joined, in order
  python3 -c '
import json,sys
print(",".join(o["name"] for o in json.load(open(sys.argv[1]))[sys.argv[2]]["options"]))' "$STATE" "$1"
}
opt_ids() {     # $1 = field name -> "name=id" pairs, so an id CHANGE is visible
  python3 -c '
import json,sys
print(",".join("%s=%s" % (o["name"], o["id"]) for o in json.load(open(sys.argv[1]))[sys.argv[2]]["options"]))' "$STATE" "$1"
}

WAVE_IDS_BEFORE="$(opt_ids Wave)"
[ "$WAVE_IDS_BEFORE" = "Wave 1=opt-w1" ] \
  || fail "fixture: the stub board must start with exactly one Wave option; got '$WAVE_IDS_BEFORE'"

# ── 1+2+3+4: pre-seed exactly the values a frozen transaction needs ───────────────────────────────
timeout "$T_S" env PATH="$BIN:$PATH" python3 - "$PLUGIN/scripts" "$REPO" <<'PY' >"$WORK/seed.out" 2>&1
import sys
scripts, repo = sys.argv[1:3]
sys.path.insert(0, scripts)
import idc_stage_options as SO

appended, problems = SO.ensure_options(repo, "acme", 7, {
    "Wave": ["Wave 1", "Wave 2", "Wave 3"],   # Wave 1 already present -> idempotent no-op
    "Phase": ["Phase 2"],
    "Domain": ["core", "telemetry"],          # core already present
})
print("appended=%s" % sorted(appended))
print("problems=%s" % problems)
PY
RC=$?
[ "$RC" -ne 124 ] || fail "the pre-seed probe hung (RED, never a slow pass)"
[ "$RC" -eq 0 ] || fail "the pre-seed probe exited $RC: $(cat "$WORK/seed.out")"

# (1) DERIVED: every requested value now exists...
for want in "Wave 2" "Wave 3"; do
  case ",$(opt_names Wave)," in
    *",$want,"*) ;;
    *) fail "#208: '$want' was not pre-seeded, so a plan beyond wave 1 still fails closed at it.
Wave options are now: $(opt_names Wave)
Probe said: $(cat "$WORK/seed.out")" ;;
  esac
done
case ",$(opt_names Phase)," in *",Phase 2,"*) ;; *) fail "#208: 'Phase 2' was not pre-seeded (Phase options: $(opt_names Phase))" ;; esac
case ",$(opt_names Domain)," in *",telemetry,"*) ;; *) fail "#208: the invented domain 'telemetry' was not pre-seeded (Domain options: $(opt_names Domain))" ;; esac

# (2) NON-DESTRUCTIVE: the pre-existing options keep their ORIGINAL node ids. This is the whole
# hazard — GitHub re-IDs every option on a wholesale replace, which silently wipes the values already
# stored on items, so an append that renumbers them is worse than no append at all.
case "$(opt_ids Wave)" in
  "Wave 1=opt-w1"*) ;;
  *) fail "#208: the append RENUMBERED an existing option. GitHub re-IDs every option when a
single-select's list is replaced wholesale, which wipes the values already on board items — the
append must re-send existing options WITH their node ids. Wave is now: $(opt_ids Wave)" ;;
esac
case "$(opt_ids Domain)" in
  "core=opt-d1"*) ;;
  *) fail "#208: the Domain append renumbered the existing 'core' option: $(opt_ids Domain)" ;;
esac

# (4) IDEMPOTENT: already-present values are no-ops, never duplicates.
[ "$(opt_names Wave | tr ',' '\n' | grep -cx 'Wave 1')" = "1" ] \
  || fail "#208: 'Wave 1' was duplicated — an already-present option must be a no-op"
grep -q "appended=\['Domain=telemetry', 'Phase=Phase 2', 'Wave=Wave 2', 'Wave=Wave 3'\]" "$WORK/seed.out" \
  || fail "#208: the pre-seed must report EXACTLY the options it created (no already-present ones).
Got: $(cat "$WORK/seed.out")"

# (3) THE REAL INTEGRATION POINT. Everything above exercises the helper; this drives
# `apply_frozen` itself, because a lane that only calls `ensure_options` stays green even if the
# whole call site is deleted from apply_frozen and `/idc:plan` pre-seeds nothing at all.
# The apply is expected to FAIL afterwards (the stub serves no board items) — the assertion is about
# what reached the helper BEFORE that, and about the ORDER the two happened in.
STAGE_BEFORE="$(opt_names Stage)"
FROZEN="$WORK/frozen.json"
# Built through the shipped writer's OWN digest function, so the bundle is one `apply_frozen` really
# accepts — a hand-rolled JSON blob would be rejected at load and the lane would assert nothing.
python3 - "$FROZEN" "$REPO" "$PLUGIN/scripts" <<'PY'
import json, sys
out, repo, scripts = sys.argv[1:4]
sys.path.insert(0, scripts)
import idc_tracker_transaction as TX
bundle = {
    "schema_version": TX.SCHEMA_VERSION,
    "repo": repo, "backend": "github", "owner": "acme", "project": 7, "tracker": "TRACKER.md",
    "obligation_relpath": "docs/workflow/plan-obligation.json",
    "label": "preseed-fixture",
    # The apply re-reads live rows and compares this digest; the probe stubs the read to [], so the
    # matching digest is the one the SHIPPED helper computes for an empty row set.
    "relevant_start_digest": TX.PR.sha256_json([]), "projection": [], "operations": [
        {"op": "set-field", "logical_id": "L1", "field": "Wave",   "value": "Wave 7"},
        {"op": "set-field", "logical_id": "L1", "field": "Phase",  "value": "Phase 7"},
        {"op": "set-field", "logical_id": "L1", "field": "Domain", "value": "ingest"},
        {"op": "set-field", "logical_id": "L1", "field": "Stage",  "value": "Recirculation"},
    ],
}
bundle["frozen_digest"] = TX._frozen_digest(bundle)
json.dump(bundle, open(out, "w", encoding="utf-8"))
PY
timeout "$T_S" env PATH="$BIN:$PATH" python3 - "$PLUGIN/scripts" "$REPO" "$FROZEN" <<'PY' >"$WORK/tx.out" 2>&1
import sys
scripts, repo, frozen = sys.argv[1:4]
sys.path.insert(0, scripts)
import idc_stage_options as SO
import idc_tracker_transaction as TX

seen = {}
order = []
real_ensure = SO.ensure_options
def spy(repo_, owner, project, wanted, color="GRAY"):
    seen.update(wanted)
    order.append("preseed")
    return real_ensure(repo_, owner, project, wanted, color)
SO.ensure_options = spy

real_oblig = TX._write_obligation
def oblig_spy(*a, **kw):
    order.append("obligation")
    return real_oblig(*a, **kw)
TX._write_obligation = oblig_spy

# The fixture serves no board items, so the live read is stubbed empty; the bundle's
# relevant_start_digest was computed for exactly that, so the real drift check still runs.
TX._live_rows = lambda *a, **kw: []

try:
    TX.apply_frozen(frozen, repo=repo, backend="github", owner="acme", project=7)
except Exception as exc:
    print("apply raised (expected past the pre-seed): %s: %s" % (type(exc).__name__, exc))
print("wanted=%s" % {k: sorted(v) for k, v in sorted(seen.items())})
print("order=%s" % order[:2])
PY
RC=$?
[ "$RC" -ne 124 ] || fail "the apply_frozen probe hung (RED)"
grep -q "wanted={'Domain': \['ingest'\], 'Phase': \['Phase 7'\], 'Wave': \['Wave 7'\]}" "$WORK/tx.out" \
  || fail "#208: apply_frozen must derive the pre-seed set from the FROZEN transaction and pass
exactly the Wave/Phase/Domain values it is about to set — with Stage EXCLUDED, because Status and
Stage option sets are the machine's own enums (workflow-machine.yaml) and minting one from a plan's
data would let a transaction invent a workflow state. Got:
$(cat "$WORK/tx.out")"
grep -q "order=\['obligation', 'preseed'\]" "$WORK/tx.out" \
  || fail "#208: the pending OBLIGATION must be persisted BEFORE the pre-seed's live board writes. A
board mutation that precedes its recovery record leaves state changed with nothing to recover from
if the process dies between them. Got:
$(cat "$WORK/tx.out")"
[ "$(opt_names Stage)" = "$STAGE_BEFORE" ] \
  || fail "#208: the Stage option set changed during pre-seeding — Stage must never be pre-seeded"

# ── 5: FAIL-SOFT — an unreachable board reports and changes nothing ───────────────────────────────
# `set-field`'s own missing-option refusal is the fail-closed gate (pinned honest by PR #207), so a
# pre-seed that cannot reach the board must not add a second failure mode.
BEFORE_ALL="$(opt_ids Wave)|$(opt_ids Phase)|$(opt_ids Domain)"
timeout "$T_S" env PATH="$BIN:$PATH" IDC_STUB_UNREACHABLE=1 python3 - "$PLUGIN/scripts" "$REPO" <<'PY' >"$WORK/soft.out" 2>&1
import sys
scripts, repo = sys.argv[1:3]
sys.path.insert(0, scripts)
import idc_stage_options as SO
appended, problems = SO.ensure_options(repo, "acme", 7, {"Wave": ["Wave 9"]})
print("appended=%s problems=%d" % (appended, len(problems)))
PY
RC=$?
[ "$RC" -ne 124 ] || fail "the fail-soft probe hung (RED)"
[ "$RC" -eq 0 ] \
  || fail "#208: an unreachable board must be REPORTED by the pre-seed, not raised — the set-field
refusal is the fail-closed gate, and a pre-seed that throws replaces a precise refusal with a crash.
Got exit $RC: $(cat "$WORK/soft.out")"
grep -q "appended=\[\] problems=1" "$WORK/soft.out" \
  || fail "#208: an unreachable board must yield no appends and exactly one reported problem. Got:
$(cat "$WORK/soft.out")"
[ "$BEFORE_ALL" = "$(opt_ids Wave)|$(opt_ids Phase)|$(opt_ids Domain)" ] \
  || fail "#208: the failed pre-seed mutated the board anyway"

# ── 6: a concurrent option-set write that CLOBBERS pre-existing options is reported ──────────────
# `cmd_apply`'s readback proves OUR option landed; it cannot see that someone else's vanished. Two
# appends that both read before either writes each resend a snapshot missing the other's option, and
# the last writer silently DELETES it along with every item value assigned to it. Simulated by a stub
# that drops the pre-existing options on the next write — a silently-emptied field must never read as
# a clean pre-seed.
cp "$STATE" "$WORK/state.bak"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env python3
import json, os, re, sys
STATE = os.environ["IDC_STUB_STATE"]
argv = sys.argv[1:]
state = json.load(open(STATE, encoding="utf-8"))
query = next((a[len("query="):] for a in argv if a.startswith("query=")), "")
m = re.search(r'field\(name:"([A-Za-z]+)"\)', query)
if m and "updateProjectV2Field" not in query:
    print(json.dumps({"data": {"user": {"projectV2": {"field": state[m.group(1)]}}, "organization": None}}))
    sys.exit(0)
if "updateProjectV2Field" in query:
    fid = re.search(r'fieldId:\s*"([^"]+)"', query).group(1)
    name = next(k for k, v in state.items() if v["id"] == fid)
    # THE CLOBBER: keep ONLY the newly appended option, as a racing writer's stale set would.
    new = [{"id": "opt-clobbered", "name": os.environ["IDC_STUB_NEWNAME"], "color": "GRAY", "description": ""}]
    state[name]["options"] = new
    json.dump(state, open(STATE, "w", encoding="utf-8"))
    print(json.dumps({"data": {"updateProjectV2Field": {"projectV2Field": {
        "id": fid, "options": [{"id": o["id"], "name": o["name"]} for o in new]}}}}))
    sys.exit(0)
sys.exit(1)
SH
chmod +x "$BIN/gh"
timeout "$T_S" env PATH="$BIN:$PATH" IDC_STUB_NEWNAME="Wave 42" python3 - "$PLUGIN/scripts" "$REPO" <<'PY' >"$WORK/clobber.out" 2>&1
import sys
scripts, repo = sys.argv[1:3]
sys.path.insert(0, scripts)
import idc_stage_options as SO
appended, problems = SO.ensure_options(repo, "acme", 7, {"Wave": ["Wave 42"]})
print("problems=%s" % problems)
PY
RC=$?
[ "$RC" -ne 124 ] || fail "the clobber probe hung (RED)"
grep -q "lost pre-existing option id" "$WORK/clobber.out" \
  || fail "#208: an append that made pre-existing option ids DISAPPEAR must be reported. The
mutation re-sends the whole option set, so a concurrent writer's stale snapshot deletes options —
and every item value assigned to them — while our own readback still says success. Got:
$(cat "$WORK/clobber.out")"
cp "$WORK/state.bak" "$STATE"

echo "PASS: a plan beyond wave 1 pre-seeds exactly the Wave/Phase/Domain options its frozen transaction needs, non-destructively (existing node ids survive), idempotently, never touching the Status/Stage enums, fail-soft when the board cannot be read, and loud when a concurrent write clobbers an option set"
