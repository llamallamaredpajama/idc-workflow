# Part 4a — sandbox e2e receipt (/idc:init after V-DOOR)

**Driver:** direct `codex exec --cd /Users/jeremy/dev/sandbox/ke-idc-test-repo-install
--dangerously-bypass-approvals-and-sandbox` per this repo's CLAUDE.md (never a nested claude, never the
codex-companion `task` wrapper). **Plugin under test:** `PLUGIN_ROOT=/Users/jeremy/dev/proj/idc-workflow-p4a`
@ `8827546`. **Capture:** `_idc-observability/run-part4a-init.txt` (452 KB).

**Setup:** the install sandbox was reset to its PRE-INIT commit `0e861526` (reversibly — restore point
`fbfd107f`, and the two untracked files preserved in the scratchpad) so init ran against a genuinely ungoverned
repo. **Backend: `filesystem`, chosen deliberately** — it avoids creating or churning a shared GitHub Projects
board, and the change under test (init's self-mint inside `idc_command_contract.py start`) is backend-independent
because `_path_gate_applies` keys on governed-repo + git-worktree, not on backend or pathway mode.

## What the receipt PROVES

**(A) Init scaffolded a governed repo.** WORKFLOW.md, WORKFLOW-config.yaml, docs/workflow/tracker-config.yaml,
TRACKER.md, the docs/workflow tree and the install receipt were all created.

**(B) The authorization was minted internally.** The Path Gate authorization carries
`"allowed_actions": ["write","edit","git"]` over `"allowed_paths": ["."]` — the fixed default profile — with no
public `authorize` call anywhere in the run.

**(C) The public door is gone.** Verbatim from the run:

    usage: idc_path_gate.py [-h] {auth-path,evaluate} ...
    idc_path_gate.py: error: argument op: invalid choice: 'authorize'
      (choose from 'auth-path', 'evaluate')

**(D) Doctor ran: `IDC doctor: 10 passed, 0 failed, 0 skipped`** — but see defect 3, which makes that PASS
weaker than it looks.

## What the receipt FOUND — four defects, none caused by V-DOOR, all real

**1. A filesystem-backend scaffold ships an unrendered template token.** VERIFIED INDEPENDENTLY by the lead:
`docs/workflow/tracker-config.yaml:27` reads `project_number: "{{TRACKER_PROJECT_NUMBER}}"` while `:26` reads
`backend: filesystem`. CI's template smoke-render step substitutes that token unconditionally, so CI cannot
catch it — the gap only appears on the backend where there IS no project number. A governed repo carries a
placeholder, and it becomes a bogus value if the operator later switches to the github backend.
**Owner: Part 4a (it owns `commands/init.md`). Folding into its fix round.**

**2. The shipped closeout instruction is incomplete, so a non-Claude runtime cannot finish the lifecycle.**
Init's closeout was rejected: `idc-command-contract: rejected closeout [bad-schema-version]:
evidence.schema_version must be the integer 1, got None`. The playbook text states only `Evidence refs: refs:{}`
and never says the envelope must also carry integer `schema_version: 1`. Doctor's closeout failed identically.
**Caveat, stated honestly:** in a real Claude session the hook injects this envelope, so this bites the runtimes
that hand-construct it — Codex and Pi — which the plugin claims to support. It is a documentation defect for
those runtimes, not proof that Claude's path is broken.

**3. A diagnostic command mutates governed state while claiming not to.** `commands/doctor.md:7` says its checks
"are **read-only for source files and tracker/board state**", yet the run's Row 10 created
`docs/workflow/reconciliation-seen-findings.json` — VERIFIED INDEPENDENTLY (43 bytes, present in the sandbox
after the run). That is a durable governed-repo ledger, not the "transient" writes the header carves out. It is
the same claim-outruns-code class this effort keeps finding, in operator-facing text.
**Pre-existing** (the file was already untracked in the sandbox before this run) and **outside the current
units' ownership** — the write happens in the janitor's seen-ledger path
(`scripts/idc_reconciliation_baseline.py::record_seen_findings`, wired at `scripts/idc_git_janitor.py`), which
belongs to a branch already at its final fix round. **Filed as a named follow-up rather than crammed into a
capped round.**

**4. Doctor's PASS does not establish what it appears to.** The run notes doctor does not reject the unrendered
`{{TRACKER_PROJECT_NUMBER}}` for a filesystem backend — so `10 passed` coexists with defect 1.

## Guardrails held

No PR opened, no issue created, no board mutation, nothing pushed. The run also declined to work around a
blocked `rm -f`, reporting it and using `unlink` instead, and declined to retry closeout with an invented
`schema_version` — preserving both lifecycle records in their failed state rather than manufacturing a pass.

## HOOK-FIDELITY CAVEAT (must accompany any citation of this receipt)

Claude Code hooks do NOT fire inside a Codex process. The run had to hand-start doctor's lifecycle record
because the loader that normally injects it was absent. So this receipt proves the *playbook* and the *scripts*
behave correctly end to end; it does not exercise the Claude hook spine. Defect 2 in particular is a direct
consequence of that boundary and must not be reported as "closeout is broken" without that qualifier.

## Restore

The sandbox is left GOVERNED (filesystem backend) from this run. Restore point for its prior controlled/github
state: `git -C /Users/jeremy/dev/sandbox/ke-idc-test-repo-install reset --hard fbfd107f`, plus the two untracked
files preserved at `<scratchpad>/sandbox-restore/`.
