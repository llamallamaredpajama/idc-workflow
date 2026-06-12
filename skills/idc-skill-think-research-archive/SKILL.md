---
name: idc-skill-think-research-archive
description: 'Use when IDC Think needs to archive polished research outputs with source and decision context.'
---
# IDC Skill — Think Research Archive (`idc:idc-skill-think-research-archive`)

CUSTOM. Schema substrate consumed exclusively by **the orchestrator inline (substrate: `idc:idc-skill-think-research-archive`)**. Encodes the polished-research-file body schema (5 H2s), the per-domain `README.md` schema (current-state-of-directory), the cross-run preservation rule, and the project-inference attribution discipline that distinguishes source-asserted claims from project-specific reframings.

## When to invoke

Inside the orchestrator inline (substrate: `idc:idc-skill-think-research-archive`) at two checkpoints:

- **Per-finding polish** — for each investigator finding being polished into `docs/research/<domain>/<slug>.md`. Validate the proposed body before writing.
- **Per-domain README emit** — for each research-domain directory after all this run's findings land. Validate the current-state-of-directory shape before overwriting `README.md`.

## Input shape

Caller passes a single packet:

- `operation` — `validate-polished-file | validate-domain-readme`.
- `body_payload` — for `validate-polished-file`: structured body with one field per H2 + frontmatter fields. For `validate-domain-readme`: structured body covering the current-state shape (this-run files + prior-run files preserved + domain takeaways).
- `output_path` — absolute path under `docs/research/<domain>/<slug>.md` (polished file) or `docs/research/<domain>/README.md` (per-domain index).

## Output shape

Returns:

- `verdict` — `PASS` or `FAIL`.
- `emitted_text` — canonical-shape markdown for the archivist to write verbatim. Empty on FAIL.
- `schema_violations[]` — list of named violations.
- `attribution_gaps[]` — list of factual claims lacking visible source attribution (cite `${CLAUDE_PLUGIN_ROOT}/agents/idc-think.md` §"Output handoff contract" — formerly `think-output-contract`, folded inline per Phase 2D PR-7).

## Polished research file schema (5 required H2s + frontmatter)

Frontmatter (load-bearing — names + casing exact):

```yaml
---
kind: research
run_id: <run-id from bootstrap>
source_kind: <web-share | web-article | repo | docs | mixed | derived>
source_url: <url-if-applicable; omit key entirely if not a URL>
investigator: <investigator-role-name>
---
```

Body (sections in this order; H2 headers exact):

```markdown
# <Subject title — what the finding is about>

## What this is

<2-4 paragraph plain-language description. What the source asserts, in the source's own framing. NOT a summary of "what the project should do" — that comes later. If the source uses a domain-specific vocabulary (e.g. coding-agent vocabulary in a software-engineering article), name that explicitly so future readers don't conflate the source's frame with the project's own charter.>

## Source citation

- URL: <url, or "n/a — repo source" / "n/a — canonical doc of the governed repo">
- Title: <source's own title>
- How fetched: <Firecrawl, WebFetch + Defuddle, Read tool against repo path, etc.>
- Published vs. derived: <which sections summarize the source directly vs. derived inference>

## Patterns useful for the project

<Bulleted list of patterns or claims from the source connecting to the project's substrate. Each bullet:
- "(per source)" suffix when the bullet is a direct source claim
- "project inference" prefix when the bullet is the archivist's reframing
- Specific named systems / numbers / patterns surfaced visibly per the evidence-based-SOTA attribution rule>

## Caveats and limits (per source)

<What the source itself acknowledges as limits, gaps, or open questions.>

## Project-fit observations

<Plain-language observations about how this material relates to the project's locked invariants. NOT prescriptive — these are observations Engineer / Develop will weigh during admission. NEVER promote a source recommendation to admission language. Use phrasings like "the source's pattern X fits the project's invariant Y; Engineer can decide whether to adopt"; never "the project should adopt X.">
```

The body MAY include additional H2 sections specific to the finding (e.g. `## Mapped against the project's existing surface` for comparative analyses, `## Pricing notes` for sources quoting 2026 pricing). The five sections above are required.

### Polished-file validation rules

The skill REJECTS (`verdict: FAIL`) if:

- Frontmatter missing `kind: research`, `run_id`, `source_kind`, or `investigator`. (`source_url` may be omitted entirely when not a URL — but the key must not be present-with-empty-value.)
- Any of the 5 required H2 sections is absent.
- The 5 sections appear out of order.
- §"Patterns useful for the project" bullets lack `(per source)` or `project inference` markers.
- §"Project-fit observations" contains language like "the project should adopt X" / "the project's path is Y" (admission-language forbid).
- Body contains any of the 7 forbidden output shapes (per `${CLAUDE_PLUGIN_ROOT}/agents/idc-think.md` §"Investigator output contract", formerly `think-output-contract`; folded inline per Phase 2D PR-7): contract-surface tables, file:line attachment maps, AST-fence inventories, composite-index recommendations, envelope-extension proposals, package-refactor plans, system-prompt edit sites.
- `kind: research` is the only allowed `kind` value (not `kind: considerations`, `kind: handoff`, etc. — those are different artifact families).

## Per-domain README schema (current-state-of-directory)

Path: `docs/research/<domain>/README.md`. Overwrite if exists from prior run — README reflects current contents of the directory; cross-run accumulation lives in the directory itself, not the README.

```markdown
# Domain — <Title-Cased Domain Name>

<1-2 paragraph plain-language description of what this research-domain covers. Frame as "external surveys" or "source-of-knowledge inputs" — NOT as "the project's plan for X."

Include a sentence naming the project's locked architectural invariants (per its PRD / architecture spec) this body of work intersects with.>

## Files

- `<filename-1.md>` — <one-line description with source pointer (e.g. "Long-form Gemini share `<id>`. Names X, Y, Z.")>
- `<filename-2.md>` — <one-line description>
- (etc., listing ALL files currently in the directory — this run's writes + prior-run files preserved)

## Domain takeaways for the project

<3-6 plain-language bullets summarizing what this directory's body of work suggests for the project's substrate. NOT prescriptive — observations to mine during Engineer / Develop. Phrase as "the source pattern aligns with the project's invariant X" / "the cross-source consensus is Y" / "Z is software-engineering-specific and conflicts with the project's charter — borrow only the spirit.">
```

### README validation rules

The skill REJECTS (`verdict: FAIL`) if:

- `## Files` section omits any file currently in the directory (cross-run preservation rule violated — prior-run files MUST be listed too).
- §"Domain takeaways for the project" contains admission language (`the project should adopt X` / `the right approach is Y`).
- §"Domain takeaways for the project" contains forbidden output shapes (per the Investigator output contract).
- README frames the domain as "the project's plan for X" instead of "external surveys" or "source-of-knowledge inputs."

## Cross-run preservation rule (load-bearing)

When emitting README, list ALL files currently in the directory, not just this run's. Read each prior file's frontmatter (`run_id`) and first H2 to derive its one-line description. NEVER edit prior-run file bodies — cross-run accumulation is the directory; per-run polish is each file.

The archivist invokes this skill once per file emit + once per README emit; the skill enforces the preservation rule on README emits by requiring the caller to enumerate all directory contents.

## project-inference attribution discipline

Every factual claim in §"Patterns useful for the project" carries one of two markers:

- `(per source)` — direct source claim. Example: `- The Letta-MemGPT recall pattern uses tiered episodic memory with explicit pull-up requests rather than implicit retrieval. (per source)`
- `project inference` — archivist's reframing. Example: `- project inference: this could fit the project's existing confidence-refusal pattern by adding a "no supporting context found, refusing rather than fabricating" branch.`

§"Project-fit observations" sentences either:

- Reference an invariant by name and an observation about fit/conflict (e.g. "the source's pattern X aligns with the project's invariant <name> because Y").
- Are explicitly framed as observations, not prescriptions.

Never blend the two. A sentence like "the project should adopt the Letta pattern (per source: <url>)" violates BOTH markers (recommendation + source attribution applied to a recommendation).

## Banlist

- **Inventing content the source did not assert.** Every factual claim traces to the named source. Verdict: FAIL with `attribution_gaps[]` populated.
- **Promoting source recommendations to admission language.** "The source recommends X" is allowed; "the project should adopt X" is forbidden. Verdict: FAIL.
- **Editing prior-run research files.** README listing only; no body rewrites.
- **Conflating considerations partition with research partition.** Research domains derive from subject matter / source-of-knowledge clusters; considerations domains derive from operator-conclusion clusters. Independence is a feature.
- **The 7 forbidden output shapes** anywhere in polished file or README. Cite the Investigator output contract.

## Codex parity note

Codex sibling `${CLAUDE_PLUGIN_ROOT}/skills/codex-idc-think/` invokes this skill identically when the Codex parent (or a return-and-die Codex subagent loaded with the TR-7 body) is about to emit polished research files or domain READMEs. The 5-H2 schema + cross-run preservation + project-inference attribution are byte-compatible across runtimes.

## See also

- the orchestrator inline (substrate: `idc:idc-skill-think-research-archive`) — the sole consumer of this skill.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-think.md` §"Output handoff contract" (formerly `think-output-contract`; folded inline per Phase 2D PR-7) — cited above for the 7 forbidden shapes + attribution discipline.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-think.md` §Authority — the parent file's authoritative statement of the `docs/research/<domain>/` write surface.
- Evidence-based-SOTA attribution rule (IDC Think doctrine) — the visible-source-attribution rule this skill enforces.
- Captures-not-recommends rule (IDC Think doctrine) — the no-promote-source-recommendations rule.
