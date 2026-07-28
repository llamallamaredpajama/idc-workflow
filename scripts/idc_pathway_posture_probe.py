#!/usr/bin/env python3
"""Print a governed repo's pathway posture on ANY Python the box happens to have.

WHY THIS EXISTS. The shared Path Gate transport (`scripts/hooks/idc_interlock_gate_hook.sh`) must
decide what to do when `python3` is missing or older than 3.10 — the version the gate itself needs
(`scripts/hooks/idc_interlock_gate.py` uses 3.10-only `X | Y` annotations and raises TypeError on
import under 3.9). Before F57 that branch was `|| exit 0`, i.e. ALLOW: in `controlled`/`app-locked`
mode the whole enforcement leg silently permitted every mutation, emitting nothing. The correct
posture is the one this PR's own git hooks already take — refuse — but refusing must be scoped to
the repos whose published contract actually promises a hard deny. `off` promises the opposite
(observe and allow), and a filesystem-backed repo defaults to `off`, so a blanket deny would brick
ordinary work in every governed repo on an old interpreter.

So the wrapper needs the mode, and it needs it WITHOUT the interpreter that cannot run the gate.
The load-bearing fact that makes this cheap: `idc_path_gate.pathway_mode()` is plain 3.9-compatible
code (no `X | Y` in an evaluated position), so the SHIPPED parser can answer even on the degraded
runtime. This probe is a thin, exception-proof shim around exactly that call — deliberately NOT a
second config parser, because a divergent shell/awk reimplementation of the mode rules is precisely
how a gate starts disagreeing with itself.

CONTRACT. Prints exactly one token on stdout and always exits 0 — the token IS the answer:

    off | controlled | app-locked   the mode the shipped parser read
    unknown                         the posture could NOT be established (the parser is
                                    unimportable on this interpreter, the repo path is bad, or the
                                    parser raised). The caller MUST treat this as enforcing:
                                    "cannot tell" is never evidence of a non-enforcing repo.

`unknown` also covers `idc_path_gate.UNKNOWN_MODE` — a config that DECLARES an unrecognized mode —
which the runtime already fails closed on (F10). Both reach the caller as "fail closed".

Written for old interpreters on purpose: no annotations, no f-strings, no walrus, stdlib only. It
must survive the very runtimes it exists to diagnose.

    python3 scripts/idc_pathway_posture_probe.py <repo-root>
"""
import os
import sys

UNKNOWN = "unknown"


def probe(repo):
    """The posture token for `repo` — never raises, never blocks, no writes."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import idc_path_gate

        mode = idc_path_gate.pathway_mode(repo)
        if mode in idc_path_gate.PATHWAY_MODES:
            return mode
        return UNKNOWN
    except BaseException:  # noqa: BLE001 — ANY failure here means "cannot tell", never "off"
        return UNKNOWN


def main(argv):
    print(probe(argv[1] if len(argv) > 1 else "."))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
