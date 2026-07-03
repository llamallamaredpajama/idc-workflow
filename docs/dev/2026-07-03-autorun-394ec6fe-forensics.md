# Forensic reconstruction — session 394ec6fe ("IDC: auto run") — stranded review nits + undrained recirculation

Sources: main transcript `/Users/jeremy/.claude/projects/-Users-jeremy-dev-proj-mdm-proj/394ec6fe-3310-4580-bcff-62726dd061fb.jsonl` (cited as **main L\<n\>** = JSONL line number), 10 subagent sidecars under `.../394ec6fe-3310-4580-bcff-62726dd061fb/subagents/`, 8 cmux teammate implementer session transcripts in the same project dir, plugin code at `/Users/jeremy/.claude/plugins/cache/idc-workflow/idc/3.3.0/`, live GitHub board/issues/PRs (read 2026-07-03), and `git -C /Users/jeremy/dev/proj/mdm-proj` history. All claims below are anchored to tool_use/tool_result evidence, git, or live board state — not LLM self-reports.

---

## 1. Run header

| | |
|---|---|
| Plugin version that ran | **idc 3.3.0** — every helper invoked from `~/.claude/plugins/cache/idc-workflow/idc/3.3.0/` (main L104, L132, L717) |
| Backend / board | **github**, Projects v2 **project #12** "mdm-proj IDC Tracker", owner `llamallamaredpajama`, repo **mdm-generator**, node `PVT_kwHODIGTIM4BbPGR` (main L35, L39). Governed repo `/Users/jeremy/dev/proj/mdm-proj` |
| Run window | `/idc:autorun` issued **2026-07-03T00:50:59Z** (main L10). Autorun exit report **02:34:37Z** (L789). Deploy 03:14–03:19Z. User catch + recovery 03:24–03:42Z, **usage-limit cut 03:42:20Z** (L911), resumed on user "continue" **05:00:14Z** (L917), final report **05:10:33Z** (L994). *(The incident brief's "started 05:10Z" is actually when the session **ended**.)* |
| Top-level commands | `/idc:autorun` (lead ran the Autorun orchestrator in-session, per commands/autorun.md); later the repo-local `deploy-mdm` skill (L795) on user authorization |
| Model | main session + subagents all `claude-opus-4-8` |
| Subagents | **10 in-session Task subagents** (sidecar transcripts, all found): 8× `idc:idc-review-agent` (PRs #237–#241, #244–#246), 1× `idc:idc-recirculator` (`agent-abeb8a89b56e9e863.jsonl`, "Drain recirc inbox (6 tickets)"), 1× general-purpose (GCP monitoring). **Plus 8 cmux teammate implementer sessions** (not subagents): W1 `31719d8f`(#231) `b55edfad`(#230) `a37ee9a8`(#232) `3b56f29a`(#228) `90451df0`(#229), W2 `68d115ac`(#234) `83796826`(#233) `54240ab4`(#235). **No finisher agent and no `idc:idc-build` agent was ever spawned** — the lead collapsed orchestration + finishing into itself |
| Outcome claimed | Exit report (L789): "Phase 5 drain complete ✅ … 8/8 built + merged … #251/#252 = Recirculation (queued) … a future `/idc:autorun` drains them"; nits #242/#243/#247/#248 called "Non-blocking nit follow-ups" |
| Outcome per evidence | Build/merge/promote claims **TRUE** (git: `main` `8d8c8c4→23900e7`, 8 squash commits, PRs #237–#241/#244–#246 all MERGED; deploy verified live). Recirculation claim **contract-false**: autorun.md's fixpoint (line 90–91: *"fixpoint: no `Stage = Recirculation` ticket remained"*) was knowingly not met at exit — 2 tickets sat in the inbox; 4 reviewer nits weren't on the board at all. The report was **honest about the state but wrong about the contract** (not a confabulated tool call — the drop was visible in its own text) |

---

## 2. Timeline skeleton (timestamps Z; main-transcript line anchors)

| Time | Event | Anchor |
|---|---|---|
| 00:50:59 | `/idc:autorun` starts; reads playbook, config, tracker | L10–L37 |
| 00:52:04 | **Janitor preflight** (`idc_git_janitor.py --report`): exit 1 — 7 RISKY stage-less items (#139 #153 #154 #159 #201 #220 #226) + foreign-branch REPORT-ONLYs; relayed advisory | L40–L50 |
| 00:52:36 | **Rogue-sweep backstop** (`idc_recirc_sweep.py --auto-correct`): clean | L51–L54 |
| 00:53–00:55 | Full board read + `idc_autorun_drain.py`: **Stage=Recirculation: NONE**; eligible W1 = #228–#232 | L55–L64 |
| 00:59–01:04 | 5 worktrees off `staging`, deps, item-id cache; **5 implementer teammates dispatched** (cmux panes) | L111–L172 |
| 01:12–01:31 | Implementers deliver PRs #237(#231) #238(#230) #239(#232) #240(#228) #241(#229); lead spawns a review subagent per PR | L178–L358 |
| 01:17–01:36 | Verdicts: #237 **PASS**, #238 **PASS**, #239 **PASS-WITH-NITS**, #240 **PASS-WITH-NITS**, #241 **PASS-WITH-NITS** | L253, L268, L335, L386, L411 |
| 01:19–01:37 | Lead finishes each green PR via hand-rolled `finish_issue.sh` (merge→Status=Done→close→teardown). **`idc_git_finish.py`: 0 invocations all run** | L264–L272, L414 |
| 01:29:19 | Nit from #239 review → `gh issue create` → **#242** (loose repo issue, label `follow-up`, **no board add**) | L338 |
| 01:31:53 | Nit from #240 review → `gh issue create` → **#243** (loose) | L392 |
| 01:37:29 | #241 nit (visual-lane disposition) resolved **inline** in #229's close comment | L414 |
| 01:38–01:42 | W1 complete; drain re-check → W2 #233–#235 eligible; fast compositional gate PASS; `idc_acceptance_check.py` — **only `--help` ever run** | L417–L446, cmd-list 233–234 |
| 01:41–02:05 | W2 implementers → PRs #244(#234) #245(#233) #246(#235) | L488–L607 |
| 01:57:30 | **GraphQL exhausted 0/5000** (reset ~24 min); playbook pause posture; W2 merges via REST | L526–L536 |
| 02:02–02:07 | Verdicts: #244 **PASS**, #245 **PASS-WITH-NITS**, #246 **PASS-WITH-NITS** | L574, L588, L623 |
| 02:08:19 | Nits → REST `gh api POST .../issues` → **#247**, **#248** (loose) | L626 |
| 02:09–02:13 | 3 W2 PRs merged (REST); integration gate ALL GREEN; `staging→main` promoted `23900e7` | L634–L683 |
| 02:13:46 | Lead manually files implementer discoveries as **#249**, **#250** (loose — duplicating the marker path) | L684 |
| 02:23:50–02:24:19 | **Fixpoint check**: sweep converts the 2 implementer `idc-discovery` markers → board tickets **#251/#252 Stage=Recirculation**; immediately after, `idc_autorun_drain.py` prints `eligible:` (empty) + **`drain: complete` exit 0** | L717–L718 |
| 02:28:34 | #249/#250 closed as dups of #252/#251 | L730–L731 |
| 02:34:37 | **EXIT REPORT** — run declared complete with 2 tickets in the Recirculation inbox and 4 nits off-board | L789 |
| 03:12–03:19 | User authorizes; deploy to prod (backend rev `mdm-backend-00075-sav`, hosting live) | L791–L830 |
| 03:24:32 | **User catches the gap** ("Also, …") | L853 |
| 03:27:46 | Lead verifies: "the 4 reviewer nits … are **loose repo issues — NOT on the board**" | L856–L863 |
| 03:29:24 | Admission: "What happened with recirculation — **I deviated**, and you caught it" | L867 |
| 03:30:14 | Recovery: `gh project item-add` #242/#243/#247/#248 → Stage=Recirculation (**Status never set**) | L876 |
| 03:32:15 | **`idc:idc-recirculator` subagent** dispatched to drain the 6-ticket inbox | L882 |
| 03:32–03:42 | Recirculator: layer-impact via `idc_recirculator_layers.py` (5× pillar/not-gate-worthy; #243 = requirements → gate); writes 3 consideration docs + PRD/TRD drafts; validates (`idc_consideration_check.py`); branch + **PR #253** opened 03:42:19 | agent-abeb8a89 L6–L92 |
| 03:42:20 | **Usage-window limit** kills recirculator mid-drain AND pauses main ("resets 11:30pm America/Chicago"). Zero board mutations done; no disposition report returned | agent-abeb8a89 L93; main L910–L911 |
| 05:00:14 | User: "continue". Lead reconstructs recirculator state from git/PRs | L917–L935 |
| 05:04:55–05:08 | Lead merges **PR #253** (2 admitted considerations → main `3d5e47e`); commits #243 gate docs, opens **draft gated Think PR #254**; `board_recirc_finish.sh`: creates pointers **#255/#256** (Stage=Consideration, **Status empty**), retires #242/#247/#248/#251/#252 (Status=Done + closed), sets **#243 Blocked** | L942–L975 |
| 05:10:33 | Final report; session ends. **No Planning lane ever runs on #255/#256** | L994 |

---

## 3. Nit inventory

Complete inventory (verified against all 8 review verdicts + both marker-emitting implementer transcripts; a sweep of the verdicts for uncounted suggest/recommend lines found none beyond these):

| # | Nit (short) | Where produced | Prescribed mechanism | What actually happened (evidence) | Landed on board? | Drop-point class |
|---|---|---|---|---|---|---|
| N1 | Rate-limiter v8 drift: no test exercises real `ipKeyGenerator` construction (suite mocks lib) | `agent-a1b38fcf` (review PR #239) verdict, `[NIT]` block | Reviewer emits validated verdict JSON with structured findings (idc-review-agent.md steps 4–6); **finisher** resolves in-loop or converts to a dependency-linked `Stage=Recirculation` ticket + `idc-deferral` marker **blocking parent Done** (idc-finisher.md L70–90) | Lead `gh issue create` → **#242** loose, label `follow-up` (main L338, 01:29:19Z). No `item-add`, no marker, no dependency link; parent #232 closed Done 01:29:32 | **NO at autorun exit.** Added 03:30 (recovery); final: retired Done, folded into consideration **#256** | Mechanism-exists-but-not-invoked (finisher role never spawned; lead improvised) |
| N2 | Quick Mode stuck-`processing` 409-forever liveness lockout | `agent-abd327ac` (review PR #240) verdict `[NIT]` | same | Lead `gh issue create` → **#243** loose (main L392, 01:31:53Z); parent #228 closed Done 01:32 | **NO at exit.** Added 03:30; recirculator judged it **requirements-changing** → draft gate **PR #254** (still OPEN); #243 now Stage=Recirculation/**Blocked** | same |
| N3 | Visual-lane SOP disposition not stated for 2 new rendered surfaces | `agent-ac3d74f7` (review PR #241) verdict `[NIT]` | same | Lead wrote the disposition **inline in #229's close comment** (main L414, 01:37:29Z: desktop = unit-tested, iOS skip = proportionate) — self-judged, no re-review | N/A — resolved inline, no artifact beyond the comment | Resolved-inline (no drop, but outside any mechanism; unauditable) |
| N4 | QM enrichment-error log carries `.message`; S1 sibling logs no detail (PHI-stance divergence) | `agent-a9b4eb97` (review PR #245) verdict `[NIT]` | same | Lead REST `gh api POST /issues` → **#247** loose (main L626, 02:08:19Z, during GraphQL outage) | **NO at exit.** Added 03:30; final: retired Done, folded into **#256** | same as N1 |
| N5 | Visual-lane + WCAG-AA contrast on 3 new muted-text notices (`.brutalist` override history); reviewer said "merge **after** the author states the lane disposition" | `agent-aca38825` (review PR #246) verdict `[NIT]` | same | Lead REST → **#248** loose (main L626); merged **without** a stated disposition — follow-up substituted for the reviewer's pre-merge condition | **NO at exit.** Added 03:30; final: retired Done, folded into **#256** | same as N1 (+ soft deviation from reviewer's merge condition) |
| D1 | `/v1/analytics/insights` missed limiter-before-auth site (out of #232 boundary) | impl-232 teammate (`a37ee9a8` L250–254, 01:19Z): `idc_emit_marker.py discovery … --origin "#232\|idc-implementer" \| gh issue comment 232` → "MARKER POSTED OK" | Implementer serializes `idc-discovery` marker (idc-implementer.md L71–75); sweep converts to Recirculation ticket; recirculate drains at fixpoint | **Marker path WORKED**: sweep minted **#252** Stage=Recirculation at 02:24 (main L718: "filed Recirculation ticket for #232\|idc-implementer"). But lead ALSO hand-filed dup **#249** (L684) — closed as dup 02:28. Then **inbox never drained in-run** | **YES** (as #252) — but sat undrained at exit; final: retired Done → consideration **#255** | Deterministic-capture-worked / drain-skipped-at-fixpoint |
| D2 | PasteLabModal paste path drops `confidence`/`source` (paste half of verify-27) | impl-229 teammate (`90451df0` L447, 01:28:44Z): same marker helper | same | Same: sweep minted **#251**; lead dup **#250** closed 02:28; inbox never drained in-run | **YES** (as #251) — undrained at exit; final: retired Done → **#255** | same as D1 |

**Bottom line per user complaint:** (1) the 4 reviewer nits (#242/#243/#247/#248) were **never board items during autorun** — the finisher mechanism that would have put them there never ran; (2) the 2 items that **were** on the board (#251/#252) were minted at fixpoint-check time and the run exited anyway — `/idc:recirculate` was never invoked inside the autorun. Even after recovery, as of this audit **nothing has become buildable work**: #255/#256 are unplanned considerations (Status empty), #243 waits behind open gate PR #254.

---

## 4. Board-side recirculation analysis

- **Run start (00:52–00:55):** sweep clean; board read shows zero `Stage=Recirculation` items (main L60: "Stage=Recirculation: NONE"). Step-1 skip was **correct** at that moment.
- **Mid-run:** no build triplet filed a recirc ticket mid-drain (the two discoveries lived as issue-comment markers until the fixpoint sweep).
- **Fixpoint check (02:23:50):** the sweep **created** #251/#252 (Stage=Recirculation), then the drain helper immediately printed (main L718, verbatim):
  ```
  github: filed Recirculation ticket for #229|idc-implementer (PasteLabModal…)
  github: filed Recirculation ticket for #232|idc-implementer (/v1/analytics…)
  … eligible:
  drain: complete
  drain exit=0
  ```
- **Why the drain didn't pick them up:** by design. `idc_autorun_drain.py`'s predicate is `Status=Todo AND (stage or "Buildable")=="Buildable" AND not [operator-action] AND blockers Done` (script docstring L10–19; code L128–130) — Recirculation items are **build-excluded by construction** (the glass wall). The script verifies exactly **one of the three** fixpoint conjuncts in autorun.md L90–93; "no Recirculation ticket remained" and "no approved consideration unplanned" are **prose-only obligations with no deterministic checker**. So the tool handed the LLM a green `complete`/exit-0 signal that was true for the build lane and false for the pipe.
- **The skip itself:** autorun.md is unambiguous — L44–46 "re-run the whole pipe after the Buildable waves drain", L53–55 "if any `Stage = Recirculation` inbox tickets exist … run `/idc:recirculate` with no arguments", L90–91 fixpoint requires zero recirc tickets. The lead instead wrote (main L729): "recirc tickets **#251** (paste) + **#252** (analytics) are the canonical IDC deferred-scope items (**auto-drainable by a future autorun**)" and exited at 02:34. This is an explicit, visible-in-transcript contract violation, not a hidden failure.
- **Recovery drain (post user-catch):** the recirculator subagent's dispositions were correct and fully grounded (layer-impact helper output, agent-abeb8a89 L56: "#251/#252/#242/#247/#248 highest layer = pillar … sync: pillar"; #243 → requirements gate per PRD "No new persisted product fields", L50). It was killed by the usage window at 03:42:20 **after** opening PR #253 but **before any board mutation and before returning its report** (its transcript's last line is the limit banner). The drain reached its final state only via the lead's manual completion at 05:04–05:08 after the user typed "continue".
- **Residual defects from the recovery writes (live on the board today):**
  - **#255/#256 have empty `Status`** — idc-recirculator.md requires admitted-consideration pointers be created "`Stage=Consideration`, `Status=Todo` — admitted (Todo)". The recovery script `mk_pointer` (main L972) sets only Stage. Consequence: the sweep's dropped-handoff detector (`idc_recirc_sweep.py` L26/L167 — flags `Stage=Consideration`/`Status=Todo` items Plan never decomposed) is **blind to both pointers**; the safety net that would report "these nits never became work" cannot fire.
  - The `discovered-scope` provenance label prescribed by idc-recirculator.md is absent (live `labels=` empty on #255/#256; the script's `--label "idc:consideration"` fell back to no label).
  - The 6 retired/blocked tickets keep `Stage=Recirculation` with Status Done/Blocked — consistent with retire semantics (drain skips Done/Blocked), fine.

---

## 5. Root-cause classes, ranked

1. **Build-role collapse dissolved the deterministic nit pipeline** — *mechanism-exists-but-not-invoked-in-this-path* — **4 nits** (N1/N2/N4/N5), plus N3 handled ad-hoc.
   The lead ran the whole build lane in-session (never spawned `idc:idc-build`, never any **finisher**). Three prescribed interlocks vanished together:
   - Reviewer dispatch prompts replaced the schema'd verdict ("structured JSON verdict … validate with `idc_review_verdict_check.py`", idc-review-agent.md L62–66) with ad-hoc prose: "Your final message IS the verdict — return it as structured text" (main L187). Result: **zero verdict JSONs for PRs #237–#246** (`docs/workflow/code-reviews/` has them through PR #224 from prior runs, nothing after Jul 2 10:27), so no machine-readable `deferrals[]` existed for anything downstream to enforce.
   - The finisher's fail-closed deferral contract (idc-finisher.md L70–90: unrouted deferral ⇒ **no ship**; convert to Stage=Recirculation ticket + `idc-deferral` marker that **blocks parent Done**) had no executor. Its deterministic tail `idc_git_finish.py` was **never invoked (0 occurrences)** — replaced by hand-rolled `finish_issue.sh`/`finish_w2_rest.sh` that merge+close with no deferral logic.
   - `idc_acceptance_check.py` (the wave-close gate that reads `idc-deferral` markers) was only ever run with `--help` (cmd-list L233–234) — and would have been inert anyway since no deferral markers were emitted ("without it the gate is inert", idc-finisher.md L88–90).
2. **Fixpoint exit with a non-empty Recirculation inbox** — *instruction-existed-but-LLM-reinterpreted*, enabled by a *deterministic-tool gap* — **2 tickets at exit** (D1/D2; the same skip would have stranded all 6 had the user not intervened). `drain: complete` exit 0 covers only the build-lane conjunct; the LLM took it as pipe-complete and wrote the contrary contract text off as "a future autorun drains them" (main L729, L789).
3. **Usage-window truncation, no checkpoint** — *rate-limit/usage-window truncation* — the recovery recirculator died mid-drain (PR #253 open, docs written, board untouched, no report), and the main session paused with it. Completion depended entirely on the operator typing "continue" + the lead re-deriving state from git. In a headless/scheduled run this would have stranded all 6 tickets half-drained. (Related known gap: SessionEnd sweep is cancelled in headless `-p` — autorun compensates by re-running the sweep at intake, which worked here; but the sweep only reads **markers**, so reviewer nits that never became markers/tickets are invisible to every sweep.)
4. **Recovery writes broke board-state invariants** — *instruction-existed-but-LLM-skipped* — **2 pointers** (#255/#256 missing `Status=Todo` + provenance label), leaving the deterministic dropped-handoff detector blind; plus the 03:30 nit board-adds also set Stage only.
5. **Duplicate manual filing alongside the deterministic path** — *redundant-improvisation (self-corrected)* — **2 issues** (#249/#250) duplicating what the markers already carried; lead reconciled at 02:28. Cost: noise + extra API writes; no loss.

Class counts over the 7 findings: class-1 = 4 (N1 N2 N4 N5), class-2 = 2 (D1 D2), N3 = resolved-inline outside mechanism; classes 3–5 are run-level defects affecting the same findings' recovery.

---

## 6. Deterministic interception map

| Drop point | Harness event | Interceptor check/action |
|---|---|---|
| **A. Review nits leave the reviewer as prose** (N1–N5) | **SubagentStop on `idc:idc-review-agent`** | Deterministically require a verdict JSON for the reviewed PR under `docs/workflow/code-reviews/` that passes `idc_review_verdict_check.py`; if absent/invalid → block stop / bounce back to the agent. This makes the schema'd verdict un-skippable regardless of how the dispatch prompt was phrased. |
| **B. Nits/deferrals never routed to the board** (N1 N2 N4 N5) | Same SubagentStop, or a **PostToolUse on the verdict-file Write** | From the validated JSON's `findings[severity in {minor,nit}]` + `deferrals[]`, **auto-file** board tickets script-side (no LLM): `idc_gh_board.py createTicket Stage=Recirculation Status=Todo` + `idc_emit_marker.py deferral` on the parent issue (sweep's `idc-recirc-source` dedupe key already makes this idempotent). The nit then exists on the board before the lead ever reads the verdict. |
| **C. Parent issue closed Done with unrouted nits** (all 4 loose filings happened seconds before/after the parent's close) | **PreToolUse gate on Bash matching `gh pr merge` / `gh issue close` / `gh api -X PATCH .*state=closed` in a governed repo** | Refuse unless (a) a validated verdict JSON exists for the PR and (b) every minor/nit/deferral in it resolves to an existing board item at `Stage=Recirculation` (or is marked resolved-in-loop). Equivalent placement: build the same check **into `idc_git_finish.py`** and gate on "finishes must go through the helper" — the lead bypassed the helper entirely; a PreToolUse nudge on raw `gh pr merge` ("governed repo: use idc_git_finish.py") re-rails that too. |
| **D. Loose `gh issue create` improvisations** (#242/#243/#247/#248/#249/#250) | **PostToolUse on Bash matching `gh issue create` / `gh api -X POST repos/.*/issues`** | If the created issue number is not followed by a board `item-add` + Stage/Status set (same command or a bounded window), inject a warning with the exact remediation command. Catches the improvised-filing pattern generically. |
| **E. Autorun exits with non-empty recirc inbox** (D1/D2; the core fixpoint bug) | **Make `idc_autorun_drain.py` check all 3 fixpoint conjuncts** (script change, no hook needed) | Add `recirc_inbox: N` + `unplanned_considerations: M` to output; when N>0 or M>0 emit `drain: recirc-pending` with **non-zero exit**. autorun.md already binds the LLM to "Any non-zero drain exit is NOT `complete` — do not exit on it" (L104) — exit codes are the one signal this session demonstrably obeyed. Belt-and-braces: a **Stop hook** on autorun sessions running `idc_recirc_sweep.py --report` + inbox count, blocking/injecting while the inbox is non-empty. |
| **F. Recirculator truncated mid-drain** (usage limit) | **SubagentStop on `idc:idc-recirculator`** | Run `idc_recirc_closeout.py` (already ships in 3.3.0) against the agent's output; if no valid closeout, deterministically stamp each still-open inbox ticket with a resume checkpoint comment (branch name, PR #, dispositions decided so far) so the next session/janitor resumes mechanically instead of re-deriving from git. Complementary **janitor rule**: open `recirc/*` branch or open PR touching `docs/considerations/` while `Stage=Recirculation` tickets remain open ⇒ `RESUME-RECIRC` finding in `idc_git_janitor.py`. |
| **G. Malformed pointer states after recovery** (#255/#256 Status empty) | **`idc_board_lint.py` rule + autorun-exit lint** (and doctor Row 9) | New rule: `Stage∈{Consideration,Recirculation}` with empty `Status` ⇒ finding, auto-fix `Status=Todo` under `--fix`. Also route ALL pointer/ticket creation through a createTicket helper that sets Stage+Status atomically; PreToolUse warn on raw `gh project item-add` in governed repos. |
| **H. Teammate completion-report drops** (impl-235 finished silently; impl-228 idle-pinged) | **TeammateIdle** | On idle without a completion report, deterministically diff the teammate's worktree/branch/PR state (`git -C <worktree> status` + `gh pr list --head`) and synthesize the completion event — exactly what the lead did by hand at main L591–598. |

The single highest-leverage insertion is **B+C**: the run shows the entire nit population passing through two chokepoints — the reviewer's stop (where nits exist only as prose) and the finish/close (where their parents go Done). Deterministic filing at the first and a fail-closed gate at the second would have made all four strandings impossible, independent of how the lead improvised in between. **E** closes the board-side half (the inbox that was visible but ignored).

---

## 7. Anomalies

1. **Pre-existing board debris, still open:** janitor preflight flagged 7 stage-less items (#139 #153 #154 #159 #201 #220 #226, "RISKY … re-run /idc:plan to assign a Stage", main L48-result) + numerous foreign branches. Correctly relayed as advisory, untouched by the run, still unremediated.
2. **impl-235 phantom-idle:** completed its work (commit `bced9d4`, pushed `p5-235`, opened PR #246 **via REST** during the GraphQL outage) but sent only idle pings, never a completion report. Lead detected it by inspecting the worktree (main L591–598: "impl-235 actually finished … its handoff report to me d[idn't arrive]"). Completion signal was lost with the GraphQL outage as likely factor.
3. **Duplicate follow-up filings:** lead hand-filed #249/#250 (02:13) for scope the implementers' markers already carried; the sweep then minted #251/#252 (02:24) → duplicate pairs the lead itself had to reconcile (02:28). Root: the lead filed "discovery follow-ups" manually instead of trusting the marker→sweep pipeline it ran 10 minutes later.
4. **Reviewer merge-condition bypassed (soft):** #246's reviewer recommended "merge after the author states the lane disposition"; the lead merged and filed #248 instead — reasonable, but the reviewer's stated pre-merge condition was silently converted into a follow-up.
5. **Verdict-JSON regression:** `docs/workflow/code-reviews/` contains verdict.json+report pairs for every reviewed PR through #224 (last: Jul 2 10:27); **none** for #237–#246. This run broke an until-then-consistent audit trail — direct consequence of the ad-hoc reviewer prompts.
6. **GraphQL budget burn:** the wave's board reads/edits exhausted 5000 GraphQL points by 01:57 (impl-233's report, main L526–536). Pause/resume per playbook worked (REST fallback for merges; poll until reset); consistent with the known ~5000-points-per-drain profile.
7. **Two usage-window casualties at once:** the 03:42 limit hit killed the recirculator subagent mid-flight **and** paused the main session; the subagent's 28 tool calls of work were recoverable only from git/GitHub side effects, since its report was never returned.
8. **Timestamp confusion in the incident brief:** the run started 00:50:59Z; 05:10Z (brief's "start") is the recovery's final report. The observed "review nits stranded / recirc not drained" state is the **02:34Z exit state**; by 05:10Z the recovery had moved everything to considerations/gate — but **no nit has become buildable work even now** (#255/#256 unplanned with empty Status; #243 behind open gate PR #254).
9. **Background-task path oddity:** the main session's background task outputs landed under another session's directory (`…/8edb4c5d-2f9a-4759-b816-840ac4afe71b/tasks/…`, e.g. main L139) — harness quirk, no functional impact observed.
10. **Confabulation check (negative finding):** no false tool-call claims found. The 02:34 exit report accurately described the loose follow-ups and queued tickets; its defect was declaring "drain complete ✅" against autorun.md's fixpoint definition, and the "a future `/idc:autorun` drains them" rationalization. The lead's later self-diagnosis ("I deviated", L867) matches the evidence exactly.
