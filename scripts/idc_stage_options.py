#!/usr/bin/env python3
"""Assemble a NON-DESTRUCTIVE single-select option-append mutation for a GitHub Projects v2 field.

Background: 3.1.0 added `Stage = Recirculation` but board provisioning was never updated, so a
pre-3.1.0 board's `Stage` field lacks the option and `/idc:recirculate` has nowhere to file.
Adding the option must NOT replace the option set — GitHub re-IDs every option on a replace, wiping
existing item values (see `idc:idc-tracker-github` provisioning caveat). The safe path, verified
against the live API: re-send every EXISTING option *with its node id* (so GitHub preserves it) and
append the new option *without* an id (so GitHub creates just that one).

Two modes:
  * `append` — the pure, testable part: turn the field's current options JSON into that exact
    `updateProjectV2Field` mutation and PRINT it. No network.
  * `apply`  — assemble the SAME mutation and RUN it via a python subprocess `gh api graphql`
    (round-7 Fix 1). This is the SANCTIONED write door: the mutation interlock hard-DENIES a raw
    `gh api graphql -f query="$MUT"` typed into the Bash tool during an active /idc:init or
    /idc:update, but never sees a `gh` subprocess spawned by this helper — so init/update reconcile
    the Stage option through here instead of a raw GraphQL mutation in command prose.

    python3 idc_stage_options.py append --ensure-option <NAME> --options-json <FILE|-> \
        [--field-id <ID>] [--color <ENUM>]
    python3 idc_stage_options.py apply  --ensure-option <NAME> --options-json <FILE|-> --repo <DIR> \
        [--field-id <ID>] [--color <ENUM>]

Input JSON — the Stage field object from
`gh api graphql … field(name:"Stage"){ id options{ id name color description } }`'s `.field`.
The field id rides along inside it, so the caller need not extract it; `--field-id` is an optional
override for the bare-field-object case:
    {"id":"PVTSSF_…","options":[{"id":"…","name":"…","color":"GRAY","description":""}, …]}

Exit codes:
    0  the option was absent — the assembled mutation is printed to stdout (run it).
    3  the option is already present — no-op; nothing printed (re-running would duplicate it).
    2  fail-closed: bad args or malformed/short option data — nothing printed.
"""
import argparse
import json
import re
import sys

# A GraphQL enum literal must be an unquoted bare token; constrain it so a malformed color can never
# break out of the literal we emit.
_ENUM = re.compile(r"^[A-Z][A-Z0-9_]*$")


def _die(msg):
    sys.stderr.write(f"idc_stage_options: {msg}\n")
    sys.exit(2)


def _load_field(path):
    """Return (field_id, normalized_options) from the Stage field object."""
    raw = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as e:
        _die(f"field JSON is malformed: {e}")
    if not isinstance(data, dict):
        _die('input must be the Stage field object {"id": …, "options": [ … ]}')
    opts = data.get("options")
    if not isinstance(opts, list) or not opts:
        _die("field JSON must carry a non-empty `options` array")
    norm = []
    for o in opts:
        if not isinstance(o, dict):
            _die("each option must be an object")
        oid, name, color = o.get("id"), o.get("name"), o.get("color")
        if not oid or not name or not color:
            _die("each existing option needs id, name, and color (got: %r)" % (o,))
        if not _ENUM.match(color):
            _die(f"existing option color {color!r} is not a valid enum token")
        norm.append({"id": oid, "name": name, "color": color, "description": o.get("description") or ""})
    return data.get("id"), norm


def _option_literal(opt, with_id):
    # name/description -> quoted+escaped strings; color -> bare enum token; id only when preserving.
    parts = []
    if with_id:
        parts.append(f"id:{json.dumps(opt['id'])}")
    parts.append(f"name:{json.dumps(opt['name'])}")
    parts.append(f"color:{opt['color']}")
    parts.append(f"description:{json.dumps(opt['description'])}")
    return "{" + ", ".join(parts) + "}"


def _build_append_mutation(args):
    """Assemble the non-destructive `updateProjectV2Field` append mutation from the field JSON.
    Returns the mutation STRING, or exits 3 (already-present, idempotent no-op) / 2 (fail-closed)."""
    json_field_id, existing = _load_field(args.options_json)
    # The field id rides in with the field JSON; --field-id is an optional override.
    field_id = (args.field_id or json_field_id or "").strip()
    if not field_id:
        _die("no field id in the input JSON and --field-id not given (never mutate with a blank id)")
    new_name = args.ensure_option
    color = args.color or "GRAY"
    if not _ENUM.match(color):
        _die(f"--color {color!r} is not a valid enum token")

    if any(o["name"] == new_name for o in existing):
        sys.stderr.write(f"already-present: {new_name}\n")
        sys.exit(3)

    lines = [_option_literal(o, with_id=True) for o in existing]
    lines.append(_option_literal({"name": new_name, "color": color, "description": ""}, with_id=False))
    options_block = "[\n    " + ",\n    ".join(lines) + "\n  ]"
    return (
        "mutation {\n"
        "  updateProjectV2Field(input: {\n"
        f"    fieldId: {json.dumps(field_id)},\n"
        f"    singleSelectOptions: {options_block}\n"
        "  }) {\n"
        "    projectV2Field { ... on ProjectV2SingleSelectField { id options { id name } } }\n"
        "  }\n"
        "}"
    )


def cmd_append(args):
    print(_build_append_mutation(args))
    sys.exit(0)


def _readback_has_option(stdout, want_name):
    """True iff the mutation response echoes an option named ``want_name``.

    The append mutation SELECTS `projectV2Field { … options { id name } }`, so GitHub's response
    carries the field's post-write option set — the server's authoritative echo of what it stored.
    Confirming the new option is present there is a positive readback of the write (round-15 Fix 2):
    a non-zero `gh` exit is not enough, because a partial/racey success could return rc=0 without the
    option actually landing. Parse defensively — any shape we can't confirm counts as "not present"
    so `apply` fails closed rather than reporting a success it did not verify."""
    try:
        data = json.loads(stdout)
    except (json.JSONDecodeError, ValueError):
        return False
    try:
        opts = data["data"]["updateProjectV2Field"]["projectV2Field"]["options"]
    except (KeyError, TypeError):
        return False
    if not isinstance(opts, list):
        return False
    return any(isinstance(o, dict) and o.get("name") == want_name for o in opts)


def cmd_apply(args):
    """Assemble AND run the append mutation via a python subprocess `gh api graphql` — the sanctioned
    write door (round-7 Fix 1). Exit 0 = applied AND read back, 3 = already-present no-op, 2 = fail-closed.

    Journaling note (round-15 Fix 2): this is a board-SCHEMA change (adding a single-select option to
    the Stage field), NOT an item-state transition. `idc_transition.journal_append` records item
    transitions keyed on an issue number / status change / verdict-guard evidence — a schema
    option-append has none of those, so forcing it into that record shape would emit a malformed,
    itemless journal line. The reconciliation guarantee here is instead met by the POSITIVE READBACK
    below plus the explicit success receipt, which together prove the write landed on the real board."""
    import subprocess
    mutation = _build_append_mutation(args)   # exits 3 if already-present (gh never invoked)
    try:
        p = subprocess.run(["gh", "api", "graphql", "-f", "query=" + mutation],
                           cwd=args.repo, capture_output=True, text=True)
    except OSError as e:
        _die(f"could not run gh to apply the append mutation: {e}")
    if p.returncode != 0:
        _die(f"gh rejected the Stage-option append mutation (rc={p.returncode}): {p.stderr.strip()[:300]}")
    # POSITIVE READBACK: confirm the option actually landed in the field's post-write option set
    # (the mutation's own `options{ id name }` selection). A silent partial success must not pass.
    if not _readback_has_option(p.stdout, args.ensure_option):
        _die("append mutation returned success but the Stage field options do NOT contain "
             f"{args.ensure_option!r} on readback — write unconfirmed (rc=0, response: "
             f"{p.stdout.strip()[:300]!r})")
    sys.stderr.write(f"idc_stage_options: applied + read back Stage option {args.ensure_option!r}\n")
    sys.exit(0)


def main():
    p = argparse.ArgumentParser(description="Assemble/apply a non-destructive single-select option-append mutation.")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, func, needs_repo in (("append", cmd_append, False), ("apply", cmd_apply, True)):
        s = sub.add_parser(name, help=("emit" if name == "append" else "assemble AND run")
                           + " a mutation that appends one option, preserving existing ones")
        s.add_argument("--field-id", default="", help="optional override; by default read from the field JSON's id")
        s.add_argument("--ensure-option", required=True)
        s.add_argument("--color", default="GRAY")
        s.add_argument("--options-json", required=True, help="file path, or - for stdin")
        if needs_repo:
            s.add_argument("--repo", required=True, help="repo dir the gh mutation runs in (cwd)")
        s.set_defaults(func=func)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
