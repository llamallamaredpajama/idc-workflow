#!/bin/bash
# idc-assert-class: behavior
# The reciprocal Think PR / requirements-gate marker is written only through the validating binder.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN/scripts" <<'PY' || gov_fail "PR/gate binder behavior failed"
import copy, sys
sys.path.insert(0, sys.argv[1])
import idc_pr_gate_bind as B

PR, GATE = 41, 52
REQ = "[operator-action] Requirements change — add export"


class Fake:
    def __init__(self, pr_body="PR body", gate_body="Gate body", title=REQ):
        self.pr_body = pr_body
        self.gate_body = gate_body
        self.title = title
        self.calls = []
        self.sabotage = None

    def gh(self, args, repo):
        self.calls.append(tuple(args))
        if args[:2] == ["pr", "view"]:
            return {"body": self.pr_body}
        if args[:2] == ["issue", "view"]:
            return {"title": self.title, "body": self.gate_body}
        if args[:2] == ["pr", "edit"]:
            if self.sabotage != "pr":
                self.pr_body = args[args.index("--body") + 1]
            return {}
        if args[:2] == ["issue", "edit"]:
            if self.sabotage != "gate":
                self.gate_body = args[args.index("--body") + 1]
            return {}
        raise AssertionError(args)

    def writes(self):
        return [c for c in self.calls if c[:2] in (("pr", "edit"), ("issue", "edit"))]

    def install(self):
        B._gh_json = self.gh
        return self


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


# Both missing: preserve each body, write reciprocal markers, and read both writes back.
f = Fake().install()
r = B.bind(".", PR, GATE)
check(r["action"] == "bound", r)
check(f.pr_body == f"PR body\n\n<!-- idc-gate-pr: {GATE} -->", f.pr_body)
check(f.gate_body == f"Gate body\n\n<!-- idc-gate-pr: {PR} -->", f.gate_body)
check(len(f.writes()) == 2, f.calls)
check(sum(c[:2] == ("pr", "view") for c in f.calls) == 2, "PR write lacked readback")
check(sum(c[:2] == ("issue", "view") for c in f.calls) == 2, "gate write lacked readback")
print("  ok both reciprocal markers bind with positive readback")

# Idempotent rerun: exact existing reciprocal binding is a write-free success.
before = len(f.calls)
r = B.bind(".", PR, GATE)
check(r["action"] == "skipped-existing", r)
check(not [c for c in f.calls[before:] if c[:2] in (("pr", "edit"), ("issue", "edit"))], f.calls[before:])
print("  ok exact reciprocal rerun is skipped-existing with no write")

# A safe partial rerun writes only the missing side.
f = Fake(pr_body=f"PR\n\n<!-- idc-gate-pr: {GATE} -->").install()
r = B.bind(".", PR, GATE)
check(r["action"] == "bound" and len(f.writes()) == 1 and f.writes()[0][:2] == ("issue", "edit"), (r, f.calls))
print("  ok a correct partial binding converges by writing only the missing side")


def refuses(fake, needle):
    fake.install()
    try:
        B.bind(".", PR, GATE)
    except B.BindError as exc:
        check(needle.lower() in str(exc).lower(), (needle, str(exc)))
    else:
        raise AssertionError("binder did not refuse")
    check(fake.writes() == [], f"refusal wrote before validating: {fake.calls}")


refuses(Fake(pr_body="<!-- idc-gate-pr: 999 -->"), "999")
refuses(Fake(gate_body="<!-- idc-gate-pr: 999 -->"), "999")
refuses(Fake(pr_body=f"<!-- idc-gate-pr: {GATE} -->\n<!-- idc-gate-pr: {GATE} -->"), "2")
refuses(Fake(title="[operator-action] Decision — choose database"), "Requirements change")
refuses(Fake(title="[operator-action] Rotate certificate"), "Requirements change")
print("  ok mismatches, duplicate markers, decision gates, and arbitrary operator actions refuse before writes")

# A write that does not read back exactly stops with a hard failure (the safe partial state reruns).
f = Fake().install(); f.sabotage = "pr"
try:
    B.bind(".", PR, GATE)
except B.BindError as exc:
    check("readback" in str(exc).lower() and "pr" in str(exc).lower(), str(exc))
else:
    raise AssertionError("missing PR readback did not fail")
check(len(f.writes()) == 1 and not any(c[:2] == ("issue", "edit") for c in f.calls), f.calls)
print("  ok divergent readback stops before the second write")

print("PASS: reciprocal PR/gate binder is validating, idempotent, requirements-only, and readback-verified")
PY

for doc in "$GOV_PLUGIN/commands/think.md" "$GOV_PLUGIN/skills/idc-gate-issue/SKILL.md"; do
  grep -q 'idc_pr_gate_bind.py' "$doc" \
    || gov_fail "$(basename "$doc") does not route reciprocal marker writes through idc_pr_gate_bind.py"
done
