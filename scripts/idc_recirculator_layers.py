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

# Greenfield defaults applied when a gating key is ABSENT (or no --config is given): the PRD gates,
# the TRD does not. A missing/unreadable toggle must never silently DROP a gate the operator wanted.
GATING_DEFAULTS = {"prd": True, "trd": False}
_TRUE = {"on", "true", "yes"}
_FALSE = {"off", "false", "no"}


def read_gating(config_path):
    """Lift the `gating:` block from a WORKFLOW-config.yaml and resolve the prd/trd toggles.

    Dependency-free, format-specific scanner (the config ships to repos that may lack PyYAML). It
    finds the `gating:` header at any indent, then reads its `prd`/`trd` children — in block style at
    ANY deeper indent (not just two spaces) and in flow style (`gating: {prd: on, trd: off}`) — and
    strips an inline `# comment` before classifying, because the shipped WORKFLOW-config.yaml ships
    its gating lines commented (`trd: off   # ...`). An ABSENT `gating:` block falls back to the
    greenfield defaults (`prd: on`, `trd: off`); an unreadable explicit --config is a hard usage
    error (exit 2) so a brownfield's `trd: on` is never silently lost to a default-off.

    Gate-arming strictness (deliberate local divergence from the lenient house parser) — the failure
    is security-relevant because the cost of a wrongly-disarmed gate is unreviewed re-architecture
    (gotcha #7: a silent architecture rewrite on a brownfield repo that intended `trd: on`):
      * a key PRESENT but carrying an unrecognized value (typo / mis-quote) FAILS CLOSED to gated
        (True) — never falls back to off;
      * a `gating:` block that is PRESENT but yields no parseable prd/trd (a shape the scanner cannot
        read — a list/mapping with no prd/trd keys, an unreadable flow block) FAILS CLOSED — both
        switches default to gated rather than to the greenfield defaults. (The old parser only saw
        children at EXACTLY two-space indent, so a hand-edited 4-space `trd: on` fell through to the
        greenfield default-off and silently DISARMED the gate; reading any deeper indent closes that.)
    Only a PRESENT block triggers the fail-closed default; an absent block keeps the greenfield
    defaults. The house parser (`idc_governance_compile.py::parse_config_scalars`) reads such values
    leniently; here we are stricter ON PURPOSE.
    """
    try:
        lines = open(config_path, "r", encoding="utf-8").read().splitlines()
    except OSError as exc:
        sys.stderr.write(f"idc_recirculator_layers: cannot read config {config_path}: {exc}\n")
        sys.exit(2)

    def classify(key, val):
        # Strip an inline `# comment` BEFORE classifying — the shipped WORKFLOW-config.yaml ships its
        # gating lines commented (`trd: off   # ...`); a boolean toggle never legitimately holds `#`.
        val = val.split("#", 1)[0].strip().strip("'\"").lower()
        if val in _TRUE:
            return True
        if val in _FALSE:
            return False
        sys.stderr.write(
            f"idc_recirculator_layers: gating.{key} has unrecognized value "
            f"{val!r}; failing closed to gated (on)\n")
        return True

    # Locate the `gating:` header (at any indent). Blank / full-comment lines never count.
    header_idx = None
    header_indent = 0
    header_rest = ""
    for idx, raw in enumerate(lines):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key, sep, rest = stripped.partition(":")
        if sep and key.strip() == "gating":
            header_idx = idx
            header_indent = len(raw) - len(raw.lstrip(" "))
            header_rest = rest
            break

    if header_idx is None:
        # No `gating:` block at all → greenfield defaults (the PRD gates, the TRD does not).
        return dict(GATING_DEFAULTS)

    parsed = {}
    flow = header_rest.split("#", 1)[0].strip()
    if flow.startswith("{"):
        # Flow style: `gating: {prd: on, trd: off}` on the header line itself.
        for part in flow.strip("{}").split(","):
            k, sep, v = part.partition(":")
            if sep and k.strip() in GATING_DEFAULTS:
                parsed[k.strip()] = classify(k.strip(), v)
    else:
        # Block style: the `gating:` children are the following lines indented DEEPER than the
        # header — at any depth, so a 4-space `trd: on` is honored, not dropped. The block ends at
        # the first non-blank/non-comment line that dedents to the header level or beyond.
        for raw in lines[header_idx + 1:]:
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if len(raw) - len(raw.lstrip(" ")) <= header_indent:
                break
            k, sep, v = stripped.partition(":")
            if sep and k.strip() in GATING_DEFAULTS:
                parsed[k.strip()] = classify(k.strip(), v)

    # A `gating:` block IS present: start fail-closed (BOTH switches gated) and apply only the
    # toggles we positively parsed. A present-but-unparseable block therefore GATES rather than
    # silently defaulting off — closing the gotcha-#7 hole where a non-2-space `trd: on` disarmed it.
    gating = {"prd": True, "trd": True}
    gating.update(parsed)
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
