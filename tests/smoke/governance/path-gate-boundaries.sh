#!/bin/bash
# path-gate-boundaries.sh — the shared Path Gate core enforces auth-object integrity:
# absent / unreadable / corrupt auth states deny distinctly, CLI defaults admit the standard profile,
# outside-repo paths stay outside this gate's jurisdiction, allowed paths/actions admit, symlink aliases
# resolve to their real target before the case-insensitive protected-surface check, protected
# machine-owned files stay denied, subprocess failures scrub child stderr at the read, and branch /
# ticket / graph-node / contract-digest / expiry mismatches all fail closed.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
# TEST-ONLY mint door. idc_path_gate.py has no `authorize` verb (V-DOOR); this fixture calls the
# same write_authorization Python API the real admission minters use, ceiling and all.
PG_AUTHORIZE="$GOV_PLUGIN/tests/smoke/lib/path_gate_authorize.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
[ -f "$CONTRACT" ] || gov_fail "idc_command_contract.py not found at $CONTRACT"
[ -f "$PATH_GATE" ] || gov_fail "idc_path_gate.py not found at $PATH_GATE (shared core not implemented yet)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow" "$REPO/src" "$REPO/tests"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
)
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO/src/app.ts"
printf 'test(1)\n' > "$REPO/tests/app.t"
ln -s ../TRACKER.md "$REPO/src/tracker-link.md"
SID="pg-boundary-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SID" --command build \
  --plugin-root "$GOV_PLUGIN" --args 'demo' --source user >/dev/null \
  || gov_fail "could not open the active /idc:build command record for $SID"
BRANCH="$(git -C "$REPO" branch --show-current)"

AUTH_PATH="$(python3 "$PATH_GATE" auth-path --repo "$REPO")" || gov_fail "could not locate the auth-object path"

emit_req() { ACTION="$1" PATHS="$2" TICKET="$3" GRAPH="$4" python3 - <<'PY'
import json, os
payload = {
    "action": os.environ["ACTION"],
    "paths": [p for p in os.environ["PATHS"].split(":") if p],
}
if os.environ["TICKET"]:
    payload["ticket"] = os.environ["TICKET"]
if os.environ["GRAPH"]:
    payload["graph_node"] = os.environ["GRAPH"]
print(json.dumps(payload))
PY
}

eval_gate() {
  OUT="$(emit_req "$1" "$2" "$3" "$4" | python3 "$PATH_GATE" evaluate --repo "$REPO" --plugin-root "$GOV_PLUGIN" 2>"$WORK/err")"
  RC=$?
}
allow_case() {
  eval_gate "$1" "$2" "$3" "$4"
  [ "$RC" -eq 0 ] || gov_fail "ALLOW expected exit 0, got $RC for action=$1 paths=$2 :: $(cat "$WORK/err")"
  printf '%s' "$OUT" | grep -q '"allowed": *true' || gov_fail "ALLOW expected allowed=true, got: $OUT"
}
deny_case() {
  eval_gate "$1" "$2" "$3" "$4"
  [ "$RC" -ne 0 ] || gov_fail "DENY expected non-zero exit for action=$1 paths=$2, got 0 with: $OUT"
  printf '%s' "$OUT" | grep -q '"allowed": *false' || gov_fail "DENY expected allowed=false, got: $OUT"
}
reason_has() {
  printf '%s' "$OUT" | grep -qi "$1" || gov_fail "expected denial reason to mention [$1], got: $OUT"
}

mutate_auth() { AUTH_PATH="$AUTH_PATH" MODE="$1" VALUE="${2:-}" python3 - <<'PY'
import json, os
path = os.environ["AUTH_PATH"]
mode = os.environ["MODE"]
value = os.environ.get("VALUE", "")
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
if mode == "branch":
    data["branch"] = value
elif mode == "contract_digest":
    data["contract_digest"] = value
elif mode == "expires_past":
    data["expires_at"] = "2000-01-01T00:00:00Z"
elif mode == "allowed_paths":
    data["allowed_paths"] = [value]
else:
    raise SystemExit(f"unknown mode: {mode}")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

authorize() {
  python3 "$PG_AUTHORIZE" --repo "$REPO" --session "$SID" --command build \
    --branch "$BRANCH" --ticket T-42 --graph-node NODE-7 \
    --allow-action write --allow-action edit --allow-action git \
    --allow-path src --allow-path tests >/dev/null \
    || gov_fail "could not write a shared Path Gate authorization"
}

# Outside-repo paths are outside this gate's jurisdiction, even without authorization.
allow_case write /tmp/idc-note.md T-42 NODE-7

# Absent auth denies with a distinct, scrubbed reason.
deny_case write src/app.ts T-42 NODE-7
reason_has 'authorization.*absent'

# A minimal mint (no explicit scope) applies the standard write/edit/git profile.
DEFAULT_AUTH="$(python3 "$PG_AUTHORIZE" --repo "$REPO" --session "$SID" --command build)" \
  || gov_fail "minimal mint failed"
printf '%s' "$DEFAULT_AUTH" | python3 -c '
import json, sys
auth = json.load(sys.stdin)
assert auth["allowed_paths"] == ["."]
assert set(auth["allowed_actions"]) == {"write", "edit", "git"}
' || gov_fail "minimal mint did not apply the standard default profile: $DEFAULT_AUTH"
allow_case write src/app.ts '' ''
deny_case write tracker.MD '' ''
reason_has 'protected machine-owned surface'

authorize
allow_case write src/app.ts T-42 NODE-7
deny_case write src/tracker-link.md T-42 NODE-7
deny_case write docs/notes.md T-42 NODE-7
deny_case write TRACKER.md T-42 NODE-7

# Authorization read failures are distinct and never echo corrupt file contents or local paths.
printf 'password=hunter2xyzzy this is not json\n' > "$AUTH_PATH"
deny_case write src/app.ts T-42 NODE-7
reason_has 'authorization.*corrupt'
! printf '%s' "$OUT" | grep -Fq 'hunter2xyzzy' || gov_fail "corrupt authorization content leaked: $OUT"
! printf '%s' "$OUT" | grep -Fq "$AUTH_PATH" || gov_fail "authorization path leaked: $OUT"
rm -f "$AUTH_PATH"
mkdir "$AUTH_PATH"
deny_case write src/app.ts T-42 NODE-7
reason_has 'authorization.*unreadable'
! printf '%s' "$OUT" | grep -Fq "$AUTH_PATH" || gov_fail "unreadable authorization path leaked: $OUT"
rmdir "$AUTH_PATH"

authorize
mutate_auth branch wrong/branch
deny_case write src/app.ts T-42 NODE-7

authorize
deny_case write src/app.ts WRONG-TICKET NODE-7

authorize
deny_case write src/app.ts T-42 WRONG-NODE

authorize
mutate_auth contract_digest deadbeef
deny_case write src/app.ts T-42 NODE-7

authorize
mutate_auth expires_past
deny_case write src/app.ts T-42 NODE-7

python3 "$PG_AUTHORIZE" --repo "$REPO" --session "$SID" --command build \
  --branch "$BRANCH" --ticket T-42 --graph-node NODE-7 \
  --allow-action write --allow-action edit --allow-action git \
  --allow-path tests >/dev/null \
  || gov_fail "could not narrow the shared Path Gate authorization to tests/**"
deny_case write src/app.ts T-42 NODE-7
allow_case write tests/app.t T-42 NODE-7

# ── D2 — NO CLI PATH MINTS AN AUTHORIZATION, least of all from a read-only command record ─────────
# The public `authorize` verb is deleted (V-DOOR): it honored caller-chosen
# --command/--allow-action/--allow-path, so any Bash in a session whose only precondition was "some
# active command record exists" could mint itself a whole-repo write/edit/git grant. The Python API
# is now reachable only from admission code. This lane asserts BOTH halves.
rm -f "$AUTH_PATH"
RO_SID="pg-readonly-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$RO_SID" --command doctor \
  --plugin-root "$GOV_PLUGIN" --args '' --source user >/dev/null \
  || gov_fail "could not open the active read-only /idc:doctor command record for $RO_SID"

# (1) CONTROL FIRST — the probe must be able to OBSERVE a mint, or every "nothing was minted" result
# below is vacuous. A mutating record through the same Python API MUST produce the auth object.
rm -f "$AUTH_PATH"
python3 "$PG_AUTHORIZE" --repo "$REPO" --session "$SID" --command build >/dev/null \
  || gov_fail "CONTROL: the mutating-role mint failed, so this lane cannot tell a mint from a no-op"
[ -f "$AUTH_PATH" ] || gov_fail "CONTROL: a successful mint left no auth object at the probed path — this lane is INERT, every 'no authorization was written' assertion below would pass for the wrong reason"

# (2) The read-only ROLE ceiling refuses a mutation grant even through the Python API, and writes
# nothing when it refuses.
rm -f "$AUTH_PATH"
if python3 "$PG_AUTHORIZE" --repo "$REPO" --session "$RO_SID" --command doctor \
     --allow-path . --allow-action write --allow-action edit --allow-action git \
     >/dev/null 2>"$WORK/ro-mint.err"; then
  gov_fail "a read-only command record minted a write/edit/git authorization: $(cat "$AUTH_PATH" 2>/dev/null)"
fi
grep -qi 'read-only' "$WORK/ro-mint.err" \
  || gov_fail "the read-only mint refusal did not name the role ceiling: $(cat "$WORK/ro-mint.err")"
[ ! -f "$AUTH_PATH" ] || gov_fail "a REFUSED read-only mint still wrote an authorization: $(cat "$AUTH_PATH")"

# (3) No verb the SHIPPED CLI exposes writes an authorization at all. The verb list is read back off
# the parser itself, so a newly added minting subcommand is covered here automatically instead of
# waiting for someone to remember to extend a hardcoded list.
PG_VERBS="$(python3 "$PATH_GATE" --help 2>&1 | python3 -c '
import re, sys
m = re.search(r"\{([a-z0-9,\-]+)\}", sys.stdin.read())
print("\n".join(m.group(1).split(",")) if m else "")
')"
[ -n "$PG_VERBS" ] || gov_fail "could not enumerate the shipped Path Gate CLI verbs from its parser"
printf '%s\n' "$PG_VERBS" | grep -qx 'evaluate' \
  || gov_fail "the verb enumeration lost the known 'evaluate' verb, so it is not really reading the parser: [$PG_VERBS]"
#
# Each verb is driven against BOTH kinds of active record, and the MUTATING one is load-bearing: a
# read-only record is refused by the role ceiling no matter what the CLI exposes, so a doctor-only
# probe would stay green even with the escalation door fully restored (it would be testing the
# ceiling, not the door). The build record is the case where a restored door DOES mint.
for verb in $PG_VERBS; do
  for pair in "$SID:build" "$RO_SID:doctor"; do
    probe_sid="${pair%%:*}"; probe_cmd="${pair##*:}"
    # mint-shaped invocation: the exact flag set the deleted door accepted
    rm -f "$AUTH_PATH"
    python3 "$PATH_GATE" "$verb" --repo "$REPO" --session "$probe_sid" --command "$probe_cmd" \
      --branch "$BRANCH" --allow-path . \
      --allow-action write --allow-action edit --allow-action git \
      </dev/null >/dev/null 2>&1
    [ ! -f "$AUTH_PATH" ] \
      || gov_fail "shipped CLI verb '$verb' minted an authorization from a caller-chosen scope on the active '$probe_cmd' record — the public minting door is back: $(cat "$AUTH_PATH")"
  done
  # bare invocation: a verb that mints implicitly from its defaults
  rm -f "$AUTH_PATH"
  python3 "$PATH_GATE" "$verb" --repo "$REPO" </dev/null >/dev/null 2>&1
  [ ! -f "$AUTH_PATH" ] \
    || gov_fail "shipped CLI verb '$verb' minted an authorization with no explicit scope: $(cat "$AUTH_PATH")"
done

# (4) The consequence that matters: with no authorization on disk, a source write is still DENIED.
rm -f "$AUTH_PATH"
deny_case write src/app.ts '' ''
reason_has 'authorization.*absent'

FAKE_GIT_DIR="$WORK/fake-git-stderr"; mkdir -p "$FAKE_GIT_DIR"
cat >"$FAKE_GIT_DIR/git" <<'SH'
#!/bin/sh
printf 'fatal: Authorization: Basic QWxhZGRpbjpvcGVuc2VzYW1l while opening repo\n' >&2
exit 1
SH
chmod +x "$FAKE_GIT_DIR/git"
PATH="$FAKE_GIT_DIR:$PATH" \
  python3 "$PATH_GATE" auth-path --repo "$REPO" >"$WORK/auth-path.out" 2>"$WORK/auth-path.err"
RC=$?
[ "$RC" -ne 0 ] || gov_fail "auth-path unexpectedly succeeded through a failing git child"
! grep -Fq 'QWxhZGRpbjpvcGVuc2VzYW1l' "$WORK/auth-path.out" \
  || gov_fail "auth-path leaked a Basic credential from child stderr: $(cat "$WORK/auth-path.out")"
grep -Fq 'IDC Path Gate infrastructure error:' "$WORK/auth-path.out" \
  || gov_fail "auth-path hid the infrastructure error context: $(cat "$WORK/auth-path.out")"
grep -Fq '[REDACTED]' "$WORK/auth-path.out" \
  || gov_fail "auth-path did not preserve a scrubbed diagnostic marker: $(cat "$WORK/auth-path.out")"
grep -Fq 'while opening repo' "$WORK/auth-path.out" \
  || gov_fail "auth-path lost the useful git failure detail after scrubbing: $(cat "$WORK/auth-path.out")"

echo "PASS: shared Path Gate boundaries hold (outside paths are out of jurisdiction; default authorization works; absent/unreadable/corrupt auth, protected case variants/symlink aliases, and branch/ticket/graph-node/contract-digest/expiry mismatches behave distinctly and fail closed) AND no shipped CLI verb mints an authorization — least of all from a read-only command record (D2/V-DOOR)"
