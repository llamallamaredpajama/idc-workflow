#!/bin/bash
# Phase 8 model-ladder smoke — the model-escalation ladder (design doc §D / issue #105): the
# user's standing principle is deterministic wherever possible; then latest Sonnet for easy/
# mechanical work; Opus when something looks risky or questionable; Fable only when truly stuck;
# the human last — as an information source, not a judge. Full chain in
# templates/WORKFLOW-config.yaml's model_routing header comment.
#
# doc: assertions — the ladder is named end-to-end in templates/WORKFLOW-config.yaml (rung 0
# "deterministic" as ladder philosophy, not a resolvable tier — no adapter ever looks it up, since
# those roles call a script directly), the three Claude-resolvable tiers carry the
# mechanical->Sonnet / risk->Opus / stuck->Fable mapping, a per-role `overrides` knob mirrors the
# pi runtime's PI_IDC_<ROLE>_MODEL / PI_IDC_MODEL pattern, and the human-last-as-information-
# source phrasing is present; plus all three runtime adapters document the ladder in parity
# (Codex's parity = keeping its untiered posture explicit, not adopting the ladder).
# behavior: assertion — the CLAUDE-resolvable tiers actually parse to the right concrete model
# ids (utility->sonnet, standard->opus, reasoning->fable), extracted directly off the shipped
# config the same way the adapter's tier resolution would.
#
# Red-when-broken: strip the RISKY-janitor/Opus escalation sentence from `standard`'s `use:` and
# the risk->Opus doc check fails; swap `standard`'s model id and the behavior assertion fails.
#
# Usage: bash tests/smoke/phase8-model-ladder.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="$PLUGIN/templates/WORKFLOW-config.yaml"
CLAUDE="$PLUGIN/skills/idc-adapter-claude/SKILL.md"
CODEX="$PLUGIN/skills/idc-adapter-codex/SKILL.md"
PI="$PLUGIN/skills/idc-adapter-pi/SKILL.md"
fail() { echo "FAIL: $1"; exit 1; }
# case-insensitive extended-regex substring assertion (BSD/GNU grep safe — no \b, no intervals)
has() { grep -qiE "$2" "$1"; }
# extract ONLY the model_routing: mapping body (top-level key, so any dedent back to column 0
# ends it) into its own file, so checks below can't accidentally match unrelated file content.
section() { awk '/^model_routing:/{f=1;next} f&&/^[A-Za-z]/{f=0} f' "$1"; }

for f in "$CONFIG" "$CLAUDE" "$CODEX" "$PI"; do
  [ -f "$f" ] || fail "expected file not found: $f"
done

MR="$(mktemp)"; trap 'rm -f "$MR"' EXIT
section "$CONFIG" > "$MR"
[ -s "$MR" ] || fail "model_routing: block not found/empty in templates/WORKFLOW-config.yaml"
# flatten once (newlines -> spaces); YAML `>-` block scalars fold onto one logical line but this
# extraction keeps the raw line breaks, so a phrase can wrap across lines and dodge a line-based
# grep. Check the flattened form throughout. (BSD/GNU-portable: tr only.)
MR_FLAT="$(tr '\n' ' ' < "$MR" | tr -s ' ')"
hasflat_mr() { printf '%s' "$MR_FLAT" | grep -qiE "$1"; }

# ---- doc: rung 0 (deterministic) is documented as ladder philosophy, never a resolvable tier ---
# (no adapter looks this up — the roles it names call a script directly), so it lives in the
# header comment, not as a fake model_routing sibling key.
has "$CONFIG" 'deterministic' \
  || fail "WORKFLOW-config.yaml must name the 'deterministic' ladder rung (no model — a script runs directly)"

# ---- doc: mechanical -> Sonnet (utility tier) --------------------------------------------------
hasflat_mr 'utility:.*claude-sonnet' \
  || fail "the utility (Sonnet) tier must resolve to a claude-sonnet model id"
hasflat_mr 'tracker ops' && hasflat_mr 'janitor triage' && hasflat_mr 'marker emission' && hasflat_mr 'board reads' \
  || fail "model_routing must assign the mechanical roles (tracker ops/janitor triage/marker emission/board reads) to the Sonnet rung"

# ---- doc: risk-flagged -> Opus (standard tier) — RED-WHEN-BROKEN if this text is stripped ------
hasflat_mr 'standard:.*claude-opus' \
  || fail "the standard (Opus) tier must resolve to a claude-opus model id"
hasflat_mr 'risky' && hasflat_mr 'janitor' && hasflat_mr 'recirc consultant' && hasflat_mr 'review escalation' \
  || fail "model_routing must route risk-flagged findings (RISKY janitor tier / recirc consultant on a cascade / review escalations) to Opus"

# ---- doc: Fable reserved for stuck-state, never a blanket default -----------------------------
hasflat_mr 'reasoning:.*claude-fable' \
  || fail "the reasoning (Fable) tier must resolve to a claude-fable model id"
hasflat_mr 'stuck' || fail "model_routing must state Fable is reserved for genuinely stuck-state escalation"

# ---- doc: human last, as an information source, never a judge ---------------------------------
has "$CONFIG" 'human' || fail "WORKFLOW-config.yaml must name the human as the last ladder rung"
has "$CONFIG" 'information source' \
  || fail "WORKFLOW-config.yaml must phrase human gates as an information source, never a rubber-stamp judge"

# ---- doc: per-role overrides mirror the pi PI_IDC_<ROLE>_MODEL / PI_IDC_MODEL pattern ----------
hasflat_mr 'overrides' || fail "model_routing must carry a per-role overrides knob"
has "$CONFIG" 'PI_IDC_.*MODEL' \
  || fail "WORKFLOW-config.yaml's overrides knob must mirror the pi PI_IDC_<ROLE>_MODEL / PI_IDC_MODEL pattern"

# ---- doc: all three adapters document the ladder, in parity -----------------------------------
for f in "$CLAUDE" "$PI"; do
  name="$(basename "$(dirname "$f")")"
  tr '\n' ' ' < "$f" | tr -s ' ' | grep -qiE 'model.escalation ladder' \
    || fail "$name must document the model-escalation ladder"
done
CODEX_FLAT="$(tr '\n' ' ' < "$CODEX" | tr -s ' ')"
printf '%s' "$CODEX_FLAT" | grep -qiE 'model.escalation ladder' \
  || fail "codex adapter must acknowledge the model-escalation ladder (documenting its untiered posture as the parity contract, not adopting the ladder)"
printf '%s' "$CODEX_FLAT" | grep -qiE 'untiered' \
  || fail "codex adapter must keep documenting its untiered posture (parity = the contract expressed identically, not Codex changing its model policy)"

# ---- behavior: the CLAUDE-resolvable tiers extract to the right concrete model ids -------------
# Dependency-free structural parse (mirrors scripts/idc_config_keys.py's approach — no PyYAML):
# walk model_routing's top-level tier keys and pull each tier's `claude.model` value, exactly the
# lookup the Claude adapter performs (`model_routing.<tier>.claude.model`). `deterministic` is
# deliberately absent here — it's ladder philosophy, never a key an adapter resolves.
resolved="$(python3 - "$MR" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
tiers = {}
cur = None
for line in lines:
    m = re.match(r'^  ([A-Za-z_][\w-]*):\s*$', line)
    if m:
        cur = m.group(1)
        continue
    if cur and re.match(r'^    claude:', line):
        mm = re.search(r'model:\s*"?([\w.\-]+|null)"?', line)
        if mm:
            tiers[cur] = mm.group(1)
for k in ('utility', 'standard', 'reasoning'):
    print(f"{k}={tiers.get(k, '')}")
PY
)"
echo "$resolved" | grep -qx 'utility=claude-sonnet-4-6' \
  || fail "behavior: utility tier must resolve claude.model to claude-sonnet-4-6 — got: $resolved"
echo "$resolved" | grep -qx 'standard=claude-opus-4-8' \
  || fail "behavior: standard tier must resolve claude.model to claude-opus-4-8 — got: $resolved"
echo "$resolved" | grep -qx 'reasoning=claude-fable-5' \
  || fail "behavior: reasoning tier must resolve claude.model to claude-fable-5 — got: $resolved"

echo "PASS: model-escalation ladder encoded in model_routing (Sonnet/Opus/Fable tiers + deterministic/human ladder philosophy + per-role overrides) and documented in parity across all three runtime adapters"
