#!/bin/bash
# idc-assert-class: behavior
# Phase 1 smoke — the github backend of the recirculation-intake safety net
# (scripts/idc_recirc_sweep.py), success-only/no-blind-refile discipline. Companion to
# phase1-recirc-sweep.sh (which covers the pure decide() brain + the filesystem re-stage).
#
# This locks in the github-only behaviours that the false-clean release hardened, all on the same
# theme — NEVER report a clean success when a sub-step failed, and NEVER risk a blind duplicate file:
#   (#4a) github_existing_sources() returns None (a VISIBLE degraded state) when the dedupe board read
#         FAILS — not an empty set — so apply_github SKIPS ticket-filing rather than re-file a blind
#         duplicate it cannot see.
#   (#4b) apply_github() files a Recirculation ticket through the ATOMIC idc_gh_board.create_item
#         (issue #130 — Stage AND Status set together, partial discarded; no empty-Status pointer),
#         gating the "filed" report + the `changed` count on that create succeeding. A create failure
#         (BoardWriteError) is surfaced and NOT counted.
#   (#2)  the re-stage loop's Wave `--clear` return is CHECKED — a failed clear is surfaced, never
#         silently reported as "+ Wave cleared".
#
# Hermetic + red-when-broken by construction: the module is imported directly and its `gh` /
# `idc_gh_board.fetch_items` / `read_config` IO boundaries are monkeypatched, so every gh call is
# scripted and every assertion flips RED if its success-gating guard is removed. NO live GitHub.
#
# Usage: bash tests/smoke/phase1-recirc-sweep-github.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
SWEEP="$SCRIPTS/idc_recirc_sweep.py"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$SWEEP" ] || fail "recirc-sweep helper not found at $SWEEP"

python3 - "$SCRIPTS" <<'PY' || fail "github success-gating / no-blind-refile assertions did not all hold"
import sys
sys.path.insert(0, sys.argv[1])
import idc_recirc_sweep as m
import idc_gh_board

CTX = {"owner": "o", "project_node": "PVT_node", "project_number": "7"}
# read_config is the tracker-config.yaml parser; pin Stage/Wave field ids so the re-stage + filing
# chains have resolvable ids (this test exercises apply_github, not the parser — covered elsewhere).
m.read_config = lambda repo: ("7", {"Stage": "PVTF_stage", "Wave": "PVTF_wave"})

def boom(owner, pn, repo):
    raise idc_gh_board.BoardReadError("simulated board outage")

def empty_board(owner, pn, repo):
    return []   # dedupe read OK but no existing Recirculation tickets → nothing deduped

def capture():
    return {"origin": "#42|finisher", "what": "shared limiter",
            "area": "src/api", "suggested_scope": "extract limiter"}

errs = []
def check(cond, msg):
    if not cond:
        errs.append(msg)

# ── #4a — github_existing_sources returns None (visible degraded), not an empty set ───────────────
logs = []
m.idc_gh_board.fetch_items = boom
res = m.github_existing_sources("/x", CTX, logs.append)
check(res is None, "github_existing_sources must return None on a board-read FAILURE (not an empty set)")
check(any("dedupe read FAILED" in l for l in logs),
      "a failed dedupe read must be SURFACED (visible degraded state), not silent")

# ── #4a (caller) — apply_github SKIPS filing when the dedupe read fails (no blind duplicate) ──────
calls = []
def gh_record(args, repo):
    calls.append(list(args))
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    return True, "", ""
m.gh = gh_record
m.idc_gh_board.fetch_items = boom   # the dedupe read fails
f = m.Finding(42, m.LEAVE, "host issue (carries an untickered marker)", item_id="PVTI_host")
f.captures = [capture()]
logs = []
changed = m.apply_github([f], "/x", CTX, logs.append)
check(not any(c[:2] == ["issue", "create"] for c in calls),
      "must NOT file a ticket (issue create) when the dedupe read failed — would risk a blind duplicate")
check(changed == 0, "a skipped (un-dedupable) filing must NOT be counted")
check(any("skipping ticket-filing" in l for l in logs),
      "the skipped filing must be surfaced (skipping ticket-filing …)")

# ── #4b — apply_github files via the ATOMIC create_item (#130) + gates 'filed'/changed on it ───────
import os, tempfile
REPO_FILING = tempfile.mkdtemp()   # a writable repo so the intake journal_append does not fail-soft-warn
os.makedirs(os.path.join(REPO_FILING, "docs", "workflow"), exist_ok=True)
# fetch_item resolves the filed ticket's issue number for the intake journal record.
m.idc_gh_board.fetch_item = lambda iid, repo: {"content": {"number": 99, "title": "recirc"}}

def gh_filing(args, repo):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    return True, "", ""

def run_filing(create_fn):
    """Apply a single LEAVE-finding-with-capture through apply_github with a scripted create_item,
    dedupe OK (empty board). Returns (changed, joined_log)."""
    m.gh = gh_filing
    m.idc_gh_board.fetch_items = empty_board
    m.idc_gh_board.create_item = create_fn
    f = m.Finding(42, m.LEAVE, "host", item_id="PVTI_host")
    f.captures = [capture()]
    lg = []
    ch = m.apply_github([f], REPO_FILING, CTX, lg.append)
    return ch, "\n".join(lg)

# (b-i) create_item RAISES (BoardWriteError — e.g. an unresolved Stage/Status option, or a partial it
#       discarded) → NOT counted as filed, surfaced. The atomic primitive owns the partial-discard, so
#       apply_github only has to honour a raise (no add/edit half-states to gate).
def ci_boom(owner, project, repo, title, body, stage, status):
    raise m.idc_gh_board.BoardWriteError("simulated atomic-create failure")
ch, log = run_filing(ci_boom)
check(ch == 0, "a failed atomic create_item must NOT count as filed")
check("not counted as filed" in log, "a failed create must be surfaced (not counted as filed)")

# (b-ii) create_item is called with Stage=Recirculation AND Status=Todo TOGETHER — the #130 atomic
#        contract that eliminates the empty-Status pointer class. Red-when-broken: a regression back to
#        the Stage-only item-edit chain would never pass a Status here.
seen = {}
def ci_capture(owner, project, repo, title, body, stage, status):
    seen["stage"], seen["status"] = stage, status
    return "PVTI_new"
ch, log = run_filing(ci_capture)
check(seen.get("stage") == "Recirculation", f"create_item must set Stage=Recirculation, got {seen.get('stage')!r}")
check(seen.get("status") == "Todo", f"create_item must set Status=Todo atomically (#130), got {seen.get('status')!r}")

# (b-iii) POSITIVE control — a successful atomic create → counted + logged 'filed' (proves the test is
#         not a tautology: a blanket 'never count' would fail HERE)
ch, log = run_filing(lambda o, p, r, t, b, s, st: "PVTI_new")
check(ch == 1, "a successful atomic filing MUST count as filed (positive control)")
check("filed Recirculation ticket" in log, "a successful filing must be logged 'filed Recirculation ticket'")

# ── #2 — the re-stage loop's Wave --clear return is checked (no false 'Wave cleared') ─────────────
def run_restage(gh_fn):
    m.gh = gh_fn
    m.idc_gh_board.fetch_items = empty_board
    f = m.Finding(207, m.RESTAGE, "rogue, no provenance", wave="Wave 2", item_id="PVTI_207")
    lg = []
    ch = m.apply_github([f], REPO_FILING, CTX, lg.append)  # writable repo so the re-stage journal lands
    return ch, "\n".join(lg)

# (2-i) Wave clear FAILS (Stage re-stage succeeds) → must surface the failure, must NOT claim cleared
def gh_wave_fail(args, repo):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    if args[:2] == ["project", "item-edit"]:
        if "--clear" in args:
            return False, "", "wave boom"   # the Wave clear FAILS
        return True, "", ""                 # the Stage re-stage succeeds
    return True, "", ""
ch, log = run_restage(gh_wave_fail)
check(ch == 1, "the re-stage itself succeeded → it counts as a board change")
check("re-staged → Recirculation" in log, "a successful re-stage must be logged")
check("Wave clear FAILED" in log, "a FAILED Wave clear must be surfaced")
check("+ Wave cleared" not in log,
      "must NOT claim '+ Wave cleared' when the clear actually failed (the false-success this guards)")

# (2-ii) POSITIVE control — Wave clear OK → '+ Wave cleared' (proves the message path works)
def gh_wave_ok(args, repo):
    if args[:2] == ["project", "field-list"]:
        return True, "OPT_recirc", ""
    return True, "", ""
ch, log = run_restage(gh_wave_ok)
check(ch == 1, "re-stage with a clean Wave clear counts")
check("+ Wave cleared" in log, "a successful Wave clear must be logged '+ Wave cleared' (positive control)")

if errs:
    for e in errs:
        sys.stderr.write("ASSERT FAILED: " + e + "\n")
    sys.exit(1)
print("ok")
PY

echo "PASS: github recirc-sweep — dedupe-fail returns None (no blind re-file), filing mints via the atomic create_item (Stage+Status together, #130) and gates 'filed'/changed on it, re-stage Wave-clear honesty (no false 'Wave cleared')"
