# `/idc:ask` + `idc-navigator` Implementation Plan

> **For agentic workers:** implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.
> Part B ships and merges to `main` BEFORE Part C starts. Part C depends on `/idc:ask` existing.

**Goal:** Give IDC a plain-language front door (`/idc:ask <what you want>`) that routes the operator
to the right governed command, and a standing skill + per-repo instruction block so an agent in a
governed repo behaves like an IDC expert instead of wandering off-pipeline.

**Architecture:** Two parts, sequential.
**Part B** adds `ask` as a real 14th command, registered read-only in the Path Gate. A deterministic
resolver (`scripts/idc_ask_resolve.py`) runs inside the existing `UserPromptExpansion` command entry
gate. On a confident resolution the gate opens the lifecycle record and mints the Path Gate
authorization **for the resolved target command** (recording `--source ask`) and injects that
command's playbook plus a mandatory one-line confirm. On an unconfident resolution it opens an `ask`
record — which can never write anything — and injects an advisory playbook.
**Part C** adds a read-only `idc:idc-navigator` skill and a marker-delimited instruction block that
`/idc:init` writes into the governed repo's `CLAUDE.md` and `AGENTS.md`, `/idc:update` backfills,
`/idc:uninstall` removes, and `/idc:doctor` checks.

**Tech stack:** Python 3 (stdlib only — the repo's python3 is ambient and ranges 3.9–3.14, so **no
3.10+ syntax**: no `match`, no `X | Y` in runtime-evaluated annotations without
`from __future__ import annotations`), bash smoke tests, markdown command/skill surfaces.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **`bash scripts/lint-references.sh` MUST exit 0 before every commit.** No exceptions.
- **`bash tests/smoke/run-all.sh` MUST pass before any PR is marked ready.**
- **Namespacing:** reference skills/agents/commands as `idc:<name>` (e.g. `idc:idc-navigator`).
  Files are flat `idc-<thing>`; the harness adds the `idc:` prefix. A bare `idc-navigator`
  reference in shipped body text is a lint failure (Rule G).
- **`${CLAUDE_PLUGIN_ROOT}` is NOT a shell env var.** It text-substitutes inside command/agent/skill
  *markdown* only. A script needing the root takes it as an argument.
- **No personal paths** in `commands/ agents/ skills/ templates/ scripts/` — portable tokens only
  (`${CLAUDE_PLUGIN_ROOT}/…`, `<repo-root>/…`, `$HOME`). Never `/Users/<name>/…`.
- **Python floor:** target 3.9. Use `from __future__ import annotations` in every new script.
- **Commit and push after every task.** Long autonomous runs die on API connection drops; unpushed
  work is lost work. Never amend a pushed commit — add a new one.
- **Red-when-broken is required.** A new guard is not trusted until you have *shown it fail* when the
  thing it guards is broken. Every task that adds a test includes an explicit break-it/see-red/
  restore step, and the PR body quotes the red output.
- **Version bump in lockstep:** `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
  must carry the same version, plus a `CHANGELOG.md` entry. Current: `6.2.0`.
  Part B ships `6.3.0`. Part C ships `6.4.0`.

---

## File Structure

**Part B — created**
| Path | Responsibility |
|------|----------------|
| `scripts/idc_ask_resolve.py` | Deterministic intent resolver. Pure decision function + CLI. No writes, no mutations. |
| `commands/ask.md` | The advisory playbook (the unconfident path only). |
| `tests/smoke/phase13-ask-resolver.sh` | Resolver decision-table coverage. |
| `tests/smoke/phase13-ask-registration.sh` | `ask` is registered everywhere and is read-only. |
| `tests/smoke/phase13-ask-entry-gate.sh` | Entry gate routing/advisory behaviour with synthetic payloads. |

**Part B — modified**
| Path | Change |
|------|--------|
| `scripts/idc_command_contract.py:85` | `COMMANDS` gains `"ask"`. |
| `scripts/idc_command_contract.py` (`_CLAIM_TABLE`, ~:3476) | new `"ask"` entry. |
| `scripts/idc_path_gate.py:70` | `READ_ONLY_COMMANDS` gains `"ask"`. |
| `hooks/hooks.json:83` | `UserPromptExpansion` matcher regex gains `ask`. |
| `scripts/hooks/idc_command_entry_gate.py` | `RECOVERY_COMMANDS`, `AUTH_REQUIRED_COMMANDS`, `BASELINE_ALLOWED_COMMANDS`; new resolve-and-retarget step. |
| `templates/WORKFLOW.md` | 13 → 14 surfaces; document `/idc:ask`. |
| `tests/smoke/run-all.sh` | register the three new phase13 tests. |
| `README.md`, `docs/architecture.md`, `CLAUDE.md` | 13 → 14 commands. |

**Part C — created**
| Path | Responsibility |
|------|----------------|
| `skills/idc-navigator/SKILL.md` | The standing read-only IDC-expert skill. |
| `scripts/idc_govern_blurb.py` | Insert / refresh / remove / check the marker block in `CLAUDE.md` + `AGENTS.md`. |
| `templates/govern-blurb.md` | The block body (single source of truth). |
| `tests/smoke/phase14-govern-blurb.sh` | Blurb insert/backfill/remove/idempotency. |

**Part C — modified**
| Path | Change |
|------|--------|
| `commands/init.md` | Phase 2/3: write the blurb; Phase 7: receipt-stamp `--customized`. |
| `commands/update.md` | Backfill the blurb into already-governed repos. |
| `commands/uninstall.md` | Remove the block, leave operator content. |
| `commands/doctor.md` | New check row: blurb present + current. |
| `tests/smoke/run-all.sh` | register `phase14-govern-blurb`. |

---

# PART B — `/idc:ask`

## Task B1: Register `ask` as the 14th command, read-only

**Files:**
- Modify: `scripts/idc_command_contract.py:85` (`COMMANDS`)
- Modify: `scripts/idc_path_gate.py:70` (`READ_ONLY_COMMANDS`)
- Modify: `hooks/hooks.json:83` (matcher)
- Modify: `scripts/hooks/idc_command_entry_gate.py` (`RECOVERY_COMMANDS`, `BASELINE_ALLOWED_COMMANDS`)
- Test: `tests/smoke/phase13-ask-registration.sh`

**Interfaces:**
- Produces: the string literal `"ask"` as a first-class member of `COMMANDS` and
  `READ_ONLY_COMMANDS`. Tasks B2–B5 rely on both.

**Why read-only matters:** `scripts/idc_path_gate.py:771 _role_action_ceiling()` returns an EMPTY
mutation ceiling for a command in `READ_ONLY_COMMANDS`. That means `/idc:ask` can never mint a
write/edit/git grant no matter what actions any caller passes. This is the containment guarantee for
the whole feature — if the resolver misfires, the advisory path still cannot touch the repo.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/phase13-ask-registration.sh`, modelled on the existing phase1 test style (read
`tests/smoke/phase1-lint-rules.sh` first for the harness idioms — `set -euo pipefail`, the shared
`tests/smoke/lib/` helpers, and how a phase reports pass/fail):

```bash
#!/usr/bin/env bash
# phase13-ask-registration.sh — `ask` is a registered, READ-ONLY 14th command.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. contract registry
python3 - "$REPO_ROOT" <<'PY' || fail "ask missing from COMMANDS"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_command_contract as C
assert "ask" in C.COMMANDS, C.COMMANDS
PY

# 2. path gate read-only ceiling is EMPTY
python3 - "$REPO_ROOT" <<'PY' || fail "ask is not read-only in the Path Gate"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_path_gate as PG
assert "ask" in PG.READ_ONLY_COMMANDS, PG.READ_ONLY_COMMANDS
assert PG._role_action_ceiling("ask") == set(), PG._role_action_ceiling("ask")
paths, actions = PG._default_profile("ask")
assert actions == [], actions
PY

# 3. the UserPromptExpansion matcher admits idc:ask
python3 - "$REPO_ROOT" <<'PY' || fail "hooks.json matcher does not admit idc:ask"
import json, re, sys, os
with open(os.path.join(sys.argv[1], "hooks", "hooks.json")) as fh:
    manifest = json.load(fh)
matchers = [h["matcher"] for h in manifest["hooks"]["UserPromptExpansion"]]
assert any(re.match(m, "idc:ask") for m in matchers), matchers
PY

# 4. ask is NOT auth-required (no Path Gate mint for the advisory path)
python3 - "$REPO_ROOT" <<'PY' || fail "ask must not be in AUTH_REQUIRED_COMMANDS"
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "hooks"))
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_command_entry_gate as G
assert "ask" not in G.AUTH_REQUIRED_COMMANDS, sorted(G.AUTH_REQUIRED_COMMANDS)
assert "ask" in G.BASELINE_ALLOWED_COMMANDS, sorted(G.BASELINE_ALLOWED_COMMANDS)
PY

echo "PASS: phase13-ask-registration"
```

- [ ] **Step 2: Run it — verify it FAILS**

```bash
bash tests/smoke/phase13-ask-registration.sh
```
Expected: `FAIL: ask missing from COMMANDS`.

- [ ] **Step 3: Make the registrations**

1. `scripts/idc_command_contract.py:85` — add `"ask"` to the `COMMANDS` set (keep alphabetical:
   `"ask", "autorun", "build", …`).
2. `scripts/idc_path_gate.py:70` — `READ_ONLY_COMMANDS = {"ask", "doctor", "pause"}`.
   Update the surrounding comment: a read-only command (`ask`/`doctor`/`pause`) has an empty ceiling.
   Also update the docstring at `scripts/idc_path_gate.py:771-776` which names `(doctor/pause)`.
3. `hooks/hooks.json:83` — matcher becomes
   `"^idc:(ask|autorun|build|doctor|init|intake|janitor|pause|plan|recirculate|resume|think|uninstall|update)$"`
4. `scripts/hooks/idc_command_entry_gate.py`:
   - `RECOVERY_COMMANDS` (`:62`) gains `"ask"` — `/idc:ask` must still expand on an invalid or
     unreadable receipt, because "something is wrong, what do I do" is exactly when you need it.
   - `AUTH_REQUIRED_COMMANDS` (`:102`) becomes `set(C.COMMANDS) - {"doctor", "pause", "ask"}`.
   - `BASELINE_ALLOWED_COMMANDS` (`:103`) gains `"ask"`.

- [ ] **Step 4: Run it — verify it PASSES**

```bash
bash tests/smoke/phase13-ask-registration.sh   # expect: PASS
```

- [ ] **Step 5: Prove the guard goes RED when broken**

Temporarily revert *only* `READ_ONLY_COMMANDS` to `{"doctor", "pause"}`, re-run the test, and
confirm it prints `FAIL: ask is not read-only in the Path Gate`. **Paste that red output into the
PR body.** Then restore.

- [ ] **Step 6: Register the phase and lint**

Add `phase13-ask-registration \` to the phase list in `tests/smoke/run-all.sh` (follow the existing
formatting at `tests/smoke/run-all.sh:106-117`).

```bash
bash scripts/lint-references.sh   # MUST exit 0
```

- [ ] **Step 7: Commit and push**

```bash
git add -A && git commit -m "feat(ask): register ask as a read-only 14th command"
git push
```

---

## Task B2: The deterministic resolver

**Files:**
- Create: `scripts/idc_ask_resolve.py`
- Test: `tests/smoke/phase13-ask-resolver.sh`

**Interfaces:**
- Consumes: `scripts/idc_next_action.py` (the oracle) — import it as a module, call `decide(repo)`,
  which returns a `NextAction` with `.verdict` in `{"action","waiting","no_action","invalid",
  "blocked_external"}` and `.command` as a string like `"/idc:build"` or `"/idc:think --doc X --unit Y"`.
- Produces: CLI `idc_ask_resolve.py --repo <repo> --text "<free text>" --json`, and the module-level
  function `resolve(repo: str, text: str) -> dict`. Task B3 imports `resolve` directly.

**Output contract (stable — B3 and the smoke tests both depend on it):**

```json
{
  "schema_version": 1,
  "verdict": "route" | "advisory",
  "command": "pause" | "resume" | "doctor" | "janitor" | "think" | "intake"
             | "plan" | "build" | "recirculate" | "autorun" | null,
  "command_args": "--doc docs/workflow/intakes/x.json --unit u1",
  "reason_code": "keyword-pause" | "oracle-action" | "ambiguous" | "no-match"
                 | "oracle-waiting" | "oracle-fixpoint" | "oracle-invalid"
                 | "oracle-rate-limited" | "lifecycle-command",
  "matched": ["stop"],
  "oracle": {"verdict": "...", "reason_code": "...", "command": "...", "refs": [], "counts": {}}
}
```

Exit 0 whenever a verdict was reached (advisory is a valid answer). Exit 2 only when `--repo` is not
a readable directory.

**Resolution order — implement exactly this, in this order:**

1. **Lifecycle guard first.** If the text matches an install-lifecycle intent
   (`install`, `set up idc`, `scaffold`, `uninstall`, `remove idc`, `update idc`, `upgrade idc`),
   return `advisory` / `lifecycle-command` with `command: null`. These change the installation
   itself and must be typed deliberately. **This check runs BEFORE everything else** so that
   "update idc and then stop" can never route to `pause`.
2. **Housekeeping keywords.** Whole-word, case-insensitive, on the normalized text. Collect every
   intent that matched.
3. **Conflict → advisory.** If two *different* housekeeping intents matched, return `advisory` /
   `ambiguous` with `matched` listing them. Never guess between them.
4. **Single housekeeping match → route** to that command with `reason_code: keyword-<cmd>`.
5. **No housekeeping match (including empty text) → ask the oracle.**
   - `verdict == "action"` and the parsed command is in `ROUTABLE` → `route`, `oracle-action`,
     carrying `command_args`.
   - `verdict == "waiting"` → `advisory` / `oracle-waiting` (a human gate is open; nothing to run).
   - `verdict == "no_action"` → `advisory` / `oracle-fixpoint`.
   - `verdict == "invalid"` → `advisory` / `oracle-invalid`.
   - `verdict == "blocked_external"` → `advisory` / `oracle-rate-limited`.
6. **Final backstop.** If the resolved command is not in `ROUTABLE`, downgrade to `advisory` /
   `no-match`. This is belt-and-braces: it makes it structurally impossible to route to `init`,
   `update`, or `uninstall` even if a future edit adds a keyword for one.

**The keyword table — use exactly these, and keep them precision-first:**

```python
ROUTABLE = frozenset({
    "pause", "resume", "doctor", "janitor",
    "think", "intake", "plan", "build", "recirculate", "autorun",
})

# NEVER routable — these change the installation and must be typed deliberately.
LIFECYCLE_ONLY = frozenset({"init", "update", "uninstall"})

LIFECYCLE_CUES = (
    "install idc", "uninstall", "remove idc", "update idc", "upgrade idc",
    "set up idc", "setup idc", "scaffold", "reinstall",
)

KEYWORDS = {
    "pause":   ("stop", "stopping", "pause", "halt", "wrap up", "wrapping up",
                "done for now", "knock off", "call it a night", "call it a day",
                "stop work", "stop here", "shut down for now"),
    "resume":  ("resume", "pick up", "picking up", "continue", "carry on",
                "back at it", "where were we", "left off", "keep going",
                "pick it back up", "start again"),
    "doctor":  ("broken", "health", "healthy", "diagnose", "diagnostic",
                "something wrong", "is anything wrong", "sanity check",
                "check the install", "misconfigured"),
    "janitor": ("tidy", "clean up", "cleanup", "reconcile", "stale",
                "housekeeping", "out of sync", "drift"),
}
```

Matching rule: a cue matches when it appears in the normalized text as a **whole-token sequence**
(pad the text with spaces and search for `" " + cue + " "` after collapsing whitespace and stripping
punctuation to spaces). This prevents `stop` matching inside `stopgap` and `drift` inside `spendthrift`.

- [ ] **Step 1: Write the failing test**

Create `tests/smoke/phase13-ask-resolver.sh`. It drives the resolver as a module against a temp
directory and asserts the full decision table:

```bash
#!/usr/bin/env bash
# phase13-ask-resolver.sh — the /idc:ask intent resolver decision table.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "$REPO_ROOT" <<'PY' || fail "resolver decision table"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_ask_resolve as R

# --- pure keyword decisions (oracle never consulted; repo may be anything) ---
CASES = [
    ("stop work here",                 "route",    "pause",   "keyword-pause"),
    ("I'm done for now",               "route",    "pause",   "keyword-pause"),
    ("pick up where we left off",      "route",    "resume",  "keyword-resume"),
    ("carry on",                       "route",    "resume",  "keyword-resume"),
    ("is anything broken?",            "route",    "doctor",  "keyword-doctor"),
    ("tidy up the board",              "route",    "janitor", "keyword-janitor"),
    # conflict -> never guess
    ("stop and then pick up later",    "advisory", None,      "ambiguous"),
    # lifecycle -> never routed, and lifecycle wins over a co-occurring cue
    ("uninstall idc",                  "advisory", None,      "lifecycle-command"),
    ("update idc and then stop",       "advisory", None,      "lifecycle-command"),
    # substring safety
    ("this is a stopgap measure for the driftwood",
                                       "advisory", None,      None),
]
for text, verdict, command, reason in CASES:
    got = R.resolve_keywords(text)
    assert got["verdict"] == verdict, (text, got)
    assert got["command"] == command, (text, got)
    if reason is not None:
        assert got["reason_code"] == reason, (text, got)

# --- the structural backstop: nothing may ever route to a lifecycle command ---
for cmd in R.LIFECYCLE_ONLY:
    assert cmd not in R.ROUTABLE, cmd
PY

echo "PASS: phase13-ask-resolver"
```

> Note for the implementer: split the pure keyword decision into `resolve_keywords(text) -> dict`
> (no repo, no oracle, no I/O) and have `resolve(repo, text)` call it first and fall through to the
> oracle. The test above depends on that split, and it is the right seam anyway — the keyword table
> is the part that needs exhaustive cheap testing.

- [ ] **Step 2: Run it — verify it FAILS**

```bash
bash tests/smoke/phase13-ask-resolver.sh
```
Expected: `ModuleNotFoundError: No module named 'idc_ask_resolve'`.

- [ ] **Step 3: Implement `scripts/idc_ask_resolve.py`**

Follow the house style of `scripts/idc_next_action.py`: module docstring stating the contract and
exit codes, `from __future__ import annotations`, stdlib only, `SCRIPT_DIR` on `sys.path` so sibling
helpers import, and a `main(argv)` returning an int.

The oracle import mirrors `scripts/idc_pause_check.py:151`:

```python
import idc_next_action as NEXT  # noqa: E402 — the shared read-only oracle
```

Parse the oracle's `command` string (e.g. `"/idc:think --doc X --unit Y"`) into `command` +
`command_args` by stripping the leading `/idc:` and splitting on the first space.

**Wrap the oracle call in a try/except.** The oracle can raise, and the resolver must never take
down the entry gate — on any exception return `advisory` / `oracle-invalid`.

- [ ] **Step 4: Run it — verify it PASSES**

```bash
bash tests/smoke/phase13-ask-resolver.sh   # expect: PASS
python3 scripts/idc_ask_resolve.py --repo "$PWD" --text "stop work here" --json
```

- [ ] **Step 5: Prove the guard goes RED when broken**

Temporarily add `"uninstall"` to `ROUTABLE`, re-run, and confirm the structural-backstop assertion
fails. Separately, temporarily move the lifecycle check to run *after* the keyword check and confirm
`"update idc and then stop"` reds. **Paste both red outputs into the PR body.** Restore.

- [ ] **Step 6: Register the phase, lint, commit, push**

```bash
# add phase13-ask-resolver to tests/smoke/run-all.sh
bash scripts/lint-references.sh
git add -A && git commit -m "feat(ask): deterministic intent resolver" && git push
```

---

## Task B3: Wire the resolver into the command entry gate

**Files:**
- Modify: `scripts/hooks/idc_command_entry_gate.py`
- Test: `tests/smoke/phase13-ask-entry-gate.sh`

**Interfaces:**
- Consumes: `idc_ask_resolve.resolve(repo, text) -> dict` (Task B2);
  `C.COMMANDS`, `READ_ONLY_COMMANDS` (Task B1).
- Produces: the retargeting behaviour Task B4's playbook assumes.

**Read `scripts/hooks/idc_command_entry_gate.py` in full before editing.** It is the trusted
admission door: it binds the plugin runtime to the install receipt, opens the lifecycle record, and
mints the Path Gate authorization. Understand `_normalize_command`, `_context`, `_bootstrap_context`,
`_emit_context`, `_register_if_governed`, `_admission_transaction`, and `_block` before touching it.

**The change, precisely:**

After `_normalize_command` resolves the command to `"ask"`, and **before** the existing
registration/authorization path runs, insert a retargeting step:

1. Extract the operator's free text from the hook payload (the raw prompt minus the `/idc:ask`
   token). Read how the payload is shaped in the existing code — do not invent a field name.
2. Call `idc_ask_resolve.resolve(repo, text)`.
3. **`verdict == "route"`** → set the working command to `result["command"]` and continue through the
   *existing, unmodified* admission path. It opens the record and mints authorization for that
   command exactly as if the operator had typed it — with `--source "ask"` on the
   `idc_command_contract.py start` call so the record tells the truth about how it was entered.
   Then inject the target command's playbook context **plus** the confirm preamble below.
4. **`verdict == "advisory"`** → keep the command as `"ask"` and continue. Because `ask` is
   read-only and not in `AUTH_REQUIRED_COMMANDS`, no authorization is minted. Inject the advisory
   context.
5. **Resolver raises or returns malformed output** → fall back to `advisory`. The gate must never
   hard-fail because the resolver had a bad day. Follow the existing fail-soft idiom in this file.

**The confirm preamble (inject verbatim on the route path):**

```
You reached this command through /idc:ask, so the operator did not name it — the resolver did.
Before you take ANY action, state in ONE line: which command this is, in plain English what it
will do, and why it fits what they said. Then stop and wait for `y` or `n`.

On `y`: proceed with the playbook below.
On `n` (or anything that is not a yes): take no action, close this command's lifecycle record with
status `no_action`, and ask the operator what they meant instead. Do not guess a second time.
```

- [ ] **Step 1: Write the failing test**

`tests/smoke/phase13-ask-entry-gate.sh` drives the gate by piping synthetic hook payloads into it,
the way the repo already tests hooks (per `CLAUDE.md`: assert hook behaviour by invoking the hook
scripts directly with synthetic payloads). **Read an existing hook smoke test first** to copy the
payload shape — grep `tests/smoke/` for a test that pipes JSON into a `scripts/hooks/*` script.

Assert three things in a temp governed repo fixture:
1. `/idc:ask stop work here` → the emitted expansion context names `pause`, and a lifecycle record
   for `pause` (not `ask`) is opened with `source` recording `ask`.
2. `/idc:ask stop and then pick up later` → advisory; the record opened is for `ask`; **no Path Gate
   authorization file is written**.
3. `/idc:ask uninstall idc` → advisory, `lifecycle-command`; no record for `uninstall`.

- [ ] **Step 2: Run it — verify it FAILS**
- [ ] **Step 3: Implement the retargeting step**
- [ ] **Step 4: Run it — verify it PASSES**

- [ ] **Step 5: Prove the guard goes RED when broken**

Temporarily make the advisory path mint authorization (e.g. drop `"ask"` from the
`AUTH_REQUIRED_COMMANDS` exclusion), re-run, and confirm assertion 2 reds on the unexpected
authorization file. **Paste the red output into the PR body.** Restore.

- [ ] **Step 6: Register the phase, lint, commit, push**

---

## Task B4: `commands/ask.md` — the advisory playbook

**Files:**
- Create: `commands/ask.md`

**Read `commands/pause.md` and `commands/resume.md` first** — they are the closest models: short,
read-only-ish, honest about no-op outcomes, and they show the exact frontmatter + lifecycle +
closeout structure every command file carries.

**Frontmatter:**

```markdown
---
description: IDC Ask — say what you want in plain English and IDC routes you to the right command. Reads live state, explains where you stand, never acts without confirming.
argument-hint: '[what you want, in plain English]'
---
```

**Body must cover:**

1. **What this is.** You reached the advisory path: the resolver could not confidently name a single
   command. That is a deliberate refusal to guess, not a failure.
2. **Verify the lifecycle record at entry** — the `idc_command_contract.py status` block, copied from
   `commands/pause.md`.
3. **Read where the run stands** — call the oracle (`scripts/idc_next_action.py --repo "$PWD" --json`)
   and `scripts/idc_pause_state.py --cwd "$PWD" status`. Both read-only.
4. **Answer in plain English**, in this order: where the pipeline stands right now; what the operator
   seems to want; the one command that does it, spelled exactly (`/idc:plan`); and what that command
   will do in one sentence of plain language.
5. **The hard boundary, stated plainly:** `/idc:ask` holds no write authority. It never edits files,
   never touches the board, never opens or merges anything. If the operator wants the work done, they
   type the command it named. Say so rather than appearing to stall.
6. **When the oracle says a human gate is open** — name the gate and say that only the operator can
   open it; no command will move until they do.
7. **When the operator's request is outside IDC** (e.g. "just open a PR for this") — say plainly that
   governed work enters through the pipeline, name the IDC route that gets them what they want, and
   cite `WORKFLOW.md` §1.1.
8. **Closeout** — `idc_command_contract.py finish --command ask --status <complete|no_action|blocked_external>`.
   - `complete` — a fresh oracle read backed a named recommendation.
   - `no_action` — the oracle reports fixpoint: nothing to do, and saying so IS the product.
   - `blocked_external` — the oracle could not read (rate-limited or invalid state); cite
     `blocker:{helper:"idc_next_action.py", exit:<2|3>, diagnostic:"<why>"}`.

- [ ] **Step 1: Write `commands/ask.md`**
- [ ] **Step 2: Add the `_CLAIM_TABLE` entry for `ask`**

In `scripts/idc_command_contract.py` near `:3476`. Model the claims on the existing read-only /
oracle-backed claims — read `_claim_plan_no_action` and `_claim_build_no_action` for the pattern of
an oracle-derived claim, and `_claim_blocker_for` for the blocker. A `(command, status)` pair with no
claim list is **not claimable** and fails closed (`:3581`), so all three statuses need entries:

```python
"ask": {
    "complete":  (Claim("ask-oracle-read", _claim_ask_oracle_read),),
    "no_action": (Claim("ask-oracle-fixpoint", _claim_ask_no_action),),
    "blocked_external": (_claim_blocker_for("ask"),),
},
```

`_claim_ask_oracle_read` re-runs the oracle and passes when it returns *any* determinate verdict —
that is the whole evidence `ask` can honestly offer, and it is genuinely re-derived rather than
asserted. `_claim_ask_no_action` re-runs it and requires `verdict == "no_action"`.
For `blocked_external`, `ask` must also be added to the `_BLOCKER_HELPERS` allowlist for
`idc_next_action.py` — read that structure before editing and follow it exactly.

- [ ] **Step 3: Verify a bogus closeout is refused**

```bash
# in a temp governed repo: claiming `complete` when the oracle cannot read must be REFUSED
python3 scripts/idc_command_contract.py finish --repo <tmp> --session t \
  --command ask --status complete --evidence-json '{"schema_version":1,"refs":{}}'
```
Expected on a broken-oracle fixture: a `REFUSED` line, not a success.

- [ ] **Step 4: Lint, commit, push**

```bash
bash scripts/lint-references.sh   # Rule J now derives 14 commands from commands/*.md
git add -A && git commit -m "feat(ask): advisory playbook and closeout contract" && git push
```

---

## Task B5: Documentation, version bump, and the full suite

**Files:**
- Modify: `templates/WORKFLOW.md`, `README.md`, `docs/architecture.md`, `CLAUDE.md`
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `CHANGELOG.md`

- [ ] **Step 1: Update every "13 commands" claim to 14**

`templates/WORKFLOW.md` carries the authoritative list (`IDC ships **13 slash surfaces**` plus the
fenced `think | intake | …` block and the prose paragraph beneath it). Add `ask` and describe it in
one sentence: *the plain-language front door — say what you want and IDC routes you to the right
command, always confirming first.* Then grep the repo for other stale counts:

```bash
grep -rn "13 slash\|13 commands\|thirteen" README.md docs/ CLAUDE.md templates/ commands/ agents/ skills/
```

- [ ] **Step 2: Bump the version in lockstep**

`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` both to `6.3.0`, plus a
`CHANGELOG.md` entry. **A version bump is what refreshes the plugin cache** — without it a governed
repo keeps running the old templates and scripts.

- [ ] **Step 3: Run the full suite**

```bash
bash scripts/lint-references.sh          # MUST exit 0
bash tests/smoke/run-all.sh              # MUST pass
```

- [ ] **Step 4: Commit, push, open the PR**

PR body must contain: what changed, the three red-when-broken outputs from B1/B2/B3, and the full
`run-all.sh` tail showing the pass.

---

# PART C — the standing-expert layer

**Part C starts only after Part B is merged to `main`.** Branch from updated `main`.

## Task C1: `skills/idc-navigator/SKILL.md`

**Files:**
- Create: `skills/idc-navigator/SKILL.md`

**Read `skills/idc-goal-contract/SKILL.md` first** for the house frontmatter and structure.

**Frontmatter — the `description` is the trigger, so it must be written to fire on ordinary work
talk, not on the word "IDC":**

```markdown
---
name: idc-navigator
description: Use when working in an IDC-governed repository (one with a WORKFLOW.md contract at its root) and the user asks for substantive work, proposes a change, reports a bug, asks what to do next, or suggests an action that would touch code, issues, branches, or pull requests. Reads the live pipeline state and answers in IDC terms, so the recommended next step is always inside the pipeline rather than around it. Triggers on ordinary phrasing — "let's add X", "fix this bug", "can you open a PR", "what should I work on", "should I just commit this" — not only on the word IDC.
---
```

**Body must cover, in this order:**

1. **Establish you are in a governed repo** — `WORKFLOW.md` at the root is the marker. If it is
   absent, this skill does not apply; say so and stop.
2. **Read before recommending.** The oracle (`scripts/idc_next_action.py`) and `WORKFLOW.md` §1.1.
   Never recommend a course of action before reading both.
3. **The altitude rule** — quote `WORKFLOW.md` §1.1: each entry point admits scope at exactly one
   altitude and none may do another's job. Think shapes one new requirement; Intake compiles a large
   foreign artifact; Recirculation admits already-covered but unplanned scope; Plan decomposes
   admitted considerations; Build consumes eligible schema-checked Buildables.
4. **The out-of-pipeline catalogue** — the specific wrong recommendations to stop making, each with
   its IDC replacement. Write these as a table:
   - "I'll just open a PR" → the build stage opens PRs through the finisher; go through `/idc:build`.
   - "I'll file an issue for that" → side findings route through the Recirculator, not `gh issue create`.
   - "Let me edit the board" → the transition engine is the single write door.
   - "Let me just fix it while I'm here" → scope enters through Think, Intake, or Recirculation.
   - "Let me merge this" → merging is the operator's call and the gate is theirs to open.
5. **This skill never acts.** It reads and recommends. It names the command, or suggests
   `/idc:ask <the user's own words>` when the right route is not obvious.
6. **Handoff line** — always end with the exact command to type.

- [ ] **Step 1: Write the skill**
- [ ] **Step 2: Lint** — `bash scripts/lint-references.sh` (Rule E: frontmatter `name:` must be bare
      `idc-navigator` and match the directory stem)
- [ ] **Step 3: Commit and push**

---

## Task C2: The governed-repo instruction block

**Files:**
- Create: `templates/govern-blurb.md`, `scripts/idc_govern_blurb.py`
- Test: `tests/smoke/phase14-govern-blurb.sh`

**Interfaces:**
- Produces: CLI used by `init`, `update`, `uninstall`, and `doctor`:

```
idc_govern_blurb.py --repo <repo> --plugin-root <root> apply    # insert or refresh, idempotent
idc_govern_blurb.py --repo <repo> --plugin-root <root> check    # exit 0 current, 1 missing/stale
idc_govern_blurb.py --repo <repo> remove                        # strip block, keep operator content
```

**Markers (exact):**

```
<!-- IDC:BEGIN — managed by the IDC plugin. Edits inside this block are replaced by /idc:update. -->
<!-- IDC:END -->
```

**Behaviour:**
- Targets **both** `CLAUDE.md` and `AGENTS.md` at the governed repo root.
- File absent → create it containing only the block.
- File present, no block → insert the block **after** any leading H1 title line, else at the top,
  separated by a blank line. Never reorder or reflow operator content.
- File present, block present → replace **only** the region between the markers.
- `remove` → delete the block and any blank line it introduced. If the file is then empty, delete it.
- Idempotent: `apply` twice in a row produces a byte-identical file.
- The block body is `templates/govern-blurb.md`, read from `--plugin-root`. One source of truth.
- Refuse to write outside the repo root (no `..`, no absolute paths, no symlink escape).

**`templates/govern-blurb.md` content — keep it under ~15 lines:**

```markdown
## This repository is IDC-governed

`WORKFLOW.md` at the root is a hard contract — read it before substantive work.

Work enters through the pipeline (`Think → Plan → Build`, healed by the Recirculator, drained by
Autorun) and nowhere else. Do not hand-roll the things IDC owns: creating issues, opening or merging
pull requests, or editing the tracker board directly. Side findings are routed through the
Recirculator, not filed ad hoc.

**When you are not sure what to run, use `/idc:ask <what you want, in plain English>`** — it reads
live pipeline state, names the right command, and always confirms before acting.

Before recommending any course of action in this repo, use the `idc:idc-navigator` skill.
```

> Lint note: this file lives in `templates/`, which lint-references.sh scans. `idc:idc-navigator` is
> the correct namespaced form (Rule G) and resolves to `skills/idc-navigator/` (Rule A), and
> `/idc:ask` resolves to `commands/ask.md` (Rule J) — both ship, so both lint clean.

- [ ] **Step 1: Write `tests/smoke/phase14-govern-blurb.sh` — failing**

Cover, in a temp repo: create-when-absent; insert-below-H1 preserving operator content byte-for-byte
outside the block; refresh-in-place when the template changes; **idempotency** (`apply` twice →
identical bytes, compare with `cmp`); `remove` restores the original file exactly; `check` exits 1
when the block is missing and 0 when current; and a path-escape attempt is refused.

- [ ] **Step 2: Run it — verify it FAILS**
- [ ] **Step 3: Implement `templates/govern-blurb.md` and `scripts/idc_govern_blurb.py`**
- [ ] **Step 4: Run it — verify it PASSES**

- [ ] **Step 5: Prove the guard goes RED when broken**

Temporarily make `apply` append unconditionally instead of replacing between markers. Re-run and
confirm the idempotency assertion reds with a byte diff. **Paste the red output into the PR body.**
Restore.

- [ ] **Step 6: Register the phase, lint, commit, push**

---

## Task C3: Wire the block into init / update / uninstall / doctor

**Files:**
- Modify: `commands/init.md`, `commands/update.md`, `commands/uninstall.md`, `commands/doctor.md`

**Read each command's existing phase structure before editing.** Match its voice and its receipt
discipline — these files are dense and deliberate.

- [ ] **Step 1: `/idc:init`**

Add the `apply` call to the scaffold phase (Phase 2/3, alongside the other template copies), and add
`CLAUDE.md` and `AGENTS.md` to the Phase 7 receipt stamp as **`--customized`**. They must be
`--customized`, not pristine: everything outside the markers is operator-owned, and a pristine stamp
would let a future update silently refresh the whole file. This is the same data-loss guard
`WORKFLOW-config.yaml` and `docs/workflow/tracker-config.yaml` already use — read that passage at
`commands/init.md:384` and follow it.

Add both files to the Phase 8 scaffold commit.

- [ ] **Step 2: `/idc:update`**

Backfill: call `apply`, which inserts the block into repos governed before this version and refreshes
a stale one. Because the files are stamped `--customized`, the operator's own content is never
touched — only the marker region. State this explicitly in the command's summary output so the
operator sees which files changed and why.

- [ ] **Step 3: `/idc:uninstall`**

Call `remove`. Note in the playbook that operator content outside the markers survives, and that a
file which existed *only* to hold the block is deleted.

- [ ] **Step 4: `/idc:doctor`**

Add one check row: the block is present and current in both files (`check` exit 0). On failure the
remediation is `/idc:update`. Follow doctor's existing row format and its report-binding discipline
exactly — read how a neighbouring row is written before adding this one.

- [ ] **Step 5: Update `templates/WORKFLOW.md`**

Note that `CLAUDE.md` and `AGENTS.md` carry an IDC-managed block, and that edits inside the markers
are replaced by `/idc:update`.

- [ ] **Step 6: Version bump to `6.4.0`** — `plugin.json` + `marketplace.json` in lockstep +
      `CHANGELOG.md`.

- [ ] **Step 7: Full suite, commit, push, open the PR**

```bash
bash scripts/lint-references.sh    # MUST exit 0
bash tests/smoke/run-all.sh        # MUST pass
```

---

## Self-Review Notes (author)

- **Spec coverage:** Part B tasks B1–B5 cover registration, resolution, gate wiring, the advisory
  surface, and release. Part C tasks C1–C3 cover the skill, the block, and its four lifecycle
  touchpoints. Every element of the approved design maps to a task.
- **Type consistency:** `resolve_keywords(text) -> dict` and `resolve(repo, text) -> dict` are named
  identically in B2's interface block, B2's test, and B3's consumer block. `ROUTABLE` and
  `LIFECYCLE_ONLY` are referenced by the same names in B2 and its test.
- **Known softness, stated rather than hidden:** Task B3's test needs the real hook payload field
  names, which the implementer must read from `scripts/hooks/idc_command_entry_gate.py` rather than
  invent — the plan says so explicitly at that step instead of guessing a shape that would be wrong.
