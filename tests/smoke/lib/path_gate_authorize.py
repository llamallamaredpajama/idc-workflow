#!/usr/bin/env python3
"""TEST-ONLY Path Gate mint fixture. NOT SHIPPED — nothing under tests/ reaches a governed repo.

`scripts/idc_path_gate.py` deliberately has NO `authorize` CLI verb (V-DOOR): minting an
authorization is an admission-side privilege, and the public verb it used to expose let any Bash in
a session mint itself a broad write grant. Production minting now happens only inside admission
code — `idc_command_entry_gate._ensure_path_gate_auth` for hook-minted commands and
`idc_command_contract._mint_or_rollback` for a self-minting command (init).

Scenario tests still need to SET UP arbitrary authorization states (narrowed paths, single-action
grants, a specific ticket/graph node) so they can prove what the gate denies. This fixture is that
setup door, and it lives under tests/ precisely so it cannot become a production escalation path.

It calls the SAME `idc_path_gate.write_authorization` the real minters call, so every write-side
guard still applies here — in particular the role-action ceiling (`_role_action_ceiling`), which is
why a test cannot use this fixture to fake a read-only command into a write grant either.

Flag surface intentionally mirrors the deleted verb, so a migrated caller changes only the script
path. Exit 0 on success and print the authorization JSON; non-zero with the error on refusal.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PLUGIN_ROOT = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(_PLUGIN_ROOT, "scripts"))
sys.path.insert(0, os.path.join(_PLUGIN_ROOT, "scripts", "hooks"))

import idc_path_gate as PG  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--session", required=True)
    ap.add_argument("--command", required=True)
    ap.add_argument("--branch")
    ap.add_argument("--ticket")
    ap.add_argument("--graph-node")
    ap.add_argument("--ttl-seconds", type=int, default=PG.DEFAULT_TTL_SECONDS)
    ap.add_argument("--allow-path", action="append", default=None)
    ap.add_argument("--allow-action", action="append", default=None)
    args = ap.parse_args(argv)
    try:
        auth = PG.write_authorization(
            PG.repo_root(args.repo),
            session=args.session,
            command=args.command,
            branch=args.branch,
            allowed_paths=args.allow_path,
            allowed_actions=args.allow_action,
            ticket=args.ticket,
            graph_node=args.graph_node,
            ttl_seconds=args.ttl_seconds,
        )
    except Exception as exc:  # noqa: BLE001 — surface the real refusal to the scenario
        print(f"path_gate_authorize fixture: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(auth, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
