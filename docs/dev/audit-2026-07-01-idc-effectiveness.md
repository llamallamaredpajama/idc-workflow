# IDC Effectiveness Audit — 2026-07-01

**What this is:** a comprehensive, evidence-first audit of whether the IDC plugin actually does
what it advertises, run against its only real production deployment (knowledge-engine, GitHub
Project #8), a completed secondary deployment (mdm-proj, Project #12), 161 production session
transcripts, 82 dev-test run captures, all 53 smoke-test scripts, and the plugin source itself.

**Who ran it:** a three-teammate analysis fleet — `recon` (Sonnet 5, board/git field forensics via
a dynamic workflow), `codemap` (Opus 4.8, enforcement-architecture + Recirculator + API-cost
tracing), `testmap` (Sonnet 5, test-assertion inventory + production transcript sweep) — with
Fable synthesis. All raw evidence artifacts live in
`/Users/jeremy/dev/sandbox/_idc-observability/audit-20260701/` (index in the appendix).

---

## 1. Executive summary — the one-paragraph version

IDC is two different machines wearing one nameplate. Everything that lives in **data** — reading
the board, deciding what is drainable, acceptance gating, runaway caps, the filesystem lock — is
genuinely deterministic, fails closed, and in places is best-in-class. Everything that lives in
**git** — removing worktrees, deleting branches, performing the merge, closing the issue after the
merge — is **prose**: instructions an LLM agent is trusted to follow, with no script doing the
work, no verification afterward, and nothing anywhere that ever compares the board against git
reality. The observed mess is exactly what that architecture predicts: the board's Status column
turned out to be largely *truthful* (after manual verification, only 2 of 132 items had a stale
status), but **21 pieces of git debris** (13 orphaned branches + 8 orphaned worktrees) and **10
"Done" issues that were never actually closed on GitHub** accumulated because every cleanup and
closure step is hope, not mechanism. The test suite reported green throughout because it verifies
that the instruction documents *contain the right sentences* — not that agents following them
produce the right state. Separately, a quadratic API-cost bug (every single field update
re-downloads the entire board) burns the 5,000-call/hour GitHub budget, and the plugin has **zero
rate-limit awareness** — no retry, no backoff, no resume — so an exhaustion mid-wave silently
drops the tail work (status sync, cleanup), compounding the drift.

**The good news:** every root cause found is mechanically fixable, most with small deterministic
helpers in the pattern the plugin already uses well. The fix package (janitor + prevention +
API-cost + e2e rebuild) is designed in `docs/dev/fix-package-design-2026-07.md`.

---

## 2. The state of your repos — verified debris inventory

### knowledge-engine (production, board #8, 132 items)

| Dimension | Finding | Verified count |
|---|---|---|
| **Board Status accuracy** | Better than it looks. The automated pass flagged 33/132 items (25%) as incoherent; manual verification (`ghost-dig.md`) cleared 10 of those as join artifacts — plan resequencing renumbered issues, and the board was *right*. | **2/132 stale statuses** (1.5%) — #529, #542, both operator-action gate items |
| **Issue-state hygiene** | Board says Done but the GitHub issue was never closed — the `close` operation is two non-atomic calls and the second one drops. | **10 issues** (#363, 364, 366–369, 371, 372, 383, 512) |
| **Orphaned branches (IDC-attributable)** | Merged weeks ago, still on the remote today. | **13** |
| **Orphaned worktrees** | All clean, all merged-and-done, none removed post-merge. | **8** under `.claude/worktrees/idc-*` |
| **Board data quality** | Items missing their Stage field. | 3 |
| **Non-IDC debris (reported, not IDC's fault)** | Codex worktrees (2 detached + 1 branch), Antigravity worktree (1), team-execute branch (1), assorted manual branches. | inventoried in `git-forensics.md` |

Corrected overall drift: **23/132 = 17.4%** of board items have some git-side incoherence — but
the *composition* matters: it is almost entirely git debris and unclosed issues, **not** wrong
statuses. Your feeling of "I'm not sure what's going on anymore" was produced less by a lying
board and more by 15 worktrees and ~40 stale branch names making every `git branch` and every
worktree listing look like chaos, plus 10 open issues whose work actually shipped.

### mdm-proj (corroboration sample, board #12)

Same disease, cleanly attributed: a tight cluster of **7 branches** (`worktree-build-140/141/142/
143/144/150/contrast`), all merged within ~24 hours of IDC going live there (06-21), all still on
the remote. The other ~30 stale branches and all 3 leftover worktrees **predate IDC** by 9 days to
4 months (different tooling, different naming) — the audit attributes fairly. Board: 34/34 Done.
Conclusion: **the cleanup gap is systemic to the plugin, not a knowledge-engine quirk.**

Both repos have GitHub's `deleteBranchOnMerge` setting **off**, so the platform does nothing
automatically and branch deletion rests entirely on agents remembering a flag mentioned in prose.

---

## 3. Root causes, ranked by evidence

### RC1 — The worktree-collision race: cleanup doctrine half-followed (CONFIRMED, 18 production sessions)

The finisher doctrine (`agents/idc-finisher.md:92-99`) is explicit: *remove the worktree first,
then* `gh pr merge --squash --delete-branch`, because git refuses to delete a branch that a
worktree still has checked out. The production transcript sweep (`ke-transcript-sweep.md` §1a)
found the exact predicted error — `cannot delete branch 'X' used by worktree at '...'` — firing in
**18 real sessions across 43 distinct branch names**, from 06-06 through 06-28, i.e. *after* the
fix-doctrine and its smoke-test guard shipped. The agents followed the merge half of the prose and
skipped the worktree-removal half. Worse: on this repo the failure left **remote** branches
surviving too (live spot-check: `build-522`, `build-383` still on origin 3 days after merge).
4 of the 18 sessions show zero recovery at all.

**Why it persists:** the step is prose-only (enforcement-map row 7), nothing verifies the
post-merge state, and the smoke guard for it greps the markdown for the instruction sentence
(`phase4-triplet.sh:29-37`) — a guard that can only fail if someone edits the paragraph.

### RC2 — `--delete-branch` simply omitted in ~12% of merges (CONFIRMED, 17/139 merges)

Independent of RC1: 17 of 139 observed production `gh pr merge` calls never included the flag at
all (`ke-transcript-sweep.md` §1b). Live spot-check of 7 head branches: 5 still on the remote.
Same enforcement class: prose instruction, no verification, repo setting provides no backstop.

### RC3 — Issue close is two non-atomic calls; the tail drops (CONFIRMED, 10 issues)

The github tracker `close` = (1) move board Status→Done, (2) `gh issue close` — two separate `gh`
calls with no transaction and no reconciler (`skills/idc-tracker-github/SKILL.md:163`,
enforcement-map row 5). The board-summary's inverse table shows the second call dropped 10 times:
board Done, issue still open. Nothing anywhere detects "PR merged / status Done but issue open."
Related discovery (`ghost-dig.md`): the repo's PR bodies write `` `Closes #N` `` **in backticks**,
which GitHub does *not* parse — `closingIssuesReferences` is empty on all 16 PRs checked — so the
platform's native auto-close never fires either. The convention actively defeats the free,
deterministic mechanism GitHub already provides.

### RC4 — Quadratic API cost + zero rate-limit awareness (CONFIRMED mechanism; 3 production hits, 1 mid-merge)

`itemid()` in the github tracker re-downloads the **entire board** on every single field mutation
(`skills/idc-tracker-github/SKILL.md:66-68`) — claim, status move, close, everything. ~6 GraphQL
calls per mutation of which the board read grows with board size: **O(waves × board)** — quadratic
as the board fills (now 132 items). A 20-issue wave ≈ hundreds of calls on board mechanics alone
(`graphql-cost.md` sink #1). The plugin has **no rate-limit handling anywhere** — no retry, no
backoff, no preflight, no resume checkpoint (verified by grep). The finisher sequence puts the
board-status sync **last**, after the merge — so when the pool empties mid-wave, merged code keeps
its stale status and downstream cleanup is skipped. Production evidence: 4 sessions hit the literal
GraphQL rate-limit error — **100% of hits were the GraphQL points pool** (zero REST 403s, zero
secondary-rate hits in 161 transcripts), exactly the pool the itemid() sink drains; one hit landed
mid-merge on PR #504 (the same merge command appears twice, ~40 calls apart — a silent
fail-then-retry at the highest-risk seam). The wasteful idiom was also caught live: the common
close-out sequence runs `gh project view` + `field-list` + a full 200-item `item-list` +
`item-edit` for **each single status write**, no caching (`ke-transcript-sweep.md` addendum).
Sizing: rate limiting is a
**real accelerant** but the debris' primary cause is RC1/RC2; the *"wait an hour"* pain you felt is
RC4's cost bug.

### RC5 — The meta-cause: prose-only enforcement at every git joint (the architecture finding)

`enforcement-map.md` classifies 23 mechanics. Every computational mechanic: deterministic,
fail-closed, solid. Every git-side effect (worktree create/remove, branch delete, merge, promote,
close-after-merge) plus the github merge lease: **prose-only, fail-open, no reconciler**. The
filesystem backend has a real flock+TTL merge lease; the github backend — the one production uses —
has **no lease op at all** ("board-backed lease" = trust one orchestrator). `/idc:doctor` never
inspects git. This is the single architectural gap the entire fix package targets. A corollary
caught in production: the acceptance-gate's board→state materialization (a prose-driven step) was
found actually *invoked* in only one of 161 sessions — hand-scaffolded through `/tmp` scripts on a
stale 3.0.4 fallback path — i.e. prose-only steps don't just fail under load, they get quietly
improvised or skipped as routine (`ke-transcript-sweep.md` addendum §b).

### RC6 — The tests verify sentences, not behavior (why everything stayed green)

`assertion-inventory.md`: of 53 smoke phases, the deterministic-helper tests are genuinely
rigorous (positive controls, fail-closed contrasts, red-when-broken by construction). But **every**
git-finalization, cleanup, staffing-gate, and autonomy claim — ~150+ assertions — is a
prose-grep against the agent markdown. Zero tests create a real branch or worktree; zero tests run
two consecutive waves; zero tests touch real GitHub (all `gh` calls are stubs); the only
crash-recovery test covers the experimental Pi runtime, not the production path. Plain-English
verdict from the artifact: *"a recipe card that's been proofread but never actually cooked."*
"All green" certified helper arithmetic + document wording, and was structurally incapable of
catching any of RC1–RC4.

### RC7 — Version lag: KE never ran the current plugin

KE's plugin cache tops out at **3.1.4**; the source shipped **3.2.0** on 06-30, and the June debris
window spans versions back to 3.0.x. Production transcripts show sessions *re-discovering and
ad-hoc-patching* bugs already fixed upstream (the integer-vs-node-id board-write bug; a hand-added
fail-closed guard on blank item ids — `ke-transcript-sweep.md` §4). Every remediation plan must
start with `claude plugin update` in the governed repo, and `/idc:doctor` already surfaces stale
cache — but nothing *forces* the update before a run.

---

## 4. The Recirculator — better bones than expected, leaky inputs

(`recirculator-deepdive.md`) The deterministic spine — sweep decision core, provenance validation,
Buildable-only glass wall, idempotent dedup, fail-closed closeout routing, runaway caps — is real
code that fails closed. Your "some basics are in place" is an *understatement*. The leaks are at
the **inputs**: the discovery/deferral markers and the provenance stamps that feed the net are
hand-written prose steps. Eight silent-drop paths were mapped; the top two:

1. **An unmarked discovery is invisible** — the sweep catches markers, not events. If the
   implementer/finisher never writes the marker (context exhaustion, judgment lapse), nothing
   downstream can see the spill. The finisher's own doc admits it: "without it the gate is inert."
2. **The provenance regime silently disarms** — if Plan skips the (prose) provenance stamp, the
   sweep's auto-restage drops to report-only, and rogue Buildables get claimed cold.

The SessionEnd sweep hook shows a 19-for-19 cancellation record in dev captures (headless `-p`
cancels SessionEnd — known) and **no trace either way** in 161 production transcripts (interactive
sessions may log hooks elsewhere; flagged as an open question, not a confirmed failure — do not
overstate). Defense-in-depth (autorun preflight + doctor 9b) is what actually runs the sweep.

Hardening tiers T1–T4 (make provenance a Plan post-condition; emit markers via helper; derive
recirc counts from board state; merged-but-not-closed reconciler) are specified in the deep-dive
and adopted into the fix package. The *decisions* — when to recirculate, layer analysis, gate
calls — stay with the LLM: guardrails, not train tracks.

---

## 5. What is actually good (calibration)

So this doesn't read as "everything is broken": the whole-board GraphQL read (refuses partial
boards, fail-closed pagination), the autorun drain predicate (`drain: unknown` on any doubt), the
acceptance gate's core, closeout routing, runaway caps, the filesystem tracker's atomic writes and
lease, and the Pi-runtime seam tests are **well-engineered, fail-closed, and tested
red-when-broken**. The 3.1.4 board-read pagination fix demonstrably works (the full 132-item board
reads cleanly). The architecture's *concept* — deterministic joints, free lanes, a netting layer —
is sound; the failure is that the git-side joints were never actually built, only described.

---

## 6. Answers to the questions this audit was chartered on

- **"The board isn't kept up to date / statuses are wrong"** → Partially right, mostly refracted:
  only 2 stale statuses, but 10 unclosed-yet-Done issues + 21 pieces of git debris made the whole
  system *feel* untrustworthy. The mechanisms that would have prevented all of it were prose.
- **"Tons of worktrees and PRs laying around"** → 8 IDC worktrees + 13 IDC branches confirmed
  orphaned (plus non-IDC debris inventoried separately). Only 1 open PR (a draft) — PR hygiene is
  actually fine; it's branches/worktrees that pile up.
- **"Does it work as advertised?"** → The data machinery: yes. The git machinery: no — it is
  advertised as "atomic," and it is aspirational prose (RC1/RC2/RC5).
- **"Is e2e a waste of tokens and time?"** → As currently pointed, largely yes for the failure
  classes that matter: it can't see them (RC6). The rebuilt gate (fix package) reuses the janitor
  scanner as the post-condition assertion so every future e2e run checks board↔git coherence.
- **"Was the rate limit hurting quality?"** → Yes, twice over: the quadratic cost bug made
  exhaustion likely (and made *you* wait), and exhaustion mid-wave dropped tail writes. But it's
  the accelerant, not the primary cause of the debris.

---

## 7. Where the fixes are designed

`docs/dev/fix-package-design-2026-07.md` — the janitor (`/idc:janitor` + `idc_git_janitor.py`
reconciler, report-first), the prevention layer (deterministic post-merge verification, provenance
post-condition, marker helper, atomic close, real closing keywords, repo-setting flip at init, a
github merge lease), the API-cost fixes (item-id cache + batched reads + rate-limit
preflight/backoff/resume), the model-escalation ladder (deterministic → Sonnet → Opus → Fable →
human-as-information-source), and the rebuilt e2e gate. GitHub issues filed per item in the
idc-workflow repo.

---

## Appendix — evidence artifact index

All in `/Users/jeremy/dev/sandbox/_idc-observability/audit-20260701/`:

| Artifact | Author | What it holds |
|---|---|---|
| `board-dump.json`, `board-fields.json`, `ke-issues.json`, `ke-prs.json` | recon | raw full dumps (132 board items, 269 issues, 328 PRs) |
| `board-summary.md` | recon | Status×Stage matrix; the 2 stale + 10 unclosed-Done lists |
| `git-forensics.md` (+ `git-forensics-data.json`) | recon | every KE worktree/branch with dates, merge state, attribution |
| `drift-table.md` | recon | automated 132-row board↔git join (raw pass, 25%) |
| `ghost-dig.md` | recon | manual verification layer — clears 10 false positives → corrected 17.4%; the backticked-`Closes` discovery |
| `enforcement-map.md` | codemap | 23 mechanics classified DET/HYBRID/PROSE; ranked top-5 gaps |
| `recirculator-deepdive.md` | codemap | contract vs mechanism; 8 silent-drop paths; T1–T4 hardening tiers |
| `graphql-cost.md` | codemap | 66-touchpoint API census; the O(K·M) sink; batching plan with savings |
| `assertion-inventory.md` | testmap | all 53 smoke phases classified; never-asserted list; false-confidence audit |
| `run-inventory.md`, `run-inventory-recon.md` | testmap / recon | 82 dev-test captures: 19/19 hook cancellations, deaths, rate hits |
| `ke-transcript-sweep.md` | testmap | 161 production transcripts: RC1 (18 sessions), RC2 (17/139), rate-limit + board-write evidence |
| `mdm-proj-sweep.md` | testmap | the corroborating second repo, with fair attribution |
| `scratch/` | recon | intermediate join scripts + raw command output |
