#!/bin/bash
# idc-assert-class: behavior
# pilot-metrics-contract.sh — U9 capstone: the source-heavy pilot evidence contract (HERMETIC).
#
# Graph spec §15.5.7 makes "at least one source-heavy pilot repository measures provider usefulness"
# a MUST for release, and §15.6 names the ten operational metrics the pilot records. Release evidence
# is therefore only as good as the artifact that carries it — so `pilot-metrics.json` gets a FIXED
# schema with a fixed validator, and the release gate REFUSES evidence that is missing, stale,
# malformed, or measured on a repository that is not actually source-heavy.
#
# What it proves:
#   A. scripts/idc_pilot_metrics.py exists and accepts a well-formed, source-heavy, SHA-bound pilot;
#   B. every one of the ten §15.6 metrics is required AT ITS EXACT FIELD PATH — drop any single leaf
#      and validation refuses (a metric that can silently vanish is not evidence);
#   C. identity binding — the pilot must name the exact reviewed SHA final evidence binds to, and a
#      mismatched/absent SHA is refused (stale evidence cannot ride along to a later head);
#   D. lane receipts are bound by digest — a missing receipt file, or one whose bytes changed after
#      the metrics were written, is refused;
#   E. a NON-source-heavy pilot is refused on a deterministic, stated criterion (file count, source
#      LOC, and source share of total LOC) — a docs/config repo cannot satisfy §15.5.7;
#   F. release-evidence mode — `idc_release_check.py --require-pilot-evidence` REFUSES missing/stale/
#      malformed pilot metrics, while a PLAIN `idc_release_check.py` run stays usable for ordinary
#      local/dev/lint invocations (the gate is the final-evidence door, not a dev tax).
#
# Red-when-broken: neuter any single refusal in idc_pilot_metrics.py (or drop the release-evidence
# flag) and the matching assertion fails.
#
# Usage: bash tests/smoke/governance/pilot-metrics-contract.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
PM="$PLUGIN/scripts/idc_pilot_metrics.py"
RC="$PLUGIN/scripts/idc_release_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# --- existence (the honest RED reason: nothing implemented yet) ---------------------------------
[ -f "$PM" ] || fail "pilot metrics validator not implemented yet: scripts/idc_pilot_metrics.py"
[ -f "$RC" ] || fail "release check missing: scripts/idc_release_check.py"

SHA="0123456789abcdef0123456789abcdef01234567"
OTHER_SHA="fedcba9876543210fedcba9876543210fedcba98"

# seed <dir> — writes a VALID pilot bundle (metrics + the two lane receipt files it binds).
seed() {
  DEST="$1" SHA="$SHA" python3 - <<'PY'
import hashlib, json, os

dest = os.environ["DEST"]
os.makedirs(dest, exist_ok=True)

receipts = {}
for name in ("pilot-source-heavy.log", "pilot-source-heavy-gate.json"):
    path = os.path.join(dest, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("pilot lane receipt: %s\n" % name)
    with open(path, "rb") as fh:
        receipts[name] = hashlib.sha256(fh.read()).hexdigest()

doc = {
    "schema_version": 1,
    "pilot": {
        "repository": "example-org/source-heavy-pilot",
        "reviewed_sha": os.environ["SHA"],
        "approved_by": "operator",
        "backend": "github",
        "pathway_mode": "controlled",
        "composition": {
            "source_files": 214,
            "source_loc": 28114,
            "total_files": 301,
            "total_loc": 34980,
        },
        "lane_receipts": [
            {"lane": "pilot-source-heavy", "path": name, "sha256": digest}
            for name, digest in sorted(receipts.items())
        ],
    },
    "metrics": {
        "planning_horizon_omissions": {"count": 3},
        "dependency_order_corrections_before_build": {"count": 5},
        "graph_board_divergence_frequency": {"count": 2, "rate_per_run": 0.18},
        "merge_file_surface_conflicts": {"count": 1},
        "missing_boundary_detections": {"count": 4},
        "outside_path_work_routed": {"count": 6},
        "recirculation": {"rate": 0.22, "repeat_count": 2},
        "janitor_convergence": {"pass_counts": [1, 2, 1], "false_positive_count": 1},
        "planning_cost": {"planning_seconds": 412.5, "api_cost_delta": 1.37},
        "provider_precision_recall": {
            "surfaces_precision": 0.88,
            "surfaces_recall": 0.79,
            "tests_precision": 0.81,
            "tests_recall": 0.74,
        },
    },
}
with open(os.path.join(dest, "pilot-metrics.json"), "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2)
PY
}

validate() { python3 "$PM" validate --metrics "$1/pilot-metrics.json" --reviewed-sha "${2:-$SHA}"; }

# --- A. a well-formed, source-heavy, SHA-bound pilot is ACCEPTED ---------------------------------
OK="$WORK/ok"
seed "$OK" || fail "could not seed the valid pilot fixture"
validate "$OK" >"$WORK/ok.out" 2>"$WORK/ok.err" \
  || fail "a well-formed source-heavy pilot bundle was rejected: $(cat "$WORK/ok.err")"

# --- refute(): break exactly one thing in a fresh copy; the validator MUST reject it -------------
n=0
refute() {
  local label="$1" body="$2" sha="${3:-$SHA}"
  n=$((n + 1))
  local dir="$WORK/refute-$n"
  seed "$dir" || fail "could not seed fixture for refutation: $label"
  MET="$dir/pilot-metrics.json" DIR="$dir" python3 - "$body" <<'PY' || fail "mutation failed to apply: $label"
import json, os, sys
path = os.environ["MET"]
d = json.load(open(path, encoding="utf-8"))
DIR = os.environ["DIR"]
exec(sys.argv[1])
with open(path, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2)
PY
  if validate "$dir" "$sha" >"$dir/out" 2>"$dir/err"; then
    fail "REFUTATION $n ACCEPTED — $label (the validator must refuse this)"
  fi
  # A refusal must be a NAMED FINDING, not a crash. Mutation testing found three neuters
  # (`if not os.path.isfile(...)` -> `if False:`, `if leaf not in body:` -> `if False:`) that kept this
  # scenario green only because the validator blew up on the very next line — a traceback exits
  # non-zero, so "did it exit non-zero" could not tell a working guard from a deleted one. Requiring a
  # clean refusal makes each guard independently provable.
  if grep -q 'Traceback (most recent call last)' "$dir/err"; then
    fail "REFUTATION $n CRASHED instead of refusing cleanly — $label: $(grep -m1 'Error' "$dir/err")"
  fi
  grep -q 'idc-pilot-metrics:' "$dir/err" \
    || fail "REFUTATION $n produced no named finding — $label: $(head -2 "$dir/err")"
}

# --- B. every one of the ten §15.6 metrics is required at its EXACT field path -------------------
# The exact paths the dispatch manifest §6.6 binds release evidence to. Dropping any single leaf must
# fail — otherwise a metric could silently vanish from the pilot artifact.
while IFS= read -r leaf; do
  [ -n "$leaf" ] || continue
  group="${leaf%%.*}"
  field="${leaf#*.}"
  refute "missing metrics.$leaf" \
    "d['metrics']['$group'].pop('$field')"
done <<'LEAVES'
planning_horizon_omissions.count
dependency_order_corrections_before_build.count
graph_board_divergence_frequency.count
graph_board_divergence_frequency.rate_per_run
merge_file_surface_conflicts.count
missing_boundary_detections.count
outside_path_work_routed.count
recirculation.rate
recirculation.repeat_count
janitor_convergence.pass_counts
janitor_convergence.false_positive_count
planning_cost.planning_seconds
planning_cost.api_cost_delta
provider_precision_recall.surfaces_precision
provider_precision_recall.surfaces_recall
provider_precision_recall.tests_precision
provider_precision_recall.tests_recall
LEAVES

# a whole metric group missing, and a wrongly-typed metric
refute "the entire provider_precision_recall group missing" "d['metrics'].pop('provider_precision_recall')"
refute "a count that is not a number"                        "d['metrics']['missing_boundary_detections']['count'] = 'many'"
refute "a negative count"                                    "d['metrics']['outside_path_work_routed']['count'] = -1"
refute "a precision outside [0,1]"                           "d['metrics']['provider_precision_recall']['tests_recall'] = 1.4"
refute "empty janitor pass_counts"                           "d['metrics']['janitor_convergence']['pass_counts'] = []"

# --- C. identity binding: the exact reviewed SHA ------------------------------------------------
refute "reviewed_sha disagrees with the head final evidence binds to" \
  "d['pilot']['reviewed_sha'] = '$OTHER_SHA'"
refute "reviewed_sha missing"          "d['pilot'].pop('reviewed_sha')"
refute "reviewed_sha not a full sha"   "d['pilot']['reviewed_sha'] = 'abc123'"
refute "pilot repository missing"      "d['pilot'].pop('repository')"
refute "operator approval missing"     "d['pilot'].pop('approved_by')"
refute "unknown schema_version"        "d['schema_version'] = 99"

# the same VALID bundle refused when the caller binds it to a different head
if validate "$OK" "$OTHER_SHA" >/dev/null 2>&1; then
  fail "a valid pilot bundle was accepted against a DIFFERENT reviewed SHA — evidence must bind to one exact head"
fi

# --- D. lane receipts are bound by digest -------------------------------------------------------
refute "no pilot lane receipt at all"  "d['pilot']['lane_receipts'] = []"
refute "a lane receipt that names no file" \
  "d['pilot']['lane_receipts'][0].pop('path')"
refute "a lane receipt whose digest does not match its bytes" \
  "d['pilot']['lane_receipts'][0]['sha256'] = '0'*64"
refute "a lane receipt pointing at a file that does not exist" \
  "d['pilot']['lane_receipts'][0]['path'] = 'nope-missing.log'"

# a receipt that CHANGED after the metrics were written (staleness, not absence)
STALE="$WORK/stale"
seed "$STALE" || fail "could not seed the stale-receipt fixture"
printf 'the lane was re-run after the metrics were written\n' >> "$STALE/pilot-source-heavy.log"
if validate "$STALE" >/dev/null 2>"$WORK/stale.err"; then
  fail "a pilot bundle whose lane receipt changed after the fact was accepted — stale evidence must be refused"
fi
grep -qi 'stale' "$WORK/stale.err" \
  || fail "the stale-receipt refusal must say the receipt changed after the metrics were written: $(cat "$WORK/stale.err")"

# --- E. a NON-source-heavy pilot is refused on a deterministic criterion -------------------------
# Each of the three thresholds is refuted IN ISOLATION — the other two stay satisfied — so a
# neutered floor cannot hide behind a sibling floor still doing the rejecting. (Mutation testing
# caught exactly that: zeroing MIN_SOURCE_LOC left this scenario green because the old fixture also
# tripped the source-share floor.)
refute "too few source files (file floor alone)" \
  "d['pilot']['composition']['source_files'] = 4"
refute "too little source LOC (LOC floor alone: share and file count stay healthy)" \
  "d['pilot']['composition'].update({'source_loc': 400, 'total_loc': 700, 'total_files': 301})"
refute "source is a minority of the repo — a docs/config repo (share floor alone)" \
  "d['pilot']['composition'].update({'source_loc': 6000, 'total_loc': 60000})"
refute "composition evidence missing entirely" "d['pilot'].pop('composition')"

# --- malformed input --------------------------------------------------------------------------
BAD="$WORK/malformed"; mkdir -p "$BAD"
printf '{ this is not json' > "$BAD/pilot-metrics.json"
python3 "$PM" validate --metrics "$BAD/pilot-metrics.json" --reviewed-sha "$SHA" >/dev/null 2>&1 \
  && fail "malformed pilot metrics JSON was accepted"
python3 "$PM" validate --metrics "$WORK/does-not-exist.json" --reviewed-sha "$SHA" >/dev/null 2>&1 \
  && fail "a missing pilot metrics file was accepted"

# --- F. release-evidence mode -------------------------------------------------------------------
# The plain invocation stays usable for ordinary local/dev/lint runs (lint-references.sh calls it on
# every commit) — it must NOT start demanding pilot evidence.
python3 "$RC" >/dev/null 2>"$WORK/plain.err" \
  || fail "the plain release check must stay green for ordinary local runs: $(cat "$WORK/plain.err")"

# ...but the final-evidence gate refuses missing / malformed / stale pilot evidence.
python3 "$RC" --require-pilot-evidence "$WORK/nope/pilot-metrics.json" --reviewed-sha "$SHA" \
  >/dev/null 2>"$WORK/miss.err" \
  && fail "release-evidence mode ACCEPTED a missing pilot-metrics.json"
grep -qi 'pilot' "$WORK/miss.err" \
  || fail "the missing-pilot-evidence refusal must name the pilot metrics: $(cat "$WORK/miss.err")"

python3 "$RC" --require-pilot-evidence "$BAD/pilot-metrics.json" --reviewed-sha "$SHA" \
  >/dev/null 2>&1 \
  && fail "release-evidence mode ACCEPTED malformed pilot metrics"

python3 "$RC" --require-pilot-evidence "$OK/pilot-metrics.json" --reviewed-sha "$OTHER_SHA" \
  >/dev/null 2>&1 \
  && fail "release-evidence mode ACCEPTED pilot metrics bound to a different reviewed SHA"

python3 "$RC" --require-pilot-evidence "$STALE/pilot-metrics.json" --reviewed-sha "$SHA" \
  >/dev/null 2>&1 \
  && fail "release-evidence mode ACCEPTED a pilot whose lane receipt went stale"

NSH="$WORK/not-source-heavy"
seed "$NSH" || fail "could not seed the non-source-heavy fixture"
MET="$NSH/pilot-metrics.json" python3 - <<'PY'
import json, os
p = os.environ["MET"]
d = json.load(open(p, encoding="utf-8"))
d["pilot"]["composition"] = {"source_files": 3, "source_loc": 90,
                             "total_files": 260, "total_loc": 41000}
json.dump(d, open(p, "w", encoding="utf-8"), indent=2)
PY
python3 "$RC" --require-pilot-evidence "$NSH/pilot-metrics.json" --reviewed-sha "$SHA" \
  >/dev/null 2>"$WORK/nsh.err" \
  && fail "release-evidence mode ACCEPTED a pilot repository that is not source-heavy (§15.5.7)"
grep -qi 'source-heavy' "$WORK/nsh.err" \
  || fail "the non-source-heavy refusal must say so: $(cat "$WORK/nsh.err")"

# release-evidence mode cannot be satisfied without naming the head it binds to
python3 "$RC" --require-pilot-evidence "$OK/pilot-metrics.json" >/dev/null 2>&1 \
  && fail "release-evidence mode ACCEPTED pilot evidence with no --reviewed-sha to bind it to"

# ...and the well-formed bundle at the right head PASSES the gate.
python3 "$RC" --require-pilot-evidence "$OK/pilot-metrics.json" --reviewed-sha "$SHA" \
  >/dev/null 2>"$WORK/good.err" \
  || fail "release-evidence mode rejected valid, source-heavy, correctly-bound pilot evidence: $(cat "$WORK/good.err")"

echo "PASS: pilot metrics carry the ten §15.6 metrics at exact field paths, bind to one reviewed SHA and digest-checked lane receipts, prove a source-heavy pilot, and gate release evidence ($n refutations refused)"
