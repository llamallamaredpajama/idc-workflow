#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken (#155): the janitor's divergence pass tolerates a board item that has NO journal
# history whenever the item is numbered BELOW the adoption watermark (the earliest journaled create)
# — those predate journaling, so their missing history is legacy, not loss.
#
# On the github backend a create whose issue-number read-back failed journals a NUMBERLESS record
# (project_item_id only). The numbered watermark is then a LIE: the true first create may be the
# numberless one, so "below the first NUMBERED create" no longer means "predates journaling". Left
# unguarded the carve-out is fail-OPEN — items whose journal history is genuinely missing read as
# legacy and `/idc:doctor` Row 10 reports board↔git coherent when it is not.
#
# The engine's dispose corroboration has always guarded this (idc_transition._journal_corroboration
# → RP.has_numberless_create); the janitor was simply never wired to the same helper. Break the wire
# (drop `numberless_create` from check_journal_divergence) and cases 1 and 2 go green-when-broken →
# they FAIL. Cases 3 and 4 are the other half of the invariant: the carve-out must still be granted
# when the journal gives no reason to doubt the watermark (mutation-checked — see the header of the
# report; forcing the guard always-on makes them FAIL).

. "$(dirname "$0")/lib.sh"

REPO="$(mktemp -d)"; trap 'rm -rf "$REPO"' EXIT
mkdir -p "$REPO/docs/workflow"

# ── case 1: through the REAL janitor CLI — a numberless create voids the below-watermark carve-out ──
# Seeded board: #1 (no journal history at all) and #2 (journaled create). The journal's numberless
# create record is the github read-back gap. Pre-fix the watermark is #2, #1 < #2, and the janitor
# reports a clean journal dimension over an item with no history.
T="$(gov_new_tracker)"; TREPO="$(dirname "$T")"
trap 'rm -rf "$REPO" "$TREPO"' EXIT
git -C "$TREPO" init -b main >/dev/null 2>&1
git -C "$TREPO" config user.email "test@example.com" >/dev/null 2>&1
git -C "$TREPO" config user.name "Test" >/dev/null 2>&1
git -C "$TREPO" commit --allow-empty -m "initial commit" >/dev/null 2>&1

n1="$(gov_seed_item "$T" --title 'item with no journal history' --stage Buildable --status Todo)"
n2="$(gov_seed_item "$T" --title 'journaled create' --stage Buildable --status Todo)"
[ "$n1" = "1" ] && [ "$n2" = "2" ] || gov_fail "expected seeded items #1 and #2, got #$n1 and #$n2"

mkdir -p "$TREPO/docs/workflow"
cat > "$TREPO/docs/workflow/transition-journal.ndjson" <<JSON
{"when": "2026-01-01T00:00:00Z", "who": "engine", "what": "create-ticket 'read-back failed'", "op": "create-ticket", "backend": "github", "project_item_id": "PVTI_kwHOnumberless"}
{"when": "2026-01-01T00:01:00Z", "who": "engine", "what": "create-ticket 'journaled create'", "op": "create-ticket", "backend": "github", "item": $n2, "to": {"stage": "Buildable", "status": "Todo"}}
JSON

set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$TREPO" --json \
    --check-journal-divergence --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || gov_fail "expected exit 1 (a board item with no journal history is a finding), got $rc: $output"
echo "$output" | grep '"dim": "journal"' | grep -q "#$n1" || gov_fail \
    "the numberless create must VOID the below-watermark carve-out — #$n1 has no journal history and \
must be reported, got: $output"
echo "  ok (1) numberless create voids the carve-out through the janitor CLI (#$n1 reported)"

# ── cases 2–4: the boundary conditions, driven in-process against a synthetic board ────────────────
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || exit 1
import json, os, sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
from idc_git_janitor import check_journal_divergence

journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")

def seed(*records):
    with open(journal, "w", encoding="utf-8") as fh:
        for r in records:
            fh.write(json.dumps(r) + "\n")

NUMBERLESS = {"when": "2026-01-01T00:00:00Z", "who": "engine", "op": "create-ticket",
              "what": "create-ticket 'read-back failed'", "backend": "github",
              "project_item_id": "PVTI_kwHOnumberless"}

def create(num):
    return {"when": "2026-01-01T00:01:00Z", "who": "engine", "op": "create-ticket",
            "what": f"create-ticket 'item {num}'", "backend": "github", "item": num,
            "to": {"stage": "Buildable", "status": "Todo"}}

def board(*nums):
    return [{"number": n, "stage": "Buildable", "status": "Todo"} for n in nums]

def run(*nums):
    findings = []
    indeterminate = check_journal_divergence({"board": list(board(*nums))}, findings, journal)
    if indeterminate:
        raise SystemExit("the journal dimension must be determinate here (readable, well-formed "
                         "journal); check_journal_divergence returned indeterminate")
    return [f for f in findings if f.get("dim") == "journal"]

# 2. The watermark is None because the ONLY create is numberless. That None means "adopted, boundary
#    unknown" — NOT "pre-journal" — so nothing may be carved out. Pre-fix the lenient watermark
#    returned None too, and a None watermark tolerated the entire board.
seed(NUMBERLESS)
found = run(30)
if not any("#30" == f.get("name") for f in found):
    raise SystemExit(f"a numberless-only journal is ADOPTED with an unknown boundary — board item "
                     f"#30 has no journal history and must be reported; got {found}")
print("  ok (2) numberless-only journal: no carve-out (watermark None means unknown, not pre-journal)")

# 3. Regression anchor: a journal whose creates are ALL numbered keeps the legacy carve-out. #10 is
#    below the watermark (#20) and stays tolerated; #30 is above it and is reported. Break the fix by
#    forcing the numberless guard on and this case FAILs.
seed(create(20), create(30))
found = run(10, 20, 30)
if any("#10" == f.get("name") for f in found):
    raise SystemExit(f"#10 is below the numbered watermark #20 with no reason to doubt it — it must "
                     f"stay tolerated as pre-journal legacy; got {found}")
if found:
    raise SystemExit(f"#20 and #30 are both journaled creates carrying state; no finding expected, got {found}")
found = run(10, 20, 30, 40)
if not any("#40" == f.get("name") for f in found):
    raise SystemExit(f"#40 is above the watermark with no journal history — must be reported; got {found}")
print("  ok (3) all-numbered journal: below-watermark legacy still tolerated, above-watermark reported")

# 4. Regression anchor: a journal with NO create record at all has not adopted journaling — a
#    genuinely pre-journal board, where every board-only item is legacy.
seed({"when": "2026-01-01T00:00:00Z", "who": "engine", "op": "move", "item": 10,
      "what": "move #10 Todo -> In Progress", "backend": "github",
      "to": {"stage": "Buildable", "status": "In Progress"}})
findings = []
check_journal_divergence({"board": [{"number": 10, "stage": "Buildable", "status": "In Progress"},
                                    {"number": 99, "stage": "Buildable", "status": "Todo"}]},
                         findings, journal)
if [f for f in findings if f.get("dim") == "journal"]:
    raise SystemExit(f"no create record has ever been journaled — journaling is not adopted and every "
                     f"board-only item is legacy; got {findings}")
print("  ok (4) journal with no create record at all: pre-journal board, everything tolerated")
PY

echo "PASS: a numberless journaled create voids the below-watermark legacy carve-out (#155); the carve-out survives where the watermark is trustworthy"
