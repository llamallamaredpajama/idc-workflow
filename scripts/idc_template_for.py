#!/usr/bin/env python3
"""idc_template_for.py — the single source of truth for governed dest -> template source mapping.

A governed repo's scaffold files come from the plugin's templates/ dir, but the dest path and the
template path are NOT the same shape: docs/workflow/README.md is rendered from
templates/docs-tree/README.md, while the unrelated templates/README.md documents the templates dir
itself. Re-deriving the template by basename or path-tail can pick the wrong file and clobber a
governed file. Both /idc:init (via idc_init_scaffold.sh) and /idc:update resolve every template
through this helper so the mapping can never drift between scaffold and resync.

Mapping (mirrors the scaffold copy step exactly):

    WORKFLOW.md                       <- templates/WORKFLOW.md
    WORKFLOW-config.yaml              <- templates/WORKFLOW-config.yaml
    docs/workflow/tracker-config.yaml <- templates/tracker-config.yaml      (special: top-level)
    docs/workflow/<rest>              <- templates/docs-tree/<rest>          (README.md, code-reviews/, pillar-matrices/, ...)

Usage:
    idc_template_for.py [--plugin-root ROOT] DEST
        DEST                 governed dest path relative to the repo root (e.g. docs/workflow/README.md)
        --plugin-root ROOT   print the ABSOLUTE source path under ROOT/templates/ and verify it
                             exists on disk; omit to print the path relative to templates/
                             (e.g. docs-tree/README.md) without a disk check.

Exit codes:
    0  printed the template source for a governed dest.
    2  bad usage.
    3  DEST is not a governed scaffold path, or (with --plugin-root) no such template exists.
       The caller must STOP rather than guess a template.
"""
from __future__ import annotations

import os
import posixpath
import sys

# The scaffold copies these to non-docs-tree destinations. Everything else under docs/workflow/
# comes from templates/docs-tree/<same-relative-path>. workflow-machine.yaml is the transition
# engine's legal-transition table (v4 Phase 2): the template lives at templates/workflow-machine.yaml
# (top-level, so it doubles as the engine's bundled fallback — idc_transition.BUNDLED_MACHINE), and
# the governed copy lands at docs/workflow/workflow-machine.yaml (where machine_path_for() prefers it).
TOP_LEVEL_MAP = {
    "WORKFLOW.md": "WORKFLOW.md",
    "WORKFLOW-config.yaml": "WORKFLOW-config.yaml",
    "docs/workflow/tracker-config.yaml": "tracker-config.yaml",
    "docs/workflow/workflow-machine.yaml": "workflow-machine.yaml",
}
DOCS_WORKFLOW_PREFIX = "docs/workflow/"


def template_rel_for(dest: str) -> str | None:
    """Return the template path (relative to templates/) for a governed dest, or None if dest is
    not a governed scaffold path."""
    norm = posixpath.normpath(dest)
    # Reject absolute paths and anything that escapes the repo root.
    if norm.startswith("/") or norm == ".." or norm.startswith("../"):
        return None
    if norm in TOP_LEVEL_MAP:  # checked first so tracker-config.yaml doesn't fall into docs-tree
        return TOP_LEVEL_MAP[norm]
    if norm.startswith(DOCS_WORKFLOW_PREFIX):
        rest = norm[len(DOCS_WORKFLOW_PREFIX):]
        if rest:
            return "docs-tree/" + rest
    return None


def main(argv: list[str]) -> int:
    plugin_root: str | None = None
    positional: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--plugin-root":
            if i + 1 >= len(argv):
                print("idc_template_for: --plugin-root needs a value", file=sys.stderr)
                return 2
            plugin_root = argv[i + 1]
            i += 2
            continue
        if arg.startswith("--plugin-root="):
            plugin_root = arg.split("=", 1)[1]
            i += 1
            continue
        positional.append(arg)
        i += 1

    if len(positional) != 1:
        print("usage: idc_template_for.py [--plugin-root ROOT] DEST", file=sys.stderr)
        return 2

    dest = positional[0]
    rel = template_rel_for(dest)
    if rel is None:
        print(f"idc_template_for: '{dest}' is not a governed scaffold path", file=sys.stderr)
        return 3

    if plugin_root is None:
        print(rel)
        return 0

    src = os.path.join(plugin_root, "templates", *rel.split("/"))
    if not os.path.exists(src):
        print(f"idc_template_for: no template for '{dest}' at {src}", file=sys.stderr)
        return 3
    print(src)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
