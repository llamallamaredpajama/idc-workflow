#!/bin/bash
# Phase 4 smoke — the BUILD-TRIGGERED "larger loop": a recirc event mid-build spawns a fresh
# specialist recirc-consultant (via the adapter), the consultant returns a STRUCTURED, FAIL-CLOSED
# closeout, and the orchestrator dispatches on it as a dumb router (no gate reasoning of its own).
#
# Two surfaces:
#   A. FUNCTIONAL — scripts/idc_recirc_closeout.py validates the consultant's closeout object and
#      emits the orchestrator's next action. Fail-closed: a malformed/missing closeout exits 2 (no
#      dispatch line), so a dropped handoff HALTS instead of silently stranding the ticket (the
#      b985c1e7 failure). Red-when-broken: every accept case is paired with a malformed CONTRAST
#      that must flip RED (exit 2) if a guard regresses.
#   B. STRUCTURAL — agents/idc-build.md + commands/build.md spawn a consultant PER recirc event and
#      act on the validated closeout; agents/idc-recirculator.md + commands/recirculate.md document
#      the structured closeout, the THIRD "trivial → grant Build permission (tiny doc PR via
#      staging)" outcome, and the cmux ping on the gated outcome.
#
# Hermetic: pure validator exercised directly + markdown prose greps. NO live GitHub.
# Usage: bash tests/smoke/phase4-larger-loop.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
CLOSEOUT="$SCRIPTS/idc_recirc_closeout.py"
BUILD="$PLUGIN/agents/idc-build.md"
RECIRC="$PLUGIN/agents/idc-recirculator.md"
RECIRC_CMD="$PLUGIN/commands/recirculate.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
# case-insensitive extended-regex substring (BSD/GNU grep safe — no \b, no PCRE).
has() { grep -qiE "$2" "$1"; }
# whitespace-flattened phrase check: markdown soft-wraps, so a chain could span lines.
hasflat() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiE "$2"; }

# ── A. FUNCTIONAL: the fail-closed closeout validator ─────────────────────────────────────────
[ -f "$CLOSEOUT" ] || fail "scripts/idc_recirc_closeout.py is missing (the fail-closed handoff validator)"

# run_co <json-file> -> prints dispatch line on stdout; returns helper exit code
run_co() { python3 "$CLOSEOUT" --closeout "$1" 2>/dev/null; }

# (1) valid PASS-THROUGH -> exit 0 + launch-plan dispatch carrying the consideration ref
cat > "$WORK/pass.json" <<'JSON'
{"ticket": 559, "outcome": "pass-through", "provenance": "originated from #391 (source->extract lineage defect)", "consideration": "docs/considerations/2026-06-29-source-extract-lineage-considerations.md"}
JSON
out="$(run_co "$WORK/pass.json")"; rc=$?
[ "$rc" -eq 0 ] || fail "valid pass-through closeout must exit 0 (got $rc)"
echo "$out" | grep -qiE 'dispatch:[[:space:]]*launch-plan' || fail "pass-through must emit a launch-plan dispatch"
echo "$out" | grep -qiE 'consideration=' || fail "pass-through dispatch must carry the consideration ref"

# (2) valid GATED -> exit 0 + notify-gated dispatch (cmux ping, no plan) carrying the think PR
cat > "$WORK/gated.json" <<'JSON'
{"ticket": 561, "outcome": "gated", "provenance": "originated from #429 (arch-spec inconsistency)", "think_pr": "https://github.com/o/r/pull/700"}
JSON
out="$(run_co "$WORK/gated.json")"; rc=$?
[ "$rc" -eq 0 ] || fail "valid gated closeout must exit 0 (got $rc)"
echo "$out" | grep -qiE 'dispatch:[[:space:]]*notify-gated' || fail "gated must emit a notify-gated dispatch"
echo "$out" | grep -qiE 'think_pr=' || fail "gated dispatch must carry the think_pr ref"

# (3) valid TRIVIAL -> exit 0 + grant-build dispatch carrying the permitted paths
cat > "$WORK/trivial.json" <<'JSON'
{"ticket": 562, "outcome": "trivial", "provenance": "stale subordinate schema mirror; authority already merged", "grant": {"issue": 393, "paths": ["docs/specs/canonical-commit-notification.schema.json"], "change": "surface enum -> {cloud_storage, spanner}"}}
JSON
out="$(run_co "$WORK/trivial.json")"; rc=$?
[ "$rc" -eq 0 ] || fail "valid trivial closeout must exit 0 (got $rc)"
echo "$out" | grep -qiE 'dispatch:[[:space:]]*grant-build' || fail "trivial must emit a grant-build dispatch"
echo "$out" | grep -qiE 'paths=' || fail "trivial dispatch must carry the permitted paths"

# ── RED-WHEN-BROKEN: every malformed closeout must FAIL CLOSED (exit 2), never silently pass ──
co_rc() { python3 "$CLOSEOUT" --closeout "$1" >/dev/null 2>&1; echo $?; }

# missing outcome
echo '{"ticket": 1, "provenance": "x"}' > "$WORK/no-outcome.json"
[ "$(co_rc "$WORK/no-outcome.json")" = "2" ] || fail "missing outcome must fail-closed (exit 2)"
# unknown outcome enum
echo '{"ticket": 1, "outcome": "merge-it", "provenance": "x"}' > "$WORK/bad-outcome.json"
[ "$(co_rc "$WORK/bad-outcome.json")" = "2" ] || fail "unknown outcome enum must fail-closed (exit 2)"
# missing provenance stamp (the user-required provenance guard)
echo '{"ticket": 1, "outcome": "pass-through", "consideration": "c.md"}' > "$WORK/no-prov.json"
[ "$(co_rc "$WORK/no-prov.json")" = "2" ] || fail "missing provenance stamp must fail-closed (exit 2)"
# pass-through missing its consideration
echo '{"ticket": 1, "outcome": "pass-through", "provenance": "x"}' > "$WORK/pass-no-cons.json"
[ "$(co_rc "$WORK/pass-no-cons.json")" = "2" ] || fail "pass-through without a consideration must fail-closed (exit 2)"
# gated missing its think_pr
echo '{"ticket": 1, "outcome": "gated", "provenance": "x"}' > "$WORK/gated-no-pr.json"
[ "$(co_rc "$WORK/gated-no-pr.json")" = "2" ] || fail "gated without a think_pr must fail-closed (exit 2)"
# trivial with empty paths (an unscoped permission grant is unsafe)
echo '{"ticket": 1, "outcome": "trivial", "provenance": "x", "grant": {"issue": 1, "paths": [], "change": "y"}}' > "$WORK/triv-empty.json"
[ "$(co_rc "$WORK/triv-empty.json")" = "2" ] || fail "trivial with empty grant.paths must fail-closed (exit 2)"
# trivial grant.paths SCOPE: each path must be a repo-relative canonical doc — the trivial outcome
# grants Build write permission for the named paths, so an unconstrained path (a source dir, an
# absolute path, a `..` escape) is a fail-OPEN. Red-when-broken: each must exit 2; the canonical-doc
# control just below must stay exit 0, so a regression to "any non-empty string" flips one of the pair.
triv() { printf '{"ticket":1,"outcome":"trivial","provenance":"x","grant":{"issue":1,"paths":["%s"],"change":"y"}}' "$1"; }
echo "$(triv 'src/app.py')"   > "$WORK/triv-src.json"
[ "$(co_rc "$WORK/triv-src.json")" = "2" ]  || fail "trivial grant.paths naming a SOURCE file (src/app.py) must fail-closed (exit 2) — not a canonical doc"
echo "$(triv '/etc/passwd')"  > "$WORK/triv-abs.json"
[ "$(co_rc "$WORK/triv-abs.json")" = "2" ]  || fail "trivial grant.paths with an ABSOLUTE path must fail-closed (exit 2) — repo escape"
echo "$(triv '../escape.md')" > "$WORK/triv-esc.json"
[ "$(co_rc "$WORK/triv-esc.json")" = "2" ]  || fail "trivial grant.paths with a '..' segment must fail-closed (exit 2) — parent-dir escape"
# canonical-doc control (red-when-broken pair): a repo-relative doc under docs/ must STILL exit 0.
echo "$(triv 'docs/specs/x.json')" > "$WORK/triv-doc.json"
[ "$(co_rc "$WORK/triv-doc.json")" = "0" ] || fail "trivial grant.paths naming a canonical doc (docs/specs/x.json) must still exit 0 (scope check must not over-reject)"
# malformed JSON
printf '{not json' > "$WORK/bad.json"
[ "$(co_rc "$WORK/bad.json")" = "2" ] || fail "malformed JSON must fail-closed (exit 2)"
# missing file
[ "$(co_rc "$WORK/does-not-exist.json")" = "2" ] || fail "missing closeout file must fail-closed (exit 2)"

# ── B. STRUCTURAL: the orchestration prose ───────────────────────────────────────────────────
# build spawns ONE fresh consultant PER recirc event (not just files-and-defers) and routes on the
# closeout. Pinned to the SPECIFIC load-bearing instruction ("one fresh … recirc-consultant per recirc
# event") rather than a loose recirc+spawn co-occurrence, so removing the per-event spawn flips it RED
# (the looser form could match incidental pre-feature prose).
hasflat "$BUILD" 'one fresh[^.]*recirc-consultant per recirc event' \
  || fail "agents/idc-build.md must spawn ONE fresh recirc-consultant PER recirc event (not batch-and-defer)"
has "$BUILD" 'idc_recirc_closeout' \
  || fail "agents/idc-build.md must consume the fail-closed closeout validator (idc_recirc_closeout)"
hasflat "$BUILD" 'closeout[^.]*(dispatch|act|route)|(dispatch|act|route)[^.]*closeout' \
  || fail "agents/idc-build.md must act on the consultant's structured closeout as a router"
# (commands/build.md is NOT modified by this feature — a `has commands/build.md 'recirc'` grep would be
# a tautology matching pre-existing text, never red-when-broken. The build-side behavior is pinned via
# the agents/idc-build.md closeout/router greps above + the recirculator prose below.)

# recirculator emits the structured closeout + the THIRD trivial outcome + the gated cmux ping
has "$RECIRC" 'idc_recirc_closeout|structured closeout|closeout (object|protocol)' \
  || fail "agents/idc-recirculator.md must emit a structured closeout"
hasflat "$RECIRC" 'trivial[^.]*(grant|permission|build)|grant[^.]*build' \
  || fail "agents/idc-recirculator.md must document the trivial -> grant-Build-permission outcome"
hasflat "$RECIRC" 'tiny|separate doc pr|doc pr[^.]*stag|stag[^.]*doc pr' \
  || fail "agents/idc-recirculator.md must route the trivial doc change as a separate doc PR via staging"
# tie the ping to the GATED outcome specifically (flattened): the recirculator already carried a
# "push notification" for the gate-pause ADMISSION on `main`, so a bare `cmux|push notif` grep passed
# pre-feature (tautology). `gated[^.]*(cmux|push)[^.]*ping` pins the NEW gated-CLOSEOUT ping — "ping" is
# the distinguishing token (the admission says "notification") — so dropping it flips RED.
hasflat "$RECIRC" 'gated[^.]*(cmux|push)[^.]*ping' \
  || fail "agents/idc-recirculator.md must fire a cmux/push PING on the GATED closeout outcome (distinct from the admission push notification)"
has "$RECIRC_CMD" 'closeout|trivial' \
  || fail "commands/recirculate.md must reference the structured closeout / trivial outcome"

# CONTRAST (red-when-broken control): the three outcomes are distinct dispatch verbs, so a regression
# that collapsed them would flip one of the (1)-(3) assertions above RED. Confirm the validator does
# NOT emit the same verb for two different outcomes.
vp="$(run_co "$WORK/pass.json")"; vg="$(run_co "$WORK/gated.json")"; vt="$(run_co "$WORK/trivial.json")"
[ "$vp" != "$vg" ] && [ "$vg" != "$vt" ] && [ "$vp" != "$vt" ] \
  || fail "the three outcomes must produce DISTINCT dispatch lines (a collapsed router is red)"

# ── C. STRUCTURAL: the loop CLOSES — Plan re-links the paused issue + nudges the parent ──────
PLAN="$PLUGIN/agents/idc-plan.md"
# the consultant records the paused ORIGIN issue on the admitted consideration, so the link survives
# the recirc ticket's retirement (otherwise Plan has no provenance to re-link from).
hasflat "$RECIRC" 'paused origin issue|origin issue[^.]*consideration|consideration[^.]*paused origin' \
  || fail "agents/idc-recirculator.md must record the paused origin issue on the admitted consideration"
# Plan re-points the paused issue off its RETIRED recirc ticket onto the new unblockers — never
# leaving it eligible-via-a-retired-ticket (the b985c1e7 premature-eligibility / infinite-loop trap).
hasflat "$PLAN" 'eligible[^.]*(behind|via)[^.]*retired[^.]*recirc|retired[^.]*recirc[^.]*eligible' \
  || fail "agents/idc-plan.md must keep a paused issue from going eligible behind a retired recirc ticket"
hasflat "$PLAN" 're-?point[^.]*(paused|unblocker)|paused[^.]*re-?point[^.]*unblocker|re-?point[^.]*paused[^.]*unblocker' \
  || fail "agents/idc-plan.md must re-point the paused issue onto its real new unblocker issues"
# Plan reports the newly-created buildable issues on completion so the spawning orchestrator re-queries.
hasflat "$PLAN" 'report[^.]*buildable[^.]*(orchestrator|frontier|re-?quer)|newly-created buildable[^.]*(report|signal|frontier)' \
  || fail "agents/idc-plan.md must report newly-created buildable issues on completion (the parent's re-query nudge)"

# ── D. STRUCTURAL: the adapter realizes recirc/plan workers in EVERY runtime (no-team fallback) ──
ADAPTER="$PLUGIN/skills/idc-adapter-claude/SKILL.md"
hasflat "$ADAPTER" 'recirc consultant[^.]*plan worker|larger loop[^.]*durable worker|recirc consultant.{0,60}durable worker' \
  || fail "idc-adapter-claude must realize the larger loop's recirc consultant + Plan worker as durable workers"
hasflat "$ADAPTER" 'task subagent[^.]*(inline|serial|no |fallback)|(inline|serial) (pass|session)[^.]*(no |where no )durable' \
  || fail "idc-adapter-claude must give the no-durable-worker fallback (Task subagent / inline serial pass)"
hasflat "$ADAPTER" "(can'?t|cannot|never) spawn[^.]*teammate" \
  || fail "idc-adapter-claude must note recirc/plan workers can't spawn teammates -> bounded fan-out (Workflow/subagents)"

echo "PASS: closeout validator fail-closes on every malformed handoff (red-when-broken) + emits distinct pass-through/gated/trivial dispatches; build spawns+routes the consultant per event; recirculator documents the structured closeout, trivial grant-Build outcome (separate doc PR via staging), gated cmux ping, and the paused origin-issue record; Plan re-links the paused issue off the retired ticket onto new unblockers + nudges the parent on completion; the adapter realizes recirc/plan workers in every runtime with a no-team subagent/inline fallback"
