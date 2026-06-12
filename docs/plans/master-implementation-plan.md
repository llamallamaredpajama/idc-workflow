# Master Implementation Plan — IDC Workflow Plugin

**Upstream trace:** admitted from `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md` (merged at `main` 95d7ab4, PR #12). Realizes `docs/prd/prd.md` (R1–R4) against the architecture in `docs/specs/master-architectural-spec.md §3` (this admission).

> First master implementation plan authored for this repository (chain-bootstrap admission). It admits one §Domain and two §Phase rough seeds. Per RFD, each §Phase carries a module sketch and a subphase **decomposition table only** — no subphase subsections, no candidate-pillar names. Subphase plans are Develop's authority (Phase 1 in this Plan run's continuation; Phase 2 in a later Plan run).

## §Domain: plugin-lifecycle

**Owns:** the lifecycle of an IDC install in a governed repo — installing, removing, and updating IDC's repo footprints — plus the committed **install receipt** substrate (`docs/specs/master-architectural-spec.md §3.1`) that ties the three operations together. The domain's organizing invariant is the safety-critical fingerprint compare (`spec §3.2`): every destructive or re-stamping action acts only on provenance IDC can prove, and ambiguity always fails toward asking.

**Does NOT own:** the IDC role chain itself (Think/Plan/Sequence/Build/Ripple behavior), tracker semantics beyond the schema-drift read, or machine-global plugin state (`claude plugin uninstall`, Codex link revert) — those are out of scope per PRD §5.

**Operator sequencing (admitted):** two trains, uninstall first (consideration §Next Role Questions). The §Phase split below mirrors that decision exactly.

---

### §Phase 1 — Train 1: install-receipt substrate (`/idc:init` receipt-writing) + `/idc:uninstall`

**Module sketch.** Phase 1 establishes the receipt substrate and the first command that consumes it. It owns two tightly-coupled deliverables: (a) making `/idc:init` fingerprint every file it stamps and write the committed `docs/workflow/install-receipt.yaml` at the end of a successful run (`spec §3.1`), and (b) a new `/idc:uninstall` command — a phased, idempotent mirror of `/idc:init` that uses the receipt as its removal manifest (with the hardcoded footprint list covering runtime-created files), archives work products to an announced `idc-archive-<date>.tar.gz`, removes all repo footprints in one revertable commit, and leaves GitHub untouched by default (opt-in `--close-issues` / `--delete-board`).

**Intentionally NOT in scope for Phase 1:** `/idc:upgrade` and the `docs/installing.md` "Updating" section (Phase 2); board migration; any silent destructive path (`spec §3.2`, `§3.5`).

**Exit criteria.** `/idc:init` writes a valid `docs/workflow/install-receipt.yaml` covering every stamped file (SHA-256 of as-written bytes); the CI template smoke-render is updated to match init's new write surface and CI is green; `/idc:uninstall` cleanly removes a fresh install in one revertable commit, reports `skipped-absent` on re-run, honors both preflight layers and their non-silent failure postures (`spec §3.5`), and its destructive GitHub options behave per `spec §3.3`.

**Subphase decomposition (rough seed — Develop polishes; this Plan run's continuation):**

| Subphase id | Name | One-line scope | Status |
|-------------|------|----------------|--------|
| `plugin-lifecycle-phase-1-subphase-1` | Install receipt substrate + `/idc:init` receipt-writing | Define the committed `docs/workflow/install-receipt.yaml` format (SHA-256 of as-written bytes; `path`/`fingerprint`/`state` entries) and make `/idc:init` fingerprint every stamped file and write the receipt at the end of a successful run; keep the `ci.yml` template smoke-render in sync with init's new write surface. | ready-for-subphase-planning |
| `plugin-lifecycle-phase-1-subphase-2` | `/idc:uninstall` command | New idempotent mirror-of-init command: receipt-driven removal manifest + hardcoded fallback for runtime-created footprints, announced archive tarball, two-layer preflight (clean-git exempting `idc-archive-*.tar.gz` + board in-flight warn-and-confirm), single revertable commit (scaffold/configs/`TRACKER.md`/`enabledPlugins` strip), GitHub opt-in `--close-issues`/`--delete-board`, `skipped-absent` re-runs. | ready-for-subphase-planning |

> Dependency note (for Develop/Sequence, not a pillar claim): `plugin-lifecycle-phase-1-subphase-2` consumes the receipt format and writer defined in `plugin-lifecycle-phase-1-subphase-1`; subphase-1 is the upstream substrate. `commands/init.md` is a shared-surface **candidate** for the subphase/pillar layer to evaluate because uninstall mirrors init's `enabledPlugins` and idempotency vocabulary, but the preferred decomposition is read-only consumption from `commands/uninstall.md`; any actual shared write surface must be declared and serialized at the subphase/pillar layer.

---

### §Phase 2 — Train 2: `/idc:upgrade` + `docs/installing.md` "Updating" section

**Module sketch.** Phase 2 adds the update path on top of the receipt substrate Phase 1 establishes. It owns the `/idc:upgrade` command — receipt-only detection that silently re-stamps only receipt-proven-untouched files, shows-diff-and-asks on customized files, treats pre-receipt installs as diff-and-ask-once then graduates a fresh receipt, rewrites the receipt only at the end of a successful run, and reports board-schema drift (report-only, three explicit outcomes; `spec §3.5`–`§3.6`) — plus the new `docs/installing.md` "Updating" section documenting the command and the plugin cache-refresh advisory.

**Intentionally NOT in scope for Phase 2:** board mutation/migration (report-only — `spec §3.6`); changing the receipt format set in Phase 1; any silent re-stamp (`spec §3.2`).

**Exit criteria.** `/idc:upgrade` re-stamps only `stamped` receipt entries whose on-disk fingerprint matches, diff-and-asks otherwise, graduates a receipt on a pre-receipt install, rewrites the receipt only on success, reports drift with the three distinct outcomes, surfaces the cache-refresh advisory, and reports `skipped-already-current` on re-run; `docs/installing.md` carries an "Updating" section; CI green.

**Subphase decomposition (rough seed — DEFERRED to a later Plan run per the two-train sequencing):**

| Subphase id | Name | One-line scope | Status |
|-------------|------|----------------|--------|
| `plugin-lifecycle-phase-2-subphase-1` | `/idc:upgrade` command | New command: receipt-only re-stamp detection, show-diff-and-ask for customized/pre-receipt files, receipt graduation + end-of-run-only rewrite, board-drift report-only with three explicit outcomes, cache-refresh advisory surfacing, `skipped-already-current` re-runs. | deferred-to-later-plan-run |
| `plugin-lifecycle-phase-2-subphase-2` | `docs/installing.md` "Updating" section | Author the missing "Updating" section documenting `/idc:upgrade` and the plugin cache-refresh advisory (`docs/dev/2026-06-12-v0.1.0-release-report.md` line ~140). | deferred-to-later-plan-run |

---

## Canonical-layer resolutions & explicit pillar-level deferrals (no silent gaps)

The consideration's open decisions are dispositioned here so nothing is silently dropped.

**Resolved at the canonical (spec) layer** — see `docs/specs/master-architectural-spec.md §3`:

- Receipt **location**: `docs/workflow/install-receipt.yaml` (`spec §3.1`).
- Receipt **fingerprint method**: SHA-256 of as-written bytes (`spec §3.1`).
- Receipt **entry semantics** incl. the customized-file rule (record kept-content fingerprint + `customized` marker; identical at graduation and end-of-run rewrite) (`spec §3.1`).
- Runtime-created footprints (`TRACKER.md`): covered permanently by uninstall's hardcoded list, not appended to the receipt (`spec §3.1` writers).
- Failure-path postures (invalid receipt; uninstall board-read failure; upgrade drift-check-can't-run) (`spec §3.5`).

**Deferred to subphase/pillar engineering (explicit — Build authors under Develop/Deconflict plans):**

- Exact YAML key names and on-disk serialization of `docs/workflow/install-receipt.yaml` entries (semantics fixed at `spec §3.1`; field spelling is pillar-level).
- Whether a receipt template lives in `templates/` or is fully init-generated (no version/stamp markers exist today — `spec §3.7`).
- The internal layout of the `idc-archive-<date>.tar.gz` work-product archive.
- Exact preflight command sequences (the clean-git check, the `idc-archive-*.tar.gz` exemption mechanism, the board in-flight query).
- How `/idc:upgrade` surfaces the cache-refresh advisory operationally (preflight note vs docs-only — PRD R3 fixes that it MUST surface; the surfacing form is pillar-level; the `docs/installing.md` "Updating" section in Phase 2 is the documentation half).
- Whether the lifecycle commands warrant new evalsets under `evals/` (dev tooling, not CI-required; planner judgment call per codebase-context packet).
