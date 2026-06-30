#!/bin/bash
# Phase 4 smoke — the BUILD-TRIGGERED "larger loop": a recirc event mid-build spawns a fresh
# specialist recirc-consultant (via the adapter), the consultant returns a STRUCTURED, FAIL-CLOSED
# closeout, and the orchestrator dispatches on it as a dumb router (no gate reasoning of its own).
#
# Two surfaces:
#   A. FUNCTIONAL — scripts/idc_recirc_closeout.py validates the consultant's closeout object and
#      emits the orchestrator's next action as ONE structured JSON dispatch line. Fail-closed has
#      TWO halves a malformed/missing closeout must satisfy: exit 2 AND zero stdout (no routable
#      dispatch left for the dumb-router parent), so a dropped handoff HALTS instead of silently
#      stranding the ticket (the b985c1e7 failure). Red-when-broken: every accept case is paired
#      with a malformed CONTRAST that must flip RED (exit 2 + no dispatch) if a guard regresses.
#   B. STRUCTURAL — agents/idc-build.md + commands/build.md spawn a consultant PER recirc event and
#      act on the validated closeout; agents/idc-recirculator.md + commands/recirculate.md document
#      the structured closeout, the THIRD "trivial -> grant Build permission (tiny doc PR via
#      staging)" outcome, and the cmux ping on the gated outcome.
#
# Hermetic: pure validator exercised directly + markdown prose greps. NO live GitHub.
# Usage: bash tests/smoke/phase4-larger-loop.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
CLOSEOUT="$SCRIPTS/idc_recirc_closeout.py"
BUILD="$PLUGIN/agents/idc-build.md"
BUILD_CMD="$PLUGIN/commands/build.md"
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

# run_co <json-file> -> prints the dispatch object (one JSON line) on stdout; caller checks rc
run_co() { python3 "$CLOSEOUT" --closeout "$1" 2>/dev/null; }
# co_rc_ok <json-file> -> exit code only (for the red-when-broken CONTROL cases that must stay exit 0)
co_rc_ok() { python3 "$CLOSEOUT" --closeout "$1" >/dev/null 2>&1; echo $?; }

# jcheck <dispatch-line> <python-expression-on-d> [argv forwarded…] — exit 0 iff the JSON line
# parses AND <expr> is truthy. A whitespace-delimited `dispatch: …` line (the OLD line protocol)
# fails json.loads -> RED, the red-when-broken signal that the structured-JSON dispatch contract is
# in force. (python -c is double-quoted so single-quoted Python strings need no escaping; no
# $/backtick in the expressions.) Any args after <expr> are forwarded to python as sys.argv[1..].
jcheck() {
  local line="$1" expr="$2"; shift 2
  printf '%s' "$line" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
assert $expr
" "$@"
}

# assert_dispatch <file> <verb> -> exit 0 AND a single valid JSON line whose 'verb' matches AND whose
# ticket/recirc_count/cascade_depth are integers (the type-check contract). Echoes the line for checks.
assert_dispatch() {
  local out rc
  out="$(python3 "$CLOSEOUT" --closeout "$1" 2>/dev/null)"; rc=$?
  [ "$rc" = "0" ] || fail "$2: valid closeout must exit 0 (got $rc)"
  jcheck "$out" "d.get('verb')==sys.argv[1]" "$2" \
    || fail "$2: dispatch must be ONE valid JSON line with verb=$2 (got: $out)"
  jcheck "$out" "all(isinstance(d.get(k),int) and not isinstance(d.get(k),bool) for k in ('ticket','recirc_count','cascade_depth'))" \
    || fail "$2: dispatch must carry integer ticket/recirc_count/cascade_depth (got: $out)"
  printf '%s' "$out"
}

# (1) valid PASS-THROUGH -> exit 0 + launch-plan JSON dispatch carrying the consideration ref
cat > "$WORK/pass.json" <<'JSON'
{"ticket": 559, "outcome": "pass-through", "provenance": "originated from #391 (source->extract lineage defect)", "recirc_count": 1, "cascade_depth": 0, "consideration": "docs/considerations/2026-06-29-source-extract-lineage-considerations.md"}
JSON
out="$(assert_dispatch "$WORK/pass.json" launch-plan)"
jcheck "$out" "d['consideration'].endswith('.md') and d['ticket']==559" \
  || fail "pass-through dispatch must carry the consideration ref + ticket (got: $out)"

# (2) valid GATED -> exit 0 + notify-gated JSON dispatch (cmux ping, no plan) carrying the think PR
cat > "$WORK/gated.json" <<'JSON'
{"ticket": 561, "outcome": "gated", "provenance": "originated from #429 (arch-spec inconsistency)", "recirc_count": 0, "cascade_depth": 0, "think_pr": "https://github.com/o/r/pull/700"}
JSON
out="$(assert_dispatch "$WORK/gated.json" notify-gated)"
jcheck "$out" "d['think_pr'].startswith('https://')" \
  || fail "gated dispatch must carry the think_pr ref (got: $out)"

# (3) valid TRIVIAL -> exit 0 + grant-build JSON dispatch carrying paths AND change (Major 3: change survives)
cat > "$WORK/trivial.json" <<'JSON'
{"ticket": 562, "outcome": "trivial", "provenance": "stale subordinate schema mirror; authority already merged", "recirc_count": 2, "cascade_depth": 1, "grant": {"issue": 393, "paths": ["docs/specs/canonical-commit-notification.schema.json"], "change": "surface enum -> {cloud_storage, spanner}"}}
JSON
out="$(assert_dispatch "$WORK/trivial.json" grant-build)"
jcheck "$out" "d['issue']==393 and isinstance(d['issue'],int) and d['paths']==['docs/specs/canonical-commit-notification.schema.json'] and d['change']=='surface enum -> {cloud_storage, spanner}'" \
  || fail "grant-build dispatch must carry paths + the validated change + integer issue (got: $out)"

# ── RED-WHEN-BROKEN: every malformed closeout must FAIL CLOSED (exit 2) AND print NO dispatch ──
# The fail-closed contract has TWO halves: exit 2 AND zero stdout (a malformed handoff must NEVER
# leave a routable dispatch for the dumb-router parent). assert_fail checks BOTH — the old co_rc
# discarded stdout, so a regression that printed a dispatch AND exited 2 would have sneaked through,
# leaving the parent with a routable action on a malformed handoff.
assert_fail() {
  local out rc
  out="$(python3 "$CLOSEOUT" --closeout "$1" 2>/dev/null)"; rc=$?
  [ "$rc" = "2" ]  || fail "$2 must fail-closed exit 2 (got $rc)"
  [ -z "$out" ]    || fail "$2 must print NO dispatch line on fail-closed (got: $out)"
}
# missing outcome
echo '{"ticket": 1, "provenance": "x", "recirc_count": 0, "cascade_depth": 0}' > "$WORK/no-outcome.json"
assert_fail "$WORK/no-outcome.json" "missing outcome"
# unknown outcome enum
echo '{"ticket": 1, "outcome": "merge-it", "provenance": "x", "recirc_count": 0, "cascade_depth": 0}' > "$WORK/bad-outcome.json"
assert_fail "$WORK/bad-outcome.json" "unknown outcome enum"
# missing provenance stamp (the user-required provenance guard)
echo '{"ticket": 1, "outcome": "pass-through", "recirc_count": 0, "cascade_depth": 0, "consideration": "c.md"}' > "$WORK/no-prov.json"
assert_fail "$WORK/no-prov.json" "missing provenance stamp"
# pass-through missing its consideration
echo '{"ticket": 1, "outcome": "pass-through", "provenance": "x", "recirc_count": 0, "cascade_depth": 0}' > "$WORK/pass-no-cons.json"
assert_fail "$WORK/pass-no-cons.json" "pass-through without a consideration"
# gated missing its think_pr
echo '{"ticket": 1, "outcome": "gated", "provenance": "x", "recirc_count": 0, "cascade_depth": 0}' > "$WORK/gated-no-pr.json"
assert_fail "$WORK/gated-no-pr.json" "gated without a think_pr"

# ── ticket TYPE-CHECK (Major 1): ticket must be a positive integer; non-integer ticket fails closed
# Red-when-broken: the old validator only checked `ticket in (None,"")`, so a string/float/bool ticket
# was accepted and routed. Each non-int form must exit 2 + no dispatch.
echo '{"ticket": "abc", "outcome": "pass-through", "provenance": "x", "recirc_count": 0, "cascade_depth": 0, "consideration": "c.md"}' > "$WORK/str-ticket.json"
assert_fail "$WORK/str-ticket.json" "non-integer ticket (string)"
echo '{"ticket": 3.5, "outcome": "pass-through", "provenance": "x", "recirc_count": 0, "cascade_depth": 0, "consideration": "c.md"}' > "$WORK/float-ticket.json"
assert_fail "$WORK/float-ticket.json" "non-integer ticket (float)"
echo '{"ticket": true, "outcome": "pass-through", "provenance": "x", "recirc_count": 0, "cascade_depth": 0, "consideration": "c.md"}' > "$WORK/bool-ticket.json"
assert_fail "$WORK/bool-ticket.json" "non-integer ticket (bool)"
echo '{"ticket": 0, "outcome": "pass-through", "provenance": "x", "recirc_count": 0, "cascade_depth": 0, "consideration": "c.md"}' > "$WORK/zero-ticket.json"
assert_fail "$WORK/zero-ticket.json" "zero ticket (must be a positive issue number)"

# ── runaway-cap count/depth protocol (Major 4): required non-negative integers, validated ──────
# The caps helper consumes these; the closeout is the consultant-authoritative source. Missing /
# negative / non-int must fail-closed so Build never invents them.
echo '{"ticket": 1, "outcome": "pass-through", "provenance": "x", "cascade_depth": 0, "consideration": "c.md"}' > "$WORK/no-rc.json"
assert_fail "$WORK/no-rc.json" "missing recirc_count"
echo '{"ticket": 1, "outcome": "pass-through", "provenance": "x", "recirc_count": 0, "consideration": "c.md"}' > "$WORK/no-cd.json"
assert_fail "$WORK/no-cd.json" "missing cascade_depth"
echo '{"ticket": 1, "outcome": "pass-through", "provenance": "x", "recirc_count": -1, "cascade_depth": 0, "consideration": "c.md"}' > "$WORK/neg-rc.json"
assert_fail "$WORK/neg-rc.json" "negative recirc_count"
echo '{"ticket": 1, "outcome": "pass-through", "provenance": "x", "recirc_count": 0, "cascade_depth": "deep", "consideration": "c.md"}' > "$WORK/str-cd.json"
assert_fail "$WORK/str-cd.json" "non-integer cascade_depth"

# ── INJECTION: a scalar carrying control chars / delimiters must round-trip as JSON, not be parsed ─
# The structured-JSON dispatch kills the line-protocol injection risk: a newline / delimiter in a
# scalar is JSON-escaped, so the parent routes on the PARSED value, not a spoofed whitespace token.
# json.loads already enforces 'one line'; this asserts the value survived with the newline IN it and
# the ticket stayed 7 (no token-spoofing of ticket=999).
cat > "$WORK/inject.json" <<'JSON'
{"ticket": 7, "outcome": "pass-through", "provenance": "x", "recirc_count": 0, "cascade_depth": 0, "consideration": "evil\nconsideration=spoofed ticket=999"}
JSON
out="$(assert_dispatch "$WORK/inject.json" launch-plan)"
jcheck "$out" "d['ticket']==7 and 'spoofed' in d['consideration'] and d['consideration'].count(chr(10))==1" \
  || fail "injected scalar must round-trip as a JSON value (ticket==7, newline preserved, no token spoofing) (got: $out)"

# trivial with empty paths (an unscoped permission grant is unsafe)
echo '{"ticket": 1, "outcome": "trivial", "provenance": "x", "recirc_count": 0, "cascade_depth": 0, "grant": {"issue": 1, "paths": [], "change": "y"}}' > "$WORK/triv-empty.json"
assert_fail "$WORK/triv-empty.json" "trivial with empty grant.paths"
# trivial grant missing its change description (Major 3 source side)
echo '{"ticket": 1, "outcome": "trivial", "provenance": "x", "recirc_count": 0, "cascade_depth": 0, "grant": {"issue": 1, "paths": ["docs/specs/x.json"]}}' > "$WORK/triv-no-change.json"
assert_fail "$WORK/triv-no-change.json" "trivial grant missing 'change'"
# trivial grant.issue not an integer
echo '{"ticket": 1, "outcome": "trivial", "provenance": "x", "recirc_count": 0, "cascade_depth": 0, "grant": {"issue": "393", "paths": ["docs/specs/x.json"], "change": "y"}}' > "$WORK/triv-str-issue.json"
assert_fail "$WORK/triv-str-issue.json" "trivial grant.issue not an integer"

# trivial grant.paths SCOPE (Major 2): each path must be a repo-relative SUBORDINATE canonical-doc
# FILE — the trivial outcome grants Build write permission for the named paths, so an unconstrained
# path (a source dir, an absolute path, a `..` escape, a GOVERNING instruction surface, a directory)
# is a fail-OPEN. Red-when-broken: each must exit 2; the canonical-doc controls just below must stay
# exit 0, so a regression to "any docs/ string" or "any *.md" flips one of the pair.
triv() { printf '{"ticket":1,"outcome":"trivial","provenance":"x","recirc_count":0,"cascade_depth":0,"grant":{"issue":1,"paths":["%s"],"change":"y"}}' "$1"; }
echo "$(triv 'src/app.py')"           > "$WORK/triv-src.json"
assert_fail "$WORK/triv-src.json"     "trivial grant.paths naming a SOURCE file (src/app.py) — not a doc"
echo "$(triv '/etc/passwd')"          > "$WORK/triv-abs.json"
assert_fail "$WORK/triv-abs.json"     "trivial grant.paths with an ABSOLUTE path — repo escape"
echo "$(triv '../escape.md')"         > "$WORK/triv-esc.json"
assert_fail "$WORK/triv-esc.json"     "trivial grant.paths with a '..' segment — parent-dir escape"
echo "$(triv 'docs/specs/')"          > "$WORK/triv-dir.json"
assert_fail "$WORK/triv-dir.json"     "trivial grant.paths naming a DIRECTORY (trailing /) — must be a file"
echo "$(triv 'docs/workflow/foo.md')" > "$WORK/triv-govdir.json"
assert_fail "$WORK/triv-govdir.json"  "trivial grant.paths under a GOVERNING subdir (docs/workflow/) — gate-disciplined surface"
echo "$(triv 'docs/plans/bar.md')"    > "$WORK/triv-plans.json"
assert_fail "$WORK/triv-plans.json"   "trivial grant.paths under docs/plans/ — governing plan layer"
echo "$(triv 'CLAUDE.md')"            > "$WORK/triv-rootmd.json"
assert_fail "$WORK/triv-rootmd.json"  "trivial grant.paths naming root CLAUDE.md — governing instruction file"
echo "$(triv 'docs/AGENTS.md')"       > "$WORK/triv-govbase.json"
assert_fail "$WORK/triv-govbase.json" "trivial grant.paths naming a governing basename (docs/AGENTS.md)"
echo "$(triv 'docs/specs/x.ts')"      > "$WORK/triv-srcext.json"
assert_fail "$WORK/triv-srcext.json"  "trivial grant.paths naming a source extension under docs/ (x.ts)"
# canonical_doc controls (red-when-broken pair): subordinate artifacts under docs/ MUST still exit 0.
echo "$(triv 'docs/specs/x.json')" > "$WORK/triv-doc.json"
[ "$(co_rc_ok "$WORK/triv-doc.json")" = "0" ] || fail "trivial grant.paths naming a subordinate doc (docs/specs/x.json) must still exit 0 (scope check must not over-reject)"
echo "$(triv 'docs/specs/canonical-commit-notification.schema.json')" > "$WORK/triv-schema.json"
[ "$(co_rc_ok "$WORK/triv-schema.json")" = "0" ] || fail "trivial grant.paths naming a schema mirror (*.schema.json) must still exit 0"
# malformed JSON
printf '{not json' > "$WORK/bad.json"
assert_fail "$WORK/bad.json" "malformed JSON"
# missing file
assert_fail "$WORK/does-not-exist.json" "missing closeout file"

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

# command/agent parity for the trivial grant-build exception (Major 5): commands/build.md must carry
# the SAME consultant-authorized trivial doc-edit exception the Build playbook grants (a regression
# that drops it from the command entry would make a bootstrapped session reject a valid trivial
# closeout). Pinned to grant-build + the trivial/exception tokens so a bare "never edit docs" line
# (the old rule) does NOT satisfy it.
hasflat "$BUILD_CMD" 'grant-build[^.]*(trivial|exception|canonical.doc)|(trivial|exception)[^.]*grant-build' \
  || fail "commands/build.md must document the consultant-authorized grant-build trivial doc-edit exception"
hasflat "$BUILD_CMD" 'never edit canonical docs|builders never edit canonical' \
  || fail "commands/build.md must STILL preserve the no-canonical-doc-edit rule (the exception is carved out of it, it does not replace it)"

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
# Minor 4: closeout AND trivial are BOTH required command-surface terms — the old `closeout|trivial`
# grep passed if EITHER term survived, so a future edit deleting the trivial outcome would stay green.
# Split into two independent greps so each must be present.
has "$RECIRC_CMD" 'closeout' \
  || fail "commands/recirculate.md must reference the structured closeout"
has "$RECIRC_CMD" 'trivial|grant-build' \
  || fail "commands/recirculate.md must reference the trivial / grant-build outcome"

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

echo "PASS: closeout validator emits one structured JSON dispatch per outcome (verb + int ticket + int recirc_count/cascade_depth; carries grant.change), fail-closes (exit 2 + ZERO stdout) on every malformed handoff (incl. non-int ticket, missing/negative counts, injection-delimited scalars, out-of-scope/governing grant.paths), and keeps subordinate docs green; build spawns+routes the consultant per event, commands/build.md carries the trivial grant-build exception; recirculator documents the structured closeout, trivial grant-Build outcome (separate doc PR via staging), gated cmux ping, and the paused origin-issue record; Plan re-links the paused issue off the retired ticket onto new unblockers + nudges the parent on completion; the adapter realizes recirc/plan workers in every runtime with a no-team subagent/inline fallback"
