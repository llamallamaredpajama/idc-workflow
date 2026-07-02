#!/bin/bash
# idc-assert-class: behavior
# Phase 7 (update template-path mapping) smoke — fix/update-template-mapping Finding B.
#
# /idc:update must resolve each governed file's TEMPLATE SOURCE through the single shared resolver
# scripts/idc_template_for.py — never by basename or path-tail. The latent footgun: the governed
# docs/workflow/README.md and the templates-dir doc templates/README.md are DIFFERENT files; a
# loose path-tail derivation can pick templates/README.md and clobber the governed README. The
# resolver must map docs/workflow/<rest> -> templates/docs-tree/<rest>, with the three top-level
# files special-cased, mirroring idc_init_scaffold.sh EXACTLY (one source of truth, can't drift).
#
# Hermetic: pure mapping assertions against the real templates dir; no GitHub, no sandbox writes.
#
# Usage: bash tests/smoke/phase7-update-template-mapping.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_template_for.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "template resolver not found at $HELPER (B2: scripts/idc_template_for.py)"

# resolve DEST -> absolute template source under PLUGIN/templates
resolve() { python3 "$HELPER" --plugin-root "$PLUGIN" "$1"; }

# 1. The collision case: docs/workflow/README.md MUST resolve to docs-tree/README.md, never the
#    unrelated templates/README.md (the templates-dir doc).
got="$(resolve docs/workflow/README.md)" || fail "resolver exited non-zero for docs/workflow/README.md"
[ "$got" = "$PLUGIN/templates/docs-tree/README.md" ] \
  || fail "docs/workflow/README.md resolved to '$got' (must be templates/docs-tree/README.md)"
[ "$got" != "$PLUGIN/templates/README.md" ] \
  || fail "docs/workflow/README.md resolved to the templates-dir doc templates/README.md — the clobber bug"

# 2. The three top-level special cases (mirror idc_init_scaffold.sh's explicit copies).
[ "$(resolve WORKFLOW.md)" = "$PLUGIN/templates/WORKFLOW.md" ] \
  || fail "WORKFLOW.md must map to templates/WORKFLOW.md"
[ "$(resolve WORKFLOW-config.yaml)" = "$PLUGIN/templates/WORKFLOW-config.yaml" ] \
  || fail "WORKFLOW-config.yaml must map to templates/WORKFLOW-config.yaml"
[ "$(resolve docs/workflow/tracker-config.yaml)" = "$PLUGIN/templates/tracker-config.yaml" ] \
  || fail "docs/workflow/tracker-config.yaml must map to templates/tracker-config.yaml (top-level, NOT docs-tree/)"

# 3. Nested docs-tree entries map under docs-tree/.
[ "$(resolve docs/workflow/code-reviews/.gitkeep)" = "$PLUGIN/templates/docs-tree/code-reviews/.gitkeep" ] \
  || fail "docs/workflow/code-reviews/.gitkeep must map under docs-tree/"

# 4. Every resolved source actually exists (resolver validates against disk under --plugin-root).
for d in WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml docs/workflow/README.md; do
  src="$(resolve "$d")" || fail "resolver failed for $d"
  [ -e "$src" ] || fail "resolved source for $d does not exist: $src"
done

# 5. Non-governed / non-template paths are rejected (the caller must not guess a template), exit 3 —
#    docs/workflow/install-receipt.yaml has no docs-tree/ template; src/main.py is out of scope.
if resolve docs/workflow/install-receipt.yaml >/dev/null 2>&1; then
  fail "resolver must reject docs/workflow/install-receipt.yaml (no template for the receipt)"
fi
if resolve src/main.py >/dev/null 2>&1; then
  fail "resolver must reject a non-governed path (src/main.py)"
fi

# 6. Scaffold parity: every docs-tree entry resolves back to itself via docs/workflow/<name>, so the
#    resolver and idc_init_scaffold.sh can never disagree about where a governed file comes from.
for entry in "$PLUGIN/templates/docs-tree/"*; do
  name="$(basename "$entry")"
  got="$(resolve "docs/workflow/$name")" || fail "resolver failed for docs/workflow/$name"
  [ "$got" = "$PLUGIN/templates/docs-tree/$name" ] || fail "docs-tree parity broke for $name (got '$got')"
done

echo "PASS: idc_template_for.py maps governed dests to the right template (docs-tree disambiguated, scaffold parity)"
