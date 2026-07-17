# Releasing IDC — the production-ready gate

A release is ready **only when all three gates below are green.** "Green = ready for production"
is the contract: if these pass, a real operator's repo won't be broken by the new version.

This exists because a green CI + smoke suite alone is **not** sufficient proof — IDC is mostly AI
instructions plus helper programs, and a prose/UX flaw can pass every hermetic test (this is exactly
how the 2.1.3 `/idc:update` data-config footgun shipped). See
[`docs/dev/2026-06-15-testing-suite-overhaul-plan.md`](dev/2026-06-15-testing-suite-overhaul-plan.md)
for the reasoning.

## Gate 1 — automated checks green (every PR; CI enforces)

```bash
bash scripts/lint-references.sh   # exit 0 — reference integrity + version lockstep (idc_release_check.py)
bash tests/smoke/run-all.sh       # ALL GREEN — the full hermetic suite
bash scripts/run-evals.sh --all   # clean exit — headless eval runner
python3 scripts/idc_release_check.py --governance   # ALL GREEN — release governance
```

**The PyYAML governance lane.** The engine's parsing paths must hold whether or not a governed repo
has PyYAML installed, so run the governance suite once *with* it — proving no parser-dependent
regression in the existing engine paths:

```bash
uv run --python 3.13 --with pyyaml bash tests/smoke/phase-governance.sh   # ALL GREEN
```

**Pin the Python.** `--python 3.13` is not optional. Without it, `uv` may base the throwaway venv on
the system Python (3.9 on stock macOS), and the plugin's helpers require **3.10 or newer** — so the
unpinned form fails for an environmental reason that looks exactly like a real regression. Any
modern interpreter (≥ 3.10) works; 3.13 is the known-good pin.

These run in CI (`.github/workflows/ci.yml`) on every push/PR. The smoke suite now includes the
**realistic-input + quiet/no-op-default** tests (`phase7-file-commands-noop-default.sh`) and the
**prose-invariant** backstop (`phase7-command-prose-invariants.sh`) — together they assert the
file-changing commands behave correctly on a *real, already-set-up* project and stay quiet when
nothing needs doing, not just that a blank scaffold round-trips.

## Gate 2 — the no-op default holds on a realistic repo (covered by Gate 1, called out here)

The single assertion the 2.1.3 miss lacked: **when a project is already correct, the file-changing
commands change nothing and raise no prompt.** `phase7-file-commands-noop-default.sh` proves this
deterministically (current repo → no advisory, no overwrite; legacy/older-schema repo → advisory
only, never overwrite). If you add or change a file-changing command (`init`/`update`/`uninstall`/
`doctor`), it must clear this bar against the shared realistic fixture
(`tests/smoke/lib/realistic-repo.sh`).

## Gate 3 — read-only sanity check against a REAL configured repo (manual, before tag)

Before bumping the version + tagging, point the structure check at a real, already-configured repo
(not a fixture) and confirm an update would be smooth — preserve data, advise only on genuinely new
structure, never offer a destructive replace:

```bash
REPO=/path/to/a/real/governed/repo          # e.g. a project you've run /idc:init in
PLUGIN_ROOT="$(pwd)"                         # this checkout
for dest in WORKFLOW-config.yaml docs/workflow/tracker-config.yaml; do
  tmpl="$(python3 scripts/idc_template_for.py --plugin-root "$PLUGIN_ROOT" "$dest")"
  rendered="$(mktemp)"
  sed -e "s/{{PROJECT_NAME}}/$(basename "$REPO")/g" -e 's/{{TRACKER_PROJECT_NUMBER}}/0/g' "$tmpl" > "$rendered"
  echo "== $dest =="
  python3 scripts/idc_config_keys.py --added "$REPO/$dest" "$rendered"   # empty = 'preserved — current'
  rm -f "$rendered"
done
```

Expected: empty output (→ `preserved — config current`, no prompt) **or** a short list of genuinely
new keys (→ a non-destructive advisory). Anything that would *overwrite* the operator's data is a
release blocker. Read-only — it never writes to `$REPO`.

(Optional, higher fidelity: run the full live e2e — a sandbox-rooted `claude -p "/idc:update"` per
[`docs/dev/local-e2e-testing.md`](dev/local-e2e-testing.md) — and confirm the Phase 5 summary shows
`preserved` for the data configs, no destructive prompt.)

## Then cut the release

Only after Gates 1–3 are green:

1. Bump `.claude-plugin/plugin.json` **and** the matching `.claude-plugin/marketplace.json` entry in
   lockstep (the `idc_release_check.py` guard, run by `lint-references.sh`, fails the build otherwise).
2. Add a dated `CHANGELOG.md` entry.
3. Cut the tag with `claude plugin tag` (creates `idc--v<version>`; add `--push` to publish). An
   unchanged version makes `claude plugin update` a silent no-op, so every shippable change
   (`commands/`, `skills/`, `agents/`, `scripts/`, `templates/`, `.claude-plugin/`) **must** bump it.
