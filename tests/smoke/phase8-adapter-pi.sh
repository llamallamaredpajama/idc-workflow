#!/bin/bash
# idc-assert-class: doc
# Phase 8 adapter smoke — skills/idc-adapter-pi maps the three abstract runtime primitives
# (WORKFLOW.md §5) onto the pi / coms-net flat-peer runtime in the SAME shape as the other two
# adapters, so callers stay runtime-blind (issue #29, te-B2):
#   (a) skills/idc-adapter-pi/SKILL.md exists and its primitive table maps EACH of the three
#       primitives the same way idc-adapter-claude / idc-adapter-codex do — durable worker →
#       standing coms-net resident, bounded fan-out → ephemeral helper / child-process, goal
#       loop → /fullauto-goal — and the same three bold primitive labels appear in all three
#       adapter files (parallel interface);
#   (b) it carries the Build-stage WORKED EXAMPLE: 1 build resident running build.md spawning N
#       implementer residents + review fan-out + finisher, realizing the A2 triplet as residents
#       and NAMING the merge-serialization mechanism (the pi-row board-backed merge lease over
#       matrix-disjoint surfaces, fail-closed), honoring the glass-wall ACL and single-source.
# Docs slice: a structural assertion over the shipped skill (no runtime exec, no GitHub).
#
# Usage: bash tests/smoke/phase8-adapter-pi.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
PI="$PLUGIN/skills/idc-adapter-pi/SKILL.md"
CLAUDE="$PLUGIN/skills/idc-adapter-claude/SKILL.md"
CODEX="$PLUGIN/skills/idc-adapter-codex/SKILL.md"
fail() { echo "FAIL: $1"; exit 1; }
# case-insensitive extended-regex substring assertion (BSD/GNU grep safe — no \b)
has() { grep -qiE "$2" "$1"; }

# ---- (a) the new pi adapter exists and parallels the other two ---------------------
[ -f "$PI" ]     || fail "pi adapter not found at $PI (not implemented yet)"
[ -f "$CLAUDE" ] || fail "idc-adapter-claude missing at $CLAUDE (cannot check parallel shape)"
[ -f "$CODEX" ]  || fail "idc-adapter-codex missing at $CODEX (cannot check parallel shape)"

# Same three bold primitive labels in ALL THREE adapters (runtime-blind parallel interface).
for f in "$PI" "$CLAUDE" "$CODEX"; do
  for prim in 'durable worker' 'bounded fan-out' 'goal loop'; do
    has "$f" "\*\*${prim}\*\*" || fail "$(basename "$(dirname "$f")") missing primitive label: **$prim**"
  done
done

# Each primitive mapped the pi way.
has "$PI" 'durable worker'                  || fail "pi adapter must map the durable-worker primitive"
has "$PI" 'standing.*resident|resident'     || fail "durable worker must map to a standing coms-net resident"
has "$PI" 'bounded fan-out'                 || fail "pi adapter must map the bounded-fan-out primitive"
has "$PI" 'ephemeral|child.process|helper'  || fail "bounded fan-out must map to an ephemeral helper / child-process"
has "$PI" 'goal loop'                       || fail "pi adapter must map the goal-loop primitive"
has "$PI" '/fullauto-goal'                  || fail "goal loop must map to /fullauto-goal"

# Single-source + glass-wall ACL honored (no playbook forks; downstream-only sends).
has "$PI" 'single.source'        || fail "pi adapter must state the playbooks stay single-source (no forks)"
has "$PI" 'glass.wall'           || fail "pi adapter must honor the glass-wall ACL"
has "$PI" 'downstream'           || fail "glass-wall ACL must be directional (downstream-only sends)"
has "$PI" 'fail.closed'          || fail "glass-wall ACL must be fail-closed"

# ---- (b) the Build-stage worked example + merge-serialization mechanism -------------
has "$PI" 'worked example'           || fail "pi adapter must carry the Build-stage worked example"
has "$PI" 'build\.md'                || fail "worked example must name the build resident running build.md"
has "$PI" 'implementer'              || fail "worked example must spawn implementer residents"
has "$PI" 'review fan-out|review'    || fail "worked example must include the review fan-out"
has "$PI" 'finisher'                 || fail "worked example must include the finisher"
# the A2 triplet realized as residents
has "$PI" 'triplet'                  || fail "worked example must realize the A2 triplet as residents"
has "$PI" 'resident'                 || fail "worked example must realize the triplet roles as residents"
# the merge-serialization mechanism — the pi-row board-backed merge lease, fail-closed
has "$PI" 'merge.serializ|serializ'  || fail "worked example must name the merge-serialization mechanism"
has "$PI" 'board-backed'             || fail "pi merge mechanism must be the board-backed merge lease"
has "$PI" 'lease'                    || fail "pi merge mechanism must name the single-holder merge lease"
has "$PI" 'matrix-disjoint|disjoint' || fail "pi merge mechanism must name matrix-disjoint surfaces"
has "$PI" 'no master orchestrator|no master' || fail "pi merge mechanism rests on the flat pool having no master orchestrator"

echo "PASS: idc-adapter-pi primitive mapping parallels the two adapters + Build worked example/merge-lease green"
