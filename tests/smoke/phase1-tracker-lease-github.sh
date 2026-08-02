#!/bin/bash
# idc-assert-class: behavior
# Phase 1 smoke — the board-backed merge lease primitive (github backend, issue #104).
#
# The filesystem backend has a real flock+TTL merge lease; the github backend — the one production
# uses — had NONE: "board-backed lease" meant trusting that only one orchestrator was running. This
# drives the github realization of the same fail-closed contract (token + TTL semantics mirroring
# scripts/idc_tracker_fs.py): each acquire APPENDS a claim issue titled `[idc-lease] <name>` and the
# lowest-numbered LIVE (unexpired, still-open) claim is the single holder — optimistic concurrency
# over GitHub's server-assigned issue numbers, which two racing acquirers cannot both win. A loser
# withdraws (closes) its own claim and exits non-zero; malformed lease state is UNKNOWN lock state
# and fail-closes rather than granting.
#
# Hermetic: a PATH `gh` stub keeps issue state in $GH_STUB_STATE (flock-serialized, so concurrent
# acquirers interleave like the real API). GH_STUB_RACE injects a rival claim between one acquirer's
# pre-check and its create — the exact two-orchestrators race the read-back winner check exists for.
#
# Failing-test-first: fails until idc_gh_board.py gains lease-acquire/lease-release/lease-show.
#
# Usage: bash tests/smoke/phase1-tracker-lease-github.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
BOARD="$PLUGIN/scripts/idc_gh_board.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$BOARD" ] || fail "idc_gh_board.py not found at $BOARD"
mkdir -p "$WORK/repo" "$WORK/bin" "$WORK/state/issues"
echo 1 > "$WORK/state/next"
export GH_STUB_STATE="$WORK/state"

# --- gh stub: the five call shapes the lease ops drive, over flock-serialized file state ---------
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env python3
import fcntl, json, os, sys, time

STATE = os.environ["GH_STUB_STATE"]


def issue_path(num):
    return os.path.join(STATE, "issues", f"{num}.json")


def load(num):
    with open(issue_path(num), encoding="utf-8") as fh:
        return json.load(fh)


def save(rec):
    with open(issue_path(rec["number"]), "w", encoding="utf-8") as fh:
        json.dump(rec, fh)


def all_issues():
    out = []
    for name in os.listdir(os.path.join(STATE, "issues")):
        if name.endswith(".json"):
            out.append(load(int(name[:-5])))
    return sorted(out, key=lambda r: r["number"])


def create(title, body):
    with open(os.path.join(STATE, "next"), "r+", encoding="utf-8") as fh:
        num = int(fh.read().strip())
        fh.seek(0)
        fh.truncate()
        fh.write(str(num + 1))
    save({"number": num, "title": title, "body": body, "state": "open"})
    return num


def flag(name):
    for i, a in enumerate(sys.argv):
        if a == name and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return None


def main():
    argv = sys.argv[1:]
    if argv[:2] == ["api", "rate_limit"]:
        print(json.dumps({"resources": {"core": {"remaining": 5000, "reset": 0}}}))
        return 0
    if argv[0] == "api" and argv[1].startswith("repos/{owner}/{repo}/issues?state=open"):
        for rec in all_issues():
            if rec["state"] == "open":
                print(json.dumps({"number": rec["number"], "title": rec["title"],
                                  "body": rec["body"]}))
        return 0
    if argv[:2] == ["issue", "create"]:
        title, body = flag("--title"), flag("--body")
        # GH_STUB_RACE (one-shot): a rival orchestrator's claim lands FIRST — between the caller's
        # pre-check (which saw a free lease) and its own create — so the caller's claim loses.
        race = os.environ.get("GH_STUB_RACE")
        if race and title.startswith("[idc-lease]") and not os.path.exists(race):
            open(race, "w").close()
            exp = time.time() + 3600
            rival = {"owner": "rival", "token": "rivaltoken", "acquired_at": "2026-01-01T00:00:00Z",
                     "expires_at": "2026-01-01T01:00:00Z", "expires_at_epoch": exp}
            create(title, "<!-- idc-lease: " + json.dumps(rival) + " -->")
        num = create(title, body)
        print(f"https://github.com/tester/repo/issues/{num}")
        return 0
    if argv[:2] == ["issue", "close"]:
        rec = load(int(argv[2]))
        if rec["state"] != "open":
            sys.stderr.write(f"issue #{rec['number']} is already closed\n")
            return 1
        rec["state"] = "closed"
        save(rec)
        return 0
    if argv[:2] == ["issue", "view"]:
        print("OPEN" if load(int(argv[2]))["state"] == "open" else "CLOSED")
        return 0
    sys.stderr.write("stub: unhandled gh call: " + " ".join(argv) + "\n")
    return 9


with open(os.path.join(STATE, "lock"), "w") as lk:
    fcntl.flock(lk.fileno(), fcntl.LOCK_EX)
    code = main()
sys.exit(code)
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

run() { python3 "$BOARD" "$@" --repo "$WORK/repo"; }
open_claims() { python3 - "$GH_STUB_STATE" <<'PY'
import json, os, sys
issues = os.path.join(sys.argv[1], "issues")
n = 0
for name in sorted(os.listdir(issues)):
    if not name.endswith(".json"):
        continue
    rec = json.load(open(os.path.join(issues, name)))
    if rec["state"] == "open" and rec["title"].startswith("[idc-lease]"):
        n += 1
print(n)
PY
}

# (a) acquire on a free lease returns a token.
tokA="$(run lease-acquire --lease merge --owner finisher-A --ttl 60)" || fail "acquire on a free lease failed (no lease primitive?)"
[ -n "$tokA" ] || fail "acquire returned an empty token"
[ "$(open_claims)" = "1" ] || fail "acquire did not leave exactly one open claim issue"

# (b) a second acquire WHILE HELD is rejected — fail-closed, never two holders.
run lease-acquire --lease merge --owner finisher-B --ttl 60 >/dev/null 2>&1 \
  && fail "a second acquire succeeded while the lease was held (two holders!)"
[ "$(open_claims)" = "1" ] || fail "a rejected acquire left a stray open claim issue"

# (c) release with the WRONG token is rejected.
run lease-release --lease merge --token deadbeefdeadbeef >/dev/null 2>&1 \
  && fail "release-by-wrong-token was accepted"

# (d) lease-show while held names the holder; release-by-correct-token closes the claim.
run lease-show --lease merge | grep -q '"held": true' || fail "lease-show does not report the held lease"
run lease-show --lease merge | grep -q "$tokA" && fail "lease-show leaked the token"
run lease-release --lease merge --token "$tokA" || fail "release-by-correct-token failed"
[ "$(open_claims)" = "0" ] || fail "release did not close the claim issue"
[ -z "$(run lease-show --lease merge)" ] || fail "lease-show is non-empty after release"
tokB="$(run lease-acquire --lease merge --owner finisher-B --ttl 60)" || fail "re-acquire after release failed"
[ -n "$tokB" ] && [ "$tokB" != "$tokA" ] || fail "re-acquire did not return a fresh token"
run lease-release --lease merge --token "$tokB" || fail "cleanup release failed"

# (e) expiry: a short-lived lease can be re-acquired after it expires, and the expired claim
#     issue is retired (closed) by the successful acquire — no dead open claims accumulate.
tokC="$(run lease-acquire --lease merge --owner finisher-C --ttl 1)" || fail "short-ttl acquire failed"
sleep 2
tokD="$(run lease-acquire --lease merge --owner finisher-D --ttl 60)" || fail "re-acquire after expiry failed (expiry not honored)"
[ "$tokC" != "$tokD" ] || fail "expired re-acquire returned the same token"
[ "$(open_claims)" = "1" ] || fail "the expired claim issue was not closed on re-acquire"
run lease-release --lease merge --token "$tokD" || fail "post-expiry release failed"

# (f) THE RACE (deterministic): a rival claim lands between this acquirer's pre-check and its
#     create. The read-back winner check must LOSE (rival has the lower live claim), withdraw
#     (close) its own claim so no zombie holder survives, and exit non-zero.
export GH_STUB_RACE="$WORK/race-fired"
run lease-acquire --lease merge --owner finisher-E --ttl 60 >/dev/null 2>&1 \
  && fail "acquire WON against an earlier live rival claim (two holders — the read-back check is gone)"
unset GH_STUB_RACE
[ -f "$WORK/race-fired" ] || fail "race fixture did not fire (stub drift — the race was never injected)"
[ "$(open_claims)" = "1" ] || fail "the losing acquirer did not withdraw its claim (zombie holder)"
run lease-show --lease merge | grep -q '"owner": "rival"' || fail "the rival is not the surviving holder"
run lease-release --lease merge --token rivaltoken || fail "release of the rival's lease failed"

# (g) CONCURRENCY: two simultaneous acquirers must yield EXACTLY ONE winner.
run lease-acquire --lease merge --owner X --ttl 60 >"$WORK/x.out" 2>/dev/null &
run lease-acquire --lease merge --owner Y --ttl 60 >"$WORK/y.out" 2>/dev/null &
wait
winners=0
[ -s "$WORK/x.out" ] && winners=$((winners + 1))
[ -s "$WORK/y.out" ] && winners=$((winners + 1))
[ "$winners" -eq 1 ] || fail "concurrent acquire: expected exactly 1 winner, got $winners (two orchestrators could both drive the board)"
[ "$(open_claims)" = "1" ] || fail "concurrent acquire left $(open_claims) open claims (expected 1)"
run lease-release --lease merge --token "$(cat "$WORK/x.out" "$WORK/y.out")" >/dev/null 2>&1 || true

# (h) MALFORMED state is fail-closed: an open claim issue with an unparseable body is UNKNOWN lock
#     state, not "free" — acquire/show must fail rather than grant a lease over it.
python3 - "$GH_STUB_STATE" <<'PY'
import json, os, sys
state = sys.argv[1]
with open(os.path.join(state, "next"), "r+", encoding="utf-8") as fh:
    num = int(fh.read().strip())
    fh.seek(0); fh.truncate(); fh.write(str(num + 1))
json.dump({"number": num, "title": "[idc-lease] merge", "body": "not a lease marker {{",
           "state": "open"}, open(os.path.join(state, "issues", f"{num}.json"), "w"))
PY
run lease-acquire --lease merge --owner finisher-Z --ttl 60 >/dev/null 2>&1 \
  && fail "lease-acquire granted a lease over a MALFORMED claim issue (fail-open) — must fail-closed"
run lease-show --lease merge >/dev/null 2>&1 \
  && fail "lease-show succeeded over a malformed claim issue — must fail-closed"

echo "PASS: github merge-lease primitive — single-holder, release-by-token, expiry, race-loser withdraws, concurrency-safe, malformed-state fail-closed"
