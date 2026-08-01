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
# SCENARIO mint door. idc_path_gate.py has no `authorize` verb (V-DOOR); this fixture calls the
# same write_authorization Python API the real admission minters use, ceiling and all. It SHIPS
# with the plugin (marketplace source is "./"), so it refuses unless BOTH IDC_SMOKE_FIXTURE=1 is
# exported AND --repo is a scratch tree; every repo below is built with `mktemp -d`.
export IDC_SMOKE_FIXTURE=1
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

# A minimal mint (no explicit scope) applies the command's default profile. `build` is CLAIM-GATED
# (V-AUTH stage 2): its entry default carries NO mutation actions — write authority is issued by the
# claim transaction (spec §3.3), so a source write under the bare entry mint DENIES.
DEFAULT_AUTH="$(python3 "$PG_AUTHORIZE" --repo "$REPO" --session "$SID" --command build)" \
  || gov_fail "minimal mint failed"
printf '%s' "$DEFAULT_AUTH" | python3 -c '
import json, sys
auth = json.load(sys.stdin)
assert auth["allowed_paths"] == ["."]
assert auth["allowed_actions"] == [], "build entry default must be read-only-until-claim"
' || gov_fail "minimal mint did not apply build's read-only-until-claim default profile: $DEFAULT_AUTH"
deny_case write src/app.ts '' ''
reason_has 'not in the live authorization'
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

# ── D2 — NO CALLER-CHOSEN-SCOPE CLI DOOR REMAINS; the one self-minting verb is fixed-profile ──────
# HONEST SCOPE, because the earlier heading ("NO CLI PATH MINTS AN AUTHORIZATION") was false. Two CLI
# surfaces are in play and this lane covers BOTH, each parser-derived:
#
#   * `scripts/idc_path_gate.py` — no verb mints anything at all. The public `authorize` verb is
#     deleted (V-DOOR): it honored caller-chosen --command/--allow-action/--allow-path, so any Bash in
#     a session whose only precondition was "some active command record exists" could mint itself a
#     whole-repo write/edit/git grant.
#   * `scripts/idc_command_contract.py` — `start` DOES mint, for the commands in
#     `SELF_MINTING_COMMANDS` (init), and this is a real residual: its only precondition is a governed
#     repo, so any Bash can still open an init record and get init's FIXED default profile. What is
#     gone is caller-chosen SCOPE — the contract parser accepts no --allow-path/--allow-action at all,
#     and the profile is chosen by the command name alone. Narrowing that residual needs an
#     admission-side token the Claude-only entry gate would have to issue, which Codex and Pi cannot
#     produce (they have no other mint path), so it is a named follow-up, not a claim.
#
# The verb lists for BOTH scripts are read back off their own parsers, so a newly added minting
# subcommand on either is covered here automatically instead of waiting for someone to remember.
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

# (3b) FLAG-SHAPE-INDEPENDENT (M1). Everything above drives the deleted door's EXACT flag spelling
# (--allow-path/--allow-action), so a fully working `authorize` verb that spelled them --path/--action
# would mint and leave this lane green. This arm asserts the parser STRUCTURALLY instead: the set of
# handler functions reachable from `build_parser()` must be exactly the two non-minting ones. A new
# subcommand — whatever its flags are called — changes that set and reds here.
timeout 60 python3 - "$GOV_PLUGIN" <<'PY' || gov_fail "the shipped Path Gate parser exposes a handler outside the two non-minting ones (see message above)"
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import idc_path_gate as PG

expected = {"cmd_auth_path", "cmd_evaluate"}
parser = PG.build_parser()
subparsers = [a for a in parser._actions if hasattr(a, "choices") and isinstance(a.choices, dict)]
if not subparsers:
    print("FAIL: could not reach build_parser()'s subparsers — this arm is INERT"); sys.exit(1)
handlers = set()
verbs = set()
for action in subparsers:
    for verb, sub in action.choices.items():
        verbs.add(verb)
        func = sub.get_default("func")
        if func is None:
            print(f"FAIL: shipped Path Gate verb {verb!r} has no `func` default — it cannot be "
                  "classified, so this structural check cannot certify"); sys.exit(1)
        handlers.add(func.__name__)
if not verbs:
    print("FAIL: the parser exposes NO verbs — the assertion below would hold vacuously"); sys.exit(1)
if handlers != expected:
    print(f"FAIL: build_parser() handler set is {sorted(handlers)}, expected {sorted(expected)}. A "
          "new handler here is a new CLI door; minting belongs behind the admission lock, on the "
          "Python API, never on a verb. (Verbs seen: %s)" % sorted(verbs)); sys.exit(1)
# The handlers named above must ALSO be the real, non-minting ones — a renamed minting function
# reusing one of these names would satisfy the set comparison alone.
import inspect
for name in sorted(expected):
    src = inspect.getsource(getattr(PG, name))
    if "write_authorization" in src:
        print(f"FAIL: Path Gate CLI handler {name}() reaches write_authorization — a CLI verb mints "
              "again"); sys.exit(1)
print(f"ok: Path Gate CLI exposes verbs {sorted(verbs)} handled only by {sorted(handlers)}, none minting")
PY

# (3c) THE OTHER CLI (B2). `idc_command_contract.py start` is the system's second minting path, so its
# parser is enumerated the same derived way rather than left uncovered because the door lives in a
# different file. Three claims, all true today:
#   i.   no contract subcommand accepts caller-chosen SCOPE flags at all;
#   ii.  no contract subcommand mints for a NON-self-minting command;
#   iii. for each command in SELF_MINTING_COMMANDS the mint is exactly `_default_profile(command)`.
CONTRACT_VERBS="$(python3 "$CONTRACT" --help 2>&1 | python3 -c '
import re, sys
m = re.search(r"\{([a-z0-9,\-]+)\}", sys.stdin.read())
print("\n".join(m.group(1).split(",")) if m else "")
')"
[ -n "$CONTRACT_VERBS" ] || gov_fail "could not enumerate the command-contract CLI verbs from its parser"
printf '%s\n' "$CONTRACT_VERBS" | grep -qx 'start' \
  || gov_fail "the contract verb enumeration lost the known 'start' verb, so it is not really reading the parser: [$CONTRACT_VERBS]"

for verb in $CONTRACT_VERBS; do
  # (i) mint-shaped invocation — a caller-chosen scope must not even PARSE here.
  rm -f "$AUTH_PATH"
  CS_SID="pg-contract-scope-$$-$verb"
  python3 "$CONTRACT" "$verb" --repo "$REPO" --session "$CS_SID" --command build \
    --plugin-root "$GOV_PLUGIN" --args '' --source user \
    --allow-path . --allow-action write --allow-action edit --allow-action git \
    </dev/null >/dev/null 2>&1
  [ ! -f "$AUTH_PATH" ] \
    || gov_fail "command-contract verb '$verb' minted an authorization from a CALLER-CHOSEN scope — the deleted door is back in another file: $(cat "$AUTH_PATH")"
  # (ii) supported-flag invocation on a NON-self-minting command — nothing may be minted.
  rm -f "$AUTH_PATH"
  python3 "$CONTRACT" "$verb" --repo "$REPO" --session "$CS_SID" --command build \
    --plugin-root "$GOV_PLUGIN" --args '' --source user \
    </dev/null >/dev/null 2>&1
  [ ! -f "$AUTH_PATH" ] \
    || gov_fail "command-contract verb '$verb' minted an authorization for the non-self-minting command 'build' — the self-mint must stay scoped to SELF_MINTING_COMMANDS: $(cat "$AUTH_PATH")"
done

# (iii) The documented residual, asserted rather than denied: each self-minting command's `start` DOES
# mint, and the grant is exactly the profile its command name selects — no caller input reaches it.
# Derived from SELF_MINTING_COMMANDS so a command added to that set is covered without editing this.
SELF_MINTERS="$(timeout 60 python3 -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import idc_command_contract as C
print("\n".join(sorted(C.SELF_MINTING_COMMANDS)))' "$GOV_PLUGIN")"
[ -n "$SELF_MINTERS" ] \
  || gov_fail "SELF_MINTING_COMMANDS is empty or unreadable — the residual below cannot be characterized"
for sm in $SELF_MINTERS; do
  rm -f "$AUTH_PATH"
  SM_SID="pg-selfmint-$$-$sm"
  python3 "$CONTRACT" start --repo "$REPO" --session "$SM_SID" --command "$sm" \
    --plugin-root "$GOV_PLUGIN" --args '' --source user >/dev/null 2>"$WORK/sm.err" \
    || gov_fail "start --command $sm failed, so the self-mint residual cannot be characterized: $(cat "$WORK/sm.err")"
  [ -f "$AUTH_PATH" ] \
    || gov_fail "start --command $sm opened its record but minted nothing — $sm is in SELF_MINTING_COMMANDS, so every later mutation in it would fail closed"
  AUTH_PATH="$AUTH_PATH" SM="$sm" GOV_PLUGIN="$GOV_PLUGIN" timeout 60 python3 - <<'PY' \
    || gov_fail "the self-mint granted something other than its command's fixed default profile"
import json, os, sys
sys.path.insert(0, os.environ["GOV_PLUGIN"] + "/scripts")
import idc_path_gate as PG
auth = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
paths, actions = PG._default_profile(os.environ["SM"])
if auth.get("allowed_paths") != PG._normalize_allowed_paths(".", list(paths)) \
        or sorted(auth.get("allowed_actions") or []) != sorted(actions):
    print(f"FAIL: {os.environ['SM']} self-mint granted paths={auth.get('allowed_paths')!r} "
          f"actions={auth.get('allowed_actions')!r}, expected the fixed profile {paths!r}/{actions!r}",
          file=sys.stderr)
    sys.exit(1)
PY
  # (iv) THE SAME COMMAND, invoked WITH a caller-chosen scope. (i) drives `--command build`, which is
  # not self-minting and so mints nothing whatever the flags say; (iii) drives the self-minter with no
  # flags at all. Between them sits the actual escalation: a `--allow-path/--allow-action` pair added
  # to `start` and honored for a command that DOES mint. That must either not parse, or be ignored —
  # never widen the grant. Asserted on the outcome, not the spelling, so it holds for whatever the
  # flags get called.
  rm -f "$AUTH_PATH"
  SMS_SID="pg-selfmint-scope-$$-$sm"
  python3 "$CONTRACT" start --repo "$REPO" --session "$SMS_SID" --command "$sm" \
    --plugin-root "$GOV_PLUGIN" --args '' --source user \
    --allow-path src --allow-action write --allow-action edit --allow-action git \
    </dev/null >/dev/null 2>&1
  if [ -f "$AUTH_PATH" ]; then
    AUTH_PATH="$AUTH_PATH" SM="$sm" GOV_PLUGIN="$GOV_PLUGIN" timeout 60 python3 - <<'PY' \
      || gov_fail "a CALLER-CHOSEN scope reached the self-mint — the deleted door is back on the command-contract parser"
import json, os, sys
sys.path.insert(0, os.environ["GOV_PLUGIN"] + "/scripts")
import idc_path_gate as PG
auth = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
paths, actions = PG._default_profile(os.environ["SM"])
if auth.get("allowed_paths") != PG._normalize_allowed_paths(".", list(paths)) \
        or sorted(auth.get("allowed_actions") or []) != sorted(actions):
    print(f"FAIL: {os.environ['SM']} start ACCEPTED caller-chosen scope flags and minted "
          f"paths={auth.get('allowed_paths')!r} actions={auth.get('allowed_actions')!r} instead of "
          f"the fixed profile {paths!r}/{actions!r}", file=sys.stderr)
    sys.exit(1)
PY
  fi
done

# (3d) THE SHIPPED MINT FIXTURE (B1). `tests/` is inside the published plugin package
# (marketplace source is "./"), so `${CLAUDE_PLUGIN_ROOT}/tests/smoke/lib/path_gate_authorize.py`
# exists on every governed machine and is runnable by the same Bash idiom every IDC script uses. The
# fixture is gated on TWO signals; each is asserted to REFUSE on its own, and nothing is written.
# Red-when-broken: delete either leg of `refuse_reason` and the matching arm mints.
rm -f "$AUTH_PATH"
if env -u IDC_SMOKE_FIXTURE python3 "$PG_AUTHORIZE" --repo "$REPO" --session "$SID" --command build \
     --allow-path . --allow-action write --allow-action edit --allow-action git \
     >/dev/null 2>"$WORK/fixture-plain.err"; then
  gov_fail "a session with no scenario signal minted through the SHIPPED fixture — it is a live escalation door: $(cat "$AUTH_PATH" 2>/dev/null)"
fi
[ ! -f "$AUTH_PATH" ] \
  || gov_fail "the refused fixture invocation still wrote an authorization: $(cat "$AUTH_PATH")"
grep -Fq 'IDC_SMOKE_FIXTURE=1 is not set' "$WORK/fixture-plain.err" \
  || gov_fail "the fixture refusal did not name the missing scenario signal: $(cat "$WORK/fixture-plain.err")"

# The scratch-tree leg is the load-bearing one (an env var is one keystroke for an agent; a governed
# repository's LOCATION is not), and it is asserted directly on the decision function, because a
# governed working tree cannot be conjured inside a hermetic scenario. A repository path outside every
# scratch root must refuse even WITH the signal set; a mktemp path must not.
timeout 60 python3 - "$GOV_PLUGIN" <<'PY' || gov_fail "the shipped fixture's scratch-tree gate does not discriminate (see message above)"
import importlib.util, os, sys, tempfile
root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "pg_authorize_fixture", os.path.join(root, "tests", "smoke", "lib", "path_gate_authorize.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

os.environ[mod.ENV_SIGNAL] = "1"
governed = os.path.join(os.path.expanduser("~"), "dev", "some-governed-repo")
if mod.is_scratch_tree(governed):
    print(f"FAIL: {governed!r} was classified as a scratch tree — a governed working tree would mint")
    sys.exit(1)
if mod.refuse_reason(governed) is None:
    print(f"FAIL: the fixture would MINT for the governed path {governed!r} with the signal set")
    sys.exit(1)
scratch = tempfile.mkdtemp()
if not mod.is_scratch_tree(scratch):
    print(f"FAIL: the scenario's own mktemp path {scratch!r} was refused — the gate is a blanket "
          "refusal, not a discriminator, and every scenario in this suite would be unable to set up")
    sys.exit(1)
if mod.refuse_reason(scratch) is not None:
    print(f"FAIL: a signalled scratch repository was still refused: {mod.refuse_reason(scratch)}")
    sys.exit(1)
os.rmdir(scratch)
print("ok: the shipped fixture refuses a governed path and admits a scratch one")
PY

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

echo "PASS: shared Path Gate boundaries hold (outside paths are out of jurisdiction; default authorization works; absent/unreadable/corrupt auth, protected case variants/symlink aliases, and branch/ticket/graph-node/contract-digest/expiry mismatches behave distinctly and fail closed); no Path Gate CLI verb mints an authorization — asserted behaviorally AND structurally off build_parser()'s handler set, so a door spelled with different flags is caught too; the command-contract CLI accepts no caller-chosen scope on any subcommand and mints only for SELF_MINTING_COMMANDS, at exactly that command's fixed default profile; and the SHIPPED scenario mint fixture refuses a session with no scenario signal and refuses any repository outside a scratch tree (D2/V-DOOR)"
