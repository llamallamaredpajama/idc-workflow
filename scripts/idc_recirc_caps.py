#!/usr/bin/env python3
"""The larger loop's RUNAWAY GUARD — a deterministic PARK / CONTINUE verdict.

The recirc->plan->build loop is recursive: a recirc fix can surface a deeper recirc event. Unbounded,
that churns all night. Two caps bound it (`WORKFLOW.md §4.3`):

  * per-issue recirc ceiling — once an issue has recirculated `ceiling` times (default 2) without
    becoming buildable-and-green, PARK it for the operator instead of re-spawning the loop on it.
  * cascade-depth cap — a recirc whose origin was itself recirc-originated carries a depth; once a
    cascade reaches `cascade_cap` (default 3), PARK the tail and report rather than recursing deeper.

The orchestrator consults this BEFORE spawning another consultant/loop on an issue. "Park" means: set
the issue Blocked + an operator-action marker + a cmux/push ping; it is a normal verdict, not an error.

CLI:
    idc_recirc_caps.py --recirc-count N --cascade-depth D [--ceiling 2] [--cascade-cap 3]

Exit codes:
    0  valid — prints `verdict: park reason=…` or `verdict: continue` to stdout.
    2  fail-closed: missing/negative/non-int counts. Nothing printed — the caller treats a non-zero
       exit as PARK+surface (a guard that can't compute its inputs must never wave the loop on).
"""
import argparse
import sys

DEFAULT_CEILING = 2
DEFAULT_CASCADE_CAP = 3


def _die(msg):
    sys.stderr.write(f"idc_recirc_caps: {msg}\n")
    sys.exit(2)


def decide(recirc_count, cascade_depth, ceiling=DEFAULT_CEILING, cascade_cap=DEFAULT_CASCADE_CAP):
    """Return 'park' if either cap is reached, else 'continue'. Inputs are non-negative ints."""
    if recirc_count >= ceiling or cascade_depth >= cascade_cap:
        return "park"
    return "continue"


def _nonneg_int(name, raw):
    try:
        v = int(raw)
    except (TypeError, ValueError):
        _die(f"{name} must be a non-negative integer, got {raw!r}")
    if v < 0:
        _die(f"{name} must be non-negative, got {v}")
    return v


def main():
    p = argparse.ArgumentParser(description="Deterministic recirc runaway guard (park/continue).")
    # parse as str so we fail-closed via _die (exit 2) on non-int, with a clear message
    p.add_argument("--recirc-count", required=True)
    p.add_argument("--cascade-depth", required=True)
    p.add_argument("--ceiling", default=str(DEFAULT_CEILING))
    p.add_argument("--cascade-cap", default=str(DEFAULT_CASCADE_CAP))
    args = p.parse_args()
    rc = _nonneg_int("--recirc-count", args.recirc_count)
    cd = _nonneg_int("--cascade-depth", args.cascade_depth)
    ceiling = _nonneg_int("--ceiling", args.ceiling)
    cap = _nonneg_int("--cascade-cap", args.cascade_cap)
    verdict = decide(rc, cd, ceiling=ceiling, cascade_cap=cap)
    if verdict == "park":
        reason = "recirc-ceiling" if rc >= ceiling else "cascade-depth"
        print(f"verdict: park reason={reason}")
    else:
        print("verdict: continue")
    sys.exit(0)


if __name__ == "__main__":
    main()
