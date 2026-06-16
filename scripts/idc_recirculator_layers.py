#!/usr/bin/env python3
"""idc_recirculator_layers.py — the Recirculator's downstream sync set + gate decision (`WORKFLOW.md §4.4`).

The Recirculator is the only retrograde path, and it obeys one-way flow: changing a canonical layer
requires syncing that layer AND every layer below it, together in ONE PR (the doc chain never
half-updates). The single gate fires iff the highest affected layer is the PRD — i.e.
user-facing product function changes. There is no verdict taxonomy and no change-order file;
the PR body is the change order.

Given the highest affected layer, this helper prints the downstream sync set and the gate
decision — the deterministic core of the recirculation analysis.

Usage: idc_recirculator_layers.py <prd|spec|master|subphase|pillar>   (exit 0 ok, 2 = bad layer)
"""
import sys

CHAIN = ["prd", "spec", "master", "subphase", "pillar"]


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in CHAIN:
        sys.stderr.write(f"usage: idc_recirculator_layers.py <{'|'.join(CHAIN)}>\n")
        sys.exit(2)
    layer = sys.argv[1]
    sync = CHAIN[CHAIN.index(layer):]          # this layer + everything downstream
    gate = "yes" if layer == "prd" else "no"   # the one gate: PRD only
    print("sync: " + " ".join(sync))
    print("gate: " + gate)


if __name__ == "__main__":
    main()
