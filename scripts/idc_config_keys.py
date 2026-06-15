#!/usr/bin/env python3
"""idc_config_keys.py — structural key-path extraction for IDC's data-bearing config files.

WORKFLOW-config.yaml and docs/workflow/tracker-config.yaml are operator-owned data files seeded
once from a stub template. After /idc:init fills them (domains, field_ids, project_number, ...),
they permanently differ from the stub template — that difference IS the data, not drift. So
/idc:update must never offer to overwrite them; it preserves them and only flags GENUINE NEW
STRUCTURE the template introduced (a new key/field/schema), which an operator may want to adopt.

This helper extracts a file's structural key-paths (dotted) so update can tell "only your data
differs" (no key-paths added → stay silent) from "the new version added a key" (advise, never
overwrite). It is dependency-free (no PyYAML — these files ship to repos that may lack it) and
deliberately conservative about what counts as "structure":

  * mapping keys are structure: `field_ids:` -> `field_ids`, nested -> `field_ids.Status`
  * LIST contents are opaque: a populated `domains:` list never yields `domains.name` etc. — the
    list is operator data, not schema. The `domains` key itself is structure.
  * BLOCK SCALARS are opaque: the prose under `use: >-` is skipped, so a colon inside that prose
    (`execute-never-decide: ...`) is never mistaken for a key.
  * FLOW values are leaves: `claude: { model: ... }` yields `claude`, not `claude.model`.

Usage:
  idc_config_keys.py FILE                 print FILE's sorted structural key-paths, one per line
  idc_config_keys.py --added BASE NEW     print key-paths NEW has that BASE lacks (the new
                                          structure NEW introduces), sorted, one per line
Exit 0 on success (empty output is valid — it means "no added structure"); 2 on bad usage;
3 if a file can't be read.
"""
from __future__ import annotations

import re
import sys

# A mapping key line: leading indent, a key token, a colon, then the rest (value/empty/block-marker).
_KEY = re.compile(r"^(\s*)([A-Za-z_][\w.-]*):(.*)$")
# Block-scalar indicators after the colon: |, >, |-, >-, |+, >+ (optionally trailing comment).
_BLOCK = re.compile(r"^[|>][+-]?\s*(#.*)?$")


def structural_keys(path: str) -> set[str]:
    try:
        lines = open(path, "r", encoding="utf-8").read().splitlines()
    except OSError as exc:
        print(f"idc_config_keys: cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(3)

    keys: set[str] = set()
    stack: list[tuple[int, str]] = []   # (indent, key) ancestry of the current mapping path
    skip_indent: int | None = None      # inside a list/block-scalar: skip lines indented > this

    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if skip_indent is not None:
            if indent > skip_indent:
                continue          # still inside the opaque list/block-scalar body
            skip_indent = None    # dedented out — fall through and process this line

        if raw.lstrip().startswith("- "):
            # list item: the enclosing key is a list. Treat the whole list as opaque (operator
            # data, not schema). Skip this item's body; sibling items re-trigger this branch.
            skip_indent = indent
            continue

        m = _KEY.match(raw)
        if not m:
            continue
        key, rest = m.group(2), m.group(3).strip()

        while stack and stack[-1][0] >= indent:   # pop to the current indent level
            stack.pop()
        stack.append((indent, key))
        keys.add(".".join(k for _, k in stack))

        if _BLOCK.match(rest):
            skip_indent = indent   # block scalar: its (deeper-indented) content is opaque

    return keys


def main(argv: list[str]) -> int:
    if len(argv) >= 1 and argv[0] == "--added":
        if len(argv) != 3:
            print("usage: idc_config_keys.py --added BASE NEW", file=sys.stderr)
            return 2
        base, new = structural_keys(argv[1]), structural_keys(argv[2])
        for k in sorted(new - base):
            print(k)
        return 0
    if len(argv) != 1:
        print("usage: idc_config_keys.py FILE | --added BASE NEW", file=sys.stderr)
        return 2
    for k in sorted(structural_keys(argv[0])):
        print(k)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
