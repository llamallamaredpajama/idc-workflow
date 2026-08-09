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
import os
import re
import sys
import tempfile

# THE CREDENTIAL SCRUB DOOR — see `idc_credential_shapes.scrub`. Every read of a CHILD PROCESS's
# stderr in this module passes through it AT THE READ, and `tests/smoke/phase11-honesty-repro.sh` R28
# is the census that keeps that true across every module in scripts/.
#
# THE IMPORT IS TOLERANT BECAUSE SEVERAL MODULES HERE RUN AS LONE RELOCATED COPIES. The smoke and
# governance suites copy a single script to a temp directory and execute it there to prove a deleted
# guard was the one doing the work (`phase1-pipe-safety` F, `governance/external-intake-completeness`,
# `phase4-completion-honesty` F) — a hard sibling import makes those copies die on ImportError. The
# fallback FAILS CLOSED: with no table to scrub with, a child's stderr is WITHHELD, never passed
# through. This block is byte-identical everywhere it appears and R28 asserts that, so no copy of it
# can drift into a pass-through.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import idc_credential_shapes as CS  # noqa: E402
except ImportError:                                      # a lone relocated copy — fail closed
    class CS:                                            # noqa: N801 — stand-in for the shared table
        scrub = staticmethod(
            lambda text: text and "[child output withheld — the credential table is not importable]")

# A GraphQL enum literal must be an unquoted bare token; constrain it so a malformed color can never
# break out of the literal we emit.
_ENUM = re.compile(r"^[A-Z][A-Z0-9_]*$")

# The sanctioned op + disclosure marker for `idc_transition.journal_append` (round-16 fix): this
# helper is a board-SCHEMA reconciliation door, not an item-transition door, so it journals a
# distinct record shape — see `cmd_apply`'s docstring and journal_append's schema-reconciliation
# branch for why this can never be misread as an item transition on replay.
SCHEMA_RECONCILE_OP = "schema-reconciliation"
DOOR = "idc_stage_options.cmd_apply"


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
    Returns ``(mutation_string, field_id)``, or exits 3 (already-present, idempotent no-op) / 2
    (fail-closed). ``field_id`` rides back out so `cmd_apply` can cite it as journal evidence
    without re-reading the (possibly stdin, already-consumed) options JSON."""
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
    mutation = (
        "mutation {\n"
        "  updateProjectV2Field(input: {\n"
        f"    fieldId: {json.dumps(field_id)},\n"
        f"    singleSelectOptions: {options_block}\n"
        "  }) {\n"
        "    projectV2Field { ... on ProjectV2SingleSelectField { id options { id name } } }\n"
        "  }\n"
        "}"
    )
    return mutation, field_id


# ── Plan-side option PRE-SEEDING (#208) ──────────────────────────────────────────────────────────
# /idc:init creates `Wave` with exactly one option (`Wave 1`) and `Phase` with one (`Phase 1`), and
# the field-creation helper never appends afterwards — it reports "already exists" and moves on. So a
# two-wave plan on a fresh board fails closed at `Wave 2`, and so does any domain Plan invents (the
# plan agent is explicitly allowed to invent domains). The tracker skill's own doctrine says options
# are "pre-seeded before a setField that needs it"; nothing performed that pre-seeding.
#
# This is that step, and it deliberately adds no machinery: it reuses THIS module's non-destructive
# append — existing options re-sent WITH their node ids, the new one without — because GitHub re-IDs
# every option when the set is replaced wholesale, which silently wipes the values already on items.
# Each append still goes through `cmd_apply`, so it keeps the positive readback and the
# `schema-reconciliation` journal record; nothing here is a second write path.

_FIELD_QUERY = (
    'query($owner:String!,$number:Int!){'
    'user(login:$owner){projectV2(number:$number){field(name:"%s"){'
    '... on ProjectV2SingleSelectField{id options{id name color description}}}}}'
    'organization(login:$owner){projectV2(number:$number){field(name:"%s"){'
    '... on ProjectV2SingleSelectField{id options{id name color description}}}}}}'
)


def _read_single_select_field(repo, owner, project, field_name):
    """The live `{id, options[{id,name,color,description}]}` for one single-select field, or None.

    Read through `gh api graphql` because `gh project field-list` omits option COLOR, and a
    non-destructive append must re-send every existing option with its color intact — dropping it
    would rewrite the option set rather than extend it. Owner may be a user or an org, so both are
    queried and whichever resolves is used."""
    import subprocess
    query = _FIELD_QUERY % (field_name, field_name)
    try:
        p = subprocess.run(
            ["gh", "api", "graphql", "-f", "query=" + query,
             "-F", f"owner={owner}", "-F", f"number={int(project)}"],
            cwd=repo, capture_output=True, text=True)
    except (OSError, ValueError):
        return None
    if p.returncode != 0:
        return None
    try:
        data = json.loads(p.stdout).get("data") or {}
    except (json.JSONDecodeError, ValueError):
        return None
    for holder in ("user", "organization"):
        node = ((data.get(holder) or {}).get("projectV2") or {}).get("field")
        if isinstance(node, dict) and node.get("id"):
            return node
    return None


def ensure_options(repo, owner, project, wanted, color="GRAY"):
    """Pre-seed every single-select option a pending transaction is about to set.

    `wanted` is {field_name: [value, …]}. Returns (appended, problems): `appended` is the list of
    "<field>=<value>" pairs this call created, `problems` the human-readable reasons any could not be.

    FAIL-SOFT BY DESIGN, and that is the point: this runs BEFORE the apply, and the apply's own
    `set-field` still refuses a missing option with the refusal PR #207 pinned honest. So a pre-seed
    that cannot reach the board must not invent a second failure mode — it reports, and the existing
    fail-closed refusal remains the thing that stops the run. Never silently widens anything: an
    option is created only when the caller's frozen transaction actually needs that exact value."""
    appended, problems = [], []
    for field_name, values in sorted((wanted or {}).items()):
        needed = [v for v in dict.fromkeys(values) if str(v).strip()]
        if not needed:
            continue
        field = _read_single_select_field(repo, owner, project, field_name)
        if field is None:
            problems.append(f"could not read the {field_name!r} field's options")
            continue
        have = {o.get("name") for o in (field.get("options") or []) if isinstance(o, dict)}
        missing = [v for v in needed if v not in have]
        if not missing:
            continue
        with tempfile.TemporaryDirectory() as tmp:
            for value in missing:
                # Re-read between appends: each one changes the option set, and re-sending a stale
                # set would drop the option the previous iteration just created.
                current = _read_single_select_field(repo, owner, project, field_name)
                if current is None:
                    problems.append(f"could not re-read {field_name!r} before appending {value!r}")
                    break
                blob = os.path.join(tmp, "field.json")
                with open(blob, "w", encoding="utf-8") as fh:
                    json.dump(current, fh)
                ns = argparse.Namespace(
                    repo=repo, options_json=blob, field_id="", ensure_option=value,
                    color=color, field_name=field_name)
                try:
                    cmd_apply(ns)
                except SystemExit as exc:                 # 0 = applied, 3 = already present
                    if exc.code not in (0, 3):
                        problems.append(f"append of {field_name}={value!r} failed (exit {exc.code})")
                        break
                if_added = f"{field_name}={value}"
                appended.append(if_added)
    return appended, problems


def cmd_append(args):
    mutation, _field_id = _build_append_mutation(args)
    print(mutation)
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

    Journaling (round-16 fix): this is a board-SCHEMA change (adding a single-select option to a
    field), NOT an item-state transition, so it does not fit `idc_transition.journal_append`'s
    item-keyed record shape (no issue number, no status change). But the Global Constraint requires
    every tracker-state write to journal itself — through the engine, the adapters, or "an explicitly
    named reconciliation helper that journals itself as reconciliation" — and a transient stderr
    receipt is not durable. So AFTER the positive readback below confirms the write landed, this
    appends a DISTINCT `op="schema-reconciliation"` record via the same canonical journal writer
    (never hand-written NDJSON): no `item`/`to` keys (so replay can never misread it as an item's
    state — see journal_append's schema-reconciliation branch), carrying the field name/id, the
    appended option, and a `door` marker as its evidence. Best-effort like every journal_append call
    (a journal failure warns, never fails an already-landed write — the existing engine contract)."""
    import subprocess
    mutation, field_id = _build_append_mutation(args)   # exits 3 if already-present (gh never invoked)
    try:
        p = subprocess.run(["gh", "api", "graphql", "-f", "query=" + mutation],
                           cwd=args.repo, capture_output=True, text=True)
    except OSError as e:
        _die(f"could not run gh to apply the append mutation: {e}")
    if p.returncode != 0:
        _die(f"gh rejected the Stage-option append mutation (rc={p.returncode}): "
             f"{CS.scrub(p.stderr).strip()[:300]}")
    # POSITIVE READBACK: confirm the option actually landed in the field's post-write option set
    # (the mutation's own `options{ id name }` selection). A silent partial success must not pass.
    if not _readback_has_option(p.stdout, args.ensure_option):
        _die("append mutation returned success but the Stage field options do NOT contain "
             f"{args.ensure_option!r} on readback — write unconfirmed (rc=0, response: "
             f"{p.stdout.strip()[:300]!r})")
    sys.stderr.write(f"idc_stage_options: applied + read back Stage option {args.ensure_option!r}\n")
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_transition as TE  # noqa: E402 — the engine's canonical journal_append, reused here
    ok = TE.journal_append(args.repo, SCHEMA_RECONCILE_OP, "github", None, {
        "agent": "idc-stage-options",
        "schema_field": args.field_name,
        "schema_field_id": field_id,
        "schema_option": args.ensure_option,
        "door": DOOR,
    })
    if not ok:
        sys.stderr.write("idc_stage_options: WARNING — the schema-reconciliation journal record did "
                          "not durably land (see journal_append's stderr above); the board write "
                          "itself already succeeded and is not rolled back\n")
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
            s.add_argument("--field-name", default="Stage",
                           help="human field name recorded on the schema-reconciliation journal "
                                "entry (informational evidence only; never affects the mutation)")
        s.set_defaults(func=func)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
