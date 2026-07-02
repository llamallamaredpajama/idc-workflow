# IDC Fix Package — design (2026-07)

Companion to `docs/dev/audit-2026-07-01-idc-effectiveness.md`. Every item below traces to a ranked
root cause (RC1–RC7) or a Recirculator hardening tier (T1–T4) from that audit. Design north star
(user's words): **"guard rails, not train tracks… and when things spill outside the guard rail, we
have the proper netting to scoop it up and put it back in the cycle."** Decisions stay with the
LLM; the mechanical plumbing around decisions becomes deterministic and fail-closed.

Standing principle (user, 2026-07-01): **deterministic wherever possible; then latest Sonnet for
easy tasks; Opus when something looks risky or questionable; Fable only when truly stuck; the human
last — as an information source, not a judge.**

---

## A. The janitor — `/idc:janitor` + `scripts/idc_git_janitor.py` (RC1, RC2, RC3 remediation; P0)

One deterministic reconciler, one command, three wirings, four verdict tiers.

**The scanner (`idc_git_janitor.py`)** — read-only by default, single board read + merged-PR list:

| Scan | Detects |
|---|---|
| worktrees | worktree whose branch's PR merged (orphan), dirty worktrees (risky), foreign worktrees |
| branches (local+remote) | merged-but-surviving branches; unmerged stale branches; foreign branches |
| board↔issue↔PR | Status=Done but issue OPEN; issue CLOSED/PR merged but Status≠Done; missing Stage; Buildable with no provenance |
| attribution | IDC naming patterns (`idc-*`, `build*`, `plan/*`, `recirculate/*`, `worktree-*`) vs Codex/Antigravity/team-execute/unknown |

**Verdict tiers:** `SAFE-FIX` (IDC-attributable + merged + clean — e.g. delete merged branch,
remove clean merged worktree, close a Done-but-open issue, set Status=Done on a merged-PR issue) ·
`REPORT-ONLY` (non-IDC artifacts — never touched, always listed) · `RISKY` (dirty worktree,
unmerged branch, ambiguous attribution — listed with a suggested action, needs explicit approval) ·
`COHERENT`.

**The command (`/idc:janitor`)**: default = full report (everything, per the user's "report
everything"); `--apply-safe` executes the SAFE-FIX tier only, re-runs the scanner, and reports the
delta; RISKY items are only ever applied one-by-one on operator confirmation. Exit codes: 0 clean,
1 findings, 2 scanner cannot establish ground truth (fail-closed, mirrors `idc_autorun_drain.py`).

**Triple wiring** (the recirc-sweep pattern): (1) on-demand command; (2) autorun preflight —
report + optional `janitor: auto-safe` config knob; (3) doctor Row 10 — report-only. **Fourth
wiring:** the sandbox e2e harness runs the same scanner as its post-condition gate (§E).

## B. Prevention — make the finisher's promises mechanical (RC1, RC2, RC3; P0–P1)

1. **`scripts/idc_git_finish.py` (P0)** — one deterministic call replaces the five prose steps:
   `--pr N --issue M --worktree PATH` → remove worktree → `gh pr merge --squash --delete-branch`
   → verify remote branch gone (explicit `git ls-remote` check — the audit proved `--delete-branch`
   alone is not sufficient on these repos) → delete local branch → tracker close (both halves) →
   **verify end-state** (PR merged, branches gone, worktree gone, Status=Done, issue closed).
   Fail-closed: any unverified step exits non-zero with a machine-readable `finish: <step> failed`
   line; the janitor is the reconciler for whatever a dead session leaves behind. The finisher
   *decides when* to merge and resolves conflicts (unchanged LLM lane); the tail is no longer prose.
2. **Atomic close (P0)** — the tracker-github `close` recipe becomes one helper invocation that
   does Status→Done + `gh issue close` + read-back verify (RC3's 10 stragglers become impossible
   going forward; the janitor repairs the historical ones).
3. **Real closing keywords (P1)** — PR bodies must carry `Closes #N` **unbackticked** (template
   fix + `lint-references.sh` rule + build-agent instruction), so GitHub's native auto-close and
   `closingIssuesReferences` start working. `/idc:init`/`update` additionally offer (operator
   consent, surfaced not silent) flipping `deleteBranchOnMerge=true` — platform-level belt and
   suspenders for RC2.
4. **Provenance post-condition (P1, T1a)** — `scripts/idc_provenance_check.py`: Plan cannot report
   done until every Buildable it minted carries a valid provenance marker (exit 2 → halt +
   re-stamp). Converts enforcement-map row 14 from PROSE-ONLY to DET-VERIFY; keeps the sweep armed.
5. **Marker emit helper (P1, T1b)** — `scripts/idc_emit_marker.py {discovery|deferral}` so
   implementer/finisher call a serializer instead of hand-writing HTML-comment JSON. The *decision*
   to mark stays LLM; the *writing* becomes deterministic.
6. **GitHub merge lease (P2)** — parity with the filesystem flock lease: `lease-acquire/release`
   ops in the github backend (optimistic-concurrency field write on a designated board item, token
   + TTL semantics mirroring `idc_tracker_fs.py`). Closes enforcement-map row 11.

## C. API cost + resilience (RC4; P0–P1)

1. **Kill the O(K·M) sink (P0)** — resolve item ids from the wave's one board read: the tracker
   ops accept a cached `{issue# → item_id}` map (tempfile, orchestrator-scoped) instead of
   `itemid()`'s full-board re-read per mutation. ~120 board-page reads/wave → ~2
   (`graphql-cost.md` fix #1).
2. **Single board read per sweep; fold per-issue reads into the board query (P2)** — sweep dedupe
   reuses the scan's fetch; `blocked_by` and issue bodies/comments ride the board GraphQL
   (fixes #2–#4).
3. **Rate-limit awareness (P1)** — the shared `_gh()` wrapper gains: preflight check, 403/secondary
   detection → emit `rate-limited until <reset>` verdict; autorun treats it as **pause-and-resume**
   (it already re-checks next `/loop`), never silent drop. Post-reset, in-flight finishes re-verify
   via `idc_git_finish.py`'s end-state check. Turns the "wait an hour" from a silent mid-wave death
   into a deliberate, resumable pause.

## D. Model-escalation ladder (user's standing principle; P2)

Encode in the runtime adapters + `WORKFLOW-config.yaml` (`models:` block): mechanical roles
(tracker ops, janitor triage, marker emission, board reads) default to latest Sonnet; risk-flagged
findings (RISKY janitor tier, recirc consultant on a cascade, review escalations) route to Opus;
Fable reserved for stuck-state; human gates phrased as information requests ("what do you know that
the board doesn't"), never rubber-stamp approvals. Per-role overrides mirror the existing
`PI_IDC_<ROLE>_MODEL` umbrella pattern so all three runtimes stay in parity.

## E. Rebuilt verification (RC6; P1)

1. **Real-git lifecycle smoke phase** — hermetic repo + `git init --bare` local "origin": real
   branch, real worktree, real merge, real delete — no GitHub needed, real git semantics. Assertion
   = the janitor scanner exits 0. **Red-when-broken by construction:** break any cleanup step and
   the scanner fails.
2. **Multi-wave accumulation phase** — run ≥2 consecutive simulated waves in one repo; assert zero
   debris growth between waves (the exact failure class the current suite structurally cannot see).
3. **Sandbox e2e post-condition gate** — every spawned e2e run ends with (a) the janitor scan
   (fail run on incoherence) and (b) a `gh api rate_limit` before/after delta written into the run
   capture (makes API cost visible per run, catches regressions of §C).
4. **Relabel, don't delete, the prose-greps** — they are legitimate *doc-integrity* checks; the
   suite's rollup should report them as `doc:` assertions distinct from `behavior:` assertions so
   "all green" states what was actually proven.

## F. Rollout

1. Ship P0 (janitor, git-finish, atomic close, item-id cache) as **3.3.0**; P1 close behind.
2. KE remediation: `claude plugin update` → `/idc:doctor` → `/idc:janitor` (report) → operator
   reviews → `--apply-safe` (clears ~21 debris items, closes the 10 open-Done issues) → RISKY items
   one-by-one. Same for mdm-proj (7 branches).
3. Flip the e2e gate on in `run-all.sh` once the real-git phase exists.

**Priority table**

| P | Items | Root cause |
|---|---|---|
| P0 | janitor · git-finish · atomic close · item-id cache | RC1 RC2 RC3 RC4a |
| P1 | rate-limit resilience · closing keywords + repo setting · provenance gate · marker helper · real-git e2e + post-condition gate | RC4b RC3 RC6 T1 |
| P2 | github lease · count derivation (T3a) · model ladder · sweep/drain read batching · job-E auto-drive (T2b) | RC5 remainder |
