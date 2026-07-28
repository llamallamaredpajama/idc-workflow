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

echo "PASS: init self-mints its fixed default Path Gate profile inside its own start transaction (a non-self-minting command's start mints nothing; the grant is write/edit/git over '.' bound to the record's nonce; a failed mint rolls the record back and refuses; the deferred-registration and self-minting sets are one set)"
