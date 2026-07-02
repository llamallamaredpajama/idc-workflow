#!/usr/bin/env python3
"""idc_emit_marker.py — serialize an idc-discovery / idc-deferral HTML-comment JSON marker
(design §B.5, T1b).

The implementer hand-writes the `idc-discovery` marker (`agents/idc-implementer.md:64`) and the
finisher hand-writes the `idc-deferral` marker (`agents/idc-finisher.md:71`) that the SessionEnd
recirculation sweep (`idc_recirc_sweep.py`) and the wave-close acceptance gate
(`idc_acceptance_check.py`) parse back out with
`re.compile(r"<!--\\s*idc-(discovery|deferral):\\s*(.*?)\\s*-->", re.S)`. A hand-typed marker is a
silent-drop risk (malformed JSON, a missing required field, a stray control character) — this
helper is the SERIALIZER only: the *decision* to mark stays with the LLM role; the *write* becomes
one deterministic, schema-checked call that can only ever emit well-formed JSON matching the
sweep's parser.

Two marker kinds, matching the two producers exactly:

  discovery  (agents/idc-implementer.md) — a fix recommended but not done in-loop:
      <!-- idc-discovery: {"what":"...","area":"...","suggested_scope":"...","origin":"..."} -->

  deferral   (agents/idc-finisher.md) — an obligation the wave-close acceptance gate consumes
             (`idc_acceptance_check.py`'s REQUIRED_DEFERRAL = kind/what/blocks_goal/suggested_issue):
      <!-- idc-deferral: {"kind":"...","what":"...","blocks_goal":true,"suggested_issue":"#365"} -->

Prints ONE marker line to stdout (no trailing marker-internal newline) and exits 0. The caller posts
it onto the issue via the tracker adapter's `comment` op (`idc:idc-tracker-adapter`) — this helper
never talks to a tracker itself.

Usage:
  idc_emit_marker.py discovery --what W --area A --suggested-scope S --origin O
  idc_emit_marker.py deferral --kind {deferred|out-of-boundary|pre-existing-breakage} --what W \\
                               --blocks-goal {true|false} --suggested-issue I

Exit codes: 0 = marker printed; 2 = a required field is blank, or --blocks-goal is not true/false.
"""
import argparse
import json
import sys

DEFERRAL_KINDS = ("deferred", "out-of-boundary", "pre-existing-breakage")


def _die(msg):
    sys.stderr.write(f"idc-emit-marker: {msg}\n")
    sys.exit(2)


def _require_nonempty(fields):
    """fields: [(flag, value), ...]. _die (exit 2) on the first blank value — a marker with a blank
    required field is corruption the sweep would silently skip (parse_markers only checks 'is this
    valid JSON', not 'is this a well-formed discovery/deferral'), so this is the one place that
    enforces the schema before the marker ever reaches an issue comment."""
    for flag, value in fields:
        if not isinstance(value, str) or not value.strip():
            _die(f"{flag} must be non-empty")


def emit_discovery(args):
    _require_nonempty([
        ("--what", args.what), ("--area", args.area),
        ("--suggested-scope", args.suggested_scope), ("--origin", args.origin),
    ])
    return {"what": args.what, "area": args.area,
            "suggested_scope": args.suggested_scope, "origin": args.origin}


def emit_deferral(args):
    # --kind is not re-checked here: argparse's `choices=DEFERRAL_KINDS` on the --kind flag already
    # guarantees a non-blank, valid value before this function is ever called.
    _require_nonempty([
        ("--what", args.what), ("--suggested-issue", args.suggested_issue),
    ])
    bg = {"true": True, "false": False}.get((args.blocks_goal or "").strip().lower())
    if bg is None:
        _die(f"--blocks-goal must be 'true' or 'false', got {args.blocks_goal!r}")
    return {"kind": args.kind, "what": args.what,
            "blocks_goal": bg, "suggested_issue": args.suggested_issue}


def main():
    ap = argparse.ArgumentParser(
        description="Serialize an idc-discovery/idc-deferral HTML-comment JSON marker "
                    "(a serializer, not a decision-maker — the caller decides WHETHER to mark).")
    sub = ap.add_subparsers(dest="marker", required=True)

    d = sub.add_parser("discovery", help="emit an idc-discovery marker (implementer)")
    d.add_argument("--what", required=True)
    d.add_argument("--area", required=True)
    d.add_argument("--suggested-scope", dest="suggested_scope", required=True)
    d.add_argument("--origin", required=True, help="'#<n>' or a role name")

    f = sub.add_parser("deferral", help="emit an idc-deferral marker (finisher)")
    f.add_argument("--kind", required=True, choices=DEFERRAL_KINDS)
    f.add_argument("--what", required=True)
    f.add_argument("--blocks-goal", dest="blocks_goal", required=True, help="'true' or 'false'")
    f.add_argument("--suggested-issue", dest="suggested_issue", required=True)

    args = ap.parse_args()
    obj = emit_discovery(args) if args.marker == "discovery" else emit_deferral(args)
    payload = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    print(f"<!-- idc-{args.marker}: {payload} -->")
    sys.exit(0)


if __name__ == "__main__":
    main()
