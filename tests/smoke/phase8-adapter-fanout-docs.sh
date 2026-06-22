#!/bin/bash
# Phase 8 adapter fan-out docs smoke — the TWO-LEVEL fan-out + worktree topology is documented
# cross-adapter, not Claude-only (issue sb-78). Each of the three runtime adapters
# (idc-adapter-claude / idc-adapter-codex / idc-adapter-pi) must document, in the SAME shape:
#   (1) the two-level fan-out primitive — an OUTER durable-worker sous-chef (area owner) whose
#       INNER level is bounded fan-out to line cooks, each cook on a DISJOINT sub-surface; and
#   (2) the cook -> area-staging -> merge worktree topology (worktree-per-cook): each line cook
#       runs in its OWN worktree, the cooks converge onto the area's staging branch, and the
#       sous-chef merges that staging branch (under the runtime's serialized merge mechanism).
# Plus each adapter's CONCRETE inner-fan-out mechanic, so a section can't be empty boilerplate:
#   claude -> the Workflow tool pipeline() with isolation:'worktree' per cook;
#   codex  -> spawn_agent / codex exec --ephemeral process fan-out;
#   pi     -> isolated child processes, with the launcher caveat that the N-resident pool is
#             adapter wiring not yet emitted by `idc-pi run`.
# Red-when-broken: removing any adapter's two-level section, its worktree topology, or its
# concrete inner mechanic turns this test red. Docs slice: a structural assertion over the
# shipped skills (no runtime exec, no GitHub) — same shape as phase8-adapter-pi.sh.
#
# Usage: bash tests/smoke/phase8-adapter-fanout-docs.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
CLAUDE="$PLUGIN/skills/idc-adapter-claude/SKILL.md"
CODEX="$PLUGIN/skills/idc-adapter-codex/SKILL.md"
PI="$PLUGIN/skills/idc-adapter-pi/SKILL.md"
fail() { echo "FAIL: $1"; exit 1; }
# case-insensitive extended-regex substring assertion (BSD/GNU grep safe — no \b, no intervals)
has() { grep -qiE "$2" "$1"; }
# whitespace-flattened phrase check: markdown wraps unpredictably, so an ordered chain could
# soft-wrap across lines and dodge a line-based grep. Flatten newlines to spaces first, then
# match — so the guard stays red-when-broken regardless of wrapping. (BSD/GNU-portable: tr only.)
hasflat() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiE "$2"; }
# section extractor: emit ONLY the "## Two-level fan-out …" section (heading exclusive, up to the next
# markdown heading of any level). The per-adapter inner-mechanic checks must hit the NEW section, not
# the pre-existing primitive-map row elsewhere in the file — otherwise dropping the new section's
# concrete mechanic would stay green (the wave/3 "file-wide grep" bypass). (BSD/GNU awk: `#+` is ERE.)
section() { awk '/^## [Tt]wo-level fan.out/{f=1;next} f&&/^#+ /{f=0} f' "$1"; }
SECDIR="$(mktemp -d)"; trap 'rm -rf "$SECDIR"' EXIT
has_sec()     { grep -qiE "$2" "$1"; }
hasflat_sec() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiE "$2"; }

# ---- all three adapters exist -----------------------------------------------------------------
for f in "$CLAUDE" "$CODEX" "$PI"; do
  [ -f "$f" ] || fail "adapter skill not found at $f"
done
# extract each adapter's two-level section to its own file; a section that fails to extract (empty)
# fails closed below (the mechanic greps go red).
section "$CLAUDE" > "$SECDIR/claude"; CLAUDE_SEC="$SECDIR/claude"
section "$CODEX"  > "$SECDIR/codex";  CODEX_SEC="$SECDIR/codex"
section "$PI"     > "$SECDIR/pi";     PI_SEC="$SECDIR/pi"
[ -s "$CLAUDE_SEC" ] || fail "idc-adapter-claude two-level fan-out section missing/empty (extraction failed)"
[ -s "$CODEX_SEC" ]  || fail "idc-adapter-codex two-level fan-out section missing/empty (extraction failed)"
[ -s "$PI_SEC" ]     || fail "idc-adapter-pi two-level fan-out section missing/empty (extraction failed)"

# ---- (1) the two-level fan-out primitive, documented the SAME way in ALL THREE ----------------
for f in "$CLAUDE" "$CODEX" "$PI"; do
  name="$(basename "$(dirname "$f")")"
  has "$f" 'two-level fan.out' \
    || fail "$name must name the TWO-LEVEL fan-out primitive (outer sous-chef + inner line cooks)"
  has "$f" 'sous-chef' \
    || fail "$name must name the OUTER level — the durable-worker sous-chef (area owner)"
  has "$f" 'line cook' \
    || fail "$name must name the INNER level — bounded fan-out to line cooks"
  has "$f" 'disjoint' \
    || fail "$name must state the cooks own DISJOINT sub-surfaces (no two cooks race on one file)"
done

# ---- (2) the cook -> area-staging -> merge worktree topology (worktree-per-cook) ---------------
for f in "$CLAUDE" "$CODEX" "$PI"; do
  name="$(basename "$(dirname "$f")")"
  has "$f" 'worktree.per.cook' \
    || fail "$name must name the worktree-per-cook topology (each line cook in its OWN worktree)"
  has "$f" 'area.stag|staging branch' \
    || fail "$name must name the area-staging branch the cooks converge onto"
  # the FULL ordered chain cook -> area-staging -> merge, on flattened prose. Red-when-broken:
  # drop the topology sentence and the ordered chain disappears. The [^.]* spans are bounded to a
  # single sentence (periods excluded), so three unrelated mentions scattered across the file
  # cannot satisfy it — only the real ordered topology sentence passes.
  hasflat "$f" 'cook[^.]*area.stag[^.]*merge' \
    || fail "$name must document the ORDERED cook -> area-staging -> merge topology in one sentence"
done

# ---- per-adapter CONCRETE inner-fan-out mechanic (a section can't be empty boilerplate) --------
# Scoped to the NEW two-level section (not the whole file): the pre-existing primitive-map row already
# names these tokens, so a file-wide grep would stay green even if the new section lost its mechanic.
# claude: the Workflow tool pipeline() with isolation:'worktree' per cook
has_sec "$CLAUDE_SEC" 'workflow'   || fail "claude adapter's two-level section must name the Workflow tool"
has_sec "$CLAUDE_SEC" 'pipeline\(' || fail "claude adapter's two-level section must name pipeline()"
has_sec "$CLAUDE_SEC" 'isolation'  || fail "claude adapter's two-level section must name isolation:'worktree' per cook"
# codex: spawn_agent / codex exec --ephemeral process fan-out
has_sec "$CODEX_SEC" 'spawn_agent' || fail "codex adapter's two-level section must name spawn_agent"
has_sec "$CODEX_SEC" 'ephemeral'   || fail "codex adapter's two-level section must name --ephemeral process fan-out"
# codex DOCS ACCURACY: worktree-per-cook is realized by the --ephemeral PROCESS path; spawn_agent
# sub-agents INHERIT the thread's worktree (no per-agent --cd). Red-when-broken: the original wording
# applied "--cd'd into its own pre-created worktree" to BOTH paths, overstating spawn_agent isolation.
hasflat_sec "$CODEX_SEC" 'spawn_agent[^.]*inherit[^.]*(thread|worktree)|inherit[^.]*(thread|worktree)[^.]*\(?no per-agent' \
  || fail "codex adapter must state spawn_agent sub-agents INHERIT the thread's worktree (no per-agent --cd) — not their own worktree"
hasflat_sec "$CODEX_SEC" 'worktree.per.cook[^.]*ephemeral|ephemeral[^.]*(process )?[^.]*worktree.per.cook|ephemeral[^.]*process[^.]*--cd' \
  || fail "codex adapter must scope worktree-per-cook to the --ephemeral PROCESS path (not spawn_agent)"
# pi: isolated child processes + the launcher caveat (N-resident pool not yet emitted by idc-pi run)
has_sec "$PI_SEC" 'child.process'  || fail "pi adapter's two-level section must name isolated child processes"
hasflat_sec "$PI_SEC" 'idc-pi run' || fail "pi adapter's two-level section must carry the launcher caveat naming idc-pi run"
hasflat_sec "$PI_SEC" 'not yet|adapter[^.]*wiring|adapter-driven' \
  || fail "pi adapter caveat must state the N-resident pool is adapter wiring not yet emitted by idc-pi run"

echo "PASS: all three adapters document the two-level fan-out + cook->area-staging->merge worktree topology"
