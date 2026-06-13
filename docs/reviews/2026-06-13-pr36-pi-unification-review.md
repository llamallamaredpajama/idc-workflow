# Code review — PR #36 (pi-unification) — broad /code-review-custom

**Scope:** `b5aee90..0d8a500` (24 commits, 66 files, +11,603 / −105 lines) — PR #36 unifies the
pi-harnesses + pi-idc-collab runtimes into the idc-workflow plugin (pi as a third runtime adapter).
Reviewed the full `git diff main...HEAD` of the local branch
`te-integration/pi-unification-plan-2026-06-13-0352`. (Note: local HEAD `0d8a500` is 18 commits
ahead of the PR's pushed head `61f4e45`; the review and merge target the local reviewed code, which
is pushed before merge.)

**Verdict (pre-fix):** FAIL/BLOCKED — 2 Major findings on real changed-code paths.
**Verdict (post-fix):** see "Resolution" at the bottom; re-gated on smoke ALL GREEN + lint CLEAN.
**Risk tier:** full (security-sensitive content: HMAC role-caps, per-session auth, HTTP/SSE hub,
fleet supervisor — the path-based classifier reported `sensitive:false`; overridden to full on content.)
**Packet:** `.code-review/runs/20260613-201949-pr36-pi-unification`
**Reviewer completion:** 6/6 required reviewers succeeded + 2/2 script dimensions ran.

## 13-dimension coverage

| # | Dimension | Tier routing | Result |
|---|---|---|---|
| 1 | Repo Protocol | subagent (protocol-reviewer) | 1 Major, 1 Minor, 1 Nit |
| 2 | Schema & Contract Drift | subagent (type-design-analyzer) | 1 Major (+1 minor test gap) |
| 3 | Error Handling Integrity | subagent (silent-failure-hunter) | 1 Minor |
| 4 | Resource Management | inline | covered (hub MAX_INBOX; see Nit) |
| 5 | Security | inline + security-reviewer subagent | 1 Nit (watchlist-grade), surfaces cleared |
| 6 | Stack Gotcha Audit | inline | no findings (bash-3.2 safe, env-map spawn) |
| 7 | Unit-Test Rigor | subagent (test-analyzer) | 0 findings, 2 minor test gaps |
| 8 | Integration-Test Gap | inline | smoke covers security branches end-to-end |
| 9 | Dependency & Bloat | script (audit-dependencies.sh) | 0 findings (no dep manifest churn) |
| 10 | Complexity Budget | inline | no findings |
| 11 | Git-History Narrative | script (check-commit-narrative.sh) | Minor only (conventional-commit subjects on merged sub-PRs) |
| 12 | Stale-Docs Sweep | subagent (comment-analyzer) | 2 Minor |
| 13 | Simplification Applied | status row | Not requested — default read-only review |

## Reviewer results

| Reviewer | Required | Status | Verdict | Findings |
|---|---|---|---|---:|
| protocol-reviewer | yes | accepted | pass-with-nits | 3 |
| security-reviewer | yes (sensitive scope) | accepted | pass-with-nits | 1 |
| silent-failure-hunter | yes | accepted | pass-with-nits | 1 |
| test-analyzer | yes | accepted | pass-with-nits | 0 (2 test gaps) |
| type-design-analyzer | yes | accepted | pass-with-nits | 1 (+1 test gap) |
| comment-analyzer | yes | accepted | pass-with-nits | 2 |
| audit-dependencies (script) | yes | ran | pass | 0 |
| check-commit-narrative (script) | yes | ran | minor | minor-only |

## Blocker

_None._

## Major

**M1 — Vendored `idc-pi` launcher ships hardcoded personal paths in the load-bearing role-launch
path (violates the repo's own lint Rule C).**
`runtime/pi/scripts/idc-pi` `role_skill()` (lines 858–862) and `build_role_argv()` (line 764) emit
`--skill /Users/jeremy/.agents/skills/{codex-idc-*,idc-workflow}`. `install-pi.sh` symlinks `idc-pi`
onto `PATH` verbatim, so `idc-pi run <role>` (and the fleet path, which reuses `build_role_argv`)
hands `pi` a `--skill` pointing at a hardcoded `/Users/jeremy/...` path that does not exist on any
other user's machine and leaks a username. The same leak is in the 7
`runtime/pi/.pi/agents/idc/*.md` role-prompt files (lines 18–20). The repo's own `lint Rule C`
forbids `/Users/<user>`, but `lint-references.sh` only scans `agents skills commands templates`, so
the new top-level `runtime/` tree escaped the fence (see m1).
*Unblock:* resolve the skill paths portably. The codex/pi skill substrate is `~/.agents/skills/<bare-name>`
(per `docs/dev/phase-0-spike-findings.md` R11), so the personal-path prefix becomes `$HOME` (launcher)
/ `~` (prompt prose); skill names (`codex-idc-*`, `idc-workflow`) are the real installed names and stay.
*Confidence 0.93.*

**M2 — GitHub tracker `query` drops legacy (no-Stage) items when filtering `Stage=Buildable`,
diverging from the FS backend and breaking the documented additive promise.**
`skills/idc-tracker-github/SKILL.md:86` filters `select($st=="" or .stage==$st)`. On a legacy 4-field
board, `.stage` is null, so a Build query (`STAGE=Buildable`) matches nothing — halting all build work
on exactly the unmigrated boards the docs (SKILL.md:26-28, `templates/WORKFLOW.md`) promise "keep
working … no migration step." The FS backend already does the right thing:
`idc_tracker_fs.py:188` `item_stage = it.get("stage") or "Buildable"`. The two backends are required
to be behaviorally identical (idc-tracker-adapter: "callers stay backend-blind").
*Unblock:* `select($st=="" or (.stage // "Buildable")==$st)` so a null/absent stage reads as Buildable.
*Confidence 0.88.*

## Minor

**m1 — `lint-references.sh` does not scan the new top-level `runtime/` tree**, so the project's own
Rule C personal-path fence has a blind spot for all shipped vendored runtime content (this is why M1
shipped undetected). `scripts/lint-references.sh:32`. *Fix:* extend the Rule C scan to `runtime/`.
*Confidence 0.85.*

**m2 — `wait_for_server` returns success (exit 0) when the hub never becomes healthy**, so the
non-fleet pane resident launches against a dead hub. `runtime/pi/scripts/idc-pi:813-820` — the retry
loop only `echo`s a warning and falls off the end (return code = the echo's = 0). The supervised
fleet path (`fleet-supervisor.ts:83-86`) correctly fail-closes; the `run` path should too.
*Fix:* `return 1` after the retry loop. *Confidence 0.85.*

**m3 — Stale "four canonical field node IDs" comment** in `templates/tracker-config.yaml:4`; the rest
of the file was updated to five in the 4→5 field sweep. *Fix:* "four" → "five". *Confidence 0.90.*

**m4 — `agents/idc-review-agent.md:42` omits the pi runtime adapter** from its bounded-fan-out
adapter list (`idc:idc-adapter-claude` / `idc:idc-adapter-codex` only), inconsistent with the sibling
`idc-build.md`/`idc-implementer.md` updated in the same PR whose whole purpose is promoting pi to a
first-class adapter. Behavior unaffected (prose forbids hardcoding a concrete runtime). *Fix:* add the
pi adapter to the list. *Confidence 0.82.*

## Nit

**n1 — Hub HTTP endpoints have no request-body-size or prompt-length cap** (`coms-net-server.ts:934`
and the SendRequest path). `MAX_INBOX` caps message *count* per target, not per-message bytes.
*Accepted / out-of-scope:* SECURITY.md correctly scopes the hub to loopback + single-OS-user, where a
same-user process already owns the fleet; the security-reviewer explicitly marked this "not required
for merge." Recorded as future hardening. *Confidence 0.83.*

**n2 — Canonical `docs/specs/master-architectural-spec.md` not synced** to the 5-field tracker /
8-agent reality (templates were updated correctly); README repo-layout omits the new `runtime/` dir.
Non-shipped, non-linted doc surface; IDC's own Ripple heals this. *Deferred.* *Confidence 0.82.*

## Test gaps (advisory)

- `tests/smoke`: no assertion that a legacy empty-Stage item is returned by `query --stage Buildable`
  (the legacy-compat branch behind M2). **Closed** by the new FS-backend regression case (see Resolution).
- `scripts/idc_schema_check.py`: the unknown-`Stage` rejection branch is untested (validation-message
  branch, not a security/data path). Accepted minor.
- `coms-net-server.ts`: the stale-reap (timeout) tombstone trigger isn't directly exercised; it calls
  the same `tombstoneSessionMessages` the DELETE path proves. Accepted minor.

## Surfaces cleared (high-signal positives)

- **HMAC role-cap minting/escalation** — `roleCap()` uses `crypto.createHmac(sha256,K)`, compared via
  length-guarded `crypto.timingSafeEqual`; re-register recomputes `claimedRole` from the new name and
  requires the cap unconditionally (`coms-net-server.ts:640-653`). No escalation path.
- **Constant-time secret comparison** — every bearer/session-token/role-cap compare routes through
  `tokensEqual` (`timingSafeEqual`); no raw `===` on secrets.
- **Token/nonce entropy** — bearer `randomBytes(32)`, session_token `randomUUID()`, fleet K
  `openssl rand -hex 32` / `/dev/urandom`. No `Math.random` in the hub chain.
- **Session resurrection** — unregister/stale/offline tombstones in-flight messages
  (`tombstoneSessionMessages`); a re-registrant must present the prior session_token. A resurrected id
  inherits no answerable in-flight message.
- **IDOR / per-session auth** — get/await/response/SSE/heartbeat/delete are sender- or target-scoped
  AND bound to the per-session token; knowing msg_id+session_id without the token → 403. Proven by
  `phase8-coms-net-bypass-probe` (SPOOF) + `session-auth-probe`.
- **Glass-wall ACL fail-CLOSED** — `evaluateComsNetSendForRole` fail-closes on unknown
  sender/target/role-not-in-river; the hub enforces it server-side off `canonical_role` before
  queue/deliver (not client-only). bypass-probe asserts raw POSTs get 403.
- **Fleet supervisor argv/env secret non-leak** — K and per-role caps reach children only via
  `Bun.spawn` execve env maps; the launcher passes K/bearer as shell env assignments, not argv. Proven
  by `phase8-pi-fleet-secret.sh` (ps sampling + per-resident environ check).
- **Fleet fail-close** — unhealthy hub → `teardown(1)` without spawning; any child non-zero exit
  propagates. Governance-gated before spawn.
- **install-pi.sh symlink safety** — refuses to clobber a non-symlink, records revert state, verifies
  the link; no curl|sh.
- **Governance compile/check** — stdlib-only, fail-closed on missing/malformed/incomplete sidecar,
  rejects absolute/traversal source keys, recompile-and-byte-compare integrity gate; atomic writes.
- **Tracker merge-lease** — `flock`-serialized acquire, token-checked release, TTL expiry, fail-closed
  on corrupt sidecar; lease state isolated from the TRACKER.md blob.
- **Agent-instruction safety** — no changed instruction file disables checks, authorizes writes,
  alters output schema, or lowers severity; changes *strengthen* enforcement (test-genuineness floor).
- **Attribution/license hygiene** — verbatim MIT, per-file vendored headers on all 10 files,
  IDC-LOCAL banners, thorough ATTRIBUTIONS.md.

## Resolution

See the follow-on fix commits on this branch. Each Major and Minor finding above is resolved at root
cause (M1 + m1 together: portable paths *and* the lint fence that would have caught them; M2 + its
test gap together: the jq fix *and* an FS-backend legacy-compat regression). Nits n1/n2 are recorded
as accepted/deferred with rationale. Final gate: `bash tests/smoke/run-all.sh` (ALL GREEN) +
`bash scripts/lint-references.sh` (CLEAN), both shown in the merge record.
