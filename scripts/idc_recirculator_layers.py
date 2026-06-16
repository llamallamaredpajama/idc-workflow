#!/usr/bin/env python3
"""idc_recirculator_layers.py — the Recirculator's downstream sync set + gate decision (`WORKFLOW.md §4.4`).

The Recirculator is the only retrograde path, and it obeys one-way flow: changing a canonical layer
requires syncing that layer AND every layer below it, together in ONE PR (the doc chain never
half-updates). The gate fires on a *requirements*-layer change: the PRD (user-facing product
function) always gates while `gating.prd: on`, and the TRD — the `spec` layer (*how* it is built) —
gates only where the repo opts in with `gating.trd: on`. Greenfield leaves the TRD ungated;
brownfield flips it on. There is no verdict taxonomy and no change-order file; the PR body is the
change order.

Given the highest affected layer — and, optionally, the governed repo's WORKFLOW-config.yaml so the
TRD toggle is honored — this helper prints the downstream sync set and the gate decision, the
deterministic core of the recirculation analysis.

Usage: idc_recirculator_layers.py <prd|spec|master|subphase|pillar> [--config <WORKFLOW-config.yaml>]
       (exit 0 ok, 2 = bad usage / unreadable --config)

Without --config the gate uses the greenfield defaults (`gating.prd: on`, `gating.trd: off`): the
PRD gates, the TRD does not.
"""
import sys

CHAIN = ["prd", "spec", "master", "subphase", "pillar"]

# Greenfield defaults applied when a gating key is absent (or no --config is given): the PRD gates,
# the TRD does not. A missing/unreadable toggle must never silently DROP a gate the operator wanted.
GATING_DEFAULTS = {"prd": True, "trd": False}
_TRUE = {"on", "true", "yes"}
_FALSE = {"off", "false", "no"}


def read_gating(config_path):
    """Lift the `gating:` block (one level of two-space nesting) from a WORKFLOW-config.yaml.

    Dependency-free, format-specific scanner (the config ships to repos that may lack PyYAML) — the
    same shape `idc_governance_compile.py::parse_config_scalars` reads. Absent or malformed values
    fall back to the greenfield defaults; an unreadable explicit --config is a hard usage error
    (exit 2) so a brownfield's `trd: on` is never silently lost to a default-off.
    """
    gating = dict(GATING_DEFAULTS)
    try:
        lines = open(config_path, "r", encoding="utf-8").read().splitlines()
    except OSError as exc:
        sys.stderr.write(f"idc_recirculator_layers: cannot read config {config_path}: {exc}\n")
        sys.exit(2)
    in_block = False
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent == 0:
            in_block = raw.startswith("gating:")
            continue
        if in_block and indent == 2 and ":" in raw:
            key, _, val = raw.strip().partition(":")
            key = key.strip()
            val = val.strip().strip("'\"").lower()
            if key in gating and val in _TRUE:
                gating[key] = True
            elif key in gating and val in _FALSE:
                gating[key] = False
    return gating


def main():
    argv = sys.argv[1:]
    config_path = None
    if "--config" in argv:
        i = argv.index("--config")
        if i + 1 >= len(argv):
            sys.stderr.write(
                "usage: idc_recirculator_layers.py <layer> [--config <WORKFLOW-config.yaml>]\n")
            sys.exit(2)
        config_path = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if len(argv) != 1 or argv[0] not in CHAIN:
        sys.stderr.write(
            f"usage: idc_recirculator_layers.py <{'|'.join(CHAIN)}> "
            "[--config <WORKFLOW-config.yaml>]\n")
        sys.exit(2)
    layer = argv[0]
    gating = read_gating(config_path) if config_path else dict(GATING_DEFAULTS)
    sync = CHAIN[CHAIN.index(layer):]          # this layer + everything downstream
    # The gate fires on a requirements-layer change: the PRD (always, while gating.prd is on) or the
    # TRD — the `spec` layer — only when the repo opts in via gating.trd.
    gate = (layer == "prd" and gating["prd"]) or (layer == "spec" and gating["trd"])
    print("sync: " + " ".join(sync))
    print("gate: " + ("yes" if gate else "no"))


if __name__ == "__main__":
    main()
