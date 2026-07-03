#!/bin/bash
# lib.sh — shared seed helpers for the glob-driven governance lane (tests/smoke/governance/).
#
# The governance lane holds red-when-broken scenarios that seed a filesystem-backend board at a
# chosen Stage+Status, then assert a deterministic signal (drain verdict, board-lint finding,
# atomic-create invariant, janitor RESUME-RECIRC finding). This file is a SOURCED helper — it is
# NOT a scenario (phase-governance.sh excludes `lib.sh` and any `_*.sh` from the runnable glob), so
# it never runs on its own.
#
# The filesystem tracker backend (scripts/idc_tracker_fs.py) IS the seed primitive: its `create`
# op writes an issue at a chosen --stage/--status atomically (one fsync+os.replace). These wrappers
# just give the four writers ONE discoverable entry point so they don't each re-derive the paths.
#
# Usage (from a scenario):
#   . "$(dirname "$0")/lib.sh"          # source it
#   T="$(gov_new_tracker)"              # a fresh throwaway TRACKER.md (remember to rm its dir)
#   trap 'rm -rf "$(dirname "$T")"' EXIT
#   n="$(gov_seed_item "$T" --title 'recirc: x' --stage Recirculation --status Todo)"
#   gov_query "$T" --stage Recirculation --status Todo    # -> newline-separated issue numbers
#
# Every helper returns non-zero (and the wrapped python's stderr) on failure, so a scenario's
# `|| fail ...` catches a broken seed instead of asserting against an empty board.

# Repo root: governance/ is tests/smoke/governance, so ../../.. is the plugin root. Resolved from
# THIS file's location so a scenario need not compute $PLUGIN itself.
GOV_PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GOV_TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
GOV_ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"

# gov_fail <msg> — the shared failure exit every scenario uses (was redefined identically in each).
gov_fail() { echo "FAIL: $1"; exit 1; }

# gov_engine_env — the one-line preamble for a transition-engine scenario. Verifies the engine
# exists, mints a fresh throwaway repo (TRACKER.md + its dir as the --repo root), installs the
# cleanup trap, and defines `eng` (the engine CLI pinned to that repo/tracker on the filesystem
# backend). After sourcing lib.sh, a scenario just calls `gov_engine_env` and then uses `eng …`,
# `$T`, `$REPO`. Sets globals: ENGINE, T, REPO, and the `eng`/`fail` functions.
gov_engine_env() {
  ENGINE="$GOV_ENGINE"
  [ -f "$ENGINE" ] || { echo "FAIL: transition engine not found at $ENGINE (not implemented yet)"; exit 1; }
  T="$(gov_new_tracker)" || { echo "FAIL: gov_new_tracker could not init a throwaway TRACKER.md"; exit 1; }
  REPO="$(dirname "$T")"
  trap 'rm -rf "$REPO"' EXIT
  eng() { python3 "$ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" "$@"; }
  fail() { echo "FAIL: $1"; exit 1; }
}

# gov_new_tracker -> echoes the path to a freshly-init'd TRACKER.md inside a NEW temp dir.
# The caller owns cleanup of that dir (e.g. `trap 'rm -rf "$(dirname "$T")"' EXIT`).
gov_new_tracker() {
  local d
  d="$(mktemp -d)" || return 1
  python3 "$GOV_TRK" --tracker "$d/TRACKER.md" init >/dev/null || return 1
  printf '%s' "$d/TRACKER.md"
}

# gov_seed_item <tracker> [create-args…] -> echoes the new issue number.
# Passes every remaining arg straight through to `idc_tracker_fs.py create`, so the full create
# surface is available: --title (required) --stage --status --wave --phase --domain --blocked-by.
#   n="$(gov_seed_item "$T" --title 'x' --stage Buildable --status Todo)"
gov_seed_item() {
  local trk="$1"; shift
  python3 "$GOV_TRK" --tracker "$trk" create "$@"
}

# gov_query <tracker> [query-args…] -> echoes matching issue numbers (one per line).
# Thin pass-through to `idc_tracker_fs.py query` (--stage/--status/--wave/--phase/--domain).
gov_query() {
  local trk="$1"; shift
  python3 "$GOV_TRK" --tracker "$trk" query "$@"
}

# gov_field <tracker> <num> <Field> -> echoes one field's value (Status/Stage/Wave/Phase/Domain).
gov_field() {
  python3 "$GOV_TRK" --tracker "$1" show --num "$2" --field "$3"
}
