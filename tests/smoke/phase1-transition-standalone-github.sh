#!/bin/bash
# idc-assert-class: behavior
# Phase 1 (transition engine, github backend) smoke — the STANDALONE door contract.
#
# ROOT CAUSE this guards (session 4731f696, 2026-08-09, idc-workflow 6.0.0): `idc_transition.py`
# built its github ctx STRAIGHT from --owner/--project (both default None). Every command playbook
# resolves and passes both flags, so inside an active /idc:* command the hole never showed; run
# STANDALONE (an agent journaling a board write outside a command) the None owner flowed unchecked
# into the `gh` argv and the door died with a raw `TypeError: expected str, bytes or os.PathLike
# object, not NoneType` deep in subprocess. A crashed door forces the exact fallback the mutation
# interlock forbids — a raw `gh project item-edit` — which is precisely what the reporting agent did.
#
# The contract under test: the single sanctioned write door WORKS standalone — owner from
# `gh repo view`, project from tracker-config.yaml::project_number, exactly the playbook preamble's
# own recipe — or REFUSES cleanly (exit 2, `idc-transition:` prefix, names the missing prerequisite).
# It never tracebacks, and explicit --owner/--project still bypass resolution entirely (the active-
# command path runs zero extra gh calls).
#
# Hermetic: no live GitHub — a PATH `gh` stub serves repo-view/project-view/field-list/item-edit/
# graphql and LOGS every call; item-edit flips a state file so the engine's read-back sees the write
# land. Every assertion is red-when-broken (reverts noted inline).
#
# Usage: bash tests/smoke/phase1-transition-standalone-github.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$PLUGIN/scripts/idc_transition.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$ENGINE" ] || fail "engine not found: $ENGINE"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export FIX="$WORK"
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow"

# --- governed-repo fixture: github backend, filled project_number (what /idc:init leaves —
#     including the template's inline comment after the quoted value, which the full-scalar
#     parser must tolerate) ------------------------------------------------------------------------
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'CFG'
backend: github
project_number: "7"     # integer; from `gh project create`
field_ids:
  Status: "F_status"
CFG

# --- board state: issue #708 at Buildable / In Progress; item-edit writes land here --------------
printf 'In Progress' > "$WORK/status.txt"
# item-id cache so the engine resolves #708 without a whole-board read (one less stub endpoint)
printf '708\tPVTI_708\n' > "$WORK/idmap"

# --- gh stub: logs every subcommand; repo-view failure togglable via $FIX/fail-repo-view ---------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/bash
echo "$1 $2" >> "$FIX/gh.log"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  if [ -e "$FIX/fail-repo-view" ]; then echo "gh: not a git repository" >&2; exit 1; fi
  if [ -e "$FIX/ratelimit-repo-view" ]; then echo "API rate limit exceeded for user" >&2; exit 1; fi
  if [ -e "$FIX/garble-repo-view" ]; then printf '\377'; exit 0; fi
  echo "tester"; exit 0
fi
if [ "$1" = "project" ] && [ "$2" = "view" ]; then echo "PVT_test"; exit 0; fi
if [ "$1" = "project" ] && [ "$2" = "field-list" ]; then
  printf '%s' '{"fields":[{"id":"F_status","name":"Status","options":[{"id":"O_blocked","name":"Blocked"},{"id":"O_todo","name":"Todo"},{"id":"O_inprog","name":"In Progress"},{"id":"O_done","name":"Done"}]},{"id":"F_stage","name":"Stage","options":[{"id":"O_build","name":"Buildable"}]}]}'
  exit 0
fi
if [ "$1" = "project" ] && [ "$2" = "item-edit" ]; then
  opt=""; prev=""
  for a in "$@"; do [ "$prev" = "--single-select-option-id" ] && opt="$a"; prev="$a"; done
  case "$opt" in
    O_todo)    printf 'Todo'        > "$FIX/status.txt" ;;
    O_inprog)  printf 'In Progress' > "$FIX/status.txt" ;;
    O_blocked) printf 'Blocked'     > "$FIX/status.txt" ;;
    O_done)    printf 'Done'        > "$FIX/status.txt" ;;
    *) echo "gh stub: unknown option id $opt" >&2; exit 99 ;;
  esac
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  st="$(cat "$FIX/status.txt")"
  printf '{"data":{"node":{"id":"PVTI_708","fieldValues":{"nodes":[{"__typename":"ProjectV2ItemFieldSingleSelectValue","name":"%s","field":{"name":"Status"}},{"__typename":"ProjectV2ItemFieldSingleSelectValue","name":"Buildable","field":{"name":"Stage"}}]},"content":{"__typename":"Issue","number":708,"title":"fixture item","repository":{"nameWithOwner":"tester/repo"}}}}}' "$st"
  exit 0
fi
if [ "$1" = "api" ]; then echo '{}'; exit 0; fi
echo "gh stub: unhandled $*" >&2; exit 99
STUB
chmod +x "$WORK/bin/gh"

run_engine() {  # run_engine <extra args...>; captures combined output + exit code
  OUT="$(PATH="$WORK/bin:$PATH" IDC_ITEMID_CACHE="$WORK/idmap" \
         python3 "$ENGINE" --repo "$REPO" "$@" 2>&1)"; RC=$?
}

# ============================================================================================
# A. STANDALONE move (the session-4731f696 crash shape): no --owner/--project — the door
#    resolves owner via `gh repo view` + project from tracker-config and the move LANDS.
#    (Red: revert the resolution fallback in main() -> TypeError traceback, exit 1.)
# ============================================================================================
: > "$WORK/gh.log"
run_engine move --num 708 --to-status Todo
[ "$RC" = "0" ] || fail "standalone move must succeed (exit 0), got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q "Traceback" && fail "standalone move must never traceback"
grep -q "^repo view$" "$WORK/gh.log" || fail "standalone move must resolve owner via gh repo view"
[ "$(cat "$WORK/status.txt")" = "Todo" ] || fail "standalone move must land the Status write (read-back path), got '$(cat "$WORK/status.txt")'"

# ============================================================================================
# B. Owner unresolvable (gh repo view fails): clean exit-2 refusal NAMING --owner — never a
#    traceback. (Red: revert the fallback -> TypeError, exit 1, no idc-transition: prefix.)
# ============================================================================================
printf 'In Progress' > "$WORK/status.txt"
touch "$WORK/fail-repo-view"
run_engine move --num 708 --to-status Todo
[ "$RC" = "2" ] || fail "owner-unresolvable must refuse with exit 2, got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q "idc-transition:" || fail "owner-unresolvable refusal must carry the idc-transition: prefix"
printf '%s' "$OUT" | grep -q -- "--owner" || fail "owner-unresolvable refusal must name --owner as the way through"
printf '%s' "$OUT" | grep -q "Traceback" && fail "owner-unresolvable must refuse cleanly, never traceback"
rm -f "$WORK/fail-repo-view"

# B2. THROTTLED owner lookup is NOT a denial: a rate-limited `gh repo view` must take the module's
#     resumable exit-3 path with the pinned verdict, never the exit-2 refusal (a drain would record
#     a refused op that merely needs to wait). (Red: classify the throttle as a missing owner.)
touch "$WORK/ratelimit-repo-view"
run_engine move --num 708 --to-status Todo
[ "$RC" = "3" ] || fail "throttled owner lookup must exit 3 (resumable), got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q "rate-limited until" || fail "throttled owner lookup must print the pinned rate-limited verdict"
rm -f "$WORK/ratelimit-repo-view"

# B3. Non-UTF-8 bytes from `gh repo view` stdout: clean exit-2 refusal naming --owner — never a
#     decode traceback. (Red: run the lookup through a raw subprocess with no ValueError handling.)
touch "$WORK/garble-repo-view"
run_engine move --num 708 --to-status Todo
[ "$RC" = "2" ] || fail "garbled owner lookup must refuse with exit 2, got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q -- "--owner" || fail "garbled owner refusal must name --owner as the way through"
printf '%s' "$OUT" | grep -q "Traceback" && fail "garbled owner lookup must refuse cleanly, never traceback"
rm -f "$WORK/garble-repo-view"

# ============================================================================================
# C. project_number unfilled (the pre-init template token): clean exit-2 refusal NAMING
#    project_number / --project — never a traceback.
# ============================================================================================
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'CFG'
backend: github
project_number: "{{TRACKER_PROJECT_NUMBER}}"
CFG
run_engine move --num 708 --to-status Todo
[ "$RC" = "2" ] || fail "unfilled project_number must refuse with exit 2, got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q "project_number" || fail "unfilled-project refusal must name project_number"
printf '%s' "$OUT" | grep -q -- "--project" || fail "unfilled-project refusal must name --project as the way through"
printf '%s' "$OUT" | grep -q "Traceback" && fail "unfilled project_number must refuse cleanly, never traceback"

# C2. PARTIAL-SCALAR read: `project_number: "7#8"` is valid YAML whose scalar is NOT an integer —
#     the old comment-stripping regex read it as 7 and aimed the write at the wrong board. Must
#     refuse, before ANY gh call. (Red: restore the `[^"#\n]*` capture in _config_project_number.)
: > "$WORK/gh.log"
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'CFG'
backend: github
project_number: "7#8"
CFG
run_engine --owner tester move --num 708 --to-status Todo
[ "$RC" = "2" ] || fail "non-integer quoted project_number must refuse with exit 2, got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q "project_number" || fail "non-integer-project refusal must name project_number"
[ ! -s "$WORK/gh.log" ] || fail "non-integer project_number must refuse before any gh call; saw: $(tr '\n' ',' < "$WORK/gh.log")"

# C3. The UNQUOTED twin: YAML only starts an inline comment at a WHITESPACE-preceded `#`, so
#     `project_number: 7#8` is the non-integer scalar "7#8" — the unconditional comment-split read
#     it as 7 (same wrong-board hazard). Must refuse; `7 # comment` must still parse as 7.
#     (Red: split on every "#" instead of only whitespace-preceded ones.)
: > "$WORK/gh.log"
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'CFG'
backend: github
project_number: 7#8
CFG
run_engine --owner tester move --num 708 --to-status Todo
[ "$RC" = "2" ] || fail "unquoted 7#8 project_number must refuse with exit 2, got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q "project_number" || fail "unquoted-7#8 refusal must name project_number"
[ ! -s "$WORK/gh.log" ] || fail "unquoted 7#8 must refuse before any gh call; saw: $(tr '\n' ',' < "$WORK/gh.log")"
printf 'In Progress' > "$WORK/status.txt"
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'CFG'
backend: github
project_number: 7 # unquoted with a real comment
CFG
run_engine --owner tester move --num 708 --to-status Todo
[ "$RC" = "0" ] || fail "unquoted '7 # comment' must still parse as 7 and succeed, got exit $RC: $(printf '%s' "$OUT" | tail -3)"
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'CFG'
backend: github
project_number: "7"
CFG

# ============================================================================================
# D. Unreadable UTF-8 in tracker-config: clean exit-2 refusal, never a decode traceback. The
#    ordinary no-flag path first exercises resolve_backend; the explicit-backend path reaches the
#    new project-only fallback directly. Both readers used to leak UnicodeDecodeError / exit 1.
# ============================================================================================
printf '\377' > "$REPO/docs/workflow/tracker-config.yaml"
run_engine move --num 708 --to-status Todo
[ "$RC" = "2" ] || fail "invalid-UTF8 backend config must refuse with exit 2, got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q "tracker-config.yaml" || fail "invalid-UTF8 backend refusal must name tracker-config.yaml"
printf '%s' "$OUT" | grep -q "Traceback" && fail "invalid-UTF8 backend config must refuse cleanly, never traceback"

run_engine --backend github --owner tester move --num 708 --to-status Todo
[ "$RC" = "2" ] || fail "invalid-UTF8 project config must refuse with exit 2, got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q "project_number" || fail "invalid-UTF8 project refusal must name project_number"
printf '%s' "$OUT" | grep -q -- "--project" || fail "invalid-UTF8 project refusal must name --project as the way through"
printf '%s' "$OUT" | grep -q "Traceback" && fail "invalid-UTF8 project config must refuse cleanly, never traceback"
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'CFG'
backend: github
project_number: "7"
CFG

# ============================================================================================
# E. Duplicate project_number keys are ambiguous durable state: refuse before ANY board call.
#    The old first-match parser silently selected project 7 and performed the write even though
#    the same config also declared project 8.
# ============================================================================================
printf 'In Progress' > "$WORK/status.txt"
: > "$WORK/gh.log"
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'CFG'
backend: github
project_number: "7"
project_number: "8"
CFG
run_engine --owner tester move --num 708 --to-status Todo
[ "$RC" = "2" ] || fail "duplicate project_number must refuse with exit 2, got exit $RC: $(printf '%s' "$OUT" | tail -3)"
printf '%s' "$OUT" | grep -q "project_number" || fail "duplicate-project refusal must name project_number"
printf '%s' "$OUT" | grep -q "Traceback" && fail "duplicate project_number must refuse cleanly, never traceback"
[ ! -s "$WORK/gh.log" ] || fail "duplicate project_number must refuse before any gh call; saw: $(tr '\n' ',' < "$WORK/gh.log")"
[ "$(cat "$WORK/status.txt")" = "In Progress" ] || fail "duplicate project_number must not mutate board state"
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'CFG'
backend: github
project_number: "7"
CFG

# ============================================================================================
# F. Explicit --owner/--project (the active-command path) BYPASS resolution: the move lands
#    and `gh repo view` is never called — zero extra gh calls for every playbook invocation.
#    (Red: make the fallback resolve unconditionally -> a repo-view line appears in the log.)
# ============================================================================================
printf 'In Progress' > "$WORK/status.txt"
: > "$WORK/gh.log"
run_engine --owner tester --project 7 move --num 708 --to-status Todo
[ "$RC" = "0" ] || fail "explicit-flags move must still succeed (exit 0), got exit $RC: $(printf '%s' "$OUT" | tail -3)"
grep -q "^repo view$" "$WORK/gh.log" && fail "explicit --owner/--project must bypass gh repo view resolution"
[ "$(cat "$WORK/status.txt")" = "Todo" ] || fail "explicit-flags move must land the Status write"

echo "PASS: phase1-transition-standalone-github (standalone resolution, missing/malformed/ambiguous config refusals, explicit-flag bypass)"
exit 0
