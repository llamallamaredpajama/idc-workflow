#!/usr/bin/env python3
"""Scenario-only Path Gate mint fixture — GATED, because it SHIPS.

IT SHIPS. `.claude-plugin/marketplace.json` declares `"source": "./"` and `plugin.json` carries no
file list, so the installed plugin cache is the whole repository tree — `tests/smoke/lib/` and
`tests/smoke/governance/` included. `${CLAUDE_PLUGIN_ROOT}/tests/smoke/lib/path_gate_authorize.py`
therefore exists on every governed machine and is runnable by the same `python3 "${CLAUDE_PLUGIN_ROOT}/…"`
idiom every IDC command uses. An earlier version of this docstring claimed the opposite ("NOT SHIPPED
— nothing under tests/ reaches a governed repo", "it lives under tests/ precisely so it cannot become
a production escalation path"); both sentences were false, and while they stood this file was an
unguarded replacement for the `authorize` verb V-DOOR deleted — caller-chosen branch, ticket, graph
node, actions and paths, minted from any Bash in any governed session.

`scripts/idc_path_gate.py` deliberately has NO `authorize` CLI verb (V-DOOR): minting an
authorization is an admission-side privilege. Production minting happens only inside admission code —
`idc_command_entry_gate._ensure_path_gate_auth` for hook-minted commands and
`idc_command_contract._mint_or_rollback` for a self-minting command (init).

Scenario tests still need to SET UP arbitrary authorization states (narrowed paths, single-action
grants, a specific ticket/graph node) so they can prove what the gate denies. This fixture is that
setup door, and it is gated by TWO independent signals, BOTH required, so a governed session cannot
reach it:

  1. `IDC_SMOKE_FIXTURE=1` must be exported — no IDC command, agent, skill or template ever sets it;
  2. `--repo` must resolve inside a SCRATCH tree (the process temp root, or a `/tmp` / `/var/folders`
     path). Every scenario builds its repository with `mktemp -d`. A real governed repository lives
     in the operator's working tree and can never satisfy this, which is the load-bearing half: an
     env var alone is one keystroke for an agent, a repository location is not.

A refusal writes NOTHING and exits 3. `governance/path-gate-boundaries.sh` asserts both halves, and
asserts that a control invocation carrying both signals still mints — otherwise the refusal
assertions would be vacuous.

It calls the SAME `idc_path_gate.write_authorization` the real minters call, so every write-side
guard still applies here — in particular the role-action ceiling (`_role_action_ceiling`), which is
why a scenario cannot use this fixture to fake a read-only command into a write grant either.

Exit 0 on success and print the authorization JSON; 2 with the error on a Path Gate refusal; 3 with
the reason when the fixture gate itself refuses.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
_PLUGIN_ROOT = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(_PLUGIN_ROOT, "scripts"))
sys.path.insert(0, os.path.join(_PLUGIN_ROOT, "scripts", "hooks"))

import idc_path_gate as PG  # noqa: E402

ENV_SIGNAL = "IDC_SMOKE_FIXTURE"
REFUSAL_PREFIX = "path_gate_authorize fixture REFUSED"


def _scratch_roots() -> list[str]:
    """The directory roots a disposable scenario repository can legitimately live under.

    `tempfile.gettempdir()` honors TMPDIR exactly as `mktemp -d` does, so it covers the normal case
    on both platforms. The literals cover a scenario that hard-codes a temp path or runs with a
    different TMPDIR than this process inherited; `/var/folders` is where macOS puts per-user temp
    trees and `/private/...` is its realpath form."""
    roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    try:
        roots.append(tempfile.gettempdir())
    except Exception:  # noqa: BLE001 — a broken temp root must not make the gate fail OPEN
        pass
    resolved: list[str] = []
    for root in roots:
        for candidate in (os.path.abspath(root), os.path.realpath(root)):
            if candidate and candidate not in resolved:
                resolved.append(candidate)
    return resolved


def is_scratch_tree(repo: str) -> bool:
    """Whether `repo` resolves inside a disposable scratch root. A governed repository does not."""
    resolved = os.path.realpath(os.path.abspath(repo))
    return any(resolved == root or resolved.startswith(root + os.sep) for root in _scratch_roots())


def refuse_reason(repo: str) -> str | None:
    """The reason this fixture must refuse, or None when both gate signals are present."""
    if os.environ.get(ENV_SIGNAL, "") != "1":
        return (
            f"{REFUSAL_PREFIX}: the scenario signal {ENV_SIGNAL}=1 is not set. This fixture mints a "
            "Path Gate authorization from caller-chosen scope; it exists for hermetic scenarios and "
            "is not an authorization door. A governed command mints through admission code, never "
            "here."
        )
    if not is_scratch_tree(repo):
        return (
            f"{REFUSAL_PREFIX}: --repo does not resolve inside a scratch tree, so this is not a "
            "disposable scenario repository. Scenarios build their repository with `mktemp -d`; a "
            "governed working tree can never mint through this fixture."
        )
    return None


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
    ap.add_argument("--deny-path", action="append", default=None,
                    help="off-limits path(s) — scenario setup for the contract-scoped denied_paths")
    args = ap.parse_args(argv)
    # The gate runs BEFORE the Path Gate is touched and before anything is written.
    refusal = refuse_reason(args.repo)
    if refusal:
        print(refusal, file=sys.stderr)
        return 3
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
            denied_paths=args.deny_path,
        )
    except Exception as exc:  # noqa: BLE001 — surface the real refusal to the scenario
        print(f"path_gate_authorize fixture: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(auth, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
