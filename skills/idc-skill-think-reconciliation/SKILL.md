---
name: idc-skill-think-reconciliation
description: 'Use when IDC Think synthesis needs to reconcile research, considerations, and decisions into final artifacts.'
---
# IDC Skill — Think Reconciliation (`idc:idc-skill-think-reconciliation`)

CUSTOM. Substrate consumed exclusively by **the orchestrator inline (substrate: `idc:idc-skill-think-reconciliation`)**. The reconciliation analyzer runs once per Think run at Phase 3 (synthesis trigger). Its job is to look across all ledger volumes' header sections (manifests + pending-investigations + executive summaries) and propose the final domain partition the operator approves before domain-agents emit considerations files.

## When to invoke

Inside the orchestrator inline (substrate: `idc:idc-skill-think-reconciliation`) at one checkpoint:

- **On spawn (return-and-die)** — analyzer reads ledger headers, derives the partition, emits the packet, SendMessages the orchestrator, stands down.

## Input shape

Caller passes a single packet:

- `ledger_paths[]` — list of all ledger volume paths in the run (typically `[<scratch>/ledger-1.md]`; rollovers add `ledger-2.md`, `ledger-3.md`, etc.).
- `scratch_dir` — `/tmp/idc-think/<YYYY-MM-DD>-<slug>/`.
- `output_filename` — typically `reconciliation-packet.md`. Skill writes to `<scratch_dir>/<output_filename>`.

## Output shape

Returns:

- `verdict` — `READY` (always; this skill doesn't fail on partition shape — it returns warnings instead).
- `output_path` — absolute path to the emitted reconciliation packet.
- `final_domains_count` — int (1–5).
- `warnings_count` — int (count of `## Warnings` items in the packet).

The emitted packet at `<scratch_dir>/<output_filename>` carries the 5 required output fields (load-bearing names + ordering):

```markdown
# Reconciliation packet — <run-id>

## final_domains

<List of 2-3 target / max 5 final domain tags as kebab-case bullets. Each bullet carries:
- tag
- one-line plain-language description
- estimated entry count (sum across volumes)
- domain status (active when emergent or merged, closed when domain-agent has already emitted)>

## tag_aliases

<Bulleted list mapping each ledger-emergent tag to its final partition tag. Example:
- `agent-recall` → `agent-memory` (merged based on subject overlap; both tags surfaced same Letta / GraphRAG cluster)
- `retrieval-mechanics` → `retrieval-mechanics` (kept as-is)
Empty list when no merges needed.>

## split_or_merge_rationale

<Plain-language paragraph (2-4 sentences) explaining each split or merge in tag_aliases. Cites manifest evidence (entry counts, first-seen dates, executive-summary snippets). NEVER recommends adoption or pre-decides; just rationalizes the partition shape.>

## orphan_check

<Bulleted list of any ledger-emergent tags that did NOT cluster into the final_domains. Each bullet:
- tag
- one-line reason it's orphan-status (insufficient entries / cross-cuts everything / surfaced too late)
- proposed disposition: defer-to-future-run | absorb-into-<final_domain> | drop-as-noise
Empty list when no orphans.>

## warnings

<Bulleted list of partition-shape concerns the operator should know about before approving. Each bullet plain language. Examples:
- "Final domains count is 5 (max). If the operator surfaces another domain post-synthesis, we'll need to defer it to a future run rather than spawn a 6th."
- "Two domains share a 30%+ entry overlap (agent-memory and retrieval-mechanics); the operator may want to consider whether they're actually one domain."
- "Pending-investigations table has 2 rows still in `dispatched` status; their findings haven't returned. The operator may want to wait for them before synthesis."
Empty list when partition is clean.>
```

## Partition-derivation rules (load-bearing)

1. **Read ledger HEADERS only.** Never read the `## Body` section of any ledger volume — bodies are downstream-writer territory (brainstormer captures, investigator findings, domain-agent tagged entries). Reconciliation works from the curator-maintained headers (`## Header`, `## Domain manifest`, `## Pending investigations`, `## Executive summary`).
2. **Target 2–3 final domains; cap at 5.** A run that synthesizes into 6+ domains has misclassified itself — the operator's exploration touched too many areas to be one Think run. The skill EMITS warnings (not errors) so the operator can decide.
3. **Single-entry tags collapse into the closest larger neighbor** unless the curator's executive summary explicitly notes the tag is genuinely standalone. Single-entry standalone tags surface as `orphan_check` with `proposed disposition: defer-to-future-run`.
4. **Cross-volume entry counts sum.** If `agent-memory` has 4 entries in `ledger-1.md` and 7 in `ledger-2.md`, the final count is 11.
5. **Merge candidates** based on subject overlap (manifest tag + executive-summary mention + first-seen proximity). Don't merge based on aesthetic ("they sound similar"). Always rationalize merges in `split_or_merge_rationale` citing manifest evidence.
6. **Pending investigations matter.** If the pending-investigations table has rows in `dispatched` status (findings haven't returned), include a warning that domains depending on those findings may shift after they return.

## Boundaries (load-bearing)

- **No recommendations.** This skill produces a partition, not an admission verdict. NEVER include language like "recommend admitting domain X" / "the right partition is Y" / "domain Z should be deferred." Phrase as "the partition surfaced is X with rationale Y; operator decides."
- **No body reads.** Header-only. Period.
- **No canonical-doc reads.** This skill works only from the run's own scratch ledger headers. Cross-referencing PRD / master plan is Engineer's territory at admission, not Think's at synthesis.
- **No considerations-file authorship.** The reconciliation packet drives Phase 3 synthesis; domain-agents emit the actual considerations files (per TS-5 schema). This skill never writes to `docs/`.

## Banlist

- **Reading ledger bodies** — refused; only headers.
- **Recommending admission language** — packet phrasing must remain partition-derivation, not adoption.
- **Inferring domains the manifest doesn't surface** — partition derives from manifest tags; never invent new tags reconciliation didn't see.
- **Writing to `docs/`** — packet lives in scratch only; downstream consumption is by orchestrator (forwards `final_domains` to brainstormer for operator sanity-check) + domain-agents (each reads the packet to know its assigned tag's final form).

## Codex parity note

Codex sibling `${CLAUDE_PLUGIN_ROOT}/skills/codex-idc-think/` invokes this skill identically when the Codex parent (or a return-and-die Codex subagent loaded with the TR-6 body) reaches synthesis. The 5-field packet shape + header-only-read + no-recommendations rules are byte-compatible across runtimes.

## See also

- the orchestrator inline (substrate: `idc:idc-skill-think-reconciliation`) — the sole consumer of this skill.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-think.md` §"Ledger header schema" (formerly `think-ledger-schema`; folded inline per Phase 2D PR-7) — defines the four header sections this skill reads from.
- TS-5 `idc:idc-skill-think-considerations-file-schema` — schema for the considerations files the partition routes domain-agents to emit.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-think.md` §Phase 3 — synthesis orchestration; this skill underpins step 1 (analyzer dispatch) and step 2 (operator sanity-check gate).
- Captures-not-recommends rule (IDC Think doctrine) — the no-recommendations rule this skill enforces.
