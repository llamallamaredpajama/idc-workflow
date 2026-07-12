#!/bin/bash
# engine-terminal-fail-closed.sh — governance scenario: NO verdict-free path to Done exists.
#
# THE terminal invariant: the terminal Status (Done) is reachable ONLY through a guarded terminal op
# whose deterministic evidence guard passes — the verdict-guarded `close` for BUILT work, or the
# `dispose` disposition op for a non-verdict terminal disposition (gate-approved / retired / drained),
# each with a per-disposition evidence guard. A terminal op that resolves to NO guards is FAIL-CLOSED:
# the engine refuses it before any board write. This holds for:
#   * `dispose` with a MISSING or UNKNOWN --disposition (no disposition ⇒ no guards ⇒ refused), and
#   * ANY hand-authored terminal op that declares `guards: []` in the machine table (an operator
#     edit that tries to sneak a guard-free Done past the engine).
#
# Red-when-broken: relax the "a terminal op with no guards is refused" check in idc_transition.run
# (or give an unknown disposition a non-empty guard set) → a verdict-free path reaches Done → FAILs.
#
# Usage: bash tests/smoke/governance/engine-terminal-fail-closed.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

# ── (1) `dispose` with a MISSING or UNKNOWN disposition is refused on EVERY stage ──────────────────
# No disposition resolves to zero guards, so the engine refuses before touching the board — on a
# build item AND on every non-build item. (A real disposition is proven in dispose-*.sh.)
for spec in "Buildable:In Progress" "Consideration:Todo" "Recirculation:Todo" "Planning:Todo"; do
  stage="${spec%%:*}"; status="${spec#*:}"
  n="$(gov_seed_item "$T" --title "x on $stage" --stage "$stage" --status "$status")" || fail "seed on $stage failed"
  if eng dispose --num "$n" 2>/dev/null; then
    fail "dispose with NO --disposition reached Done on a Stage=$stage item (verdict-free path to Done)"
  fi
  [ "$(gov_field "$T" "$n" Status)" != "Done" ] || fail "denied dispose (no disposition) still drove the Stage=$stage item to Done"
  if eng dispose --disposition not-a-real-disposition --num "$n" 2>/dev/null; then
    fail "dispose with an UNKNOWN --disposition reached Done on a Stage=$stage item (verdict-free path to Done)"
  fi
  [ "$(gov_field "$T" "$n" Status)" != "Done" ] || fail "denied dispose (unknown disposition) still drove the Stage=$stage item to Done"
  echo "  ok dispose with a missing/unknown disposition is refused on a Stage=$stage item (no verdict-free Done)"
done

# ── (2) a hand-authored terminal op declaring `guards: []` is refused by the ENGINE itself ─────────
# Independent of any shipped op: the engine's structural check must refuse a guard-free terminal op
# even if an operator adds one to their machine table. Exercised via the Python API (the CLI has no
# subcommand for an arbitrary op name).
n="$(gov_seed_item "$T" --title 'a plain item' --stage Buildable --status 'In Progress')" || fail "seed failed"
python3 - "$GOV_PLUGIN/scripts" "$REPO" "$T" "$n" <<'PY' || fail "guard-free-terminal engine check failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
repo, tracker, num = sys.argv[2], sys.argv[3], int(sys.argv[4])
import idc_transition as E, idc_tracker_fs as FS
# A minimal, backend-consistent machine that declares a GUARD-FREE terminal op.
machine = {
    "statuses": list(FS.STATUSES), "stages": list(FS.STAGES),
    "terminal_status": "Done", "worked_status": "In Progress",
    "worked_forbidden_stages": ["Recirculation", "Consideration"],
    "ops": {"badterminal": {"kind": "terminal", "to_status": "Done", "guards": []},
            # an operator-visible machine file could mis-author `dispositions` as a list/scalar
            "baddispose": {"kind": "terminal", "to_status": "Done", "dispositions": ["gate-approved"]},
            # ...or a disposition's `guards` as a non-list scalar
            "badguards": {"kind": "terminal", "to_status": "Done",
                          "dispositions": {"x": {"guards": 1}}}},
}
E.validate_machine(machine, "synthetic")  # passes: domains are in lockstep with the backend
ctx = E.fs_ctx(repo, tracker, machine=machine)
try:
    E.run("badterminal", ctx, num=num)
    print("FAIL: the engine performed a guard-free terminal op (verdict-free path to Done)"); sys.exit(1)
except E.TransitionError:
    pass
after = next(i for i in FS.load(tracker)["issues"] if i["number"] == num)["status"]
assert after != "Done", "denied guard-free terminal op still drove the item to Done"
print("  ok a hand-authored guards:[] terminal op is refused by the engine (no verdict-free Done)")
# A malformed `dispositions` (a list, not a mapping) must fail closed with a TransitionError (→ exit 2),
# never an unhandled AttributeError traceback that breaks the 0/2/3 exit-code contract.
try:
    E.run("baddispose", ctx, num=num, disposition="gate-approved")
    print("FAIL: a malformed dispositions table did not raise"); sys.exit(1)
except E.TransitionError:
    pass
except Exception as exc:  # noqa: BLE001 — an AttributeError/other here IS the bug
    print(f"FAIL: a malformed dispositions table raised {type(exc).__name__}, not a fail-closed TransitionError: {exc}"); sys.exit(1)
print("  ok a malformed `dispositions` (list, not mapping) fails closed with a TransitionError (not a traceback)")
# A disposition whose `guards` is a non-list scalar must also fail closed (not a TypeError on iterate).
try:
    E.run("badguards", ctx, num=num, disposition="x")
    print("FAIL: a scalar `guards` did not raise"); sys.exit(1)
except E.TransitionError:
    pass
except Exception as exc:  # noqa: BLE001
    print(f"FAIL: a scalar `guards` raised {type(exc).__name__}, not a fail-closed TransitionError: {exc}"); sys.exit(1)
print("  ok a disposition with a non-list `guards` scalar fails closed with a TransitionError (not a traceback)")
PY

# ── (3) a guarded `close` DOES reach Done (Done is reachable — just only through a guarded door) ────
n="$(gov_seed_item "$T" --title 'proper build' --stage Buildable --status 'In Progress')" || fail "seed failed"
cat > "$REPO/v.json" <<JSON
{"verdict":"PASS","pr":9,"issue":$n,"findings":[]}
JSON
eng close --num "$n" --verdict "$REPO/v.json" --pr 9 >/dev/null 2>&1 || fail "the guarded close path to Done is broken"
[ "$(gov_field "$T" "$n" Status)" = "Done" ] || fail "guarded close did not reach Done"
echo "  ok the guarded close (valid, passing, item-owning verdict) DOES reach Done — a guarded door"

echo "PASS: no verdict-free path to Done — dispose with a missing/unknown disposition AND a hand-authored guards:[] terminal op are both fail-closed on every stage; only a guarded close/dispose reaches Done"
