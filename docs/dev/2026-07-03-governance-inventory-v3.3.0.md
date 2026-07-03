# IDC v3.3.0 — Workflow-Governance Inventory (Explore-agent result, 2026-07-03)

## Headline

Exactly ONE harness-automatic enforcement point exists in the whole plugin: the `SessionEnd` hook
(`hooks/hooks.json:4-11` → `idc_recirc_sweep_hook.sh` → `idc_recirc_sweep.py --auto-correct`),
and it is cancelled in headless `-p` runs — the exact mode autorun/loop uses. Everything else is
PROMPT+SCRIPT (~27 points: deterministic helper, voluntary invocation) or PROMPT-ONLY (~31 points:
pure prose).

**The asymmetry that explains the symptoms:** deterministic helpers cluster on READS, VALIDATIONS,
and the terminal FINISH TAIL (`idc_git_finish.py`, `idc_gh_close.py`, `idc_*_check.py`). The
mid-pipeline WRITE-side state transitions — pointer advances, recirc-ticket filing, provenance
preservation, paused-origin re-linking, nit/finding filing, gate unblocking — are almost all
PROMPT-ONLY. Nits strand because no helper FILES them; recirculation fails because no helper
PERFORMS admit/retire/re-link (validators only check closeouts that presuppose the LLM already did
the work).

## Enforcement-class counts

| Class | Count | Notes |
|---|---|---|
| HOOK | 1 | SessionEnd sweep (fail-soft, exits 0 always; off in headless) |
| PROMPT+SCRIPT | ~27 | schema/matrix/acceptance/provenance/closeout/caps/drain/janitor/finish/close/verdict/marker/layers/stage-options/board-read |
| PROMPT-ONLY | ~31 | all mid-pipeline board writes + gate open/unblock + claim + PR open + automerge + merge-lease (gh) + staging promotion |
| SCRIPT (pure predicates) | 4 | drain eligibility; janitor SAFE-FIX allowlist; trivial-grant path list; provenance-regime activation |

## Top-10 most fragile PROMPT-ONLY points (ranked by fit to the two symptoms)

1. **Re-link paused origins in Plan Phase 4** — `agents/idc-plan.md:78-83` (+ `skills/idc-matrix-analysis/SKILL.md:94-98`). Skipped → premature-eligibility / infinite-recirc trap (issue eligible behind a Done recirc ticket). `idc_board_lint.py` detects only in doctor, advisory.
2. **Provenance-preservation trio on recirc admit** — `agents/idc-recirculator.md:57-64` (label + origin line + closing comment + paused-origin link). Garbled → Plan can't find origin to re-point → recirculation silently fails downstream.
3. **Out-of-boundary scope MUST be filed as `Stage=Recirculation` five-field ticket** — `agents/idc-implementer.md:81-97`, `idc-finisher.md:74-78`, `idc-build.md:265-272`. Unstaged item defaults to Buildable (scooped unreviewed) or discovery is lost. SessionEnd backstop off in headless.
4. **Finisher drives ALL findings incl. side issues to green before merge** — `agents/idc-finisher.md:52,94-99`. Nothing blocks merge on unactioned minor/nit once verdict is PASS-WITH-NITS. → the direct "stranded review nits" cause. Verdict validator checks SHAPE, not RESOLUTION.
5. **Phase-close delta-review findings filed as new board issues** — `agents/idc-build.md:247-258`, `skills/idc-review-engine (SKILL):24-26`. LLM summarizes instead of filing → phase-close nits strand with no artifact.
6. **Gate-admission detection → remove blocks-link + `setField Status=Todo`** — `skills/idc-gate-issue/SKILL.md:83-86`. Skipped → admitted work Blocked forever; misfired → builds against draft.
7. **Enumerate + drain the `Stage=Recirculation` inbox** — `commands/recirculate.md:20-26`, `agents/idc-recirculator.md:24-32`, `commands/autorun.md:54-61`. LLM loop over a query; early exit → tickets sit undrained; autorun's fixpoint predicate only measures the BUILD lane so it never notices.
8. **Recirc-consultant spawn + handoff BEFORE the fail-closed validator** — `agents/idc-build.md:87-152`. `idc_recirc_closeout.py` fail-closed but only guards a closeout that EXISTS (documented b985c1e7 failure: tickets filed and abandoned).
9. **`blocks_goal:true` deferral → dependency-linked ticket blocking parent Done** — `agents/idc-finisher.md:74-78`. Marker mechanized; ticket creation + blocks-link is prose. Skipped → Done-but-inert ships; acceptance gate can't catch (enabler doesn't exist).
10. **Consideration pointer advance/retire** — `agents/idc-plan.md:110-111`, `agents/idc-recirculator.md:55`. Missed advance = dropped larger-loop handoff; missed retire = inbox-drain idempotency broken (re-drains every pass).

## Hooks registered

- SessionEnd (only one): `hooks/hooks.json:4-11` → `idc_recirc_sweep_hook.sh` (early-exit 0 if no `docs/workflow/tracker-config.yaml`; fail-soft always-0) → `idc_recirc_sweep.py --repo "$PWD" --auto-correct`.
- NO PreToolUse/PostToolUse/Stop/SubagentStop/UserPromptSubmit/SessionStart/Notification hooks anywhere.
- Known limitation (in-source): cancelled in headless `-p`; won't fire on SIGKILL (`commands/autorun.md:50-51`, `commands/doctor.md:250-251`). Backstops (autorun preflight, doctor Row 9b) re-run the same detective. NOTE: inventory internally inconsistent on whether autorun preflight runs `--auto-correct` or `--report` — VERIFY during synthesis (autorun.md:48-53 vs section-3 note).

## Scripts inventory (runtime governance helpers)

idc_recirc_sweep.py (rogue-Buildable detective; HOOK + preflight/doctor) · idc_autorun_drain.py (eligibility predicate + --width) · idc_acceptance_check.py (Done-but-inert detector) · idc_git_janitor.py (board↔git reconciler, 4-tier verdict) · idc_git_finish.py (deterministic finish tail RC1/2/3) · idc_gh_close.py (atomic verified close) · idc_gh_board.py (paginating board reader + --emit-idmap) · idc_recirc_closeout.py (fail-closed closeout validator) · idc_recirc_caps.py (runaway PARK/CONTINUE) · idc_board_lint.py (advisory lane lint incl. retired-recirc trap) · idc_provenance_check.py (Plan DET-VERIFY, exit 2 halts) · idc_schema_check.py (issue-body contract) · idc_matrix_check.py + idc_dag.py (matrix/DAG) · idc_review_verdict_check.py (verdict shape, 0.8 floor, ladder) · idc_emit_marker.py (discovery/deferral markers) · idc_recirculator_layers.py (sync set + gate decision) · idc_consideration_check.py · idc_tracker_fs.py (fs backend + merge lease) · idc_stage_options.py (non-destructive Stage append) · idc_receipt_check.py · idc_settings_json.py · idc_plugin_freshness.py (exit 4 stale guard) · idc_brownfield_scan.py · idc_template_for.py · idc_config_keys.py · idc_governance_compile.py / idc_governance_check.py (pi-only sidecar) · idc_release_check.py (CI only).
Shell: idc_recirc_sweep_hook.sh (the hook) · idc_init_scaffold.sh · install-codex.sh · install-pi.sh · lint-references.sh · materialize-sandbox.sh · run-evals.sh.

## State-file / marker formats (existing deterministic substrate to build on)

- Filesystem board: TRACKER.md fenced JSON between `<!-- idc-tracker-state:begin/end -->`.
- GitHub board: Projects v2, 5 single-selects + native blocked-by + attempt:<n> label.
- Item-id cache: `NUM\titem_id` at `$IDC_ITEMID_CACHE` (per-wave).
- Provenance marker: `<!-- idc-provenance: {"matrix":…,"pillar":…} -->`.
- Deferral marker: `<!-- idc-deferral: {"kind","what","blocks_goal",…} -->`; Discovery marker: `<!-- idc-discovery: {...} -->` (both via idc_emit_marker.py).
- Recirc ticket body: 5 fields (Discovered/Area/Suggested-scope/Provenance/PRD-TRD-impact).
- Recirc closeout JSON: `{ticket, outcome, provenance, recirc_count, cascade_depth,…}` (idc_recirc_closeout.py fail-closed).
- Review verdict JSON: `{verdict, findings[{dimension,severity,confidence≥0.8,evidence,attack,unblock,fingerprint}], deferrals[]}`.
- Phase matrix YAML: `docs/workflow/pillar-matrices/<tag>-matrix.yaml`.
- Goal-contract issue: 7 labelled elements + Dependencies/Trace footer.
- Install receipt: `docs/workflow/install-receipt.yaml` (sha256 manifest, stamped|customized).
- Pi-only governance sidecar: `docs/workflow/idc-governance-contract.yaml` (source_hashes).
- Config gates: `WORKFLOW-config.yaml` (gating.prd/trd, staffing_gate_threshold, janitor knob); tracker-config.yaml (backend, project_number, field_ids).

## Misc

- Doc drift: `commands/janitor.md:10,17` + `agents/idc-finisher.md` cite `WORKFLOW.md §A`, but shipped `templates/WORKFLOW.md` ends at §7 — dangling contract anchor.
- Merge lease: filesystem backend has real CAS (`idc_tracker_fs.py lease-*`); github backend has NO native CAS (interim single-holder rule, prose).
