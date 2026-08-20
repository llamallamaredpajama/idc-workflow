# Part 0 — re-grounding sweep + triage table

**Ground truth:** merged main `6c1254c` (PR #182 release + PR #183's 55 review fixes).
**Sweep date:** 2026-07-28. Two independent read-only agents: (0a) re-grounded every "Grounded facts"
claim in `docs/dev/2026-07-27-pr182-parked-findings-plan.md`; (0b) enumerated parked/deferred/
contested items from PR #182/#183 bodies+comments, issue #184, 84 commits, 4 review docs, both
fix-run ledgers (55 + 65 rows), the `.pi` run dir, and an in-code debt-marker sweep.

---

## A. Re-grounding — what MOVED since the plan was written

The plan was written against integration @ `9e50a1e` / fix branch @ `fd87097`; the fix branch ran to
11 commits. Confirmed drift (every anchor below re-derived by grep, not trusted from the plan):

| Plan claim | Verdict at merged main |
|---|---|
| "Exactly **three** unpinned `uses:` lines" | **NO LONGER TRUE — there are 4**, and zero are pinned: `ci.yml:13`, `ci.yml:22`, `idc-pathway-integrity.yml:52`, `idc-pathway-integrity.yml:61`. The plan's `idc-pathway-integrity.yml:31` is now the *deferral comment*. The predicted "second job" is actually a **second checkout step in the same job** (trusted base ref → `trusted/`, exact head → `head/`). |
| "No local lint/test inspects the pin value" | **STILL TRUE.** `lint-references.sh` rules are A/C/H/L/O/P — none touch Actions refs. The one test that reads the workflow (`pathway-github-check-local.sh:20-44`) greps for the check name and checker path, never an action ref. |
| `authorize` door `:586-599` / parser `:617-627` | **MOVED** → handler `scripts/idc_path_gate.py:710-723`, parser `:741-751`. Door still exists. |
| "fix branch adds a role-action ceiling — confirm it landed" | **CONFIRMED LANDED.** `_normalize_actions:399-413`, `_role_action_ceiling:422-427`, enforced in `write_authorization:539-546`. **Correction to the plan:** it is **write-side only** — `_evaluate_request` does its own inline compare at `:630`; it does *not* call the ceiling. |
| `write_authorization` `:401-449` | **MOVED** → `:494-559` |
| `_default_profile` `:331-334` | **MOVED** → `:416-419` |
| identity `is not None and !=` deny `:533-538` | **MOVED** → `:657-662`, now preceded by a 14-line rationale comment at `:643-656` naming F3 as contested and deferred |
| `contract_digest` self-hash `:337-351` | **MOVED** → `_digest_payload:430-444`, applied `:490`, verified `:668-670`. Still a self-hash, **not** bound to the frozen contract. Spec intent anchor `spec:154` unchanged. |
| `_ensure_path_gate_auth` `:308-337` | **MOVED** → `scripts/hooks/idc_command_entry_gate.py:308-392`; mint call `:329-334` |
| `touch`/`off_limits` storage `:430-431,454-455` | **MOVED** → `scripts/idc_validation_contract.py:848-849` (normalize), `:872-873` (frozen doc) |
| Claude interlock request build `:2346-2382` | **MOVED** → `scripts/hooks/idc_interlock_gate.py:2384-2389`, `:2418`, `:2434`. Fields unchanged. |
| Pi harness request build `:606-741` | **MOVED** → `runtime/pi/extensions/idc-role-harness.ts:699-725`, `:734-737`, `:741`. Fields unchanged. |
| Spec §3.2 Codex mandate `:167-168` | **MOVED** → `:167` alone (`:168` is the Pi bullet) |
| Spec §3.2 denial clause `:158-160` | **MOVED** → `:158-162`; substance identical (mismatch, never absence) |

**Verified UNCHANGED at the exact plan anchors:** `READ_ONLY_COMMANDS:43` · `DEFAULT_TTL_SECONDS:44`
(4 h) · `DEFERS_REGISTRATION` `idc_command_entry_gate.py:67` · hook mint `:329` ·
`commands/init.md:139-141` and `:144-146` · `_boundary_problems` `idc_build_receipt.py:61-72` ·
`idc_transition.py:1781`/`:1857` (claim still mints nothing) · `idc_git_path_gate.py:281-282` ·
`path-gate-boundaries.sh:95-96, 116, 144, 147, 157-160` · spec `:154`, `:195`, `:296-297`, `:310`.

**Two production mint paths, not one.** `_ensure_path_gate_auth` is the only runtime *Python API*
caller, but `commands/init.md:144` reaches `write_authorization` through the CLI door. V-DOOR must
account for both.

**No adapter sends identity.** All three (Claude interlock, Pi harness, git backstop) send only
`action` + `paths` (or `raw_reason`). Flipping the identity check today would deny every mutation
from every runtime — the in-code rationale at `:648-656` already says so. Confirms the F3
adjudication and confirms V-AUTH stage 3 must land adapters first.

---

## B. Triage table

Legend: **ROLL-IN** = folded into a Part-4 unit · **CLOSE** = already done, verified · **DEFER** =
named owner, not this build.

### From the plan doc

| Item | Status at merged main | Triage |
|---|---|---|
| **V-PIN** | 4 unpinned `uses:`, no pin lint | **ROLL-IN → V-PIN** (count corrected 3→4) |
| **V-DOOR** | door still present; ceiling landed write-side only; 1 production + 5 test callers | **ROLL-IN → V-DOOR** |
| **V-AUTH** | entry-mint still whole-repo `["."]` + 4 h; claim mints nothing; `contract_digest` still a self-hash | **ROLL-IN → V-AUTH** (staged 1→2→3) |
| **D1** — Codex per-tool gate absent | **STILL OPEN.** `install-codex.sh` wires zero hooks (337 lines, all skill-symlink work). No Codex adapter anywhere. Codex is covered only by the git backstop. | **DEFER — own unit.** *Not* a V-AUTH stage-3 blocker: the git backstop **is** Codex's request path and can echo identity from the live authorization like the others. Building a real Codex per-tool gate needs runtime-capability research first. |
| **D2** — no read-only self-grant negative test | **HALF CLOSED.** Python API covered: `_command_entry_auth_transaction_unit.py:502-532` (+ case/whitespace variant `:534-562`). **CLI verb still untested.** | **ROLL-IN → V-DOOR** (V-DOOR deletes the CLI door, so the assertion becomes "no CLI path exists") |
| **D3/N1** — CODEOWNERS coverage | **HALF OPEN.** `idc_pathway_check.py` COVERED (`CODEOWNERS:22`, ruleset json `:11`, `PROTECTED_SURFACES:67`, `SURFACE_CLASSES:83`). `idc_ruleset_check.py` **NOT covered anywhere** — the script that enforces the ownership contract governs everything except itself. | **ROLL-IN → V-PIN/V-DOOR PR** |
| **D3/N2** — CHANGELOG | Dated (`CHANGELOG.md:5` `## 5.0.0 — 2026-07-23`). Carries a *commit-history* remediation note (`:66-69`) but **no disclosure of the four parked items** shipping in 5.0.0. Also the date predates the 2026-07-27 merge. | **ROLL-IN → V-PIN/V-DOOR PR** |

### New items found by the sweep

| id | Item | Triage | Lands in |
|---|---|---|---|
| **NEW-1** | Interlock tokenize-failure backstop `_ws_combos` denies 11/15 protected `gh project` verbs and 6/11 `gh issue` verbs — `item-archive`/`edit`/`copy`/`unlink`, `lock`/`unlock`/`transfer`/`pin`/`unpin` absent (`idc_interlock_gate.py:249-256` vs `:455-497`). Reviewer asked for a named follow-up; run's `followups/` dir is empty. | **ROLL-IN** | V-PIN/V-DOOR PR |
| **NEW-2** | `templates/WORKFLOW.md` — a SHIPPED file scaffolded into every governed repo — still tells operators six `controlled` limitations are "tracked to U8/U9". **U8/U9 merged 2026-07-23** (PRs #176/#177). The pointer is dangling: the units shipped, the limitations did not. | **ROLL-IN** | V-PIN/V-DOOR PR (reword) + V-AUTH (retire the items it actually closes) |
| **NEW-3** | No TTL heartbeat/renewal — flat 4 h, no `renew` verb; a drain longer than 4 h dies on an expired authorization. | **ROLL-IN** | V-AUTH (it reworks minting) |
| **NEW-4** | No sanctioned finisher/merge helper for Pi; PR-182 Major #1 was closed by *documenting* the carve-out. | **DEFER** — Pi-runtime unit, named owner. NEW-2 must stop citing U8/U9 for it. | — |
| **NEW-5** | "Live-tracker comparison" (second half of Blocker #3's unblock) is in no unit. | **ROLL-IN → V-AUTH.** Resolved *structurally*: stage 2 mints at claim time, so the authorization's identity comes **from** the live claim transaction. A per-mutation live board read is refused on latency grounds (`path-gate-overhead.sh` bounds it). Reword WORKFLOW.md to state the mechanism actually delivered. | V-AUTH |
| **NEW-6** | Required check's workflow definition is PR-head-controlled: a PR can keep the `idc/pathway-integrity` job name and replace the run step with `exit 0`. Compensating control is CODEOWNERS review only. Disclosed at `.github/workflows/idc-pathway-integrity.yml:13-21`. **Distinct from V-PIN.** | **DEFER — operator.** The real fix (org-level required check / pinned reusable workflow a PR head cannot redefine) needs org admin. Compensating control verified present (`CODEOWNERS:10` covers `/.github/workflows/`). | — |
| **NEW-7** | Spec §2.3 (`spec:98-106`) still MANDATES the ruleset refuse a merge on missing/stale/corrupt/divergent evidence. The code closed that blocker by **narrowing the checker's published contract** (`idc_pathway_check.py:23-32`) and reassigning the duty — but the spec was never amended. | **ROLL-IN** — amend §2.3 to match the delivered split | V-PIN/V-DOOR PR |
| **NEW-8** | `--default-branch` trusted with no cross-check against GitHub's actual default; a wrong operator assertion certifies a ruleset binding no reviewer on the real default (the F39/F44 harm class). | **ROLL-IN** — cheap `gh api` cross-check | V-PIN/V-DOOR PR |
| **NEW-9** | `app-locked` live RG12 write unreceipted — a GitHub App cannot write user-owned Projects v2; proving it needs an ORG-owned board. | **DEFER — operator** (provision an org board) | — |
| **NEW-10** | `pi-runtime` full-drain e2e never run; closure by proxy coverage. `update-adoption` / `claude-hook-fidelity` never re-driven at final head. | **DEFER** — next e2e wave, not a build unit | — |
| **NEW-11** | `GIT_NO_LAZY_FETCH=1` deliberately unset — a blobless/treeless partial clone still makes a git network fetch during ruleset dry-run. One-line flip. | **DEFER — operator policy choice** (strict = refuse partial clones vs permissive = today). Batched into the single operator question. | — |
| **NEW-12** | Code-owner principal gate residual: when GitHub omits `permission` entirely, a custom `role_name` case-folding to `write`/`maintain`/`admin` is still accepted (`idc_ruleset_install.py:477-490,571`). | **ROLL-IN** — same file as NEW-8 | V-PIN/V-DOOR PR |
| **NEW-13** | `_gh_json_all_pages` / `_MAX_LISTING_PAGES` duplicated between `idc_ruleset_check.py` and `idc_ruleset_install.py`; consolidation parked. | **DEFER** — pure refactor, low value | — |
| **NEW-14** | Test-harness fragility: the F57 hook-assertion fixture silently degrades to **all-ALLOW** when `timeout` is missing from PATH. Recorded as a lesson with no code change. | **ROLL-IN** — one-line "control denies first" assertion | V-PIN/V-DOOR PR |
| **NEW-15** | Spec §7 threat-matrix row **T3** never updated for U11; a reader tracing T3 finds neither U11 nor its test. | **ROLL-IN** — folds into the NEW-7 spec amendment | V-PIN/V-DOOR PR |

### Verified CLEAN (coverage was real, not thin)

PR #183 has zero comments/reviews; PR #182 has one comment (the operator's "still needing your
judgment: F3, F42, F2-residual") and zero formal reviews. All 19 open issues enumerated — only #184
relates to this effort. All 84 commits in `71d711a..6c1254c` scanned for deferral language; only
rounds 7 and 8 carry parked dispositions and both are already in #184. Relay-1's 55-row ledger: only
F3 and F42 non-fixed, both adjudicated. Relay-2's 65-row ledger: everything open lands in #184
except NEW-11/12/13. In-code debt sweep across 13 pathway surfaces found **no orphan TODO/FIXME/XXX**
— every marker is a documented known-non-coverage block, the F3 rationale, the F22 scope boundary,
or a normal enum value.

### Already filed elsewhere — do NOT re-file

Issue #184 "Pathway-integrity follow-ups" already carries relay-2 F51, F38, F41, F49, F58/F63-code,
F64-binding, F62, F52, F53, F50, F54–F56 plus two sandbox-e2e operator-experience items. **Two
F-numbering namespaces exist** (relay-1 numbered the 8-reviewer packet F1–F55; relay-2 restarted at
F1 against the fix branch, then continued F57–F65). Do not cross-reference them.

**Ordering dependency the lead must respect:** `idc_pathway_check.py:88-93` defers gutted-but-nonempty
surface protection to code-owner review "whose ownership validator must therefore be sound (F20)".
Issue #184 says that validator is unsound in four ways (F38/F41/F49/F51). Those four are **filed, not
in this work order** — but any unit that leans on that deferral must say so honestly.
