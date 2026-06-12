# plugin-lifecycle-phase-1-subphase-1 — Install receipt substrate + `/idc:init` receipt-writing

**Upstream Master Plan Domain/Phase:** §Domain: plugin-lifecycle / §Phase 1 — Train 1: install-receipt substrate (`/idc:init` receipt-writing) + `/idc:uninstall` (staged in `draft-master.md`, landing at `docs/plans/master-implementation-plan.md`)
**Source master-plan row:** `plugin-lifecycle-phase-1-subphase-1` (master §Phase 1 subphase decomposition table)
**Highest Affected Layer:** subphase
**No Higher-Layer Impact Rationale:** This plan polishes an admitted master-plan subphase row into pillar-grade detail; every decision below is either fixed upstream (spec §3.1–§3.5) or explicitly deferred to this layer by the master plan's deferral list — no PRD/spec/master-plan edits required.
**Absorbed considerations:** `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md` (merged at main 95d7ab4, PR #12)
**Spec resolutions binding on this subphase:** `draft-spec.md §3.1` (receipt location `docs/workflow/install-receipt.yaml`; SHA-256 of as-written bytes; `path`/`fingerprint`/`state` entry semantics incl. customized-file rule; writers = init + upgrade only; TRACKER.md outside receipt; end-of-successful-run-only rewrite), `§3.2` (fail toward asking), `§3.4` (idempotency vocabulary), `§3.5` (failure postures)

## Goal

Define the exact on-disk serialization of the committed install receipt (`docs/workflow/install-receipt.yaml`) and extend `/idc:init` with a receipt-writing phase that fingerprints every file init stamped this run (SHA-256 of final as-written bytes, post token-substitution) and writes the receipt only at the end of a successful run — keeping the `.github/workflows/ci.yml` template smoke-render in sync with init's new write surface.

## Scope

- Exact YAML key names + serialization of the receipt (semantics fixed at spec §3.1; field spelling resolved here — see §Rough Pillars).
- Resolution of the master-plan deferral "receipt template in `templates/` vs fully init-generated": **fully init-generated.** Fingerprints are per-install computed values, not substitutable tokens; a `templates/` receipt would carry either fake entries or unrenderable placeholders, and the ci.yml smoke-render's no-surviving-`{{`-tokens check has nothing meaningful to assert against computed content.
- New receipt-writing phase in `commands/init.md` (inserted as the new Phase 7, before the Summary, which renumbers to Phase 8), including the receipt-coverage rule for fresh installs vs gap-fill re-runs vs pre-receipt installs.
- `ci.yml` template smoke-render kept in sync with init's new write surface (substitution set audit + sync-comment update).
- `CHANGELOG.md ## Unreleased` entry.

## Non-scope

- `/idc:uninstall` (subphase 1.2 — consumes the receipt defined here).
- `/idc:upgrade`, receipt graduation for pre-receipt installs, and `docs/installing.md` "Updating" (Phase 2; this subphase's init phase explicitly declines to fingerprint files it did not write — graduation is upgrade's job).
- `/idc:doctor` receipt awareness — the master row admits init + ci sync only; no trace supports a doctor edit (declared OUT per brief constraint).
- Board/tracker mutation of any kind; `TRACKER.md` receipt coverage (permanently excluded per spec §3.1 writers).
- New evalsets under `evals/` — dev tooling, not CI-required; the sandbox artifact check in the pillar's exit criteria covers the behavior (planner judgment per master deferral list; revisit at phase close if Build finds the artifact check insufficient).

## Work Packets (rough — polished in the pillar plan)

Two packets inside one pillar: (1) receipt format + init receipt-writing phase; (2) ci.yml smoke-render sync + CHANGELOG entry. See the pillar plan for dispatch-grade IDs, file surfaces, and acceptance criteria.

## Dependencies

- **Within-subphase:** (none — single pillar.)
- **Cross-subphase (downstream):** `plugin-lifecycle-phase-1-subphase-2` **blocks_on this subphase** — the receipt format and writer defined here are 1.2's removal-manifest input (master §Phase 1 dependency note). The phase-wide clash pass resolves the master-level `commands/init.md` candidate as read-only consumption by 1.2 (no shared write); the true shared write surface is `CHANGELOG.md ## Unreleased` (both append entries — union-append, wave-ordered).

## Architectural Fitness Obligations

No `tests/test_arch_*.py` fences exist in this repo (no `tests/` dir). The binding CI-level fences instead: `bash scripts/lint-references.sh` (reference-integrity over all `*.md` in `agents skills commands templates`); `ci.yml` plugin-manifest `jq` checks; `ci.yml` template smoke-render (must stay in sync with `commands/init.md` Phase 3 + Phase 4 substitutions — this subphase's explicit sync obligation); `bash -n scripts/*.sh`.

## Exit Criteria

- A fresh-sandbox init run (per `commands/init.md` incl. the new receipt phase) produces a `docs/workflow/install-receipt.yaml` that parses as YAML and lists every file init created that run, each entry carrying `path` / `fingerprint` (64-hex SHA-256 of as-written bytes) / `state: stamped` — verifiable via `bash scripts/materialize-sandbox.sh <dir> --fresh` + the assertion commands in the pillar plan's Exit criteria.
- `bash scripts/lint-references.sh` exits 0; the ci.yml smoke-render step body run locally exits 0 ("rendered YAML parses"); `bash -n` passes for every `scripts/*.sh`; manifest `jq` checks stay green.
- `CHANGELOG.md ## Unreleased` documents the receipt substrate.

## §Rough Pillars

> Recursive Fractal Distillation handoff — Deconflict polishes each subsection into a canonical pillar plan at `docs/plans/pillars/<subphase_id>-pillar-<n>-<pillar_slug>-plan.md`. Rough pillars live INLINE in this subphase plan; never as separate files. Per the folded `idc-develop` orchestrator (now `idc:idc-plan`) anti-pattern line 252, omitting this section makes the subphase plan non-canonical.

### receipt-format-and-init-writer

**Rough scope:** Fix the receipt's exact YAML serialization (top-level `receipt_version: 1`, `fingerprint_method: sha256`, `written_by`, `written_at`; `files:` entries with exactly `path` / `fingerprint` / `state`, sorted by `path`; receipt never lists itself or `TRACKER.md`) and add the `commands/init.md` receipt-writing phase that computes SHA-256 over final on-disk bytes at end of a successful run for every file init created this run, with explicit non-silent postures for re-runs and pre-receipt installs; keep the `ci.yml` template smoke-render in sync. Acceptance: fresh-sandbox init yields a parseable receipt covering every created file with verifiable fingerprints; lint-references, smoke-render, manifest checks, and `bash -n` all exit 0.

**File surfaces (write paths):**

| Path | Role | Co-owners |
|------|------|-----------|
| commands/init.md | exclusive | (n/a) |
| .github/workflows/ci.yml | exclusive | (n/a) |
| CHANGELOG.md | shared | plugin-lifecycle-phase-1-subphase-2:uninstall-command |

**Dependencies:**

- Within-subphase: (none)
- Cross-subphase: (none)

**Parallel-safety hints:** Sole pillar in subphase 1.1, so no intra-subphase pairs exist. Cross-subphase: every subphase-1.2 pillar serializes after this pillar because 1.2's removal manifest consumes the receipt format fixed here; 1.2's pillar plans carry the matching `Blocks on:` directives. `commands/init.md` remains exclusive to this pillar because 1.2 consumes it read-only; `CHANGELOG.md ## Unreleased` is a shared append-only union with 1.2's entry, wave-ordered and recorded in the pair-wise clash evidence as `resolution: union`.

> *Note for polish:* `commands/init.md` is exclusive to this pillar after the cross-bundle pass; `CHANGELOG.md` is the sole shared cross-subphase write surface and names its co-owning rough pillar above. The manifest shard and pair-wise clash evidence record the union resolution.

## Wave-Orchestrator Handoff

### Work Units

| Pillar (§Rough Pillars anchor) | Polished trace key | Wave hint | Blocks on |
|--------------------------------|--------------------|-----------|-----------|
| `receipt-format-and-init-writer` | `plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer` | wave-1 (Train-1 substrate; first admit of the phase) | (none) |

### Gates And Operator Decisions

- No operator gate inside this subphase: subphase plans, pillar plans, clash evidence, and the planning manifest are autonomous (architecture §2 Engineer Gate scope). The phase-level pre-merge gate on the master-plan admission is exercised by the parent Plan run, not here.
- Operator sequencing decision already admitted upstream (two trains, uninstall first) is honored: this subphase is the first wave of Train 1.

### Canonical Ripple Notes

(none — no `ripple_flags` forwarded from §Rough Pillars; all load-bearing decisions trace to spec §3.1–§3.5 or the master deferral list.)
