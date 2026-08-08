#!/bin/bash
# tracker-transaction-github-body-provenance.sh — governance scenario (U12 / final-review B1).
#
# THE DEFECT (B1): the sanctioned U5 planning transaction mints github Buildable issues with an EMPTY
# body. `_execute_operation` hardcoded `body=""`, `build_operations` carried only title/stage/status,
# and `freeze`/`apply` took no body input — so the model-authored goal-contract body + its
# machine-derived provenance marker never reached the `gh issue create --body …` door the transaction
# already drives. `idc_provenance_check.py` then re-reads each issue's LIVE body and exit-2-halts Plan,
# and no sanctioned body-edit door exists to recover: Plan→Build cannot complete on github.
#
# THE FIX (Option A — restore create-with-body through the EXISTING sanctioned door): `freeze` gains an
# optional `--bodies <map.json>` ({logical_id: model-authored body}); for each github create-ticket op
# it derives the provenance marker in FIXED CODE from (basename(matrix), logical_id) and APPENDS it to
# the authored body; the composed body rides the frozen op (covered by operations_digest → tamper-
# evident); `_execute_operation` passes it to the create call; and after the live postcondition passes,
# a github-only body-marker postcondition re-reads each minted issue's LIVE body and asserts the marker
# landed. Filesystem behaviour is byte-for-byte unchanged (its creates carry no body → still "").
#
# HERMETIC — no credential, no network. A stateful fake `gh` on a temp PATH bindir records
# `issue create --body`, reflects `project item-edit` field writes, and serves the graphql board/item
# reads + `issue view --json body` the transaction's github path (and idc_provenance_check) make.
#
# Red-when-broken (proven by the U12 mutation neuters):
#   * hardcode `body=""` in _execute_operation      → recorded body empty → provenance miss → RED.
#   * drop the marker-append in freeze               → recorded body lacks the marker → RED.
#   * drop the fail-closed missing-body guard         → the missing-body freeze case stops failing → RED.
# On the B1 (pre-fix) head, `freeze` rejects the unknown `--bodies` flag, so assertion A1 FAILs — the
# exact B1 signature (no body channel), hermetically reproduced.
#
# Usage: bash tests/smoke/governance/tracker-transaction-github-body-provenance.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PLUGIN="$GOV_PLUGIN"
TXN="$PLUGIN/scripts/idc_tracker_transaction.py"
PROV="$PLUGIN/scripts/idc_provenance_check.py"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$TXN" ]  || fail "missing sanctioned tracker transaction helper: $TXN"
[ -f "$PROV" ] || fail "missing provenance post-condition helper: $PROV"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── the stateful hermetic fake `gh` ────────────────────────────────────────────────────────────────
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env python3
# Hermetic fake `gh` for the U12 github body-provenance governance test. Stateful in $GH_STATE (JSON):
# records `issue create --body`, reflects `project item-edit` single-select writes, and serves the
# graphql whole-board / single-item reads + `issue view --json body` the transaction + provenance
# check drive. Any unmodelled call exits non-zero LOUDLY (never a silent empty board).
import json, os, sys

args = sys.argv[1:]
STATE = os.environ["GH_STATE"]
PNODE = "PVT_test"

def load():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"next": 1, "issues": {}, "items": {}}

def save(s):
    with open(STATE, "w") as fh:
        json.dump(s, fh)

_FIELD_OPTS = {
    "Stage":  ["Buildable", "Consideration", "Planning", "Recirculation"],
    "Status": ["Todo", "In Progress", "Blocked", "Done"],
    # The fake board must carry the options /idc:init actually provisions. Wave is a LABEL
    # single-select (`Wave 1`), like Phase below — bare numbers modelled a board no init ever
    # creates, and let a bare-number `set-field Wave` resolve here that fails on a real one (#206).
    "Wave":   ["Wave %d" % i for i in range(1, 8)],
    "Phase":  ["Phase 1", "Phase 2", "Phase 3"],
    "Domain": ["core", "api", "cli", "docs"],
}
def _fid(f): return "FID_" + f
def _oid(f, o): return "OID_%s__%s" % (f, o)
FIELDS = {"fields": [
    {"name": f, "id": _fid(f), "options": [{"name": o, "id": _oid(f, o)} for o in opts]}
    for f, opts in _FIELD_OPTS.items()
]}
FID2NAME = {_fid(f): f for f in _FIELD_OPTS}
OID2NAME = {_oid(f, o): o for f, opts in _FIELD_OPTS.items() for o in opts}

def _val(flag):
    return args[args.index(flag) + 1] if flag in args else None

def _node(iid, item, issues):
    num = item["number"]
    issue = issues[str(num)]
    fvs = [{"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": v, "field": {"name": k}}
           for k, v in item["fields"].items()]
    return {"id": iid, "fieldValues": {"nodes": fvs},
            "content": {"__typename": "Issue", "number": num, "title": issue["title"],
                        "repository": {"nameWithOwner": "o/r"}}}

def out(s):
    sys.stdout.write(s)
    if not s.endswith("\n"):
        sys.stdout.write("\n")

s = load()

if args[:2] == ["api", "rate_limit"]:
    out(json.dumps({"resources": {"graphql": {"remaining": 5000, "reset": 9999999999},
                                  "core": {"remaining": 5000, "reset": 9999999999}}}))
    sys.exit(0)

if args[:2] == ["api", "graphql"]:
    pid = next((a for a in args if a.startswith("pid=")), None)
    iid = next((a for a in args if a.startswith("id=")), None)
    if pid is not None:                                   # whole-board items connection
        nodes = [_node(k, v, s["issues"]) for k, v in s["items"].items()]
        out(json.dumps({"data": {"node": {"items": {
            "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}}))
        sys.exit(0)
    if iid is not None:                                   # single node(id:) read
        key = iid[len("id="):]
        item = s["items"].get(key)
        out(json.dumps({"data": {"node": _node(key, item, s["issues"]) if item else None}}))
        sys.exit(0)
    sys.stderr.write("FAKE-GH UNHANDLED graphql: %r\n" % args); sys.exit(1)

if args[:1] == ["api"] and len(args) > 1 and "dependencies/blocked_by" in args[1]:
    sys.exit(0)                                           # no native blocked-by edges

if args[:2] == ["project", "view"]:
    if "--jq" in args and args[args.index("--jq") + 1] == ".id":
        out(PNODE); sys.exit(0)
    out(json.dumps({"id": PNODE, "number": int(args[2]), "title": "T"})); sys.exit(0)

if args[:2] == ["project", "field-list"]:
    out(json.dumps(FIELDS)); sys.exit(0)

if args[:2] == ["project", "item-add"]:
    num = (_val("--url") or "").rstrip("/").split("/")[-1]
    iid = "PVTI_" + str(num)
    s["items"][iid] = {"number": int(num), "fields": {}}
    save(s); out(iid); sys.exit(0)

if args[:2] == ["project", "item-edit"]:
    if "--clear" in args:
        sys.exit(0)
    iid = _val("--id")
    fname = FID2NAME.get(_val("--field-id")); oname = OID2NAME.get(_val("--single-select-option-id"))
    if fname is None or oname is None:
        sys.stderr.write("FAKE-GH item-edit unknown field/option: %r\n" % args); sys.exit(1)
    s["items"].setdefault(iid, {"number": None, "fields": {}})["fields"][fname] = oname
    save(s); sys.exit(0)

if args[:2] == ["issue", "create"]:
    num = s["next"]; s["next"] = num + 1
    s["issues"][str(num)] = {"title": _val("--title") or "", "body": _val("--body") or ""}
    save(s); out("https://github.com/o/r/issues/%d" % num); sys.exit(0)

if args[:2] == ["issue", "view"]:
    if "--json" in args and "body" in (_val("--json") or "") and "-q" in args:
        issue = s["issues"].get(str(args[2]))
        out(issue["body"] if issue else ""); sys.exit(0)
    sys.stderr.write("FAKE-GH UNHANDLED issue view: %r\n" % args); sys.exit(1)

if args[:2] == ["issue", "close"]:
    sys.exit(0)

sys.stderr.write("FAKE-GH UNHANDLED: %r\n" % args); sys.exit(1)
STUB
chmod +x "$BIN/gh"

# ── the governed repo + one-pillar matrix ──────────────────────────────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: github\n' > "$REPO/docs/workflow/tracker-config.yaml"
MATRIX="$REPO/phase1-matrix.yaml"
cat > "$MATRIX" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/alpha/]
    blocks_on: []
YAML
MBASE="$(basename "$MATRIX")"
PROSE='GOAL: ship alpha. VERIFICATION SURFACE: run the alpha tests. CONSTRAINTS: existing suite green.'
# The EXACT machine-derived marker fixed code must append — computed the same way so the assertion can
# never silently drift from the implementation.
MARKER="$(python3 - "$MBASE" alpha <<'PY'
import json, sys
print("<!-- idc-provenance: " + json.dumps({"matrix": sys.argv[1], "pillar": sys.argv[2]},
      separators=(",", ":")) + " -->")
PY
)"

export GH_STATE="$WORK/state.json"
gh_reset() { rm -f "$GH_STATE"; }
run_gh() { ( cd "$REPO" && PATH="$BIN:$PATH" GH_STATE="$GH_STATE" "$@" ); }

write_bodies() {  # write a bodies map JSON: write_bodies <path> <json-object-literal>
  printf '%s' "$2" > "$1"
}

freeze_gh() {  # freeze_gh <bodies-arg…> ; leaves $FZ / rc in the caller. Resets the board first.
  gh_reset
  run_gh python3 "$TXN" freeze --repo "$REPO" --backend github --owner o --project 1 \
    --matrix "$MATRIX" --baseline expected-red --label u12 --out "$WORK/frozen.json" "$@" 2>&1
}

# ── (A) GREEN happy path: freeze --bodies + apply mints a body-bearing, marker-stamped Buildable ─────
BODIES="$WORK/bodies.json"
write_bodies "$BODIES" "{\"alpha\": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$PROSE")}"

out="$(freeze_gh --bodies "$BODIES")"; rc=$?
[ "$rc" -eq 0 ] || fail "A1: freeze --backend github --bodies did not exit 0 — the github body channel is absent (B1). rc=$rc: $out"

out="$(run_gh python3 "$TXN" apply --repo "$REPO" --backend github --owner o --project 1 --frozen "$WORK/frozen.json" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "A2: apply did not exit 0 (the github body-marker postcondition must pass once the create carries the body). rc=$rc: $out"
[ -f "$REPO/docs/workflow/planning-receipts/u12.json" ] || fail "A2: apply did not write the planning receipt"

NUM="$(python3 -c "import json;print(sorted(int(n) for n in json.load(open('$GH_STATE'))['issues'])[0])")"
BODY="$(python3 -c "import json;print(json.load(open('$GH_STATE'))['issues']['$NUM']['body'])")"
[ -n "$BODY" ] || fail "A3: the recorded create body for #$NUM is EMPTY (the B1 defect)"
case "$BODY" in
  *"$PROSE"*) : ;;
  *) fail "A3: the recorded create body does not contain the model-authored prose: $BODY" ;;
esac
# The body must END WITH the exact machine-derived marker (trailing whitespace aside).
TAIL="$(printf '%s' "$BODY" | python3 -c 'import sys;print(sys.stdin.read().rstrip())')"
case "$TAIL" in
  *"$MARKER") : ;;
  *) fail "A3: the recorded create body does not END WITH the exact machine-derived marker.
    want tail: $MARKER
    got  body: $BODY" ;;
esac
echo "  ok (A) freeze --bodies + apply mints #$NUM with the goal-contract body + machine-derived provenance marker"

# ── provenance post-condition now PASSES against the live body (belt-and-suspenders) ────────────────
out="$(run_gh python3 "$PROV" --matrix "$MATRIX" --issues "$NUM" --repo "$REPO" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "A4: idc_provenance_check exit $rc against the minted body (must be 0 now): $out"
printf '%s\n' "$out" | grep -q "provenance: ok 1" || fail "A4: provenance check did not print 'provenance: ok 1': $out"
echo "  ok (A4) idc_provenance_check.py exits 0 ('provenance: ok') — an already-satisfied invariant"

# ── (B) FAIL CLOSED at freeze: missing / empty / marker-shadowing body, and post-freeze body tamper ──
# (B1) a create whose logical_id has NO body entry → TransactionError (exit 2), no frozen bundle.
rm -f "$WORK/frozen.json"
write_bodies "$WORK/bodies-missing.json" '{"not-alpha": "unrelated"}'
out="$(freeze_gh --bodies "$WORK/bodies-missing.json")"; rc=$?
[ "$rc" -ne 0 ] || fail "B1: freeze accepted a github create with NO body entry (must fail closed — no empty-body Buildable can be frozen)"
[ ! -f "$WORK/frozen.json" ] || fail "B1: a fail-closed freeze still wrote a frozen bundle"
printf '%s\n' "$out" | grep -qi "body" || fail "B1: the missing-body refusal did not name the body cause: $out"
echo "  ok (B1) freeze fails closed when a github create has no goal-contract body"

# (B2) an EMPTY / whitespace-only body → fail closed.
write_bodies "$WORK/bodies-empty.json" '{"alpha": "   \n  "}'
out="$(freeze_gh --bodies "$WORK/bodies-empty.json")"; rc=$?
[ "$rc" -ne 0 ] || fail "B2: freeze accepted an empty/whitespace github body (must fail closed)"
echo "  ok (B2) freeze fails closed on an empty/whitespace body"

# (B3) a body that ALREADY carries an idc-provenance marker → fail closed (the machine owns the marker;
#      a model-authored marker could shadow the machine-derived one via provenance_of's first-match).
write_bodies "$WORK/bodies-marker.json" "{\"alpha\": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$PROSE"$'\n'"<!-- idc-provenance: {\"matrix\":\"evil.yaml\",\"pillar\":\"alpha\"} -->")}"
out="$(freeze_gh --bodies "$WORK/bodies-marker.json")"; rc=$?
[ "$rc" -ne 0 ] || fail "B3: freeze accepted a body already carrying an idc-provenance marker (must fail closed — the machine owns the marker)"
echo "  ok (B3) freeze fails closed when the authored body already carries an idc-provenance marker"

# (B4) a post-freeze tamper of the frozen bundle's create body → load_frozen digest mismatch on apply.
out="$(freeze_gh --bodies "$BODIES")"; rc=$?
[ "$rc" -eq 0 ] || fail "B4: the clean freeze for the tamper case did not exit 0: $out"
python3 - "$WORK/frozen.json" <<'PY'
import json, sys
p = sys.argv[1]
b = json.load(open(p))
ops = b["operations"]
c = next(o for o in ops if o.get("op") == "create-ticket")
c["body"] = (c.get("body") or "") + "\nTAMPERED AFTER FREEZE"     # mutate the frozen, digest-covered body
json.dump(b, open(p, "w"), indent=2, sort_keys=True)
PY
out="$(run_gh python3 "$TXN" apply --repo "$REPO" --backend github --owner o --project 1 --frozen "$WORK/frozen.json" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "B4: apply accepted a frozen bundle whose create body was edited after freeze (the operations_digest/frozen_digest must catch it)"
printf '%s\n' "$out" | grep -qi "digest" || fail "B4: the post-freeze tamper refusal was not attributed to the frozen digest: $out"
echo "  ok (B4) a post-freeze body tamper fails load_frozen's digest check on apply (tamper-evident)"

echo "PASS: the sanctioned github planning transaction threads the goal-contract body + machine-derived provenance marker through the existing create door; the body is tamper-evident in the frozen bundle; the transaction's own post-apply body postcondition and idc_provenance_check both pass; and freeze fails closed on a missing/empty/marker-shadowing body"
