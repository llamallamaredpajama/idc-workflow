---
name: idc-skill-think-considerations-file-schema
description: Use when an IDC Think run is about to create or update an active consideration file under docs/considerations/.
---

# IDC Skill — Think Considerations File Schema

Use this skill to validate the active consideration queue output for `/idc:think` and `idc:codex-idc-think`.

## Active Queue Rule

Top-level `docs/considerations/*.md` files are active unprocessed pre-canonical items. Exclude `README.md` and `archived-considerations/` from active scans.

Before creating a new file, scan active files and merge into a matching unresolved topic when one exists. Active files are organized by topic, not by session.

## Path Rule

Valid active path:

`docs/considerations/<YYYY-MM-DD>-<topic>-considerations.md`

Processed or dismissed files leave the active queue. Default cleanup is archive-preserving with `git mv` to `docs/considerations/archived-considerations/<same-name>`. Hard deletion requires explicit operator instruction.

## Required Shape

The file must be 100 lines or fewer and include frontmatter:

```yaml
---
kind: consideration
queue_status: active-unprocessed
domain: <topic>
updated: <YYYY-MM-DD>
---
```

Required H2 sections, in order:

1. `## Frame`
2. `## Named Ideas`
3. `## Context Notes`
4. `## Open Decisions`
5. `## Engineering Implications`
6. `## Source Pointers`
7. `## Next Role Questions`

## Merge Rule

When merging into an existing active file, rewrite the whole file into the concise shape. Preserve distinct ideas, open decisions, source pointers, and engineering implications. Remove duplicate explanation, stale session scaffolding, transcript material, and old per-session structure.

## Banlist

Reject output that includes:

- More than 100 lines.
- Missing `queue_status: active-unprocessed` for active files.
- Raw transcript or ledger material.
- Recommendation, admission, or implementation verdict language.
- Engineer/Develop/Build output shapes: file:line edit maps, contract tables, index proposals, package refactors, system-prompt edit sites.
- A new sibling file for a topic that clearly matches an existing active consideration.

## Optional Research

Do not require persisted research. Research files are optional and require explicit operator approval. A consideration file may carry source pointers instead of archived research.
