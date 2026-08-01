#!/bin/bash
# init-self-mint-transaction.sh — V-DOOR: `init` mints its own Path Gate authorization INSIDE the
# transaction that opens its lifecycle record, and the pair is all-or-nothing.
#
# WHY THIS EXISTS. Every other command's authorization is minted by the UserPromptExpansion entry
# gate with no caller-chosen scope. `init` cannot use that path: at its expansion the repo is not
# governed yet, so the gate defers registration entirely and init self-registers from
# commands/init.md once tracker-config.yaml exists. That deferral used to be paid for with a PUBLIC
# `idc_path_gate.py authorize` verb that honored caller-supplied
# --command/--allow-action/--allow-path — an escalation door with exactly one production caller that
# needed none of its flexibility. The verb is deleted; `idc_command_contract.py start` mints the
# FIXED default profile for a self-minting command instead.
#
# ASSERTS, each red-when-broken:
#   1. CONTROL — a NON-self-minting command's `start` mints NOTHING (so assertion 2 is not just
#      "start always writes an auth object", which would pass for the wrong reason).
#   2. `start --command init` writes the authorization, with the FIXED default profile
#      (write/edit/git over `.`), bound to the SAME nonce as the record it just opened.
#   3. When the mint FAILS, the record it just opened is ROLLED BACK — a governed repo is never left
#      carrying an obligation with no authorization behind it — and `start` exits non-zero.
#   3b. The nonce binding is a real compare-and-swap, not a coincidence: when the active record
#      DIVERGES between the ledger write and the mint (a concurrent writer replaced it), `start`
#      refuses, mints nothing, and leaves the foreign record alone. Assertion 2 alone stays green
#      with the CAS deleted — there is only one record in the happy path — so 3b is what makes the
#      "bound to the record's nonce" claim earned.
#   4. The two sets that must never drift are literally the same set: the entry gate's
#      DEFERS_REGISTRATION is the contract's SELF_MINTING_COMMANDS. A command that self-registers but
#      is not self-minting would run with no authorization at all.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
[ -f "$CONTRACT" ]  || gov_fail "idc_command_contract.py not found at $CONTRACT"
[ -f "$PATH_GATE" ] || gov_fail "idc_path_gate.py not found at $PATH_GATE"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow" "$REPO/src"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
)
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO/src/app.ts"

AUTH_PATH="$(python3 "$PATH_GATE" auth-path --repo "$REPO")" \
  || gov_fail "could not locate the auth-object path"

# has_active <session> <command> -> 0 when an active record for that pair exists
has_active() {
  python3 "$CONTRACT" status --repo "$REPO" --session "$1" --json 2>/dev/null | CMD="$2" python3 -c '
import json, os, sys
try:
    doc = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
records = doc.get("active") or doc.get("active_commands") or []
if isinstance(doc, list):
    records = doc
sys.exit(0 if any(r.get("command") == os.environ["CMD"] for r in records) else 1)'
}

# ── 1. CONTROL: a non-self-minting command's start mints NOTHING ───────────────────────────────────
# Without this, assertion 2 could pass simply because `start` always writes an auth object.
rm -f "$AUTH_PATH"
CTRL_SID="init-mint-control-$$"
python3 "$CONTRACT" start --repo "$REPO" --session "$CTRL_SID" --command build \
  --plugin-root "$GOV_PLUGIN" --args 'demo' --source user >/dev/null 2>&1 \
  || gov_fail "CONTROL: could not open the /idc:build record"
has_active "$CTRL_SID" build \
  || gov_fail "CONTROL: the /idc:build record did not persist, so this scenario cannot tell a rollback from a failed write"
[ ! -f "$AUTH_PATH" ] \
  || gov_fail "CONTROL: a NON-self-minting command's start minted an authorization — the mint is not scoped to self-minting commands: $(cat "$AUTH_PATH")"

# ── 2. init's start mints the FIXED default profile, bound to its own record's nonce ───────────────
rm -f "$AUTH_PATH"
SID="init-mint-$$"
python3 "$CONTRACT" start --repo "$REPO" --session "$SID" --command init \
  --plugin-root "$GOV_PLUGIN" --args '' --source user >"$WORK/start.out" 2>"$WORK/start.err" \
  || gov_fail "init start failed: $(cat "$WORK/start.err")"
[ -f "$AUTH_PATH" ] \
  || gov_fail "init start opened its record but minted NO Path Gate authorization — every later Write/Edit/git mutation in init would fail closed"
AUTH_PATH="$AUTH_PATH" SID="$SID" REPO="$REPO" CONTRACT="$CONTRACT" python3 - <<'PY' \
  || gov_fail "init's minted authorization is not the fixed default profile bound to its record"
import json, os, subprocess, sys
auth = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
problems = []
if auth.get("command") != "init":
    problems.append(f"command={auth.get('command')!r}, expected 'init'")
if auth.get("allowed_paths") != ["."]:
    problems.append(f"allowed_paths={auth.get('allowed_paths')!r}, expected ['.']")
if set(auth.get("allowed_actions") or []) != {"write", "edit", "git"}:
    problems.append(f"allowed_actions={auth.get('allowed_actions')!r}, expected write/edit/git")
out = subprocess.run(
    ["python3", os.environ["CONTRACT"], "status", "--repo", os.environ["REPO"],
     "--session", os.environ["SID"], "--json"],
    capture_output=True, text=True).stdout
doc = json.loads(out)
records = doc if isinstance(doc, list) else (doc.get("active") or doc.get("active_commands") or [])
rec = next((r for r in records if r.get("command") == "init"), None)
if rec is None:
    problems.append("no active init record found after start")
elif rec.get("nonce") != auth.get("nonce"):
    problems.append(f"auth nonce {auth.get('nonce')!r} != record nonce {rec.get('nonce')!r}")
if problems:
    print("; ".join(problems), file=sys.stderr)
    sys.exit(1)
PY

# ── 3. A FAILED mint rolls the just-opened record back ─────────────────────────────────────────────
# Force a deterministic mint failure by making the authorization file path a DIRECTORY: the admission
# lock (a different file in the same dir) still works, registration still works, and only the atomic
# authorization write fails — exactly the seam the rollback exists for.
rm -f "$AUTH_PATH"
mkdir -p "$AUTH_PATH"
FAIL_SID="init-mint-rollback-$$"
python3 "$CONTRACT" start --repo "$REPO" --session "$FAIL_SID" --command init \
  --plugin-root "$GOV_PLUGIN" --args '' --source user >"$WORK/fail.out" 2>"$WORK/fail.err"
RC=$?
rmdir "$AUTH_PATH" 2>/dev/null || rm -rf "$AUTH_PATH"
[ "$RC" -ne 0 ] \
  || gov_fail "init start reported SUCCESS even though its authorization mint could not be written"
grep -qi 'authorization could not be minted' "$WORK/fail.err" \
  || gov_fail "the refusal did not name the failed mint as the reason: $(cat "$WORK/fail.err")"
if has_active "$FAIL_SID" init; then
  gov_fail "the init record survived a FAILED mint — the repo is left carrying an obligation with no authorization behind it"
fi

# ── 3b. The mint is BOUND to this start's nonce — a DIVERGED record gets no authorization ─────────
# Assertion 2 compares the minted nonce against the record `status` reports, but in the happy path
# those are trivially the same object: there is exactly one active init record, so `write_authorization`
# would pick it with or without a nonce compare-and-swap. Delete `expected_nonce=nonce` AND the
# `auth["nonce"] != nonce` guard from `_mint_or_rollback` and assertion 2 stays GREEN — the banner's
# claim "bound to the record's nonce" was, until this arm, unproven.
#
# The real failure is a RACE: between the ledger write and the mint, another writer replaces the
# (session, command) record with one carrying a different nonce. Without the CAS the mint binds to
# THAT record — an authorization issued against an admission attempt this start never made. Injected
# deterministically by wrapping `register_start` so the on-disk record's nonce is rewritten after the
# real write returns; everything downstream (the mint, the guard, the rollback) is the REAL code path.
#
# Verified red-when-broken: with the CAS and its guard removed, this arm's `start` exits 0 and writes
# an authorization carrying the FOREIGN nonce.
rm -f "$AUTH_PATH"
DIVERGE_SID="init-mint-diverge-$$"
cat > "$WORK/diverge.py" <<'PY'
import json, os, sys

plugin, repo, sid = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(plugin, "scripts"))
sys.path.insert(0, os.path.join(plugin, "scripts", "hooks"))
import idc_command_contract as C
import idc_ledger

ledger = idc_ledger.ledger_path(repo)
_real = C.register_start


def shim(repo_arg, session, command, version, args_text, source):
    """Open the record for real, then let a 'concurrent writer' replace its nonce."""
    rec = _real(repo_arg, session, command, version, args_text, source)
    with open(ledger, encoding="utf-8") as fh:
        doc = json.load(fh)
    rewritten = 0
    for record in doc.get("commands", []):
        if (record.get("session_id") == session and record.get("command") == command
                and record.get("state") == "active"):
            record["nonce"] = "FOREIGN-" + str(record.get("nonce"))
            rewritten += 1
    if rewritten != 1:
        print(f"INJECTION-FAILED: expected exactly 1 active {command} record to diverge, found "
              f"{rewritten} — this arm would assert nothing", file=sys.stderr)
        raise SystemExit(97)
    with open(ledger, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
    return rec


C.register_start = shim
raise SystemExit(C.main(["start", "--repo", repo, "--session", sid, "--command", "init",
                         "--plugin-root", plugin, "--args", "", "--source", "user"]))
PY
timeout 120 python3 "$WORK/diverge.py" "$GOV_PLUGIN" "$REPO" "$DIVERGE_SID" \
  >"$WORK/diverge.out" 2>"$WORK/diverge.err"
DRC=$?
[ "$DRC" -ne 97 ] \
  || gov_fail "the nonce-divergence injection did not take effect, so this arm proved nothing: $(cat "$WORK/diverge.err")"
[ "$DRC" -ne 0 ] \
  || gov_fail "start SUCCEEDED after the active record's nonce diverged from the one it wrote — the mint is not bound to this start's admission nonce, so an authorization can be issued against an attempt this start never made"
[ ! -f "$AUTH_PATH" ] \
  || gov_fail "start minted an authorization against a DIVERGED record: $(cat "$AUTH_PATH")"
grep -qi 'no longer matches the expected admission nonce' "$WORK/diverge.err" \
  || gov_fail "the refusal must name the nonce mismatch as the reason, not fail for some unrelated cause: $(cat "$WORK/diverge.err")"
# The diverged record is NOT removed — it belongs to the writer that replaced it, and rollback's CAS
# deliberately never touches a foreign record. Asserting this pins the rollback's blast radius.
has_active "$DIVERGE_SID" init \
  || gov_fail "the rollback deleted the CONCURRENT writer's record — rollback is a nonce compare-and-swap and must never remove a record it did not write"

# ── 4. The deferral set and the self-minting set are the SAME set ──────────────────────────────────
GOV_PLUGIN="$GOV_PLUGIN" python3 - <<'PY' \
  || gov_fail "the entry gate's deferred-registration set and the contract's self-minting set have drifted apart"
import os, sys
root = os.environ["GOV_PLUGIN"]
sys.path.insert(0, os.path.join(root, "scripts"))
sys.path.insert(0, os.path.join(root, "scripts", "hooks"))
import idc_command_contract as C
import idc_command_entry_gate as EG
if set(EG.DEFERS_REGISTRATION) != set(C.SELF_MINTING_COMMANDS):
    print(f"DEFERS_REGISTRATION={sorted(EG.DEFERS_REGISTRATION)} != "
          f"SELF_MINTING_COMMANDS={sorted(C.SELF_MINTING_COMMANDS)}", file=sys.stderr)
    sys.exit(1)
if not C.SELF_MINTING_COMMANDS:
    print("SELF_MINTING_COMMANDS is EMPTY — the equality above would hold vacuously", file=sys.stderr)
    sys.exit(1)
PY

echo "PASS: init self-mints its fixed default Path Gate profile inside its own start transaction (a non-self-minting command's start mints nothing; the grant is write/edit/git over '.'; a failed mint rolls the record back and refuses; the mint is BOUND to this start's admission nonce by compare-and-swap — a record that diverged between the ledger write and the mint gets no authorization at all, and the concurrent writer's record is left untouched; the deferred-registration and self-minting sets are one set)"
