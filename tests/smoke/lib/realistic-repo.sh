#!/bin/bash
# realistic-repo.sh — shared smoke fixtures: a REALISTIC, already-set-up IDC repo (filled configs),
# not just a blank scaffold. Tests that only exercise blank scaffolds miss real-world bugs — the
# 2.1.3 /idc:update footgun only appeared on a *filled-in* config, never on a fresh stub. Source this
# and call the makers. The caller must set $PLUGIN to the plugin root.
#
#   make_realistic_repo DIR [BACKEND]   scaffold + fill configs with real-looking operator data
#                                       (domains, field_ids, project_number) + stamp a receipt with
#                                       the two data configs --customized — a repo a few /idc:init +
#                                       /idc:plan cycles in. BACKEND defaults to github.
#   make_legacy_repo DIR                like make_realistic_repo but an OLDER schema (tracker-config
#                                       lacks the Stage field) with a pre-guard receipt (data configs
#                                       state: stamped) — the "init'd at an older version, now
#                                       upgrading" case.

# Inject real-looking operator data the way /idc:init's agent phase does (domains + tracker ids).
_realistic_fill_configs() {
  local dir="$1"
  python3 - "$dir/WORKFLOW-config.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("domains: []", """domains:
  - name: api-data
    brief: Next.js API routes, Prisma ORM, request validation
    surfaces: [src/app/api/, prisma/, src/lib/validations/]
  - name: auth-security
    brief: NextAuth sessions, ownership authorization, middleware
    surfaces: [src/auth.ts, src/middleware.ts, src/lib/auth/]""")
open(p, "w").write(s)
PY
  python3 - "$dir/docs/workflow/tracker-config.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('{{TRACKER_PROJECT_NUMBER}}', '7')
for f in ("Status", "Stage", "Wave", "Phase", "Domain"):
    s = s.replace(f + ': ""', f + ': "PVTSSF_real_' + f.lower() + '"')
open(p, "w").write(s)
PY
}

make_realistic_repo() {
  local dir="$1" backend="${2:-github}"
  mkdir -p "$dir"
  bash "$PLUGIN/scripts/idc_init_scaffold.sh" "$PLUGIN" "$dir" "RealProj" "$backend" >/dev/null || return 1
  _realistic_fill_configs "$dir" || return 1
  ( cd "$dir" && python3 "$PLUGIN/scripts/idc_receipt_check.py" stamp --repo "$dir" \
      --out docs/workflow/install-receipt.yaml --written-by idc:init \
      --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
      WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml \
      docs/workflow/README.md docs/workflow/pillar-matrices/.gitkeep \
      docs/workflow/code-reviews/.gitkeep >/dev/null )
}

make_legacy_repo() {
  local dir="$1"
  make_realistic_repo "$dir" github || return 1
  # Older schema: the pre-Stage tracker-config had no Stage field.
  python3 - "$dir/docs/workflow/tracker-config.yaml" <<'PY'
import sys
p = sys.argv[1]
open(p, "w").write("\n".join(l for l in open(p).read().splitlines() if "Stage:" not in l) + "\n")
PY
  # Pre-guard receipt: re-stamp the two data configs state: stamped (no --customized).
  ( cd "$dir" && python3 "$PLUGIN/scripts/idc_receipt_check.py" stamp --repo "$dir" \
      --out docs/workflow/install-receipt.yaml --written-by idc:init \
      WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml \
      docs/workflow/README.md docs/workflow/pillar-matrices/.gitkeep \
      docs/workflow/code-reviews/.gitkeep >/dev/null )
}
